# observability-stack

## Nginx observability — [Vector](https://vector.dev) → VictoriaLogs + VictoriaMetrics

A single **Vector** agent tails nginx's JSON access log and fans it out: raw logs to
**[VictoriaLogs](https://docs.victoriametrics.com/victorialogs/)** for drill-down, and
derived metrics to **[VictoriaMetrics](https://docs.victoriametrics.com/)** for cheap
dashboards/alerts. Grafana reads both.

> 📖 **Full design, metrics catalog, runbook, and lessons learned:**
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)

```
                          ┌─ logs ───────────────→ VictoriaLogs ──┐
nginx access.log → Vector ┤                                        ├→ Grafana
                          └─ log_to_metric → VictoriaMetrics ──────┘
```

### How it works

- **Log format** — assumes nginx's extended `json_analytics` `log_format` (one JSON object per
  line) including a `route` field. The full nginx config (`map $uri $route` + `log_format` +
  `access_log`) is in [`docs/nginx-logging.conf.example`](docs/nginx-logging.conf.example).
- **URL normalization happens in nginx**, not Vector: a `map $uri $normalized_url { … }` allowlist
  maps real paths to bounded templates (`/api/users/:id`, `/static/*`) with a `default "empty"`
  catch-all, so metric cardinality is bounded by construction. Vector consumes the `normalized_url`
  field as-is.
- **Vector** (`vector/vector.yaml`) tails `/var/log/nginx/access.log` (host path via
  `NGINX_LOG_DIR`, mounted read-only). It runs **non-root** (uid `VECTOR_UID`, default `10000`);
  a `vector-init` one-shot chowns its data volume, and `group_add` of `NGINX_LOG_GID` (the group
  owning the logs — `adm`/`4` on Debian/Ubuntu, check `getent group adm`) lets it read them. It:
  - parses each JSON line, adds `app=nginx` and a `status_class` (`2xx`…), and passes through the
    nginx-provided `normalized_url` (defaulting to `empty` if absent);
  - ships raw logs to VictoriaLogs via its Elasticsearch ingestion API (`_msg`←`request`,
    `_time`←`time_iso8601`, streams `server_name,app`);
  - derives metrics with `log_to_metric` — `nginx_http_requests_total`,
    `nginx_http_bytes_sent_total`, `nginx_request_duration_seconds` (histogram) — passes them
    through a `tag_cardinality_limit` firewall, and `remote_write`s to VictoriaMetrics.
  - Checkpoints and on-disk sink buffers live in the `vector_data` volume, so data survives
    restarts and brief backend outages.
- **VictoriaLogs** — logs in `victorialogs_data` (`VL_RETENTION`, default `30d`); API + UI on `9428` (`/select/vmui`).
- **VictoriaMetrics** — metrics in `victoriametrics_data` (`VM_RETENTION`, default `12` months); API + UI on `8428` (`/vmui`).
- **Grafana** — auto-installs the VictoriaLogs datasource plugin; provisions a **VictoriaMetrics**
  (Prometheus-type) datasource and the **Nginx Access Analytics** logs dashboard.

> The nginx container is **not** part of this stack — point `NGINX_LOG_DIR` at the host
> directory where nginx writes its logs. If nginx runs elsewhere, run Vector there and point
> its sinks at this VictoriaLogs/VictoriaMetrics.

### Cardinality note

`request_uri`, client IP, and user-agent are **high-cardinality** — they are kept in logs
(VictoriaLogs) but only the **nginx-normalized `normalized_url`** (plus bounded
`status`/`method`/`host`/`cache_status`) is used as a metric label. The `map $uri $normalized_url`
allowlist + `default "empty"` bounds it by construction; `tag_cardinality_limit`
(`value_limit: 500`) is a second backstop. To add per-URL metrics safely, add entries to the `map`
in [`docs/nginx-logging.conf.example`](docs/nginx-logging.conf.example).

### Query cheat sheet

```logsql
# VictoriaLogs (LogsQL)
status:~"5.."                                  # all 5xx
* | stats by (geoip_country_code) count() c    # requests per country
* | stats quantile(0.95, request_time) p95     # p95 latency
```
```promql
# VictoriaMetrics (PromQL / MetricsQL)
sum(rate(nginx_http_requests_total[5m])) by (status_class)
sum(rate(nginx_http_requests_total{status_class="5xx"}[5m])) / sum(rate(nginx_http_requests_total[5m]))
histogram_quantile(0.95, sum(rate(nginx_request_duration_seconds_bucket[5m])) by (le, status_class))
```

---

## Grafana

Production-ready Grafana **13.0.2** backed by PostgreSQL 17.

### Quick start

```bash
cp .env.example .env
# Edit .env – change all passwords before first run
docker compose up -d
```

Grafana is available at <http://localhost:3000>.

### What's included

| Feature | Detail |
|---|---|
| Pinned image | `grafana/grafana-oss:13.0.2` |
| Database backend | PostgreSQL 17-alpine (named volume) |
| Persistent storage | `grafana_data` + `postgres_data` named volumes |
| Health checks | Both services; Grafana waits for healthy Postgres |
| Security hardening | `no-new-privileges`, read-only container FS, secure cookies, CSP/HSTS headers, anonymous access off, sign-up disabled |
| Resource limits | Grafana: 1 CPU / 512 MB · Postgres: 0.5 CPU / 256 MB |
| Provisioning | `grafana/provisioning/` mounted read-only – drop datasource/dashboard YAML files there |
| SMTP | Disabled by default; configure via `.env` |
| Telemetry | All Grafana analytics/update-checks disabled |

### Provisioning

- **Datasources** → `grafana/provisioning/datasources/*.yml`
- **Dashboards** → `grafana/provisioning/dashboards/*.yml` + JSON files
- **Alerting** → `grafana/provisioning/alerting/*.yml`

See the `README.md` inside each directory for examples.

### Production checklist

- [ ] Set strong passwords in `.env` (never commit `.env`)
- [ ] Put Grafana behind a TLS-terminating reverse proxy (nginx, Traefik, Caddy)
- [ ] Set `GF_SERVER_ROOT_URL` and `GF_SERVER_DOMAIN` to your real domain
- [ ] Set `GF_SECURITY_COOKIE_SECURE=true` (already on; requires HTTPS)
- [ ] Configure SMTP for alert notifications
- [ ] Set up regular PostgreSQL backups (`pg_dump`)

