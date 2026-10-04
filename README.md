# observability-lab

Prometheus, node_exporter, Grafana and Grafana Alloy under Docker Compose on one Linux machine, built to answer one question: **what would this cost to send to a hosted metrics service, and which settings decide it?**

```text
                      ┌──────────── scrape every 15s, everything ───────────┐
  node_exporter ──────┤                                                     ├──► Prometheus ──► Grafana
  (+ textfile/*.prom) └──► Alloy: scrape every 60s, drop unused families ───┘   (remote write)
```

The same exporter is collected twice. Prometheus scrapes it the way a default install does (`job="node"`). Alloy scrapes it the way you would before paying for it (`job="node-via-alloy"`), and remote-writes into the same Prometheus, so the two can be counted side by side.

## The billing model it measures

Hosted Prometheus-compatible services bill by **active series**, but not only by series. Grafana Cloud's metrics invoice documentation gives the usage as:

```text
billable series = max(active series, total data points per minute / included DPM)
```

with 1 included data point per minute (DPM) per series on its Pro plan. A series scraped every 15 seconds sends 4 DPM, so it is billed as four series. **The scrape interval and the label set are both cost settings.**

## Requirements

- Linux or WSL2 with Docker Engine and the Compose plugin
- `curl` and Python 3 for `experiments.sh`
- About 1 GB of RAM

## Quick start

```bash
./write-prom.sh              # the textfile collector's input: a handful of bounded series
docker compose up -d
# wait at least six minutes for a full averaging window
./experiments.sh measure
./experiments.sh users 500   # add 500 series with an unbounded label, then measure
./experiments.sh reset
docker compose down          # add -v to drop the stored samples too
```

Prometheus is on <http://127.0.0.1:9090>, Grafana on <http://127.0.0.1:3000> (dashboard: **Cost drivers**), Alloy's UI on <http://127.0.0.1:12345>. Every port binds to loopback only; Grafana has anonymous admin access for that reason.

## What the experiments measured

One WSL2 machine with 16 logical CPUs, 4 October 2026. Data points per minute are counted from stored samples over five minutes, not derived from the configured interval.

| Pipeline | Active series | DPM | Billable series |
|---|---:|---:|---:|
| Direct scrape, 15s, everything | 1,003 | 4,012 | 4,012 |
| Alloy, 60s, unused families dropped | 505 | 505 | 505 |
| Direct scrape, plus 500 per-user series | 1,503 | 6,012 | 6,012 |
| Alloy, plus 500 per-user series | 1,005 | 1,005 | 1,005 |

- **The interval cost more than the filter saved.** Dropping half the series halved the series count; scraping every 60 seconds instead of every 15 divided the billable figure by four.
- **Name-based filtering does nothing for cardinality.** The per-user series arrived through Alloy untouched, because they belong to a metric worth keeping. The fix belongs where the metric is written: drop the `user` label, or count per user somewhere other than a time series database.
- **Most series describe the collector, not the host.** On this machine the largest families were per-CPU counters (16 CPUs × 8 modes) and `node_scrape_collector_*` — two series per collector, describing node_exporter itself.

## Alerts

[`prometheus/rules/host.yml`](prometheus/rules/host.yml) holds five alerts. Each one passed the same test: *will someone have to do something about this, and soon?* The answer is carried as `severity: page` or `severity: ticket`.

| Alert | Severity | Why it exists |
|---|---|---|
| `HostUnreachable` | page | Every other alert for the host goes quiet at the same moment |
| `DiskFullWithinFourHours` | page | Predicts with `predict_linear`; a full disk that is not growing is not an alert |
| `BackupNotSucceededIn26Hours` | ticket | Alerts on the absence of success; a job that never starts reports no failure |
| `BackupMetricMissing` | ticket | The rule above goes blind if the timestamp stops arriving; stands down when the host or the file is already alerting |
| `TextfileUnreadable` | ticket | A half-written `.prom` file takes all of its metrics with it |

Deliberately absent: CPU, memory and disk-percentage thresholds.

```bash
docker run --rm -v "$PWD/prometheus/rules:/r:ro" -w /r --entrypoint promtool \
  prom/prometheus:v3.15.0 test rules host.test.yml
```

[`host.test.yml`](prometheus/rules/host.test.yml) has twelve cases, and every alert has at least one that must fire and one that must stay quiet. Breaking each rule in turn (a static threshold instead of the prediction, a guard or a `for:` removed, a job filter dropped) was caught by a test every time.

## Things this lab taught me about itself

- **An unscoped rule turned one failure into two alerts.** The backup timestamp reaches Prometheus through both pipelines, so a rule without `job="node"` fired once per pipeline. Every rule now names its job, and a test covers it.

- **`rslave` fails on WSL.** node_exporter's documented `/:/host:ro,rslave` mount is refused because WSL's root is not a shared mount; plain `:ro` works.
- **`count_over_time()` over every metric fails** with "vector cannot contain metrics with the same labelset": it drops `__name__` first. Prometheus 3's `promql-delayed-name-removal` feature flag fixes it.
- **Remote-written samples arrive late.** A DPM window ending *now* undercounted Alloy's data points by a fifth, because the newest sample had not landed yet. The window ends a minute ago instead.
- **Prometheus's shipped config is not its default.** The binary defaults to a one-minute scrape interval; the sample `prometheus.yml` in the image sets 15 seconds. Alloy's `prometheus.scrape` defaults to 60 seconds.
- **The textfile collector reads whatever is there.** `write-prom.sh` writes to a temporary file and renames it into place, so a scrape never sees half a file.

## Licence

GPL-3.0. See [LICENSE](LICENSE).
