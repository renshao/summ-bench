#!/usr/bin/env bash
# acr-import.sh — bulk-import images from an images.txt file into an ACR registry
# using 'az acr import'. Docker Hub images are automatically qualified with the
# correct registry host. Continues on per-image failure and reports a final tally.

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 --registry <acr-name> --file <images.txt> [options]

  --registry <name>         ACR registry name (without .azurecr.io)
  --file <path>             Images file (one ref per line, # comments ok)
  --source-user <user>      Username for source registry (e.g. Docker Hub login)
  --source-password <pass>  Password / token for source registry
  --dry-run                 Print commands without executing
  -h, --help                Show this help

Examples:
  $0 --registry myregistry --file bench/config/images-small.txt
  $0 --registry myregistry --file bench/config/images.txt \\
      --source-user myuser --source-password \$(cat ~/.docker-token) --dry-run
EOF
}

REGISTRY=""
IMAGES_FILE=""
SOURCE_USER=""
SOURCE_PASSWORD=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)        REGISTRY="$2";        shift 2 ;;
    --file)            IMAGES_FILE="$2";     shift 2 ;;
    --source-user)     SOURCE_USER="$2";     shift 2 ;;
    --source-password) SOURCE_PASSWORD="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=true;         shift ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -z "$REGISTRY"    ]] && { echo "ERROR: --registry is required" >&2; exit 2; }
[[ -z "$IMAGES_FILE" ]] && { echo "ERROR: --file is required"     >&2; exit 2; }
[[ -f "$IMAGES_FILE" ]] || { echo "ERROR: file not found: $IMAGES_FILE" >&2; exit 2; }

log() { printf '[acr-import %s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# Return the fully-qualified source reference for 'az acr import --source'.
# A ref with no '/' is a Docker Hub official image (e.g. "ubuntu:24.04") and
# gets registry-1.docker.io/library/ prepended. A ref whose first path component
# contains '.' or ':' or equals "localhost" already has a registry hostname and
# is returned unchanged. Everything else is a Docker Hub user/org image.
qualify_source() {
  local ref="$1"
  if [[ "$ref" != *"/"* ]]; then
    echo "registry-1.docker.io/library/$ref"
    return
  fi
  local first="${ref%%/*}"
  if [[ "$first" == *"."* || "$first" == *":"* || "$first" == "localhost" ]]; then
    echo "$ref"
  else
    echo "registry-1.docker.io/$ref"
  fi
}

# Return the target repo:tag for 'az acr import --image' by stripping the
# registry hostname from a ref that has one, leaving everything else intact.
strip_host() {
  local ref="$1"
  if [[ "$ref" != *"/"* ]]; then
    echo "$ref"
    return
  fi
  local first="${ref%%/*}"
  if [[ "$first" == *"."* || "$first" == *":"* || "$first" == "localhost" ]]; then
    echo "${ref#*/}"
  else
    echo "$ref"
  fi
}

ok=0
fail=0
failed_refs=()

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"   # strip inline comments
  line="${line// /}"   # strip spaces
  [[ -z "$line" ]] && continue

  source_ref=$(qualify_source "$line")
  target_ref=$(strip_host "$line")

  auth_flags=()
  if [[ -n "$SOURCE_USER" && -n "$SOURCE_PASSWORD" ]]; then
    auth_flags=(--username "$SOURCE_USER" --password "$SOURCE_PASSWORD")
  fi

  cmd=(
    az acr import
    --name     "$REGISTRY"
    --source   "$source_ref"
    --image    "$target_ref"
    --force
    "${auth_flags[@]}"
  )

  log "importing $source_ref → $REGISTRY.azurecr.io/$target_ref"

  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] %s\n' "${cmd[*]}"
    continue
  fi

  if "${cmd[@]}"; then
    ok=$((ok + 1))
  else
    log "FAILED: $source_ref"
    fail=$((fail + 1))
    failed_refs+=("$source_ref")
  fi
done < "$IMAGES_FILE"

echo
if [[ "$DRY_RUN" == true ]]; then
  log "dry-run complete"
  exit 0
fi

log "done — imported: $ok  failed: $fail"

if [[ ${#failed_refs[@]} -gt 0 ]]; then
  echo
  echo "Failed imports:"
  printf '  %s\n' "${failed_refs[@]}"
  exit 1
fi
