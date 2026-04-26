#!/usr/bin/env bash
# populate.sh — runs on the registry VM. For each ref in images.txt:
#   1. crane copy <public src> -> localhost:5000/<repo>:<tag>  (filesystem-backed registry)
#   2. crane copy localhost:5000/<repo>:<tag> -> localhost:5001/<repo>:<tag>  (azure-backed registry)
# Records duration + bytes per image into populate-report.json.

set -euo pipefail

IMAGES_FILE="${1:-images.txt}"
REPORT="${2:-populate-report.json}"
FS_REGISTRY="${FS_REGISTRY:-localhost:5000}"
AZ_REGISTRY="${AZ_REGISTRY:-localhost:5001}"

if [[ ! -f "$IMAGES_FILE" ]]; then
  echo "ERROR: images file not found: $IMAGES_FILE" >&2
  exit 1
fi

if ! command -v crane >/dev/null 2>&1; then
  echo "ERROR: crane not found in PATH" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found in PATH" >&2
  exit 1
fi

if [[ -n "${CRANE_REGISTRY:-}" && -n "${CRANE_USER:-}" && -n "${CRANE_PASSWORD:-}" ]]; then
  echo "authenticating crane with $CRANE_REGISTRY"
  crane auth login "$CRANE_REGISTRY" -u "$CRANE_USER" -p "$CRANE_PASSWORD"
fi

results=()

ref_to_repo_tag() {
  local ref="$1"
  local without_registry="${ref#*/}"
  if [[ "$ref" == "$without_registry" ]] || [[ "${ref%%/*}" != *"."* && "${ref%%/*}" != *":"* && "${ref%%/*}" != "localhost" ]]; then
    without_registry="$ref"
  fi
  if [[ "$without_registry" == *":"* ]]; then
    echo "${without_registry%:*}|${without_registry##*:}"
  else
    echo "${without_registry}|latest"
  fi
}

while IFS= read -r ref || [[ -n "$ref" ]]; do
  ref="${ref%%#*}"
  ref="$(echo "$ref" | tr -d '[:space:]')"
  [[ -z "$ref" ]] && continue

  IFS='|' read -r repo tag <<<"$(ref_to_repo_tag "$ref")"
  fs_target="${FS_REGISTRY}/${repo}:${tag}"
  az_target="${AZ_REGISTRY}/${repo}:${tag}"

  echo "===> $ref"
  echo "     -> $fs_target"

  start=$(date +%s.%N)
  crane copy --insecure "$ref" "$fs_target" 2>&1 | sed 's/^/      [src->fs] /' || {
    echo "FAILED: $ref -> $fs_target" >&2
    results+=("$(jq -nc --arg ref "$ref" --arg target "$fs_target" --arg phase "src->fs" '{ref:$ref,target:$target,phase:$phase,ok:false}')")
    continue
  }
  end=$(date +%s.%N)
  fs_duration=$(echo "$end - $start" | bc -l)

  echo "     -> $az_target"
  start=$(date +%s.%N)
  crane copy --insecure "$fs_target" "$az_target" 2>&1 | sed 's/^/      [fs->az] /' || {
    echo "FAILED: $fs_target -> $az_target" >&2
    results+=("$(jq -nc --arg ref "$ref" --arg target "$az_target" --arg phase "fs->az" '{ref:$ref,target:$target,phase:$phase,ok:false}')")
    continue
  }
  end=$(date +%s.%N)
  az_duration=$(echo "$end - $start" | bc -l)

  size_bytes=$(crane manifest --insecure "$fs_target" 2>/dev/null \
    | jq '[.layers[]?.size, .config.size] | map(select(. != null)) | add // 0')

  results+=("$(jq -nc \
    --arg ref "$ref" \
    --arg repo "$repo" \
    --arg tag "$tag" \
    --argjson fs_duration "$fs_duration" \
    --argjson az_duration "$az_duration" \
    --argjson size_bytes "$size_bytes" \
    '{ref:$ref,repo:$repo,tag:$tag,fs_duration_seconds:$fs_duration,az_duration_seconds:$az_duration,size_bytes:$size_bytes,ok:true}')")
done < "$IMAGES_FILE"

export FS_REGISTRY AZ_REGISTRY
printf '%s\n' "${results[@]}" \
  | jq -s '{populated_at: now | todate, registries: {fs: env.FS_REGISTRY, azure: env.AZ_REGISTRY}, images: .}' \
  > "$REPORT"

echo
echo "Populate complete. Report: $REPORT"
jq -r '.images | length as $n
  | (map(select(.ok)) | length) as $ok
  | "  images attempted: \($n)\n  images ok:        \($ok)\n  images failed:    \($n - $ok)"' "$REPORT"
