# bench/ — container registry pull-speed benchmark

End-to-end harness that provisions cloud VMs, deploys two
`distribution/distribution` registry instances on the same VM (one
filesystem-backed on local NVMe, one blob-storage-backed), mirrors a curated
set of public ML/CUDA images into both, and runs a Rust load tester from a
separate VM in the same region. Output: per-pull p50/p90/p95/p99 latencies and
per-pull throughput (MB/s).

Both **Azure** (Azure Blob storage driver) and **AWS** (S3 storage driver) are
supported. Select with `--provider azure|aws` (default: `azure`).

## Layout

```
bench/
  bench.sh                    # single entry point
  populate.sh                 # runs on registry VM (image mirror via crane)
  config/
    images.txt                # curated public ML/CUDA refs (default corpus)
    images-smoke.txt          # 3 small images for fast pipeline validation
  terraform/
    azure/                    # azurerm Terraform module
    aws/                      # AWS Terraform module (EC2, VPC, S3)
  ansible/
    registry-setup.yml        # Docker, NVMe, distribution v3 (×2 ports) — Azure
    registry-setup-aws.yml    # same, S3 storage driver — AWS
    loadtester-setup.yml      # Rust toolchain, build loadtest — Azure
    loadtester-setup-aws.yml  # same — AWS
    templates/                # distribution config + docker-compose
  loadtest/                   # Rust crate (tokio + reqwest)
  reports/                    # written by bench.sh on each run
```

## Prerequisites (operator workstation)

- `terraform` (>= 1.6) or `tofu`
- `ansible` (>= 9) with `community.docker`, `ansible.posix`, `community.general` collections
- Cloud CLI: `az` (Azure, signed in via `az login`) **or** `aws` (AWS, configured via `aws configure` or `AWS_PROFILE`/`AWS_*` env vars)
- `jq`, `ssh`, `scp`, `rsync`

Install ansible collections:

```
ansible-galaxy collection install community.docker ansible.posix community.general
```

## One-time setup

### Azure

```bash
cd bench/terraform/azure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set operator_cidr to YOUR_PUBLIC_IP/32
# (curl -s ifconfig.me)
```

### AWS

```bash
cd bench/terraform/aws
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set operator_cidr to YOUR_PUBLIC_IP/32
# AWS auth: aws configure  OR  set AWS_PROFILE / AWS_* env vars
```

## Running

Smoke run (alpine/nginx/postgres, end-to-end in ~5 min):

```bash
# Azure (default)
./bench/bench.sh --smoke

# AWS
./bench/bench.sh --provider aws --smoke
```

Real run with the curated ML corpus:

```bash
./bench/bench.sh
./bench/bench.sh --provider aws
```

Useful flags:

- `--provider azure|aws` — cloud provider (default: `azure`)
- `--concurrency 4` — pull 4 images in parallel (default sequential)
- `--iterations 3` — pull each (repo, tag) 3 times (more samples for percentiles)
- `--destroy` — terraform destroy after the run (default: leave running)
- `--skip-provision` — reuse existing terraform state, skip apply
- `--skip-populate` — registry already has images; skip mirror
- `--skip-loadtest` — only provision + populate
- `--crane-registry / --crane-user / --crane-password` — Docker Hub auth for crane (avoids rate limits)

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
- `azure` / `s3` — `:5001`, blob storage driver (Azure Blob or S3 depending on `--provider`)

Why same VM: the load tester is the client; the bottleneck is registry+storage
reads and the link between the two VMs. Co-locating both registries lets us
reuse one image population and avoid skew from two slightly different VMs.

## Outputs

After a run:

```
bench/reports/<run-id>/
  terraform.json              # captured terraform outputs
  populate-report.json        # which images were mirrored, durations, sizes
  report-fs.json              # full per-pull samples + aggregates (FS scenario)
  report-blob.json            # ditto, blob storage scenario (Azure or S3)
  summary.md                  # combined Markdown table
```

## Infrastructure defaults

| Provider | Registry VM | Load tester VM |
|----------|-------------|----------------|
| Azure | `Standard_L8s_v3` — 8 vCPU, 64 GiB RAM, ~1.92 TB NVMe | `Standard_D8s_v5` — 8 vCPU, 32 GiB RAM |
| AWS | `m6id.2xlarge` — 8 vCPU, 32 GiB RAM, 474 GB NVMe instance store | `c6i.large` — 2 vCPU, 4 GiB RAM |

## Cost

**Azure:** `Standard_L8s_v3` (~$0.70/hr in eastus) + `Standard_D8s_v5` (~$0.40/hr) + trivial storage.

**AWS:** `m6id.2xlarge` (~$0.54/hr in us-east-1) + `c6i.large` (~$0.09/hr) + S3 storage (negligible).

A 1-hour run is dollars, not tens of dollars. The default is `--keep` (leave infra up after run); use `--destroy` once you've inspected results.

## Troubleshooting

- **`terraform apply` complains about quotas (Azure)**: `Standard_L8s_v3` and the Premium SSD it uses have regional vCPU quotas; switch region or request a quota increase.
- **Crane copy from Docker Hub fails with 429**: anonymous Docker Hub rate limit. Use `--crane-registry registry-1.docker.io --crane-user <user> --crane-password <token>`, or replace offending images in `config/images.txt` with mirrors.
- **Registry container OOMs on multi-GB pushes**: bump VM SKU; the registry uses a goroutine per upload but still buffers manifest content.
- **NVMe device not found (Azure)**: confirm the VM SKU is Lsv3 family. DSv5 etc. don't have local NVMe.
- **NVMe device not found (AWS)**: confirm the instance type has an instance store (e.g. `m6id`, `i3en`). `c6i` / `m6i` do not.
- **AWS auth failure**: run `aws sts get-caller-identity` to verify credentials before running the harness.

## Useful commands

SSH into registry VM (Azure):
```bash
ssh -i (terraform -chdir=bench/terraform/azure output -raw ssh_private_key_path) \
    (terraform -chdir=bench/terraform/azure output -raw admin_username)@(terraform -chdir=bench/terraform/azure output -raw registry_public_ip)
```

SSH into registry VM (AWS):
```bash
ssh -i (terraform -chdir=bench/terraform/aws output -raw ssh_private_key_path) \
    (terraform -chdir=bench/terraform/aws output -raw admin_username)@(terraform -chdir=bench/terraform/aws output -raw registry_public_ip)
```
