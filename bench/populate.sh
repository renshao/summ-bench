#!/usr/bin/env bash
# populate.sh — runs on the registry VM. Mirrors every image in the images file
# into every selected engine, so each engine holds a byte-identical corpus.
#
#   1. crane copy <public src>       -> <engine[0]>/<repo>:<tag>
#   2. crane copy <engine[0]>/<ref>  -> <engine[N]>/<repo>:<tag>   for N >= 1
#
# The public registry is hit once per image, not once per engine: pulling the
# same image from Docker Hub several times would burn rate limit and make the
# corpus depend on when each copy ran. Engine[0] is the local fan-out source.
#
# Per-engine push durations land in the report. Push throughput is a genuine
# signal in an implementation comparison, not just a setup side effect.
#
# Usage: populate.sh <images-file> <engines-json> <report-path>

set -euo pipefail

IMAGES_FILE="${1:-images.txt}"
ENGINES_JSON="${2:-engines-selected.json}"
REPORT="${3:-populate-report.json}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$IMAGES_FILE" ]]  || die "images file not found: $IMAGES_FILE"
[[ -f "$ENGINES_JSON" ]] || die "engines file not found: $ENGINES_JSON"

command -v crane >/dev/null 2>&1 || die "crane not found in PATH"
command -v jq    >/dev/null 2>&1 || die "jq not found in PATH"

# Engine names and their host:port, in the order bench.sh selected them.
# Read with a while loop rather than mapfile: the rest of this harness runs on
# bash 3.2 (stock macOS) and there is no reason for this script to be the one
# file that cannot be tested outside a VM.
ENGINE_NAMES=()
ENGINE_ADDRS=()
while IFS= read -r line; do
  ENGINE_NAMES+=("$line")
done < <(jq -r '.selected_engines[].name' "$ENGINES_JSON")
while IFS= read -r line; do
  ENGINE_ADDRS+=("$line")
done < <(jq -r '.selected_engines[] | "\(.host // "localhost"):\(.port)"' "$ENGINES_JSON")

[[ ${#ENGINE_NAMES[@]} -gt 0 ]] || die "no engines in $ENGINES_JSON"

echo "populating ${#ENGINE_NAMES[@]} engine(s): ${ENGINE_NAMES[*]}"
echo "fan-out source: ${ENGINE_NAMES[0]} (${ENGINE_ADDRS[0]})"
echo

if [[ -n "${CRANE_REGISTRY:-}" && -n "${CRANE_USER:-}" && -n "${CRANE_PASSWORD:-}" ]]; then
  echo "authenticating crane with $CRANE_REGISTRY"
  crane auth login "$CRANE_REGISTRY" -u "$CRANE_USER" -p "$CRANE_PASSWORD"
fi

# "nvcr.io/nvidia/cuda:12.0" -> "nvidia/cuda|12.0";  "ubuntu:22.04" -> "ubuntu|22.04"
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

results=()

while IFS= read -r ref || [[ -n "$ref" ]]; do
  ref="${ref%%#*}"
  ref="$(echo "$ref" | tr -d '[:space:]')"
  [[ -z "$ref" ]] && continue

  IFS='|' read -r repo tag <<<"$(ref_to_repo_tag "$ref")"
  source_target="${ENGINE_ADDRS[0]}/${repo}:${tag}"

  echo "===> $ref"

  # --- hop 1: public source into engine[0] ---
  echo "     [${ENGINE_NAMES[0]}] <- $ref"
  start=$(date +%s.%N)
  if ! crane copy --insecure "$ref" "$source_target" 2>&1 | sed 's/^/       /'; then
    echo "FAILED: $ref -> $source_target" >&2
    results+=("$(jq -nc --arg ref "$ref" --arg engine "${ENGINE_NAMES[0]}" \
      '{ref:$ref,ok:false,failed_engine:$engine}')")
    continue
  fi
  end=$(date +%s.%N)

  pushes="$(jq -nc --arg name "${ENGINE_NAMES[0]}" \
    --argjson secs "$(echo "$end - $start" | bc -l)" '{($name): $secs}')"

  # --- hop 2..N: engine[0] into every other engine ---
  failed=""
  for i in $(seq 1 $(( ${#ENGINE_NAMES[@]} - 1 )) ); do
    target="${ENGINE_ADDRS[$i]}/${repo}:${tag}"
    echo "     [${ENGINE_NAMES[$i]}] <- ${ENGINE_NAMES[0]}"
    start=$(date +%s.%N)
    if ! crane copy --insecure "$source_target" "$target" 2>&1 | sed 's/^/       /'; then
      echo "FAILED: $source_target -> $target" >&2
      failed="${ENGINE_NAMES[$i]}"
      break
    fi
    end=$(date +%s.%N)
    pushes="$(jq -nc --argjson acc "$pushes" --arg name "${ENGINE_NAMES[$i]}" \
      --argjson secs "$(echo "$end - $start" | bc -l)" '$acc + {($name): $secs}')"
  done

  if [[ -n "$failed" ]]; then
    results+=("$(jq -nc --arg ref "$ref" --arg engine "$failed" \
      '{ref:$ref,ok:false,failed_engine:$engine}')")
    continue
  fi

  size_bytes=$(crane manifest --insecure "$source_target" 2>/dev/null \
    | jq '[.layers[]?.size, .config.size] | map(select(. != null)) | add // 0')

  results+=("$(jq -nc \
    --arg ref "$ref" --arg repo "$repo" --arg tag "$tag" \
    --argjson size_bytes "${size_bytes:-0}" \
    --argjson pushes "$pushes" \
    '{ref:$ref,repo:$repo,tag:$tag,size_bytes:$size_bytes,push_seconds:$pushes,ok:true}')")
done < "$IMAGES_FILE"

[[ ${#results[@]} -gt 0 ]] || die "no images processed from $IMAGES_FILE"

printf '%s\n' "${results[@]}" \
  | jq -s --slurpfile spec "$ENGINES_JSON" --arg fanout "${ENGINE_NAMES[0]}" \
      '{populated_at: (now | todate),
        engines: ($spec[0].selected_engines | map({name, port, label})),
        fanout_source: $fanout,
        images: .}' \
  > "$REPORT"

echo
echo "Populate complete. Report: $REPORT"
jq -r '.images | length as $n
  | (map(select(.ok)) | length) as $ok
  | "  images attempted: \($n)\n  images ok:        \($ok)\n  images failed:    \($n - $ok)"' "$REPORT"

# Mean push seconds per engine. Not a like-for-like write benchmark: the
# fan-out source also absorbed the pull from the public registry, so its number
# includes internet transfer that the others never paid.
echo
echo "  mean push seconds per engine (${ENGINE_NAMES[0]} includes the upstream pull):"
jq -r '[.images[] | select(.ok)] as $ok
  | if ($ok | length) == 0 then "    (none)"
    else ($ok[0].push_seconds | keys_unsorted[]) as $e
      | "    \($e): \(([$ok[].push_seconds[$e]] | add / length) * 100 | round / 100)"
    end' "$REPORT"
