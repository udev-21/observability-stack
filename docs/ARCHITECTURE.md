# Observability Stack — Architecture & Design

End-to-end nginx observability: a single **Vector** agent tails nginx's JSON access log,
ships raw logs to **VictoriaLogs** and derives bounded metrics into **VictoriaMetrics**,
both visualized in **Grafana** (backed by PostgreSQL).

This document captures *what* was built, *why*, and the *non-obvious lessons* learned while
building and operating it.

---

## 1. High-level architecture

```
                          ┌───────────────────────────► VictoriaLogs  (logs DB, :9428) ─┐
nginx access.log (JSON) ─► Vector                                                         ├─► Grafana (:3000)
  (json_analytics)         └─ log_to_metric ───────────► VictoriaMetrics (TSDB, :8428) ──┘        │
                                                                                            PostgreSQL (Grafana state)
```

- **nginx** is *not* part of the stack — it writes `access.log` to a host directory that Vector
  reads (`NGINX_LOG_DIR`, mounted read-only).
- **Vector** is the only agent. It does parsing, enrichment, normalization, log shipping,
  log→metric conversion, and cardinality control.
- **VictoriaLogs** stores every field of every request (high-cardinality friendly).
- **VictoriaMetrics** stores pre-aggregated, bounded-label time series (cheap dashboards/alerts).
- **Grafana** reads both via two provisioned datasources.

### Services (docker-compose)

| Service | Image | Port | Role |
|---|---|---|---|
| `postgres` | `postgres:17-alpine` | 5432 (internal) | Grafana metadata store |
| `grafana` | `grafana/grafana-oss:13.0.2` | 3000 | UI; auto-installs `victoriametrics-logs-datasource` |
| `victorialogs` | `victoriametrics/victoria-logs:v1.50.0` | 9428 | log database + vmui + ingestion API |
| `victoriametrics` | `victoriametrics/victoria-metrics:v1.145.0` | 8428 | TSDB + vmui + remote_write target |
| `vector-init` | `busybox:1.37` | — | one-shot: chowns `vector_data` for non-root Vector |
| `vector` | `timberio/vector:0.56.0-distroless-libc` | — | the pipeline (runs non-root) |

Volumes: `postgres_data`, `grafana_data`, `victorialogs_data`, `victoriametrics_data`, `vector_data`.

---

## 2. Data flow & the Vector pipeline

The log file is read by **two independent file sources** (see §4.1 for why):

```
nginx access.log
  ├─ source "nginx"          read_from: beginning ─► enrich ─────────────► sink victorialogs   (raw logs)
  └─ source "nginx_metrics"  read_from: end        ─► enrich_metrics ─┬──► metric_prep ─► to_metrics ─┐
                                                                      └──► upstream_filter ─► upstream_prep ─► upstream_metrics ─┴─► cap ─► sink victoriametrics
```

### Transforms

| Component | Type | Purpose |
|---|---|---|
| `enrich` / `enrich_metrics` | `remap` (VRL) | `parse_json!(.message)`; add `app=nginx`, `status_class` (`2xx`…), pass through `normalized_url` (default `empty`). Two copies, one per source. |
| `metric_prep` | `remap` | Coerce numeric strings → numbers (`request_time`, `bytes_sent`, `tcpinfo_rtt`→s, …); normalize bounded labels (empty → `none`); normalize `content_type` (strip params/lowercase); derive `completion` (ok/incomplete). |
| `to_metrics` | `log_to_metric` | Emit the general metrics (every request). |
| `upstream_filter` | `filter` | Keep only requests that hit a backend (`upstream` not `-`/empty). |
| `upstream_prep` | `remap` | Take the **final** value from multi-valued upstream fields (retries: `a, b`; redirects: `a : b`). |
| `upstream_metrics` | `log_to_metric` | Emit upstream metrics (proxied requests only). |
| `cap` | `tag_cardinality_limit` | `value_limit: 500` per tag, `drop_tag` on exceed — a safety net over all metric streams. |

### Sinks

- **victorialogs** — `elasticsearch` sink → `http://victorialogs:9428/insert/elasticsearch/`,
  `_msg_field=request`, `_time_field=time_iso8601`, `_stream_fields=server_name,app`. Disk buffer 256 MiB.
- **victoriametrics** — `prometheus_remote_write` → `http://victoriametrics:8428/api/v1/write`,
  histogram `buckets=[0.001 … 10]` (seconds). Disk buffer 256 MiB.

---

## 3. The log format & URL normalization

nginx emits the extended `json_analytics` `log_format` (one JSON object per line) — see
[`nginx-logging.conf.example`](nginx-logging.conf.example). All `*_time` fields are **seconds**
(ms resolution); all values are JSON strings (nginx quotes everything via `escape=json`).

**URL normalization happens in nginx, not Vector.** A `map $uri $normalized_url { … }` allowlist
maps real paths to bounded templates (`/api/users/:id`, `/static/*`) with a `default "other"`
catch-all. This bounds metric cardinality **by construction** (number of map entries + 1). Vector
just reads the `normalized_url` field; if absent/blank it defaults to `empty`.

> Until the nginx `map` is deployed, `normalized_url` is `empty` for all requests — raw
> `request_uri` is still in the logs, so nothing is lost.

---

## 4. Key design decisions (the "why")

### 4.1 Two file sources — `read_from end` for metrics only

Metrics are **forward-looking aggregates**; logs are a **historical record**. A single source
forces one policy on both. The split lets:
- **logs** backfill from the file's beginning (full history in VictoriaLogs, at real timestamps), and
- **metrics** start at the file's end (no replay of history into counters → no startup spike).

Each source keeps its own checkpoint in `vector_data` (keyed by component + file fingerprint).
Cost: the file is read twice (negligible for tailing).

### 4.2 Vector for everything (vs vlagent / dedicated exporter)

Considered: `vlagent`→VictoriaLogs for logs + `prometheus-nginxlog-exporter`→vmagent for metrics.
Chose Vector because **one agent** does parse + enrich + normalize + log-ship + metricize +
cardinality control, and VRL is far more capable than relabel-regex for normalization. Trade-off:
heavier than single-purpose agents, and a Vector fault affects both signals.

### 4.3 Cardinality discipline (the core constraint)

A metric label = one time series per distinct value; per-series cost multiplies across labels,
and **histograms multiply again by bucket count**. Rules applied:
- **Only bounded fields are labels:** `status`, `status_class`, `method`, `scheme`,
  `server_protocol`, `http2`, `host`, `ssl_protocol`, `ssl_session_reused`, `upstream`,
  `upstream_status`, `cache_status`, `country`, `content_type` (normalized), `normalized_url`,
  `limit_*_status`.
- **High-cardinality fields stay in logs only:** raw `request_uri`, `remote_addr`,
  `http_user_agent`, `http_referer`, `ssl_cipher`, forwarded IPs.
- **Histograms carry minimal labels** (no `normalized_url`) — they multiply by ~12 buckets.
- **Two backstops:** nginx `map` allowlist (bounds by construction) + Vector
  `tag_cardinality_limit` (`value_limit: 500`, caps each tag key — but **not** the combinatorial
  product, so label counts per metric are kept small deliberately).
- **Split, narrow metrics** instead of one mega-counter (e.g. `nginx_tls_requests_total`,
  `nginx_protocol_requests_total`, … each with a tiny label set).

### 4.4 Metrics vs logs division of labor

| Question shape | Tool |
|---|---|
| Rates, error %, latency quantiles, trends, alerts | **VictoriaMetrics** (PromQL) |
| "Top N of a high-cardinality thing" (URIs, IPs, UAs, referers) | **VictoriaLogs** (LogsQL `stats`) |
| "Why did *this* request fail?" / per-request forensics | **VictoriaLogs** |
| Exact ledger counts (no extrapolation) | **VictoriaLogs** `count()` |

### 4.5 Non-root Vector

Vector runs as `VECTOR_UID` (default 10000). Two obstacles solved in compose:
- **Reading root-owned logs** (`640 root:adm`) → `group_add: [NGINX_LOG_GID]` (`adm`=4 on Debian/Ubuntu).
- **Writing its data_dir** (named volumes are root-owned) → `vector-init` one-shot `chown`s the
  volume before Vector starts (`depends_on: service_completed_successfully`).

---

## 5. Metrics catalog (emitted by Vector)

General (every request):

| Metric | Type | Labels |
|---|---|---|
| `nginx_http_requests_total` | counter | host, method, status, status_class, normalized_url |
| `nginx_http_bytes_sent_total` | counter | host, status_class, normalized_url |
| `nginx_http_request_bytes_total` | counter | host, method |
| `nginx_cache_total` | counter | host, cache_status |
| `nginx_tls_requests_total` | counter | host, ssl_protocol, ssl_session_reused |
| `nginx_protocol_requests_total` | counter | host, scheme, server_protocol, http2 |
| `nginx_requests_by_country_total` | counter | country, status_class |
| `nginx_content_type_requests_total` | counter | content_type, status_class |
| `nginx_content_type_bytes_total` | counter | content_type |
| `nginx_response_completion_total` | counter | host, completion, status_class |
| `nginx_ratelimit_total` | counter | host, result |
| `nginx_connlimit_total` | counter | host, result |
| `nginx_request_duration_seconds` | histogram | host, method, status_class |
| `nginx_client_rtt_seconds` | histogram | country |

Upstream (proxied requests only — `upstream_filter`):

| Metric | Type | Labels |
|---|---|---|
| `nginx_upstream_responses_total` | counter | host, upstream, upstream_status |
| `nginx_upstream_bytes_received_total` | counter | host, upstream |
| `nginx_upstream_bytes_sent_total` | counter | host, upstream |
| `nginx_upstream_response_seconds` | histogram | host, upstream |
| `nginx_upstream_connect_seconds` | histogram | host |
| `nginx_upstream_header_seconds` | histogram | host |

Histogram buckets (seconds, shared): `0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0`.

The full superset of *possible* metrics (incl. logs-only ones) is catalogued in
[`metrics_plan_extended.txt`](../metrics_plan_extended.txt).

---

## 6. Dashboards

Provisioned via `grafana/provisioning/dashboards/nginx.yml` (folder "Nginx").

- **`nginx-metrics.json`** — 29 panels on the VictoriaMetrics datasource, with a `$host` template
  filter. Sections: Overview (RPS, 5xx ratio, p95, cache hit, bandwidth, TLS resumption) ·
  Request counts (`increase[$__range]` tables/bargauges) · Traffic · Errors & reliability ·
  Latency (request/upstream/RTT quantiles) · Edge (TLS/cache/geo/limits) · Bandwidth & capacity.

Logs are explored via VictoriaLogs vmui (`:9428/select/vmui`) or LogsQL queries (see §8); a logs
dashboard can be added on the VictoriaLogs datasource if desired.

---

## 7. Deep analysis — lessons & gotchas

Hard-won, non-obvious knowledge from building and operating this:

### Metrics semantics
1. **Backfill produces a spike, not a timeline.** `log_to_metric` stamps metrics at *processing
   time*, not the log's `time_iso8601` (and `. = parse_json!` wipes Vector's own timestamp). So
   replaying old logs counts every historical request "now" → one giant `rate()` spike, never a
   historical trend. History belongs in logs.
2. **`rate()`/`histogram_quantile()` need a *live, increasing* counter.** With no new traffic the
   counter is flat → `rate()` returns **empty** (not 0). `histogram_quantile()` of all-zero buckets
   = NaN = **"No data"**. This is correct behavior, not a bug — the dashboard needs ongoing traffic.
3. **`increase([$__range])` is near-exact, not integer.** Edge extrapolation makes counts slightly
   fractional. For exact tallies, count log rows in VictoriaLogs.

### Datasource / query engine
4. **LogsQL only runs on VictoriaLogs; PromQL/MetricsQL only on VictoriaMetrics.** Running
   `* | stats …` against VM gives `422 … unexpected token "*"`. Rule: `* | stats` → VictoriaLogs;
   `rate()`, `histogram_quantile()`, `{label=…}` → VictoriaMetrics.
5. **Empty panels are usually the time range.** vmui/Grafana default to a recent window; backfilled
   data sits in the past → widen the range. (`request_time`, all `*_time` are **seconds**.)

### Vector / VRL
6. **The `file` source has no `decoding` option** — parse JSON in a `remap` (`. = parse_json!(.message)`).
7. **`??` catches errors, not `null`.** Array indexing returns `null`, so `parts[0] ?? "x"` is
   rejected (`E651`) while `replace(parts[0], …)` is fallible (`E103`). Use `string(parts[0]) ?? "x"`.
8. **Vector interpolates `$VAR` across the whole config — even in comments/VRL.** A literal `$uri`
   in a comment becomes a "missing environment variable" error. Avoid `$` or escape as `$$`.
9. **nginx multi-value upstream fields use `, ` / ` : ` separators with whitespace**; a naive
   `[,:]` regex eats the colon in `addr:port`. Match `[,:]\s+` (separator *plus* whitespace).

### Operations
10. **Distroless images (Vector, VictoriaLogs/Metrics) have no shell** → no `CMD-SHELL`
    healthchecks and no `docker exec`. Inspect via their HTTP `/metrics`, the host-mounted volume
    (busybox sidecar), or `docker compose logs`.
11. **Backfilling a huge log is heavy.** A 2.28 GB history raced through the logs source flooded
    VictoriaLogs and, with Vector capped at 384 MB, **stalled the metrics sink** (130 MB stuck in
    its disk buffer, FIFO-blocking fresh data). Restarting cleared the stall; clearing the buffer +
    spike series gave a clean slate. Lesson: don't backfill multi-GB logs casually — prefer
    `read_from: end` on the logs source too, or raise Vector's memory/buffer for a deliberate load.
12. **Vector disk buffers are FIFO and persistent.** A backlog of stale/junk metrics delays fresh
    ones; they live in `vector_data/buffer/v2/<sink>` and survive restarts (clear by stopping
    Vector and removing the sink's buffer dir).
13. **Counter resets on Vector restart are normal** — `prometheus_remote_write` accumulates
    incremental counters in memory; a restart resets them and `rate()`/`increase()` handle the reset.
14. **VictoriaLogs silently drops entries older than `-retentionPeriod`.** Ingestion returns
    HTTP 200 but the row is discarded (only a throttled `warn` in the VL log). This bites
    historical backfill: importing logs older than `VL_RETENTION` (default 30 d) stores nothing.

---

## 8. Operations runbook

### Deploy
```bash
cp .env.example .env          # set passwords, NGINX_LOG_DIR, NGINX_LOG_GID (getent group adm)
docker compose up -d
```
UIs: Grafana `:3000` · VictoriaLogs `:9428/select/vmui` · VictoriaMetrics `:8428/vmui`.

### Verify logs reaching VictoriaLogs
```bash
curl -s 'http://localhost:9428/select/logsql/query' \
  --data-urlencode 'query=* | stats count() logs' --data-urlencode 'start=2020-01-01T00:00:00Z'
curl -s http://localhost:9428/metrics | grep -i ingested        # vl_bytes_ingested_total rising
```

### Verify metrics reaching VictoriaMetrics
```bash
curl -s http://localhost:8428/api/v1/status/tsdb | python3 -m json.tool   # series per metric
curl -s http://localhost:8428/metrics | grep 'vm_rows_inserted_total'      # rising = ingesting
```

### Useful LogsQL (VictoriaLogs)
```logsql
* | stats by (remote_addr) count() requests | sort by (requests desc) | limit 20       # top client IPs
* | stats quantile(0.95, request_time) p95, quantile(0.99, request_time) p99           # latency (seconds)
http_user_agent:!"" | stats by (http_user_agent) count() c | sort by (c desc) | limit 20  # top UAs
status:~"5.." | stats by (request_uri) count() errs | sort by (errs desc)              # 5xx by URL
```

### Useful PromQL (VictoriaMetrics)
```promql
sum(rate(nginx_http_requests_total[$__rate_interval]))                                  # RPS
sum(rate(nginx_http_requests_total{status_class="5xx"}[5m])) / sum(rate(nginx_http_requests_total[5m]))  # 5xx ratio
histogram_quantile(0.95, sum(rate(nginx_request_duration_seconds_bucket[5m])) by (le))  # p95 latency
sum by (method,status)(increase(nginx_http_requests_total[$__range]))                   # counts in range
```

### Troubleshooting "No data" on metric panels
1. **Time range** — widen it; data may be in the past or only briefly live.
2. **No live traffic** — flat counters → `rate()` empty. Confirm with
   `increase(nginx_http_requests_total[2h])` (works on a static backfill) vs `rate(...[5m])` (empty).
3. **Wrong datasource** — LogsQL on VM gives a 422; use the VictoriaLogs datasource for `* | stats`.
4. **Sink stalled / buffer growing** — check `vector_data/buffer/v2/victoriametrics` size and
   `vm_rows_inserted_total`; restart Vector to clear a stall.

### Backfilling already-rotated logs

The live pipeline watches only the active `access.log` (glob `/var/log/nginx/access.log`), so
**already-rotated files (`access.log.1`, `*.gz`) are never read** — and Vector can't read `.gz`
anyway. To import them into VictoriaLogs (logs only — historical data can't become meaningful
metrics, see §7.1), use the helper:

```bash
scripts/backfill-rotated-logs.sh /var/log/nginx/access.log.*.gz /var/log/nginx/access.log.1
scripts/backfill-rotated-logs.sh --dry-run logs/access.log.*      # preview + first timestamps
```

It decompresses `.gz`, streams ndjson straight to `/insert/jsonline` (mapping `_time`←`time_iso8601`,
`_msg`←`request`), and records a content fingerprint per file in a **state file** so re-runs never
duplicate (VictoriaLogs does **not** dedupe). It refuses an exact `access.log` basename (already
ingested by Vector) unless `--force`.

> **Retention caveat:** VictoriaLogs silently drops entries older than `-retentionPeriod`
> (`VL_RETENTION`, default `30d`) — HTTP 200, nothing stored. To backfill older logs, raise
> `VL_RETENTION` and recreate the `victorialogs` service **first**. The script prints each file's
> first timestamp so you can check against the window.

---

## 9. Known limitations & future work

- **`normalized_url` requires the nginx `map`** to be deployed; otherwise it's `empty` everywhere
  (and the Top-URLs metric panel is uninformative). Raw `request_uri` remains in logs.
- **No logs dashboard** is currently provisioned (only metrics). Logs via vmui/LogsQL for now.
- **Referer/UA classification not implemented as metrics** (deliberately) — top referers/UAs are
  done via LogsQL; bounded `referer_class` / `ua_class` metrics can be added via nginx `map` later.
- **Extreme-tail latency** (>10 s, e.g. WebSockets like `/api/live/ws`) lands in the histogram
  `+Inf` bucket — fine for p95/p99, but use logs for "the single slowest request." Consider
  excluding long-lived endpoints from latency SLOs.
- **Single-node** VictoriaLogs/Metrics; no alerting rules (`vmalert`) configured yet.
- **Backfill caution** — see §7.11; large historical loads need a deliberate plan.

---

## 10. File map

| Path | Purpose |
|---|---|
| `docker-compose.yml` | All services, volumes, network, non-root Vector + init |
| `.env.example` | Config knobs (secrets, `NGINX_LOG_DIR`, `VECTOR_UID`, `NGINX_LOG_GID`, retentions) |
| `vector/vector.yaml` | The pipeline (2 sources, transforms, 2 sinks) |
| `grafana/provisioning/datasources/victorialogs.yml` | VictoriaLogs datasource (plugin) |
| `grafana/provisioning/datasources/victoriametrics.yml` | VictoriaMetrics datasource (Prometheus type) |
| `grafana/provisioning/dashboards/nginx.yml` | Dashboard provider |
| `grafana/provisioning/dashboards/nginx-metrics.json` | The metrics dashboard (29 panels) |
| `docs/nginx-logging.conf.example` | nginx `map` + extended `log_format` + `access_log` |
| `docs/ARCHITECTURE.md` | This document |
| `scripts/backfill-rotated-logs.sh` | One-time import of rotated/archived logs into VictoriaLogs |
| `metrics_plan.txt` / `metrics_plan_extended.txt` | Full metric catalogs (incl. logs-only) |
| `README.md` | Quick start + overview |
