#!/usr/bin/env bash
# bench.sh — container registry implementation benchmark.
#
#   Self-hosted mode (default): provision a VM, install every selected registry
#     implementation on it, mirror the same image corpus into each, then pull
#     from one engine at a time and compare.
#   Managed mode (--managed-registry): skip provisioning entirely and run the
#     load tester against an existing managed registry (ACR, ECR, ...).
#
# The comparison axis is the registry implementation. Every engine runs on the
# same VM against the same local NVMe, one at a time, over an identical image
# list — so a difference in the numbers is a difference in the registry.

set -euo pipefail

# ---------- paths ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANSIBLE_DIR="$SCRIPT_DIR/ansible"
LOADTEST_DIR="$SCRIPT_DIR/loadtest"
REPORTS_DIR="$SCRIPT_DIR/reports"
CONFIG_DIR="$SCRIPT_DIR/config"
ENGINE_CATALOG="$CONFIG_DIR/engines.json"

log() { printf '[bench %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$ENGINE_CATALOG" ]] || die "engine catalog not found: $ENGINE_CATALOG"

# ---------- defaults ----------
PROVIDER="azure"
IMAGES_FILE="$CONFIG_DIR/images.txt"
ENGINES="$(jq -r '.default_engines | join(",")' "$ENGINE_CATALOG")"
BASELINE="$(jq -r '.default_baseline' "$ENGINE_CATALOG")"
SUMM_SRC="$REPO_ROOT/../summ"
ROUNDS=1
SMOKE=false
DESTROY=false
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
  --engines <a,b,...>           Registry implementations to compare
                                (default: $ENGINES)
  --baseline <engine>           Engine the speedup column compares against
                                (default: $BASELINE)
  --rounds <n>                  Repeat the whole engine sweep n times, interleaved
                                round-robin so VM drift does not favour whichever
                                engine ran first (default: 1)
  --summ-src <path>             Local summ working tree to build and benchmark
                                (default: $SUMM_SRC)
  --images <file>               Override images list (default: config/images.txt)
  --smoke                       Use config/images-smoke.txt (3 small images)
  --concurrency <n>             Parallel image pulls in load test (default: 1)
  --iterations <n>              How many times to pull each image (default: 1)
  --blob-concurrency <n>        Per-image blob fetch fanout (default: 3)
  --destroy                     terraform destroy at end (no prompt)
  --keep                        Leave infra running after run (default)
  --skip-provision              Reuse existing terraform state and VM setup
  --skip-populate               Reuse existing registry contents
  --skip-loadtest               Run only provisioning + populate
  --crane-registry <host>       Registry host to authenticate with crane
  --crane-user <user>           Username for crane auth login
  --crane-password <pass>       Password for crane auth login
  --list-engines                Print the engine catalog and exit

Managed registry mode:
  --managed-registry <host>     Benchmark a managed registry (ACR, ECR, ...) instead
                                of provisioning engines. Image refs in images.txt are
                                rewritten: hostnames stripped and replaced with this
                                host. Registry setup and populate are skipped.
  --registry-user <user>        Username for managed registry auth.
                                For ECR: "AWS". For ACR: service principal client ID.
  --registry-password <pass>    Password / token for managed registry auth.

  -h, --help                    Show this help

Available engines:
$(jq -r '.engines | to_entries[] | "  \(.key)\(" " * (20 - (.key | length)))\(.value.label)"' "$ENGINE_CATALOG")
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)           PROVIDER="$2"; shift 2 ;;
    --engines)            ENGINES="$2"; shift 2 ;;
    --baseline)           BASELINE="$2"; shift 2 ;;
    --rounds)             ROUNDS="$2"; shift 2 ;;
    --summ-src)           SUMM_SRC="$2"; shift 2 ;;
    --images)             IMAGES_FILE="$2"; shift 2 ;;
    --smoke)              SMOKE=true; shift ;;
    --concurrency)        CONCURRENCY="$2"; shift 2 ;;
    --iterations)         ITERATIONS="$2"; shift 2 ;;
    --blob-concurrency)   BLOB_CONCURRENCY="$2"; shift 2 ;;
    --destroy)            DESTROY=true; shift ;;
    --keep)               DESTROY=false; shift ;;
    --skip-provision)     SKIP_PROVISION=true; shift ;;
    --skip-populate)      SKIP_POPULATE=true; shift ;;
    --skip-loadtest)      SKIP_LOADTEST=true; shift ;;
    --crane-registry)     CRANE_REGISTRY="$2"; shift 2 ;;
    --crane-user)         CRANE_USER="$2"; shift 2 ;;
    --crane-password)     CRANE_PASSWORD="$2"; shift 2 ;;
    --managed-registry)   MANAGED_REGISTRY="$2"; shift 2 ;;
    --registry-user)      REGISTRY_USER="$2"; shift 2 ;;
    --registry-password)  REGISTRY_PASSWORD="$2"; shift 2 ;;
    --list-engines)       jq -r '.engines | to_entries[] | "\(.key)\t\(.value.label)"' "$ENGINE_CATALOG"; exit 0 ;;
    -h|--help)            usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$SMOKE" == true ]]; then
  IMAGES_FILE="$CONFIG_DIR/images-smoke.txt"
fi

[[ "$PROVIDER" == "azure" || "$PROVIDER" == "aws" ]] \
  || die "unsupported provider '$PROVIDER'. Use azure or aws."

[[ "$ROUNDS" =~ ^[0-9]+$ && "$ROUNDS" -ge 1 ]] || die "--rounds must be a positive integer"

# ---------- engine selection ----------
# Resolved here and nowhere else: ansible and populate.sh both consume the
# result, so config/engines.json is read exactly once per run.
ENGINE_LIST=$(echo "$ENGINES" | tr ',' ' ')
[[ -n "${ENGINE_LIST// /}" ]] || die "--engines is empty"

if [[ -z "$MANAGED_REGISTRY" ]]; then
  for e in $ENGINE_LIST; do
    jq -e --arg e "$e" '.engines[$e]' "$ENGINE_CATALOG" >/dev/null 2>&1 \
      || die "unknown engine '$e'. Known engines: $(jq -r '.engines | keys | join(", ")' "$ENGINE_CATALOG")"
    # An engine needing a provider we are not running is a hard error, not a
    # silent skip: a summary missing a row is a result nobody questions.
    req=$(jq -r --arg e "$e" '.engines[$e].requires_provider // ""' "$ENGINE_CATALOG")
    [[ -z "$req" || "$req" == "$PROVIDER" ]] \
      || die "engine '$e' requires --provider $req (running $PROVIDER)"
  done

  baseline_ok=false
  for e in $ENGINE_LIST; do
    [[ "$e" == "$BASELINE" ]] && baseline_ok=true
  done
  [[ "$baseline_ok" == true ]] \
    || die "--baseline '$BASELINE' is not among the selected engines: $ENGINES"

  # summ is built from the operator's working tree, so it must exist locally.
  needs_summ=false
  for e in $ENGINE_LIST; do
    [[ "$(jq -r --arg e "$e" '.engines[$e].kind' "$ENGINE_CATALOG")" == "summ" ]] && needs_summ=true
  done
  if [[ "$needs_summ" == true ]]; then
    [[ -d "$SUMM_SRC" ]] || die "summ source not found at $SUMM_SRC (set --summ-src)"
    [[ -f "$SUMM_SRC/summ-server/Cargo.toml" ]] \
      || die "$SUMM_SRC does not look like the summ workspace (no summ-server/Cargo.toml)"
    SUMM_SRC="$(cd "$SUMM_SRC" && pwd)"
  fi
fi

# ---------- provider-specific paths ----------
case "$PROVIDER" in
  azure) TERRAFORM_DIR="$SCRIPT_DIR/terraform/azure" ;;
  aws)   TERRAFORM_DIR="$SCRIPT_DIR/terraform/aws" ;;
esac

# ---------- prereqs ----------
require() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

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
    az account show >/dev/null 2>&1 || die "az not logged in. Run 'az login' first."
    ;;
  aws)
    require aws
    aws sts get-caller-identity >/dev/null 2>&1 \
      || die "aws not authenticated. Run 'aws configure' or set AWS_PROFILE / AWS_* env vars."
    ;;
esac

[[ -f "$IMAGES_FILE" ]] || die "images file not found: $IMAGES_FILE"

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

TF_RAW="$(terraform -chdir="$TERRAFORM_DIR" output -json)"

tf() { jq -r --arg k "$1" '.[$k].value // ""' <<<"$TF_RAW"; }

# The saved copy is redacted. Every file in the run directory is uploaded to
# cloud storage at the end of the run, and the raw outputs carry the storage
# account key and a write-capable SAS URL — credentials must not ride along
# with a performance report.
jq 'with_entries(if .value.sensitive == true
                 then .value.value = "[redacted]"
                 else . end)' <<<"$TF_RAW" > "$RUN_DIR/terraform.json"

LT_PUB=$(tf loadtester_public_ip)
ADMIN=$(tf admin_username)
SSH_KEY=$(tf ssh_private_key_path)

if [[ -z "$MANAGED_REGISTRY" ]]; then
  REG_PUB=$(tf registry_public_ip)
  REG_PRIV=$(tf registry_private_ip)
  log "registry   vm: $REG_PUB (private $REG_PRIV)"
fi
log "loadtester vm: $LT_PUB"

# ---------- 2. resolved engine spec ----------
# Secret-free by construction: storage credentials go to ansible as separate
# --extra-vars, never into a file that lands in the run directory.
ENGINE_SPEC="$RUN_DIR/engines-selected.json"

if [[ -z "$MANAGED_REGISTRY" ]]; then
  SUMM_REV="n/a"
  if [[ "$needs_summ" == true ]]; then
    if git -C "$SUMM_SRC" rev-parse HEAD >/dev/null 2>&1; then
      SUMM_REV="$(git -C "$SUMM_SRC" rev-parse --short HEAD)"
      git -C "$SUMM_SRC" diff --quiet || SUMM_REV="$SUMM_REV-dirty"
    fi
    log "summ source: $SUMM_SRC @ $SUMM_REV"
  fi

  jq --arg names "$ENGINES" --arg summ_src "$SUMM_SRC" --arg summ_rev "$SUMM_REV" \
     --arg cloud "$PROVIDER" '
    . as $cfg
    | {
        cloud: $cloud,
        summ_src: $summ_src,
        summ_src_rev: $summ_rev,
        distribution_version: $cfg.distribution_version,
        selected_engines: [
          ($names | split(",") | map(select(length > 0))[]) as $n
          | $cfg.engines[$n] + {
              name: $n,
              data_dir: ($cfg.registry_data_root + "/" + $n),
              unit: ("bench-registry-" + $n + ".service")
            }
        ]
      }' "$ENGINE_CATALOG" > "$ENGINE_SPEC"

  log "engines: $(jq -r '.selected_engines | map("\(.name):\(.port)") | join("  ")' "$ENGINE_SPEC")"
fi

# ---------- 3. inventory ----------
INV="$ANSIBLE_DIR/inventory/${PROVIDER}.ini"
mkdir -p "$ANSIBLE_DIR/inventory"
{
  if [[ -z "$MANAGED_REGISTRY" ]]; then
    printf '[registry]\n%s ansible_user=%s ansible_ssh_private_key_file=%s ansible_python_interpreter=/usr/bin/python3\n\n' \
      "$REG_PUB" "$ADMIN" "$SSH_KEY"
  fi
  printf '[loadtester]\n%s ansible_user=%s ansible_ssh_private_key_file=%s ansible_python_interpreter=/usr/bin/python3\n\n' \
    "$LT_PUB" "$ADMIN" "$SSH_KEY"
  printf "[all:vars]\nansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'\n"
} > "$INV"

# ---------- 4. wait for SSH ----------
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

ssh_lt()  { ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$ADMIN@$LT_PUB" "$@"; }
ssh_reg() { ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$ADMIN@$REG_PUB" "$@"; }

ssh_wait() {
  local ip="$1"
  for _ in $(seq 1 30); do
    if ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" -o ConnectTimeout=5 "$ADMIN@$ip" 'echo ok' >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  die "SSH to $ip timed out"
}

log "waiting for SSH..."
[[ -z "$MANAGED_REGISTRY" ]] && ssh_wait "$REG_PUB"
ssh_wait "$LT_PUB"

# ---------- 5. ansible ----------
export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"

if [[ -z "$MANAGED_REGISTRY" && "$SKIP_PROVISION" == false ]]; then
  log "ansible: registry-setup.yml"
  # Storage credentials are passed on the command line, deliberately not via the
  # engine spec file, which is written into the uploaded run directory.
  storage_vars=()
  case "$PROVIDER" in
    azure)
      storage_vars=(
        --extra-vars "azure_storage_account=$(tf storage_account_name)"
        --extra-vars "azure_storage_key=$(tf storage_account_key)"
        --extra-vars "azure_storage_container=$(tf registry_blob_container)"
      )
      ;;
    aws)
      storage_vars=(
        --extra-vars "s3_bucket=$(tf s3_registry_bucket)"
        --extra-vars "s3_region=$(tf aws_region)"
      )
      ;;
  esac
  ansible-playbook -i "$INV" "$ANSIBLE_DIR/registry-setup.yml" \
    --extra-vars "@$ENGINE_SPEC" "${storage_vars[@]}"
fi

if [[ "$SKIP_PROVISION" == false ]]; then
  log "ansible: loadtester-setup.yml"
  ansible-playbook -i "$INV" "$ANSIBLE_DIR/loadtester-setup.yml" \
    --extra-vars "loadtest_local_dir=$LOADTEST_DIR" \
    --extra-vars "cloud=$PROVIDER"
fi

# ---------- engine lifecycle ----------
# Exactly one engine runs at a time. An idle engine still holds page cache and
# a RocksDB block cache; leaving one up would hand the engine under test a
# smaller share of a machine it is supposed to have to itself.
ALL_UNITS=""
if [[ -z "$MANAGED_REGISTRY" ]]; then
  ALL_UNITS="$(jq -r '.selected_engines | map(.unit) | join(" ")' "$ENGINE_SPEC")"
fi

engine_field() { jq -r --arg n "$1" --arg f "$2" '.selected_engines[] | select(.name == $n) | .[$f]' "$ENGINE_SPEC"; }

stop_all_engines() {
  [[ -n "$ALL_UNITS" ]] || return 0
  ssh_reg "sudo systemctl stop $ALL_UNITS 2>/dev/null || true"
}

# Poll rather than sleep: summ opens RocksDB before it binds, and a fixed sleep
# would either waste time or hand work to a port nothing is listening on yet.
wait_engine() {
  local name="$1" unit port
  unit="$(engine_field "$name" unit)"
  port="$(engine_field "$name" port)"
  ssh_reg "for i in \$(seq 1 60); do
             curl -sf -o /dev/null http://127.0.0.1:$port/v2/ && exit 0
             sleep 1
           done
           echo 'engine $name did not become healthy on :$port' >&2
           sudo journalctl -u $unit -n 40 --no-pager >&2
           exit 1" \
    || die "engine '$name' failed to become healthy"
}

start_engine() {
  local name="$1"
  ssh_reg "sudo systemctl start $(engine_field "$1" unit)"
  wait_engine "$name"
}

# Bring every engine up — only for the populate phase, where the fan-out needs
# them all accepting pushes at once.
start_all_engines() {
  ssh_reg "sudo systemctl start $ALL_UNITS"
  for e in $ENGINE_LIST; do
    wait_engine "$e"
  done
}

drop_caches() {
  ssh_reg "sudo sync && sudo bash -c 'echo 3 > /proc/sys/vm/drop_caches'"
}

# ---------- 6. populate ----------
if [[ -z "$MANAGED_REGISTRY" && "$SKIP_POPULATE" == false ]]; then
  log "populating ${ENGINES//,/, } from $(basename "$IMAGES_FILE")"
  # Every engine is up for this phase only: the fan-out copies from engine[0]
  # into each of the others, so they must all accept pushes at once.
  scp -i "$SSH_KEY" "${SSH_OPTS[@]}" \
      "$SCRIPT_DIR/populate.sh" "$IMAGES_FILE" "$ENGINE_SPEC" "$ADMIN@$REG_PUB:/tmp/"
  start_all_engines

  populate_env=""
  if [[ -n "$CRANE_REGISTRY" && -n "$CRANE_USER" && -n "$CRANE_PASSWORD" ]]; then
    populate_env="CRANE_REGISTRY=$(printf '%q' "$CRANE_REGISTRY") CRANE_USER=$(printf '%q' "$CRANE_USER") CRANE_PASSWORD=$(printf '%q' "$CRANE_PASSWORD")"
  fi
  ssh_reg "env $populate_env bash /tmp/populate.sh /tmp/$(basename "$IMAGES_FILE") /tmp/engines-selected.json /tmp/populate-report.json"
  scp -i "$SSH_KEY" "${SSH_OPTS[@]}" \
      "$ADMIN@$REG_PUB:/tmp/populate-report.json" "$RUN_DIR/populate-report.json"
  stop_all_engines
fi

# ---------- 7. load test ----------
# Both modes drive the same binary from the same images file. Using the file
# rather than per-engine catalog discovery keeps the pull set and its order
# byte-identical across engines: catalog ordering is implementation-defined, and
# a different order is a different benchmark.
REMOTE_IMAGES="/tmp/images-${RUN_ID}.txt"

if [[ "$SKIP_LOADTEST" == false ]]; then

  if [[ -n "$MANAGED_REGISTRY" ]]; then
    # ---- managed registry mode ----
    # Rewrite images.txt: strip source hostname, keep repo:tag.
    REWRITTEN_IMAGES="$RUN_DIR/images-managed.txt"
    log "rewriting image refs for $MANAGED_REGISTRY"
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="${line// /}"
      [[ -z "$line" ]] && continue
      first="${line%%/*}"
      if [[ "$first" == *"."* || "$first" == *":"* || "$first" == "localhost" ]]; then
        line="${line#*/}"
      fi
      printf '%s\n' "$line"
    done < "$IMAGES_FILE" > "$REWRITTEN_IMAGES"
    log "$(wc -l < "$REWRITTEN_IMAGES") image refs after rewrite"

    scp -i "$SSH_KEY" "${SSH_OPTS[@]}" "$REWRITTEN_IMAGES" "$ADMIN@$LT_PUB:$REMOTE_IMAGES"

    managed_auth_flags=""
    if [[ -n "$REGISTRY_USER" && -n "$REGISTRY_PASSWORD" ]]; then
      managed_auth_flags="--username $(printf '%q' "$REGISTRY_USER") --password $(printf '%q' "$REGISTRY_PASSWORD")"
    fi

    scenario="${MANAGED_REGISTRY%%.*}"
    log "loadtest engine=$scenario target=https://$MANAGED_REGISTRY"
    ssh_lt "RUST_LOG=info /home/$ADMIN/loadtest/target/release/loadtest \
        --target https://$MANAGED_REGISTRY \
        --scenario $scenario \
        --engine-label $(printf '%q' "$MANAGED_REGISTRY") \
        --round 1 \
        --images-file $REMOTE_IMAGES \
        --concurrency $CONCURRENCY \
        --iterations $ITERATIONS \
        --blob-concurrency $BLOB_CONCURRENCY \
        $managed_auth_flags \
        --output /tmp/report-$scenario-r1.json"

    scp -i "$SSH_KEY" "${SSH_OPTS[@]}" \
        "$ADMIN@$LT_PUB:/tmp/report-$scenario-r1.json" "$RUN_DIR/report-$scenario-r1.json"

  else
    # ---- self-hosted mode ----
    scp -i "$SSH_KEY" "${SSH_OPTS[@]}" "$IMAGES_FILE" "$ADMIN@$LT_PUB:$REMOTE_IMAGES"

    DIST_VERSION="$(jq -r '.distribution_version' "$ENGINE_SPEC")"

    run_scenario() {
      local name="$1" round="$2"
      local port kind version out
      port="$(engine_field "$name" port)"
      kind="$(engine_field "$name" kind)"
      case "$kind" in
        summ) version="$SUMM_REV" ;;
        *)    version="$DIST_VERSION" ;;
      esac
      out="report-${name}-r${round}.json"

      log "round $round/$ROUNDS  engine=$name ($version)  target=$REG_PRIV:$port"

      # Restart the engine for every scenario: this resets its in-process caches
      # (distribution's blob descriptor cache, summ's RocksDB block cache) so
      # each measurement starts genuinely cold, not warmed by the previous round.
      stop_all_engines
      start_engine "$name"
      drop_caches

      ssh_lt "RUST_LOG=info /home/$ADMIN/loadtest/target/release/loadtest \
          --target http://$REG_PRIV:$port \
          --scenario $name \
          --engine-label $(printf '%q' "$(engine_field "$name" label)") \
          --engine-version $version \
          --round $round \
          --images-file $REMOTE_IMAGES \
          --concurrency $CONCURRENCY \
          --iterations $ITERATIONS \
          --blob-concurrency $BLOB_CONCURRENCY \
          --output /tmp/$out"

      scp -i "$SSH_KEY" "${SSH_OPTS[@]}" "$ADMIN@$LT_PUB:/tmp/$out" "$RUN_DIR/$out"
      stop_all_engines
    }

    # Round-robin, not grouped: with --rounds 2 the order is A,B,A,B rather than
    # A,A,B,B, so a machine that drifts slower over the run penalises both
    # engines evenly instead of whichever went last.
    for round in $(seq 1 "$ROUNDS"); do
      for engine in $ENGINE_LIST; do
        run_scenario "$engine" "$round"
      done
    done
  fi
fi

# ---------- 8. summary ----------
SUMMARY_MD="$RUN_DIR/summary.md"
log "rendering summary -> $SUMMARY_MD"

# Percentiles are pooled from the raw samples across every round rather than
# averaged from each round's percentiles: the mean of two p95s is not the p95 of
# the union, and with --rounds > 1 that difference is exactly what is being read.
POOL_JQ='
def pct($p): if length == 0 then 0 else .[((($p / 100) * (length - 1)) | floor)] end;
[ inputs ] as $reports
| ($reports | map(.samples[] | select(.ok)) ) as $ok
| ($reports | map(.samples[] | select(.ok | not)) | length) as $failed
| ($ok | map(.duration_ms) | sort) as $d
| ($ok | map(if .duration_ms > 0 then (.bytes / 1048576) / (.duration_ms / 1000) else 0 end) | sort) as $r
| {
    engine:  ($reports[0].scenario),
    label:   ($reports[0].engine_label // $reports[0].scenario),
    version: ($reports[0].engine_version // ""),
    rounds:  ($reports | length),
    ok:      ($ok | length),
    failed:  $failed,
    bytes:   ($ok | map(.bytes) | add // 0),
    wall:    ($reports | map(.wall_clock_seconds) | add),
    d50: ($d | pct(50)), d90: ($d | pct(90)), d95: ($d | pct(95)),
    d99: ($d | pct(99)), dmax: ($d | max // 0),
    r50: ($r | pct(50)), rmean: (if ($r | length) > 0 then ($r | add / length) else 0 end)
  }'

render_summary() {
  local engines_for_summary
  if [[ -n "$MANAGED_REGISTRY" ]]; then
    engines_for_summary="${MANAGED_REGISTRY%%.*}"
  else
    engines_for_summary="$ENGINE_LIST"
  fi

  # One pooled record per engine, collected once and reused by both tables.
  local pooled="$RUN_DIR/.pooled.json"
  : > "$pooled"
  for engine in $engines_for_summary; do
    local files=( "$RUN_DIR"/report-"$engine"-r*.json )
    [[ -f "${files[0]}" ]] || continue
    jq -n "$POOL_JQ" "${files[@]}" >> "$pooled"
  done

  {
    echo "# Registry benchmark $RUN_ID"
    echo
    echo "Comparing registry **implementations** on one VM: same local NVMe, one"
    echo "engine running at a time, identical image list in identical order."
    echo
    echo "| Setting | Value |"
    echo "|---------|-------|"
    echo "| Provider | $PROVIDER |"
    [[ -n "$MANAGED_REGISTRY" ]] && echo "| Mode | managed ($MANAGED_REGISTRY) |"
    echo "| Images | \`$(basename "$IMAGES_FILE")\` |"
    echo "| Rounds | $ROUNDS |"
    echo "| Concurrency | $CONCURRENCY |"
    echo "| Iterations/image | $ITERATIONS |"
    echo "| Blob fanout | $BLOB_CONCURRENCY |"
    [[ -z "$MANAGED_REGISTRY" ]] && echo "| Baseline | $BASELINE |"
    echo

    echo "## Engines"
    echo
    echo "| Engine | Build | Pulls ok/fail | Data |"
    echo "|--------|-------|---------------|------|"
    jq -r '"| \(.label) | \(if .version == "" then "—" else .version end) | \(.ok)/\(.failed) | \((.bytes / 1048576 * 10 | round / 10)) MB |"' "$pooled"
    echo

    echo "## Per-pull duration (ms, pooled over all rounds)"
    echo
    echo "| Engine | p50 | p90 | p95 | p99 | max | vs baseline (p50) |"
    echo "|--------|-----|-----|-----|-----|-----|-------------------|"
    local base_d50
    base_d50=$(jq -r --arg b "$BASELINE" 'select(.engine == $b) | .d50' "$pooled" | head -1)
    jq -r --arg b "$BASELINE" --arg base "${base_d50:-0}" '
      def r2: . * 100 | round / 100;
      (if .engine == $b then "baseline"
       elif ($base | tonumber) > 0 and .d50 > 0
       then ((($base | tonumber) / .d50) | . * 100 | round / 100 | tostring) + "×"
       else "—" end) as $ratio
      | "| \(.engine) | \(.d50 | r2) | \(.d90 | r2) | \(.d95 | r2) | \(.d99 | r2) | \(.dmax | r2) | \($ratio) |"' "$pooled"
    echo
    echo "> \`vs baseline\` is baseline p50 ÷ engine p50, so **higher is faster**."
    echo

    echo "## Per-pull throughput (MB/s, pooled over all rounds)"
    echo
    echo "| Engine | mean | p50 |"
    echo "|--------|------|-----|"
    jq -r 'def r2: . * 100 | round / 100; "| \(.engine) | \(.rmean | r2) | \(.r50 | r2) |"' "$pooled"

    if [[ "$ROUNDS" -gt 1 ]]; then
      echo
      echo "## Per-round duration p50 (ms)"
      echo
      echo "Read this before trusting the pooled table: rounds that disagree mean"
      echo "the machine drifted and the comparison needs more rounds."
      echo
      echo "| Engine | Round | p50 | ok/fail |"
      echo "|--------|-------|-----|---------|"
      for engine in $engines_for_summary; do
        for f in "$RUN_DIR"/report-"$engine"-r*.json; do
          [[ -f "$f" ]] || continue
          jq -r '"| \(.scenario) | \(.round // 1) | \(.aggregates.duration_ms.p50 * 100 | round / 100) | \(.aggregates.successful)/\(.aggregates.failed) |"' "$f"
        done
      done
    fi

    if [[ -f "$RUN_DIR/populate-report.json" ]]; then
      echo
      echo "## Push (populate) mean seconds per image"
      echo
      echo "| Engine | mean s | note |"
      echo "|--------|--------|------|"
      jq -r '.fanout_source as $src
        | [.images[] | select(.ok)] as $ok
        | if ($ok | length) == 0 then empty
          else ($ok[0].push_seconds | keys_unsorted[]) as $e
            | (if $e == $src then "**includes the upstream pull**"
               else "local fan-out from " + $src end) as $note
            | "| \($e) | \(([$ok[].push_seconds[$e]] | add / length) * 100 | round / 100) | \($note) |"
          end' "$RUN_DIR/populate-report.json"
      echo
      echo "> These are **not** comparable to each other. The fan-out source pulls each"
      echo "> image from the public registry, so its time is dominated by internet"
      echo "> transfer the other engines never paid. Populate is setup, not a benchmark;"
      echo "> the pull tables above are the measurement."
    fi
  } > "$SUMMARY_MD"

  rm -f "$pooled"
}

render_summary
cat "$SUMMARY_MD"

# ---------- 9. upload reports ----------
case "$PROVIDER" in
  azure)
    REPORTS_SAS=$(tf reports_sas_url)
    if command -v azcopy >/dev/null 2>&1 && [[ -n "$REPORTS_SAS" ]]; then
      log "uploading reports to bench-reports/$RUN_ID/"
      base_url="${REPORTS_SAS%%\?*}"
      qs="${REPORTS_SAS#*\?}"
      for f in "$RUN_DIR"/*; do
        [[ -f "$f" ]] || continue
        azcopy copy "$f" "${base_url}/${RUN_ID}/$(basename "$f")?${qs}" >/dev/null 2>&1 \
          || log "WARN: upload $(basename "$f") failed"
      done
    else
      log "azcopy not installed locally — skipping upload (reports kept in $RUN_DIR)"
    fi
    ;;
  aws)
    S3_REPORTS_BUCKET=$(tf s3_reports_bucket)
    AWS_REGION=$(tf aws_region)
    if [[ -n "$S3_REPORTS_BUCKET" ]]; then
      log "uploading reports to s3://$S3_REPORTS_BUCKET/$RUN_ID/"
      for f in "$RUN_DIR"/*; do
        [[ -f "$f" ]] || continue
        aws s3 cp "$f" "s3://$S3_REPORTS_BUCKET/$RUN_ID/$(basename "$f")" \
          --region "$AWS_REGION" >/dev/null 2>&1 \
          || log "WARN: upload $(basename "$f") failed"
      done
    fi
    ;;
esac

# ---------- 10. teardown ----------
log "reports saved to: $RUN_DIR"
if [[ "$DESTROY" == true ]]; then
  log "terraform destroy"
  terraform -chdir="$TERRAFORM_DIR" destroy -input=false -auto-approve
else
  log "leaving infra running. To destroy: terraform -chdir=$TERRAFORM_DIR destroy"
fi
