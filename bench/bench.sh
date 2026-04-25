#!/usr/bin/env bash
# bench.sh — end-to-end harness:
#   1. Provision Azure (terraform apply).
#   2. Configure VMs (ansible).
#   3. Mirror curated images into both registries.
#   4. Run Rust load tester against fs-backed and azure-blob-backed registries.
#   5. Pull reports back, render a combined Markdown summary, upload to blob.
#   6. Print summary, optionally destroy.

set -euo pipefail
shopt -s inherit_errexit

# ---------- paths ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform/azure"
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
RUN_ID="$(date +%Y%m%d-%H%M%S)"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --provider <azure>        Cloud provider (azure only in Phase 1; default: azure)
  --images <file>           Override images list (default: config/images.txt)
  --smoke                   Use config/images-smoke.txt (3 small images for fast validation)
  --concurrency <n>         Parallel image pulls in load test (default: 1)
  --iterations <n>          How many times to pull each image (default: 1)
  --blob-concurrency <n>    Per-image blob fetch fanout (default: 3)
  --destroy                 terraform destroy at end (no prompt)
  --keep                    leave infra running after run (default)
  --skip-provision          Reuse existing terraform state (skip apply)
  --skip-populate           Reuse existing registry contents (skip image mirror)
  --skip-loadtest           Run only provisioning + populate
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)         PROVIDER="$2"; shift 2 ;;
    --images)           IMAGES_FILE="$2"; shift 2 ;;
    --smoke)            SMOKE=true; shift ;;
    --concurrency)      CONCURRENCY="$2"; shift 2 ;;
    --iterations)       ITERATIONS="$2"; shift 2 ;;
    --blob-concurrency) BLOB_CONCURRENCY="$2"; shift 2 ;;
    --destroy)          DESTROY=true; KEEP=false; shift ;;
    --keep)             KEEP=true; DESTROY=false; shift ;;
    --skip-provision)   SKIP_PROVISION=true; shift ;;
    --skip-populate)    SKIP_POPULATE=true; shift ;;
    --skip-loadtest)    SKIP_LOADTEST=true; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$SMOKE" == true ]]; then
  IMAGES_FILE="$CONFIG_DIR/images-smoke.txt"
fi

if [[ "$PROVIDER" != "azure" ]]; then
  echo "ERROR: only azure is supported in Phase 1 (got: $PROVIDER)" >&2
  exit 2
fi

# ---------- prereqs ----------
log() { printf '[bench %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

log "checking prerequisites..."
require terraform
require ansible-playbook
require az
require jq
require ssh
require scp
require rsync

if [[ ! -f "$IMAGES_FILE" ]]; then
  die "images file not found: $IMAGES_FILE"
fi

if ! az account show >/dev/null 2>&1; then
  die "az not logged in. Run 'az login' first."
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

# Pull terraform outputs once and cache.
TF_JSON="$RUN_DIR/terraform.json"
terraform -chdir="$TERRAFORM_DIR" output -json > "$TF_JSON"

REG_PUB=$(jq -r '.registry_public_ip.value' "$TF_JSON")
REG_PRIV=$(jq -r '.registry_private_ip.value' "$TF_JSON")
LT_PUB=$(jq -r '.loadtester_public_ip.value' "$TF_JSON")
ADMIN=$(jq -r '.admin_username.value' "$TF_JSON")
SSH_KEY=$(jq -r '.ssh_private_key_path.value' "$TF_JSON")
STORAGE_ACCT=$(jq -r '.storage_account_name.value' "$TF_JSON")
STORAGE_KEY=$(jq -r '.storage_account_key.value' "$TF_JSON")
REG_CONTAINER=$(jq -r '.registry_blob_container.value' "$TF_JSON")
REPORTS_SAS=$(jq -r '.reports_sas_url.value' "$TF_JSON")

log "registry  vm: $REG_PUB (private $REG_PRIV)"
log "loadtester vm: $LT_PUB"

# ---------- 2. inventory ----------
INV="$ANSIBLE_DIR/inventory/azure.ini"
mkdir -p "$ANSIBLE_DIR/inventory"
cat > "$INV" <<EOF
[registry]
$REG_PUB ansible_user=$ADMIN ansible_ssh_private_key_file=$SSH_KEY ansible_python_interpreter=/usr/bin/python3

[loadtester]
$LT_PUB ansible_user=$ADMIN ansible_ssh_private_key_file=$SSH_KEY ansible_python_interpreter=/usr/bin/python3

[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
EOF

# ---------- 3. wait for SSH ----------
log "waiting for SSH on both VMs..."
for ip in "$REG_PUB" "$LT_PUB"; do
  for _ in $(seq 1 30); do
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 "$ADMIN@$ip" 'echo ok' >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
done

# ---------- 4. ansible ----------
export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"

log "ansible: registry-setup.yml"
ansible-playbook -i "$INV" "$ANSIBLE_DIR/registry-setup.yml" \
  --extra-vars "storage_account_name=$STORAGE_ACCT" \
  --extra-vars "storage_account_key=$STORAGE_KEY" \
  --extra-vars "registry_blob_container=$REG_CONTAINER"

log "ansible: loadtester-setup.yml"
ansible-playbook -i "$INV" "$ANSIBLE_DIR/loadtester-setup.yml" \
  --extra-vars "loadtest_local_dir=$LOADTEST_DIR"

# ---------- 5. populate ----------
ssh_reg() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$ADMIN@$REG_PUB" "$@"
}
ssh_lt() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$ADMIN@$LT_PUB" "$@"
}

if [[ "$SKIP_POPULATE" == false ]]; then
  log "populating registries from: $IMAGES_FILE"
  scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$SCRIPT_DIR/populate.sh" "$IMAGES_FILE" "$ADMIN@$REG_PUB:/tmp/"
  ssh_reg "bash /tmp/populate.sh /tmp/$(basename "$IMAGES_FILE") /tmp/populate-report.json"
  scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$ADMIN@$REG_PUB:/tmp/populate-report.json" "$RUN_DIR/populate-report.json"
fi

# ---------- 6. load test ----------
if [[ "$SKIP_LOADTEST" == false ]]; then
  drop_caches() {
    log "dropping page cache on registry VM"
    ssh_reg "sudo sync && sudo bash -c 'echo 3 > /proc/sys/vm/drop_caches'"
  }

  run_scenario() {
    local scenario="$1"
    local port="$2"
    local out="$3"
    log "loadtest scenario=$scenario target=$REG_PRIV:$port concurrency=$CONCURRENCY iterations=$ITERATIONS"
    ssh_lt "/home/$ADMIN/loadtest/target/release/loadtest \
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
  run_scenario fs    5000 "report-fs.json"
  drop_caches
  run_scenario azure 5001 "report-azure.json"
fi

# ---------- 7. summary ----------
SUMMARY_MD="$RUN_DIR/summary.md"
log "rendering summary -> $SUMMARY_MD"

render_summary() {
  local fs="$RUN_DIR/report-fs.json"
  local az="$RUN_DIR/report-azure.json"
  {
    echo "# Bench run $RUN_ID"
    echo
    echo "- Provider: $PROVIDER"
    echo "- Images file: \`$(basename "$IMAGES_FILE")\`"
    echo "- Concurrency: $CONCURRENCY"
    echo "- Iterations/image: $ITERATIONS"
    echo "- Blob fanout: $BLOB_CONCURRENCY"
    echo
    echo "## Per-pull duration (ms)"
    echo
    echo "| Scenario | pulls ok/fail | p50 | p90 | p95 | p99 | max |"
    echo "|----------|---------------|-----|-----|-----|-----|-----|"
    for f in "$fs" "$az"; do
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
    for f in "$fs" "$az"; do
      [[ -f "$f" ]] || continue
      jq -r '
        "| \(.scenario) | \(.aggregates.mb_per_sec.mean | tostring | .[0:6]) | \(.aggregates.mb_per_sec.p50 | tostring | .[0:6]) | \(.aggregates.mb_per_sec.p95 | tostring | .[0:6]) | \(.aggregates.mb_per_sec.p99 | tostring | .[0:6]) |"
      ' "$f"
    done
  } > "$SUMMARY_MD"
}

render_summary
cat "$SUMMARY_MD"

# ---------- 8. upload to blob ----------
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

# ---------- 9. teardown ----------
log "reports saved to: $RUN_DIR"
if [[ "$DESTROY" == true ]]; then
  log "terraform destroy"
  terraform -chdir="$TERRAFORM_DIR" destroy -input=false -auto-approve
else
  log "leaving infra running. To destroy: terraform -chdir=$TERRAFORM_DIR destroy"
fi
