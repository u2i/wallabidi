#!/usr/bin/env bash
# Run the perf_bench LV-scenario suite (in ../perf_bench) across each
# wallabidi driver × max_cases, producing bench/perf_bench_matrix.tsv.
#
# perf_bench is a separate Phoenix LiveView app with 33 scenario files
# (counter, form, async, components, navigation, …) that we wrote
# specifically to measure cross-driver LV-test performance. Test counts
# match what each driver can actually run — drivers that don't support
# a scenario (e.g. browser-only scenarios on the LV driver) just skip
# them.
#
# Usage:
#   bench/perf_bench_matrix.sh           # run all cells
#   bench/perf_bench_matrix.sh -f        # force re-run (truncate first)

set -u

cd "$(dirname "$0")/.."

OUT=bench/perf_bench_matrix.tsv
FORCE=${1:-}

PERF_BENCH=/Users/tom/dev/perf_bench
LP_PATH=/Users/tom/dev/lightpanda-browser/zig-out/bin/lightpanda

if [[ "$FORCE" == "-f" ]] || [[ ! -f "$OUT" ]]; then
  echo -e "driver\tmc\twall_seconds\ttests\tfailures" > "$OUT"
fi

DRIVERS=(
  "live_view:LiveView"
  "lightpanda_v2:Lightpanda"
  "chrome_cdp_v2:Chrome CDP"
  "chrome_bidi_v2:Chrome BiDi"
)

MC_LEVELS=(1 2 4 8 16)

cleanup_browsers() {
  pkill -9 -f "Google Chrome for Testing" 2>/dev/null || true
  pkill -9 -f "Chrome.*--headless"        2>/dev/null || true
  pkill -9 -f "lightpanda"                2>/dev/null || true
  pkill -9 -f "chromium-bidi"             2>/dev/null || true
  pkill -9 -f "bidi-server/run.mjs"       2>/dev/null || true
  sleep 1
}

already_done() {
  local label=$1 mc=$2
  awk -F'\t' -v d="$label" -v m="$mc" 'NR>1 && $1==d && $2==m {found=1} END {exit !found}' "$OUT"
}

run_cell() {
  local driver=$1 label=$2 mc=$3

  if already_done "$label" "$mc"; then
    echo "SKIP  $label  mc=$mc  (already in $OUT)"
    return
  fi

  echo
  echo "=== $label  mc=$mc ==="
  cleanup_browsers

  local logfile=/tmp/perf_bench_matrix_$(echo "$driver" | tr './' '__')_mc${mc}.log
  local start=$(date +%s)

  set +e
  (
    cd "$PERF_BENCH"
    env LIGHTPANDA_PATH="$LP_PATH" \
        PERF_BENCH_DRIVER=wallabidi \
        WALLABIDI_DRIVER="$driver" \
        MIX_ENV=test \
        mix test --max-cases "$mc" > "$logfile" 2>&1
  )
  set -e

  local end=$(date +%s)
  local wall=$((end - start))

  local summary=$(grep -E "[0-9]+ tests?, [0-9]+ failures?" "$logfile" | tail -1)
  local tests=$(echo "$summary" | grep -oE "[0-9]+ tests?" | head -1 | grep -oE "[0-9]+" || echo "?")
  local fails=$(echo "$summary" | grep -oE "[0-9]+ failures?" | head -1 | grep -oE "[0-9]+" || echo "?")

  printf "%s\t%s\t%s\t%s\t%s\n" "$label" "$mc" "$wall" "$tests" "$fails" >> "$OUT"
  echo "==> $label mc=$mc: ${wall}s  ${tests} tests / ${fails} failures  (log: $logfile)"
}

for entry in "${DRIVERS[@]}"; do
  driver="${entry%%:*}"
  label="${entry#*:}"
  for mc in "${MC_LEVELS[@]}"; do
    run_cell "$driver" "$label" "$mc"
  done
done

echo
echo "=== Done. ==="
echo
column -t -s $'\t' "$OUT"
