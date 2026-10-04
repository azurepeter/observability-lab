#!/usr/bin/env bash
# Writes textfile/lab.prom for node_exporter's textfile collector.
#
#   ./write-prom.sh                 bounded labels only: a handful of series
#   ./write-prom.sh --users 500     also one series per user — the mistake
#
# The file is written to a temporary name and renamed into place. A rename
# within one directory is atomic, so node_exporter never reads half a file;
# writing lab.prom directly can expose a truncated file to a scrape.
set -euo pipefail

users=0
if [[ ${1:-} == --users ]]; then users=${2:?--users needs a number}; fi

dir="$(dirname "$0")/textfile"
mkdir -p "$dir"
tmp="$(mktemp "$dir/.lab.prom.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

now=$(date +%s)
{
  echo '# HELP lab_backup_last_success_timestamp_seconds When the nightly backup last succeeded.'
  echo '# TYPE lab_backup_last_success_timestamp_seconds gauge'
  echo "lab_backup_last_success_timestamp_seconds $((now - 3600))"

  echo '# HELP lab_jobs_total Jobs processed, by outcome.'
  echo '# TYPE lab_jobs_total counter'
  for status in ok retried failed; do
    echo "lab_jobs_total{status=\"$status\"} $((RANDOM % 1000))"
  done

  if (( users > 0 )); then
    echo '# HELP lab_requests_total Requests, by user. Unbounded label: do not do this.'
    echo '# TYPE lab_requests_total counter'
    for ((i = 1; i <= users; i++)); do
      printf 'lab_requests_total{user="user-%05d"} %d\n' "$i" $((RANDOM % 100))
    done
  fi
} > "$tmp"

chmod 644 "$tmp"
mv "$tmp" "$dir/lab.prom"
trap - EXIT
