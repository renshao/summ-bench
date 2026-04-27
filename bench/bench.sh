#!/usr/bin/env bash
# bench.sh — end-to-end harness:
#   Self-hosted mode  (default): provision cloud infra, mirror images into two
#     distribution instances (fs + blob-backed), run Rust load tester.
#   Managed mode (--managed-registry): skip registry setup/populate; run the
#     load tester against an existing managed registry (ACR, ECR, etc.) with
#     image refs rewritten from images.txt to match the target registry.

set -euo pipefail

# ---------- paths ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$SCRIPT_DIR/ansible"
LOADTEST_DIR="$SCRIPT_DIR/loadtest"
REPORTS_DIR="$SCRIPT_DIR/reports"
CONFIG_DIR="$SCRIPT_DIR/config"

# ---------- defaults ----------
PROVIDER="azure"
IMAGES_FILE="$CONFIG_DIR/images.txt"
SMOKE=false
DESTROY=false
KEEP=true
CONCURRENCY=1
ITERATIONS=1
BLOB_CONCURRENCY=3
SKIP_PROVISION=false
SKIP_POPULATE=false
SKIP_LOADTEST=false
CRANE_REGISTRY=""
CRANE_USER=""
CRANE_PASSWORD=""
MANAGED_REGISTRY=""
REGISTRY_USER=""
REGISTRY_PASSWORD=""
RUN_ID="$(date +%Y%m%d-%H%M%S)"

usage() {
  cat <<EOF
Usage: $0 [options]

Self-hosted mode (default):
  --provider <azure|aws>        Cloud provider (default: azure)
  --images <file>               Override images list (default: config/images.txt)
  --smoke                       Use config/images-smoke.txt (3 small images for fast validation)
  --concurrency <n>             Parallel image pulls in load test (default: 1)
  --iterations <n>              How many times to pull each image (default: 1)
  --blob-concurrency <n>        Per-image blob fetch fanout (default: 3)
  --destroy                     terraform destroy at end (no prompt)
  --keep                        Leave infra running after run (default)
  --skip-provision              Reuse existing terraform state (skip apply)
  --skip-populate               Reuse existing registry contents (skip image mirror)
  --skip-loadtest               Run only provisioning + populate
  --crane-registry <host>       Registry host to authenticate with crane before populating
  --crane-user <user>           Username for crane auth login
  --crane-password <pass>       Password for crane auth login

Managed registry mode:
  --managed-registry <host>     Benchmark a managed registry (ACR, ECR, etc.) instead
                                of provisioning distribution instances. Image refs in
                                images.txt are rewritten: hostnames stripped and replaced
                                with this host. Registry/populate setup is skipped.
                                Use --skip-provision to reuse an existing loadtester VM.
  --registry-user <user>        Username for managed registry auth (Bearer token exchange).
                                For ECR: "AWS". For ACR: service principal client ID.
  --registry-password <pass>    Password / token for managed registry auth.
                                For ECR: output of 'aws ecr get-login-password'.
                                For ACR: service principal secret.

  -h, --help                    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)           PROVIDER="$2"; shift 2 ;;
    --images)             IMAGES_FILE="$2"; shift 2 ;;
    --smoke)              SMOKE=true; shift ;;
    --concurrency)        CONCURRENCY="$2"; shift 2 ;;
    --iterations)         ITERATIONS="$2"; shift 2 ;;
    --blob-concurrency)   BLOB_CONCURRENCY="$2"; shift 2 ;;
    --destroy)            DESTROY=true; KEEP=false; shift ;;
    --keep)               KEEP=true; DESTROY=false; shift ;;
    --skip-provision)     SKIP_PROVISION=true; shift ;;
    --skip-populate)      SKIP_POPULATE=true; shift ;;
    --skip-loadtest)      SKIP_LOADTEST=true; shift ;;
    --crane-registry)     CRANE_REGISTRY="$2"; shift 2 ;;
    --crane-user)         CRANE_USER="$2"; shift 2 ;;
    --crane-password)     CRANE_PASSWORD="$2"; shift 2 ;;
    --managed-registry)   MANAGED_REGISTRY="$2"; shift 2 ;;
    --registry-user)      REGISTRY_USER="$2"; shift 2 ;;
    --registry-password)  REGISTRY_PASSWORD="$2"; shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$SMOKE" == true ]]; then
  IMAGES_FILE="$CONFIG_DIR/images-smoke.txt"
fi

if [[ "$PROVIDER" != "azure" && "$PROVIDER" != "aws" ]]; then
  echo "ERROR: unsupported provider '$PROVIDER'. Use azure or aws." >&2
  exit 2
fi

# ---------- provider-specific paths ----------
case "$PROVIDER" in
  azure)
    TERRAFORM_DIR="$SCRIPT_DIR/terraform/azure"
    REGISTRY_SETUP_PLAYBOOK="registry-setup.yml"
    LOADTESTER_SETUP_PLAYBOOK="loadtester-setup.yml"
    BLOB_SCENARIO="azure"
    ;;
  aws)
    TERRAFORM_DIR="$SCRIPT_DIR/terraform/aws"
    REGISTRY_SETUP_PLAYBOOK="registry-setup-aws.yml"
    LOADTESTER_SETUP_PLAYBOOK="loadtester-setup-aws.yml"
    BLOB_SCENARIO="s3"
    ;;
esac

# ---------- prereqs ----------
log() { printf '[bench %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

log "checking prerequisites..."
require terraform
require ansible-playbook
require jq
require ssh
require scp
require rsync

case "$PROVIDER" in
  azure)
    require az
    if ! az account show >/dev/null 2>&1; then
      die "az not logged in. Run 'az login' first."
    fi
    ;;
  aws)
    require aws
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
      die "aws not authenticated. Run 'aws configure' or set AWS_PROFILE / AWS_* env vars."
    fi
    ;;
esac

if [[ ! -f "$IMAGES_FILE" ]]; then
  die "images file not found: $IMAGES_FILE"
fi

if [[ ! -f "$TERRAFORM_DIR/terraform.tfvars" && "$SKIP_PROVISION" == false ]]; then
  die "Missing $TERRAFORM_DIR/terraform.tfvars. Copy terraform.tfvars.example and edit."
fi

mkdir -p "$REPORTS_DIR"
RUN_DIR="$REPORTS_DIR/$RUN_ID"
mkdir -p "$RUN_DIR"

# ---------- 1. terraform ----------
if [[ "$SKIP_PROVISION" == false ]]; then
  log "terraform init"
  terraform -chdir="$TERRAFORM_DIR" init -input=false -upgrade >/dev/null
  log "terraform apply"
  terraform -chdir="$TERRAFORM_DIR" apply -input=false -auto-approve
fi

TF_JSON="$RUN_DIR/terraform.json"
terraform -chdir="$TERRAFORM_DIR" output -json > "$TF_JSON"

LT_PUB=$(jq -r '.loadtester_public_ip.value' "$TF_JSON")
ADMIN=$(jq -r '.admin_username.value' "$TF_JSON")
SSH_KEY=$(jq -r '.ssh_private_key_path.value' "$TF_JSON")

if [[ -z "$MANAGED_REGISTRY" ]]; then
  REG_PUB=$(jq -r '.registry_public_ip.value' "$TF_JSON")
  REG_PRIV=$(jq -r '.registry_private_ip.value' "$TF_JSON")
  log "registry  vm: $REG_PUB (private $REG_PRIV)"
fi
log "loadtester vm: $LT_PUB"

# Provider-specific storage outputs (not needed in managed mode)
if [[ -z "$MANAGED_REGISTRY" ]]; then
  case "$PROVIDER" in
    azure)
      STORAGE_ACCT=$(jq -r '.storage_account_name.value' "$TF_JSON")
      STORAGE_KEY=$(jq -r '.storage_account_key.value' "$TF_JSON")
      REG_CONTAINER=$(jq -r '.registry_blob_container.value' "$TF_JSON")
      REPORTS_SAS=$(jq -r '.reports_sas_url.value' "$TF_JSON")
      ;;
    aws)
      S3_REGISTRY_BUCKET=$(jq -r '.s3_registry_bucket.value' "$TF_JSON")
      S3_REPORTS_BUCKET=$(jq -r '.s3_reports_bucket.value' "$TF_JSON")
      AWS_REGION=$(jq -r '.aws_region.value' "$TF_JSON")
      ;;
  esac
fi

# ---------- 2. inventory ----------
INV="$ANSIBLE_DIR/inventory/${PROVIDER}.ini"
mkdir -p "$ANSIBLE_DIR/inventory"
if [[ -n "$MANAGED_REGISTRY" ]]; then
  # Managed mode: loadtester only
  cat > "$INV" <<EOF
[loadtester]
$LT_PUB ansible_user=$ADMIN ansible_ssh_private_key_file=$SSH_KEY ansible_python_interpreter=/usr/bin/python3

[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
EOF
else
  cat > "$INV" <<EOF
[registry]
$REG_PUB ansible_user=$ADMIN ansible_ssh_private_key_file=$SSH_KEY ansible_python_interpreter=/usr/bin/python3

[loadtester]
$LT_PUB ansible_user=$ADMIN ansible_ssh_private_key_file=$SSH_KEY ansible_python_interpreter=/usr/bin/python3

[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
EOF
fi

# ---------- 3. wait for SSH ----------
ssh_lt() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$ADMIN@$LT_PUB" "$@"
}

ssh_wait() {
  local ip="$1"
  for _ in $(seq 1 30); do
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 "$ADMIN@$ip" 'echo ok' >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  die "SSH to $ip timed out"
}

if [[ -n "$MANAGED_REGISTRY" ]]; then
  log "waiting for SSH on loadtester..."
  ssh_wait "$LT_PUB"
else
  log "waiting for SSH on both VMs..."
  ssh_wait "$REG_PUB"
  ssh_wait "$LT_PUB"
fi

# ---------- 4. ansible ----------
export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"

if [[ -z "$MANAGED_REGISTRY" ]]; then
  log "ansible: $REGISTRY_SETUP_PLAYBOOK"
  case "$PROVIDER" in
    azure)
      ansible-playbook -i "$INV" "$ANSIBLE_DIR/$REGISTRY_SETUP_PLAYBOOK" \
        --extra-vars "storage_account_name=$STORAGE_ACCT" \
        --extra-vars "storage_account_key=$STORAGE_KEY" \
        --extra-vars "registry_blob_container=$REG_CONTAINER"
      ;;
    aws)
      ansible-playbook -i "$INV" "$ANSIBLE_DIR/$REGISTRY_SETUP_PLAYBOOK" \
        --extra-vars "s3_registry_bucket=$S3_REGISTRY_BUCKET" \
        --extra-vars "s3_bucket_region=$AWS_REGION"
      ;;
  esac
fi

log "ansible: $LOADTESTER_SETUP_PLAYBOOK"
ansible-playbook -i "$INV" "$ANSIBLE_DIR/$LOADTESTER_SETUP_PLAYBOOK" \
  --extra-vars "loadtest_local_dir=$LOADTEST_DIR"

# ---------- 5. populate ----------
ssh_reg() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$ADMIN@$REG_PUB" "$@"
}

if [[ -z "$MANAGED_REGISTRY" && "$SKIP_POPULATE" == false ]]; then
  log "populating registries from: $IMAGES_FILE"
  scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$SCRIPT_DIR/populate.sh" "$IMAGES_FILE" "$ADMIN@$REG_PUB:/tmp/"
  populate_env=""
  if [[ -n "$CRANE_REGISTRY" && -n "$CRANE_USER" && -n "$CRANE_PASSWORD" ]]; then
    populate_env="CRANE_REGISTRY=$(printf '%q' "$CRANE_REGISTRY") CRANE_USER=$(printf '%q' "$CRANE_USER") CRANE_PASSWORD=$(printf '%q' "$CRANE_PASSWORD")"
  fi
  ssh_reg "env $populate_env bash /tmp/populate.sh /tmp/$(basename "$IMAGES_FILE") /tmp/populate-report.json"
  scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$ADMIN@$REG_PUB:/tmp/populate-report.json" "$RUN_DIR/populate-report.json"
fi

# ---------- 6. load test ----------
if [[ "$SKIP_LOADTEST" == false ]]; then

  if [[ -n "$MANAGED_REGISTRY" ]]; then
    # ---- managed registry mode ----
    # Rewrite images.txt: strip source hostname, keep repo:tag.
    # "nvcr.io/nvidia/cuda:12.0"  -> "nvidia/cuda:12.0"
    # "ubuntu:22.04"              -> "ubuntu:22.04"
    REWRITTEN_IMAGES="$RUN_DIR/images-managed.txt"
    log "rewriting image refs for $MANAGED_REGISTRY -> $REWRITTEN_IMAGES"
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"   # strip inline comments
      line="${line// /}"   # strip spaces
      [[ -z "$line" ]] && continue
      # Detect hostname: first path component contains '.' or ':' or is "localhost"
      first="${line%%/*}"
      if [[ "$first" == *"."* || "$first" == *":"* || "$first" == "localhost" ]]; then
        line="${line#*/}"
      fi
      printf '%s\n' "$line"
    done < "$IMAGES_FILE" > "$REWRITTEN_IMAGES"
    log "$(wc -l < "$REWRITTEN_IMAGES") image refs after rewrite"

    # Upload rewritten images file to loadtester
    REMOTE_IMAGES="/tmp/images-managed-${RUN_ID}.txt"
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$REWRITTEN_IMAGES" "$ADMIN@$LT_PUB:$REMOTE_IMAGES"

    MANAGED_SCENARIO="${MANAGED_REGISTRY%%.*}"  # first label, e.g. "myregistry" from "myregistry.azurecr.io"
    MANAGED_OUT="report-managed.json"

    log "loadtest scenario=$MANAGED_SCENARIO target=https://$MANAGED_REGISTRY concurrency=$CONCURRENCY iterations=$ITERATIONS"

    managed_auth_flags=""
    if [[ -n "$REGISTRY_USER" && -n "$REGISTRY_PASSWORD" ]]; then
      managed_auth_flags="--username $(printf '%q' "$REGISTRY_USER") --password $(printf '%q' "$REGISTRY_PASSWORD")"
    fi

    # RUST_LOG=info is the default; set to debug for per-token and per-request detail.
    ssh_lt "RUST_LOG=info /home/$ADMIN/loadtest/target/release/loadtest \
        --target https://$MANAGED_REGISTRY \
        --scenario $MANAGED_SCENARIO \
        --images-file $REMOTE_IMAGES \
        --concurrency $CONCURRENCY \
        --iterations $ITERATIONS \
        --blob-concurrency $BLOB_CONCURRENCY \
        $managed_auth_flags \
        --output /tmp/$MANAGED_OUT"

    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$ADMIN@$LT_PUB:/tmp/$MANAGED_OUT" "$RUN_DIR/$MANAGED_OUT"

  else
    # ---- self-hosted mode ----
    drop_caches() {
      log "dropping page cache on registry VM"
      ssh_reg "sudo sync && sudo bash -c 'echo 3 > /proc/sys/vm/drop_caches'"
    }

    run_scenario() {
      local scenario="$1"
      local port="$2"
      local out="$3"
      log "loadtest scenario=$scenario target=$REG_PRIV:$port concurrency=$CONCURRENCY iterations=$ITERATIONS"
      ssh_lt "RUST_LOG=info /home/$ADMIN/loadtest/target/release/loadtest \
          --target http://$REG_PRIV:$port \
          --scenario $scenario \
          --concurrency $CONCURRENCY \
          --iterations $ITERATIONS \
          --blob-concurrency $BLOB_CONCURRENCY \
          --output /tmp/$out"
      scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          "$ADMIN@$LT_PUB:/tmp/$out" "$RUN_DIR/$out"
    }

    drop_caches
    run_scenario fs              5000 "report-fs.json"
    drop_caches
    run_scenario "$BLOB_SCENARIO" 5001 "report-blob.json"
  fi
fi

# ---------- 7. summary ----------
SUMMARY_MD="$RUN_DIR/summary.md"
log "rendering summary -> $SUMMARY_MD"

render_summary() {
  {
    echo "# Bench run $RUN_ID"
    echo
    echo "- Provider: $PROVIDER"
    if [[ -n "$MANAGED_REGISTRY" ]]; then
      echo "- Mode: managed ($MANAGED_REGISTRY)"
    fi
    echo "- Images file: \`$(basename "$IMAGES_FILE")\`"
    echo "- Concurrency: $CONCURRENCY"
    echo "- Iterations/image: $ITERATIONS"
    echo "- Blob fanout: $BLOB_CONCURRENCY"
    echo
    echo "## Per-pull duration (ms)"
    echo
    echo "| Scenario | pulls ok/fail | p50 | p90 | p95 | p99 | max |"
    echo "|----------|---------------|-----|-----|-----|-----|-----|"
    for f in "$RUN_DIR"/report-*.json; do
      [[ -f "$f" ]] || continue
      jq -r '
        "| \(.scenario) | \(.aggregates.successful)/\(.aggregates.failed) | \(.aggregates.duration_ms.p50 | tostring | .[0:7]) | \(.aggregates.duration_ms.p90 | tostring | .[0:7]) | \(.aggregates.duration_ms.p95 | tostring | .[0:7]) | \(.aggregates.duration_ms.p99 | tostring | .[0:7]) | \(.aggregates.duration_ms.max | tostring | .[0:7]) |"
      ' "$f"
    done
    echo
    echo "## Per-pull throughput (MB/s)"
    echo
    echo "| Scenario | mean | p50 | p95 | p99 |"
    echo "|----------|------|-----|-----|-----|"
    for f in "$RUN_DIR"/report-*.json; do
      [[ -f "$f" ]] || continue
      jq -r '
        "| \(.scenario) | \(.aggregates.mb_per_sec.mean | tostring | .[0:6]) | \(.aggregates.mb_per_sec.p50 | tostring | .[0:6]) | \(.aggregates.mb_per_sec.p95 | tostring | .[0:6]) | \(.aggregates.mb_per_sec.p99 | tostring | .[0:6]) |"
      ' "$f"
    done
  } > "$SUMMARY_MD"
}

render_summary
cat "$SUMMARY_MD"

# ---------- 8. upload reports ----------
case "$PROVIDER" in
  azure)
    if command -v azcopy >/dev/null 2>&1; then
      log "uploading reports to bench-reports/$RUN_ID/"
      base_url="${REPORTS_SAS%%\?*}"
      qs="${REPORTS_SAS#*\?}"
      for f in "$RUN_DIR"/*; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f")
        azcopy copy "$f" "${base_url}/${RUN_ID}/${base}?${qs}" >/dev/null 2>&1 \
          || log "WARN: upload $base failed"
      done
    else
      log "azcopy not installed locally — skipping upload (reports kept in $RUN_DIR)"
    fi
    ;;
  aws)
    if command -v aws >/dev/null 2>&1; then
      log "uploading reports to s3://$S3_REPORTS_BUCKET/$RUN_ID/"
      for f in "$RUN_DIR"/*; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f")
        aws s3 cp "$f" "s3://$S3_REPORTS_BUCKET/$RUN_ID/$base" \
          --region "$AWS_REGION" >/dev/null 2>&1 \
          || log "WARN: upload $base failed"
      done
    else
      log "aws CLI not found — skipping upload (reports kept in $RUN_DIR)"
    fi
    ;;
esac

# ---------- 9. teardown ----------
log "reports saved to: $RUN_DIR"
if [[ "$DESTROY" == true ]]; then
  log "terraform destroy"
  terraform -chdir="$TERRAFORM_DIR" destroy -input=false -auto-approve
else
  log "leaving infra running. To destroy: terraform -chdir=$TERRAFORM_DIR destroy"
fi
