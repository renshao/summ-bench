# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

A **container registry pull-speed benchmark harness** — not a registry implementation. It provisions cloud VMs, deploys two `distribution/distribution` registry instances (one filesystem-backed, one blob-storage-backed), mirrors ML/CUDA images into both, then benchmarks cold-cache pull performance from a separate load tester VM.

Both **Azure** (filesystem + Azure Blob) and **AWS** (filesystem + S3) providers are implemented. Select with `--provider azure|aws` (default: azure).

Tech stack: Bash (orchestration), Rust (load tester), Terraform (Azure + AWS IaC), Ansible (VM config), `jq` (report parsing).

## Running the Benchmark

```bash
# Smoke run — 3 small images, ~5 min, validates the full pipeline
./bench/bench.sh --smoke

# AWS provider (default is azure)
./bench/bench.sh --provider aws --smoke

# Production run
./bench/bench.sh --iterations 3 --concurrency 4

# Reuse existing infra (skip terraform/ansible)
./bench/bench.sh --skip-provision

# Reuse existing registry contents
./bench/bench.sh --skip-populate

# Tear down after run
./bench/bench.sh --destroy

# Supply Docker Hub credentials to crane (avoids pull-rate limits)
./bench/bench.sh --crane-registry registry-1.docker.io --crane-user <user> --crane-password <token>
```

All output lands in `bench/reports/<YYYYMMDD-HHMMSS>/`: `terraform.json`, `populate-report.json`, `report-fs.json`, `report-blob.json`, `summary.md`.

## Building the Rust Load Tester

```bash
cd bench/loadtest
cargo build --release        # outputs target/release/loadtest
cargo clippy
cargo fmt
```

Ansible builds this automatically on the load tester VM during provisioning. Local builds are only needed for development.

## One-time setup per provider

```bash
# Azure
cd bench/terraform/azure && cp terraform.tfvars.example terraform.tfvars
# Set operator_cidr = "YOUR_PUBLIC_IP/32" (curl -s ifconfig.me)

# AWS
cd bench/terraform/aws && cp terraform.tfvars.example terraform.tfvars
# Set operator_cidr = "YOUR_PUBLIC_IP/32"
# AWS auth: aws configure  OR  set AWS_PROFILE / AWS_* env vars
```

## Syntax Checking

```bash
bash -n bench/bench.sh
bash -n bench/populate.sh
```

## Architecture

```
bench.sh (workstation)
  ├── terraform apply         → Azure or AWS: registry VM + load tester VM + storage
  ├── ansible registry-setup  → NVMe format, Docker, two distribution registries
  │                              :5000 = filesystem on /mnt (NVMe)
  │                              :5001 = Azure Blob driver (Azure) / S3 driver (AWS)
  ├── ansible loadtester-setup → Rust toolchain, cargo build --release
  ├── populate.sh (via SSH)   → crane copy public images → :5000 → :5001
  ├── run_scenario() ×2       → drop page cache, run loadtest binary, scp report
  └── render summary.md       → jq extracts percentiles from both JSON reports
```

**Key design decisions:**
- Both registries run on the same VM to eliminate provisioning skew; the bottleneck is storage I/O and intra-datacenter network.
- Page cache is dropped between scenarios (filesystem then blob) for cold-cache realism.
- The Rust client simulates containerd: `GET manifest → GET all blobs concurrently` (configurable fanout via `--blob-concurrency`, default 3).
- HDR histograms for p50/p90/p95/p99 — more accurate for tail latencies than sorting.

## Key Files

| File | Role |
|------|------|
| `bench/bench.sh` | Main orchestrator — all phases |
| `bench/populate.sh` | Image mirror script (runs on registry VM via SSH) |
| `bench/loadtest/src/main.rs` | Load tester CLI: catalog discovery, concurrent pulls |
| `bench/loadtest/src/client.rs` | OCI Registry V2 API client |
| `bench/loadtest/src/metrics.rs` | HDR histogram aggregations |
| `bench/loadtest/src/report.rs` | `PullSample` + `Report` serialization |
| `bench/terraform/azure/` | Azure infrastructure (VMs, VNet, storage, SAS URLs) |
| `bench/terraform/aws/` | AWS infrastructure (EC2, VPC, S3, EIP) |
| `bench/ansible/registry-setup.yml` | Registry VM config (Azure) |
| `bench/ansible/registry-setup-aws.yml` | Registry VM config (AWS, S3 driver) |
| `bench/ansible/loadtester-setup.yml` | Load tester VM config (Rust toolchain + build) |
| `bench/ansible/loadtester-setup-aws.yml` | Load tester VM config (AWS variant) |
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
