#!/usr/bin/env bash
# Re-run the README's per-driver × max-cases perf table.
#
# Output: bench/perf_matrix.tsv (driver, mc, wall_seconds, tests, failures)
# Resumable: re-running skips cells already in the TSV.
#
# Usage:
#   bench/perf_matrix.sh           # run all cells
#   bench/perf_matrix.sh -f        # force re-run (truncate TSV first)
#
# Note: 35 cells (7 drivers × 5 mc levels). Total ~75 min. Some cells
# may legitimately fail (e.g. legacy BiDi at mc16 — chromium-bidi
# pool is too small). We log the failure and move on.

set -u

cd "$(dirname "$0")/.."

OUT=bench/perf_matrix.tsv
FORCE=${1:-}

if [[ "$FORCE" == "-f" ]] || [[ ! -f "$OUT" ]]; then
  echo -e "driver\tmc\twall_seconds\ttests\tfailures" > "$OUT"
fi

# Driver atoms (mix alias suffix → friendly label).
DRIVERS=(
  "live_view:LiveView"
  "lightpanda:Lightpanda V1"
  "lightpanda_v2:Lightpanda V2"
  "chrome:Chrome CDP V1"
  "chrome_v2:Chrome CDP V2"
  "chrome.bidi:Chrome BiDi V1"
  "chrome.bidi_v2:Chrome BiDi V2"
)

MC_LEVELS=(1 2 4 8 16)

cleanup_browsers() {
  # Kill any leftover Chrome / Lightpanda / chromium-bidi processes
  # so the next driver starts from a clean slate.
  pkill -9 -f "Google Chrome for Testing" 2>/dev/null || true
  pkill -9 -f "Chrome.*--headless"        2>/dev/null || true
  pkill -9 -f "lightpanda-aarch"          2>/dev/null || true
  pkill -9 -f "chromium-bidi"             2>/dev/null || true
  pkill -9 -f "bidi-server/run.mjs"       2>/dev/null || true
  sleep 1
}

already_done() {
  local driver=$1 mc=$2
  awk -F'\t' -v d="$driver" -v m="$mc" 'NR>1 && $1==d && $2==m {found=1} END {exit !found}' "$OUT"
}

run_cell() {
  local alias=$1
  local label=$2
  local mc=$3

  if already_done "$label" "$mc"; then
    echo "SKIP  $label  mc=$mc  (already in $OUT)"
    return
  fi

  echo
  echo "=== $label  mc=$mc ==="
  cleanup_browsers

  local logfile=/tmp/perf_matrix_$(echo "$alias" | tr './' '__')_mc${mc}.log
  local start=$(date +%s)

  set +e
  mix "test.$alias" --max-cases "$mc" > "$logfile" 2>&1
  set -e

  local end=$(date +%s)
  local wall=$((end - start))

  # Pull "X tests, Y failures" from the last summary line. ExUnit
  # prefixes with "N features," when the suite uses Wallabidi.Feature
  # (Chrome BiDi/CDP via use Feature) but not for plain ExUnit.Case
  # suites (Lightpanda, LiveView), so match either form.
  local summary=$(grep -E "[0-9]+ tests?, [0-9]+ failures?" "$logfile" | tail -1)

  local tests=$(echo "$summary" | grep -oE "[0-9]+ tests?" | head -1 | grep -oE "[0-9]+" || echo "?")
  local fails=$(echo "$summary" | grep -oE "[0-9]+ failures?" | head -1 | grep -oE "[0-9]+" || echo "?")

  printf "%s\t%s\t%s\t%s\t%s\n" "$label" "$mc" "$wall" "$tests" "$fails" >> "$OUT"
  echo "==> $label mc=$mc: ${wall}s  ${tests} tests / ${fails} failures  (log: $logfile)"
}

for entry in "${DRIVERS[@]}"; do
  alias="${entry%%:*}"
  label="${entry#*:}"

  for mc in "${MC_LEVELS[@]}"; do
    run_cell "$alias" "$label" "$mc"
  done
done

echo
echo "=== Done. ==="
echo
column -t -s $'\t' "$OUT"
