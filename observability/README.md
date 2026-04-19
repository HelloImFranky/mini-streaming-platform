# Observability Stack — Architecture & Port Reservations

This directory contains configuration for the observability layer: Prometheus, Grafana, and OpenTelemetry Collector.

---

## Components

| Component | Role | Port(s) | Image |
|-----------|------|---------|-------|
| **Prometheus** | Time-series metrics database + alert engine | `9090` | `prom/prometheus:v2.50.1` |
| **Grafana** | Metrics visualization + dashboards | `3000` | `grafana/grafana:10.3.3` |
| **OTel Collector** | OTLP trace receiver + metrics exporter | See below | `mini-streaming/otel-collector:local` (custom build) |

---

## Port Reservations — OTel Collector

The OpenTelemetry Collector exposes multiple listeners on distinct ports. This layout prevents collisions and clarifies responsibility:

| Port | Protocol | Purpose | Used By |
|------|----------|---------|---------|
| **4317** | gRPC | OTLP traces receiver | Application services (api-gateway, playback-service, etc.) |
| **4318** | HTTP | OTLP metrics receiver | Future: alternative ingestion path (metrics over HTTP) |
| **8889** | HTTP | Prometheus exporter (metrics) | Prometheus scrape target — collector's own metrics + re-exported application metrics |
| **13133** | HTTP | Health check endpoint | Docker healthcheck + Kubernetes liveness probes |
| **1777** | HTTP | pprof profiling endpoint | Debugging collector performance issues in production |
| ~~8888~~ | ~~HTTP~~ | **COLLISION — do not use** | Collector's internal telemetry server (internal, not exposed) |

### Why :8888 is Reserved (Not Exposed)

The OTel Collector's internal telemetry metrics server binds `:8888` by default. **Do not** configure any exporter on `:8888` — it will collide with this internal listener and cause the collector to fail at startup with `listen tcp 0.0.0.0:8888: bind: address already in use`.

The convention is to use `:8889` for the `prometheus` exporter, which is what is configured in `otel-collector.yaml` and published in `docker-compose.observability.yaml`.

See [incident-002 postmortem](../sre/postmortems/incident-002.md) for the debugging narrative of this collision.

---

## Startup & Health Checks

### Docker Compose

```bash
# Start the observability stack (depends on base services being up)
docker compose -f docker-compose.observability.yaml up -d

# Verify all three components are healthy
docker compose -f docker-compose.observability.yaml ps
# Expected: all three should show "Up (healthy)"

# Check healthcheck logs
docker inspect prometheus --format '{{json .State.Health}}'
docker inspect grafana --format '{{json .State.Health}}'
docker inspect otel-collector --format '{{json .State.Health}}'
```

### Kubernetes

```bash
# Services are deployed in the `streaming` namespace via infra/k8s/
# Liveness probes use the health endpoints defined above

kubectl -n streaming get pods -l app=prometheus,app=grafana,app=otel-collector
kubectl -n streaming logs -f deployment/prometheus
kubectl -n streaming logs -f deployment/grafana
kubectl -n streaming logs -f deployment/otel-collector
```

---

## Configuration Files

- **`otel-collector.yaml`** — OTel Collector config (receivers, processors, exporters, pipelines). Mounted into the container at `/etc/otelcol-contrib/config.yaml`.
  - Validated in CI via `docker run ... validate --config=/config.yaml`
  - Schema enforced by the OTel binary; invalid keys cause startup failure

- **`Dockerfile.otel-collector`** — Custom image derived from `otel/opentelemetry-collector-contrib:0.96.0`. Adds `wget` from busybox (vendor image is distroless) to support Docker healthcheck probes.

---

## Troubleshooting

### otel-collector in restart loop

**Symptoms:** `docker ps` shows `otel-collector` with status `Restarting (1) ...`

**First steps:**
1. Check logs: `docker logs otel-collector --tail 50`
2. Look for:
   - **`invalid keys: ...`** — stale config key not recognized by the schema. Remove it.
   - **`listen tcp 0.0.0.0:XXXX: bind: address already in use`** — port collision. Check all configured ports (receivers, exporters, health, pprof). If `:8888` appears, move the exporter to `:8889`.
   - **`failed to get config`** — syntax error in YAML. Validate locally with `docker run otel/opentelemetry-collector-contrib:0.96.0 validate --config=./otel-collector.yaml`.

3. After fixing the config, restart:
   ```bash
   # For config file changes only:
   docker compose -f docker-compose.observability.yaml restart otel-collector
   
   # For compose-file changes (ports, env, volumes):
   docker compose -f docker-compose.observability.yaml up -d otel-collector
   ```

4. Verify: `docker ps` should show `otel-collector Up (healthy)` after 15-30 seconds.

### Prometheus can't scrape otel-collector metrics

**Symptoms:** Prometheus dashboard shows "no data" for OTel metrics. Prometheus targets page shows otel-collector scrape failing.

**Root cause:** Prometheus scrape target is misconfigured or the port changed.

**Fix:**
1. Check `infra/prometheus/prometheus.yml` for the otel-collector scrape job. Should be:
   ```yaml
   - job_name: "otel-collector"
     static_configs:
       - targets: ["otel-collector:8889"]
   ```
2. Verify the collector exports to `:8889`: `docker ps | grep otel-collector` should show `8889:8889` in ports.
3. Test the endpoint: `curl http://localhost:8889/metrics` should return Prometheus-format output.
4. If Prometheus is in Kubernetes, ensure the scrape target uses the service DNS: `otel-collector.streaming.svc.cluster.local:8889`.

---

## SLOs & Alerting

The observability stack itself is **not** covered by application SLOs (99.9% availability, p95 < 250ms). However:

- **Prometheus uptime** is monitored via healthchecks (Docker) / liveness probes (K8s). Target: keep it up for operational visibility.
- **Alerting latency** is not SLO-bound but should be < 30s from alert rule evaluation to notification (Prometheus default: 15s eval interval).
- **OTel trace export** is a best-effort pipeline. If the collector is down, traces are dropped but application availability is unaffected (application services continue to run).

---

## References

- [OTel Collector documentation](https://opentelemetry.io/docs/collector/)
- [Incident-002 Postmortem](../sre/postmortems/incident-002.md) — full analysis of the port collision and recovery
- [Prometheus Scrape Configuration](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config)
