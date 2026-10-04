#!/usr/bin/env bash
# Measures what each job would be billed for, from the data Prometheus holds.
#
#   ./experiments.sh measure       series, data points per minute, billable series
#   ./experiments.sh users 500     add 500 per-user series at the source, then measure
#   ./experiments.sh reset         back to bounded labels only, then measure
#
# "Billable series" follows the hosted model this lab is about:
#   max(active series, data points per minute / included DPM)
# with 1 included DPM per series. Data points per minute are counted from
# the stored samples, not derived from the configured interval.
set -euo pipefail
cd "$(dirname "$0")"

PROM=${PROM:-http://127.0.0.1:9090}
WINDOW=5   # minutes of samples to average over; needs several 60s scrapes

query() {
  curl -sf --get "$PROM/api/v1/query" --data-urlencode "query=$1" |
    python3 -c 'import sys, json
for r in json.load(sys.stdin)["data"]["result"]:
    print(r["metric"].get("job", "-"), round(float(r["value"][1])))'
}

measure() {
  local series dpm
  series=$(query 'count by (job) ({job=~"node|node-via-alloy"})')
  dpm=$(query "sum by (job) (count_over_time({job=~\"node|node-via-alloy\"}[${WINDOW}m] offset 1m)) / ${WINDOW}")
  python3 - "$series" "$dpm" <<'EOF'
import sys
parse = lambda s: dict(l.split() for l in s.splitlines() if l)
series, dpm = parse(sys.argv[1]), parse(sys.argv[2])
print(f"{'job':<16}{'series':>8}{'DPM':>8}{'billable':>10}")
for job in sorted(series):
    s, d = int(series[job]), int(dpm.get(job, 0))
    print(f"{job:<16}{s:>8}{d:>8}{max(s, d):>10}")
EOF
}

settle() {
  # A full averaging window, so the DPM figure is not a blend of before and after.
  echo "waiting $((WINDOW * 60 + 90))s for a full window of samples..."
  sleep $((WINDOW * 60 + 90))
}

case ${1:-measure} in
  measure) measure ;;
  users)   ./write-prom.sh --users "${2:?how many users}"; settle; measure ;;
  reset)   ./write-prom.sh; settle; measure ;;
  *)       echo "usage: $0 measure | users N | reset" >&2; exit 2 ;;
esac
