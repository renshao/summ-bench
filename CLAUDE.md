# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

A **container registry implementation benchmark** — not a registry itself. It
provisions a cloud VM, installs several registry implementations on it, mirrors
an identical image corpus into each, then pulls from one implementation at a
time and compares them.

The comparison axis is the **registry software**. Every engine runs on the same
VM, against the same local NVMe, one at a time, over a byte-identical image list
— so a difference in the numbers is a difference in the registry.

Currently compared: **distribution/distribution** (Go, the reference registry)
and **summ** (Rust, a sibling checkout at `../summ`).

Both **Azure** and **AWS** are implemented. Select with `--provider azure|aws`
(default: `azure`).

Tech stack: Bash (orchestration), Rust (load tester), Terraform (Azure + AWS
IaC), Ansible (VM config), `jq` (engine catalog + report parsing).

## Running the Benchmark

```bash
# Smoke run — 3 small images, validates the whole pipeline
./bench/bench.sh --smoke

# The headline comparison
./bench/bench.sh --engines distribution,summ-rocks --iterations 3 --concurrency 4

# Three interleaved rounds (A,B,A,B,A,B) to expose machine drift
./bench/bench.sh --smoke --rounds 3

# Both summ metadata engines against the baseline
./bench/bench.sh --engines distribution,summ-rocks,summ-redb

# The original storage-backend comparison, still available
./bench/bench.sh --provider aws --engines distribution,distribution-s3

# Reuse existing infra / registry contents
./bench/bench.sh --skip-provision --skip-populate

# Tear down after the run
./bench/bench.sh --destroy

# List every known engine
./bench/bench.sh --list-engines
```

Output lands in `bench/reports/<YYYYMMDD-HHMMSS>/`: `summary.md`,
`report-<engine>-r<round>.json`, `populate-report.json`,
`engines-selected.json`, `terraform.json` (sensitive values redacted).

## The Engine Catalog

`bench/config/engines.json` is the single source of truth for what can be
benchmarked. `bench.sh` reads it with `jq`, resolves the selected engines into
`engines-selected.json`, and both Ansible and `populate.sh` consume that result.
**Add a new engine there and nowhere else.**

| Engine | Implementation | Storage | Port | Default |
|--------|----------------|---------|------|---------|
| `distribution` | distribution/distribution | local NVMe | 5000 | yes |
| `summ-rocks` | summ, RocksDB metadata | local NVMe | 5010 | yes |
| `summ-redb` | summ, redb metadata | local NVMe | 5011 | no |
| `distribution-azure` | distribution/distribution | Azure Blob | 5001 | no |
| `distribution-s3` | distribution/distribution | S3 | 5002 | no |

summ is built from the **local working tree** (`--summ-src`, default `../summ`),
so a run measures work in progress. The revision built — with a `-dirty` marker
— is recorded in every report.

## Building the Rust Load Tester

```bash
cd bench/loadtest
cargo build --release        # outputs target/release/loadtest
cargo clippy
cargo fmt
```

Ansible builds this on the load tester VM during provisioning. Local builds are
only needed for development.

## Syntax Checking

```bash
bash -n bench/bench.sh
bash -n bench/populate.sh
cd bench/ansible && ansible-playbook --syntax-check registry-setup.yml \
  --extra-vars "@../reports/<run>/engines-selected.json"
```

Both shell scripts stay **bash 3.2 compatible** — that is what stock macOS
ships, and `env bash` resolves to it on the workstation. No associative arrays,
no `mapfile`. The engine catalog is JSON precisely because of this.

## Architecture

```
bench.sh (workstation)
  ├── terraform apply           → registry VM (local NVMe) + load tester VM
  ├── resolve engines.json      → engines-selected.json (the one resolution point)
  ├── ansible registry-setup    → roles: local_disk, tooling, distribution, summ
  │                                one systemd unit per engine, all left stopped
  ├── ansible loadtester-setup  → Rust toolchain, cargo build --release
  ├── populate.sh (via SSH)     → crane copy public → engine[0] → every other engine
  ├── per round, per engine     → stop all, start one, drop page cache, loadtest
  └── render summary.md         → percentiles pooled from raw samples across rounds
```

**Key design decisions:**

- **Every engine on one VM.** Eliminates provisioning skew; the bottleneck is
  storage I/O and intra-datacenter network.
- **One engine runs at a time.** An idle engine still holds page cache and a
  RocksDB block cache. `bench.sh` stops all units and starts exactly one.
- **Both run natively, no containers.** Comparing a host process against a
  containerised one folds cgroup limits and an overlay filesystem into one side
  of the measurement.
- **Identical pull set and order.** Scenarios read the same `--images-file`
  rather than each registry's catalog; catalog ordering is
  implementation-defined, and a different order is a different benchmark.
- **Cold every time.** The engine is restarted per scenario, then the page cache
  is dropped after it starts.
- **Round-robin rounds.** `--rounds N` interleaves A,B,A,B rather than A,A,B,B so
  machine drift penalises both engines evenly. Percentiles are pooled from raw
  samples — the mean of two p95s is not the p95 of the union.
- **Populate is setup, not a benchmark.** The fan-out source also absorbs the
  pull from the public registry, so its push time is not comparable to the
  others'. `summary.md` labels this rather than inviting a false reading.
- The Rust client simulates containerd: `GET manifest → GET all blobs
  concurrently` (`--blob-concurrency`, default 3).
- HDR histograms for the per-run aggregates; the cross-round summary recomputes
  percentiles from raw samples.

## Key Files

| File | Role |
|------|------|
| `bench/config/engines.json` | **The engine catalog** — add engines here |
| `bench/bench.sh` | Main orchestrator — all phases |
| `bench/populate.sh` | Image mirror, N-engine fan-out (runs on registry VM) |
| `bench/loadtest/src/main.rs` | Load tester CLI |
| `bench/loadtest/src/client.rs` | OCI Registry V2 API client |
| `bench/loadtest/src/metrics.rs` | HDR histogram aggregations |
| `bench/loadtest/src/report.rs` | `PullSample` + `Report` serialization |
| `bench/ansible/registry-setup.yml` | Registry VM, every provider and engine |
| `bench/ansible/roles/local_disk/` | NVMe detect, format, mount at `/mnt` |
| `bench/ansible/roles/tooling/` | Base packages + crane |
| `bench/ansible/roles/distribution/` | Release binary, config + unit per engine |
| `bench/ansible/roles/summ/` | rsync source, cargo build, unit per engine |
| `bench/ansible/tasks/verify-engine.yml` | Start, health-check, stop — per engine |
| `bench/terraform/azure/`, `bench/terraform/aws/` | Infrastructure |
| `bench/config/images.txt` | Curated ML/CUDA image corpus (~100 GB) |
| `bench/config/images-smoke.txt` | 3 small images for smoke validation |
| `notes/fs_limit.md` | Performance analysis and capacity planning |

## Infrastructure Defaults

**Azure:**
- Registry VM: `Standard_L8s_v3` — 8 vCPU, 64 GiB RAM, ~1.92 TB NVMe
- Load tester VM: `Standard_D8s_v5` — 8 vCPU, 32 GiB RAM
- NVMe throughput: ~3 GB/s sequential; network cap: ~1.56 GB/s (12.5 Gbps)

**AWS:**
- Registry VM: `m6id.2xlarge` — 8 vCPU, 32 GiB RAM, 474 GB NVMe instance store
- Load tester VM: `c6i.large` — 2 vCPU, 4 GiB RAM

The first run including a summ engine compiles RocksDB from source on the VM
(~10 min). It is cached across runs; `--skip-provision` skips it.
