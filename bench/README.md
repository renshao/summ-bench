# bench/ — container registry implementation benchmark

End-to-end harness that provisions a cloud VM, installs several container
registry **implementations** on it, mirrors an identical image corpus into each,
then pulls from one implementation at a time and compares them. Output:
per-pull p50/p90/p95/p99 latency, per-pull throughput (MB/s), and a speedup
column against a chosen baseline.

The comparison axis is the registry software. Every engine runs on the same VM,
against the same local NVMe, one at a time, over a byte-identical image list —
so a difference in the numbers is a difference in the registry.

Both **Azure** and **AWS** are supported. Select with `--provider azure|aws`
(default: `azure`).

## Engines

An *engine* is one registry process under test. The catalog lives in
`config/engines.json` and is the single source of truth — `bench.sh`,
`populate.sh` and the Ansible playbook all read it, so a new engine is added in
exactly one place.

| Engine | Implementation | Storage | Port | In default set |
|--------|----------------|---------|------|----------------|
| `distribution` | distribution/distribution (Go) | local NVMe | 5000 | yes |
| `summ-rocks` | summ (Rust), RocksDB metadata | local NVMe | 5010 | yes |
| `summ-redb` | summ (Rust), redb metadata | local NVMe | 5011 | no |
| `distribution-azure` | distribution/distribution | Azure Blob | 5001 | no |
| `distribution-s3` | distribution/distribution | S3 | 5002 | no |

`distribution-azure` and `distribution-s3` are the original storage-backend
comparison, kept but out of the default set: storage backend and registry
implementation are independent variables, and mixing them in one table makes
neither readable. Benchmark them deliberately:

```bash
./bench.sh --provider aws --engines distribution,distribution-s3
```

`summ` is built from your **local working tree** (`--summ-src`, default
`../summ`), not from a git ref, so a run measures work in progress. The exact
revision — with a `-dirty` marker — is recorded in every report.

```bash
./bench.sh --list-engines
```

## Running

```bash
# Smoke run — 3 small images, validates the whole pipeline
./bench.sh --smoke

# The headline comparison
./bench.sh --engines distribution,summ-rocks --iterations 3 --concurrency 4

# Three interleaved rounds; the per-round table shows whether the VM held steady
./bench.sh --smoke --rounds 3

# Both summ metadata engines against the baseline
./bench.sh --engines distribution,summ-rocks,summ-redb

# Reuse existing infra and registry contents
./bench.sh --skip-provision --skip-populate

# Tear down afterwards
./bench.sh --destroy
```

Output lands in `reports/<YYYYMMDD-HHMMSS>/`:

| File | Contents |
|------|----------|
| `summary.md` | The comparison tables |
| `report-<engine>-r<round>.json` | One load-test run: aggregates plus every raw sample |
| `populate-report.json` | Per-engine push durations from the mirror phase |
| `engines-selected.json` | The resolved engine specs this run used |
| `terraform.json` | Infrastructure outputs, with sensitive values redacted |

## What keeps the comparison honest

A head-to-head number is only worth reading if the two sides ran under the same
conditions. The harness enforces that:

- **One engine runs at a time.** Every engine is a systemd unit, installed
  disabled. `bench.sh` stops all of them and starts exactly one per scenario, so
  the engine under test never shares CPU or page cache with an idle competitor.
- **Both run natively.** No containers. Comparing a host process against a
  containerised one folds cgroup limits and an overlay filesystem into the
  measurement of only one side.
- **Same disk.** Every engine's data directory is `/mnt/registry-data/<engine>`
  on the same local NVMe.
- **Identical pull set and order.** All scenarios read the same `--images-file`
  rather than discovering each registry's catalog. Catalog ordering is
  implementation-defined, and a different order is a different benchmark.
- **Cold every time.** The engine is restarted before each scenario (resetting
  distribution's blob descriptor cache and summ's RocksDB block cache) and the
  page cache is dropped after it starts.
- **Round-robin rounds.** `--rounds N` interleaves engines A,B,A,B rather than
  A,A,B,B, so a machine that drifts slower over the run penalises both engines
  evenly. Percentiles are pooled from raw samples across rounds — the mean of
  two p95s is not the p95 of the union.
- **Attributable.** Each report records the engine build measured: a summ git
  revision or a distribution release tag.

## Layout

```
bench/
  bench.sh                      # single entry point, all phases
  populate.sh                   # runs on the registry VM (image mirror via crane)
  config/
    engines.json                # THE engine catalog — add engines here
    images.txt                  # curated public ML/CUDA refs (default corpus)
    images-smoke.txt            # 3 small images for fast validation
  loadtest/                     # Rust load tester (containerd-shaped pull)
  ansible/
    registry-setup.yml          # one playbook, every provider and engine
    loadtester-setup.yml
    tasks/verify-engine.yml     # start, health-check, stop — per engine
    roles/
      local_disk/               # NVMe detect, format, mount at /mnt
      tooling/                  # base packages + crane
      distribution/             # release binary, config + unit per engine
      summ/                     # rsync source, cargo build, unit per engine
  terraform/azure/ , terraform/aws/
  reports/<run-id>/
```

## Flags

Run `./bench.sh --help` for the full list. The ones that shape a comparison:

| Flag | Default | Purpose |
|------|---------|---------|
| `--engines <a,b,...>` | `distribution,summ-rocks` | Which implementations to compare |
| `--baseline <engine>` | `distribution` | What the speedup column divides by |
| `--rounds <n>` | `1` | Interleaved repeats of the whole sweep |
| `--summ-src <path>` | `../summ` | Local summ working tree to build |
| `--iterations <n>` | `1` | Pulls per image within one scenario |
| `--concurrency <n>` | `1` | Parallel image pulls |
| `--blob-concurrency <n>` | `3` | Per-image blob fanout (containerd's default) |

## One-time setup

```bash
# Azure
cd terraform/azure && cp terraform.tfvars.example terraform.tfvars
# set operator_cidr = "YOUR_PUBLIC_IP/32"   (curl -s ifconfig.me)
# auth: az login

# AWS
cd terraform/aws && cp terraform.tfvars.example terraform.tfvars
# set operator_cidr = "YOUR_PUBLIC_IP/32"
# auth: aws configure, or AWS_PROFILE / AWS_* env vars
```

The first run that includes a summ engine compiles RocksDB from source on the
VM (~10 min). It is cached across runs; `--skip-provision` skips it entirely.

## Managed registries

`--managed-registry <host>` benchmarks a hosted registry (ACR, ECR, ...)
instead of provisioning engines. Image refs are rewritten to the target host and
registry setup and populate are skipped.

```bash
./bench.sh --managed-registry myreg.azurecr.io \
           --registry-user <client-id> --registry-password <secret>
```

Note this is *not* an apples-to-apples comparison with the self-hosted engines:
different hardware, different network path, and a cold local cache. It answers
"how fast is my managed registry", not "which implementation is faster".
