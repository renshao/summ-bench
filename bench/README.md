# bench/ — container registry pull-speed benchmark

End-to-end harness that provisions an Azure environment, deploys two
`distribution/distribution` registry instances on the same VM (one
filesystem-backed on local NVMe, one Azure-Blob-backed), mirrors a curated set
of public ML/CUDA images into both, and runs a Rust load tester from a separate
VM in the same region. Output: per-pull p50/p90/p95/p99 latencies and per-pull
throughput (MB/s), uploaded to an Azure Blob container.

Phase 1 supports Azure only. Layout reserves room for AWS/GCP next.

## Layout

```
bench/
  bench.sh                    # single entry point
  populate.sh                 # runs on registry VM (image mirror via crane)
  config/
    images.txt                # curated public ML/CUDA refs (default corpus)
    images-smoke.txt          # 3 small images for fast pipeline validation
    bench.yaml                # reference defaults (documentation)
  terraform/
    azure/                    # azurerm Terraform module
  ansible/
    registry-setup.yml        # Docker, NVMe, distribution v3 (×2 ports)
    loadtester-setup.yml      # Rust toolchain, build loadtest
    templates/                # distribution config + docker-compose
  loadtest/                   # Rust crate (tokio + reqwest)
  reports/                    # written by bench.sh on each run
```

## Prerequisites (operator workstation)

- `terraform` (>= 1.6) or `tofu`
- `ansible` (>= 9) with `community.docker`, `ansible.posix`, `community.general` collections
- `az` CLI, signed in (`az login`)
- `jq`, `ssh`, `scp`, `rsync`
- Optional: `azcopy` (for uploading reports to the blob container)

Install ansible collections:

```
ansible-galaxy collection install community.docker ansible.posix community.general
```

## One-time setup

```
cd bench/terraform/azure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set operator_cidr to YOUR_PUBLIC_IP/32.
# (curl -s ifconfig.me)
```

## Running

Smoke run (alpine/nginx/postgres, end-to-end in ~5 min, dollars-not-tens-of-dollars cost):

```
./bench/bench.sh --smoke
```

Real run with the curated ML corpus:

```
./bench/bench.sh
```

Useful flags:

- `--concurrency 4` — pull 4 images in parallel (default sequential)
- `--iterations 3` — pull each (repo, tag) 3 times (more samples for percentiles)
- `--destroy` — terraform destroy after the run (default: leave running)
- `--skip-provision` — reuse existing terraform state, skip apply
- `--skip-populate` — registry already has images; skip mirror
- `--skip-loadtest` — only provision + populate

## What gets measured

Per-pull (one repo:tag):

1. Start clock.
2. `GET /v2/<repo>/manifests/<tag>` — accept all standard manifest types.
3. If image index → fetch `linux/amd64` sub-manifest by digest.
4. Concurrently fetch all blobs (config + layers) — drain bodies into a sink, no
   disk write, no decompression. Default per-image fanout: 3 (containerd default).
5. Stop clock when last byte received.

Aggregates: min / p50 / p90 / p95 / p99 / max / mean for both per-pull duration
(ms) and per-pull throughput (MB/s), success/fail counts, total bytes, total
wall-clock.

## Two scenarios

The harness runs the load tester twice against two distribution instances
co-located on the same VM, with OS page cache dropped between runs:

- `fs`    — `:5000`, `storage.filesystem` driver on local NVMe
- `azure` — `:5001`, `storage.azure` driver on the provisioned Storage Account

Why same VM: the load tester is the client; the bottleneck is registry+storage
reads and the link between the two VMs. Co-locating both registries lets us
reuse one image population and avoid skew from two slightly different VMs.

## Outputs

After a run:

```
bench/reports/<run-id>/
  terraform.json              # captured outputs
  populate-report.json        # which images were mirrored, durations, sizes
  report-fs.json              # full per-pull samples + aggregates (FS scenario)
  report-azure.json           # ditto, Azure-Blob scenario
  summary.md                  # combined Markdown table
```

Plus all of the above uploaded to the `bench-reports` blob container under
`<run-id>/` (when `azcopy` is available locally).

## Cost

Standard_L8s_v3 (~$0.70/hr in eastus) + Standard_D8s_v5 (~$0.40/hr) +
trivial storage. A 1-hour run is dollars, not tens of dollars. The default is
`--keep` (leave infra up after run); you should `--destroy` once you've
inspected results.

## Troubleshooting

- **`terraform apply` complains about quotas**: `Standard_L8s_v3` and the
  Premium SSD it uses have regional vCPU quotas; switch region or request a
  quota increase.
- **Crane copy from Docker Hub fails with 429**: anonymous Docker Hub limits.
  Either `docker login` first, or replace the offending images in
  `config/images.txt` with mirrors.
- **Registry container OOMs on multi-GB pushes**: bump VM SKU; the registry
  uses a goroutine per upload but still buffers manifest content.
- **NVMe device not found in registry-setup.yml**: confirm the VM SKU is an
  Lsv3 family (or other SKU with local NVMe). DXSv5 etc. don't have local NVMe.

## Phase 2 (deferred)

- AWS provider (`terraform/aws/` mirroring the Azure module — EC2 with instance
  store NVMe, S3 bucket for the registry, a second container in the same bucket
  for reports).
- GCP provider.
- Concurrency sweep mode (1, 4, 16) producing a curve.
- Compare against alternatives: Harbor, zot, Spegel.
