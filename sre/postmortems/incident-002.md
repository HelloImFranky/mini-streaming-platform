# Postmortem: OpenTelemetry Collector Crash Loop

**Incident ID:** INC-002
**Date:** 2026-04-15
**Severity:** SEV-4
**Duration:** ~15 minutes (15:57 – 16:12 UTC)
**Status:** Resolved
**Author:** On-Call SRE
**Last Updated:** 2026-04-15

---

## Impact

- `otel-collector` container in restart loop; exited with status 1 every ~60 seconds
- **No user-facing impact** — traces and metrics from the 4 application services could not be exported, but Prometheus scraping of `/metrics` endpoints was unaffected, so the Grafana dashboard and alerts continued to function
- Complete loss of trace export for the duration of the incident
- Observability stack ran in a degraded state (metrics-only) for 15 minutes

---

## Timeline

| Time (UTC) | Event |
|------------|-------|
| 15:57 | `otel-collector` container enters restart loop. Docker logs show two distinct errors across restart attempts: an invalid `file_format` key in the config parse stage, and `listen tcp 0.0.0.0:8888: bind: address already in use` during pipeline startup |
| 16:00 | On-call inspects `observability/otel-collector.yaml` and identifies two independent misconfigurations: (1) a stale `file_format` key carried over from a prior config, and (2) a port collision — the `prometheus` exporter is configured on `:8888`, which is also the default bind for the collector's own internal telemetry metrics server |
| 16:03 | Removes the invalid `file_format` key. Moves the `prometheus` exporter endpoint from `:8888` to `:8889` (the convention used in OTel's own documentation examples to avoid this exact collision) |
| 16:05 | Updates `docker-compose.observability.yaml` ports list to publish `:8889`. Updates `infra/prometheus/prometheus.yml` scrape target to match |
| 16:08 | Runs `docker compose -f docker-compose.observability.yaml up -d otel-collector` — the correct command for a compose-spec change (ports), not `restart`, which would not reconcile the new port publication |
| 16:10 | Container comes up healthy; OTLP gRPC on `:4317`, Prometheus-exposed metrics on `:8889` |
| 16:12 | Verified via `docker ps` — `otel-collector` status `Up`, no more restart loop |

---

## Root Cause

Two independent misconfigurations in the original collector config, both surfaced during the restart loop:

1. **Invalid `file_format` key** — a stale configuration artifact rejected by the collector's schema validation. This caused the initial parse failure before any pipeline could start.
2. **Port `:8888` collision within the collector process itself.** The `prometheus` exporter and the collector's own internal telemetry metrics server both default to `:8888`. Only one can bind; the second bind attempt returned `address already in use` — an error typically associated with *cross-container* conflicts, but in this case both listeners belonged to the same process.

Resolution: remove the invalid key, and move the `prometheus` exporter endpoint to `:8889` — the convention in OTel's own documentation examples, specifically to avoid this internal collision.

---

## Contributing Factors

1. **No config validation in CI.** The OTel Collector config is not schema-validated before deployment. The first signal of an invalid config is the container crashing in its target environment. A pre-merge `otelcol validate --config` check would have caught the `file_format` key without ever starting a container.
2. **No healthcheck integration in docker-compose.** Although the collector exposes `health_check` on `:13133`, the `docker-compose.observability.yaml` service did not declare a `healthcheck:` block — so a crash-looping container was visible only via `docker ps` `Restarting` status, not via compose health signals.
3. **Port `:8888` collision is non-obvious.** Neither the OTel docs nor the error message explicitly warn that the `prometheus` exporter and the internal telemetry server both default to `:8888`. This collision is documented only in community issues and example configs.
4. **`docker compose restart` vs `up` distinction.** `restart` re-runs the process but does not reconcile the container against an updated compose spec. Recreation (`up -d`) is required for any change to ports, env vars, or volumes. An engineer unfamiliar with this distinction could spend cycles wondering why a port change has not taken effect.

---

## What Went Well

- **Trace export failure did not cascade.** Metrics-only observability continued to function; Prometheus scraping was independent of the collector's OTLP pipeline, so dashboards and alerts remained operational.
- **Error messages were literal and actionable.** Each error pointed at a specific line or component. The final fix (`:8888 → :8889`) was directly implied by the bind error.
- **Local environment only.** No production blast radius; the incident served as a learning artifact for strengthening observability-stack hygiene.

---

## Action Items

| # | Action | Owner | Status | Reference |
|---|--------|-------|--------|-----------|
| 1 | Move `prometheus` exporter to `:8889` to avoid internal telemetry collision | SRE | Done | `observability/otel-collector.yaml` line 27 |
| 2 | Publish `:8889` in compose ports list and update Prometheus scrape target | SRE | Done | `docker-compose.observability.yaml`, `infra/prometheus/prometheus.yml` |
| 3 | Add `healthcheck:` to `otel-collector` compose service using `:13133/health` | SRE | Done | `docker-compose.observability.yaml`; custom image in `observability/Dockerfile.otel-collector` (vendor image is distroless — wget added via busybox multi-stage) |
| 4 | Add CI step to validate OTel Collector config with `otelcol validate --config` | SRE | Pending | `.github/workflows/ci.yaml` |
| 5 | Document port reservations (4317 OTLP gRPC, 4318 OTLP HTTP, 8888 collector internal, 8889 prometheus exporter, 13133 health, 1777 pprof) | SRE | Pending | `observability/README.md` |
| 6 | Add runbook entry: "otel-collector in restart loop — first steps" | SRE | Pending | `sre/runbooks/otel-collector.md` |

---

## Lessons Learned

**Port conflicts can originate inside a single process.** `address already in use` is conventionally read as "another container is bound to this port," but the OTel Collector demonstrates that a single process can host multiple listeners, and their defaults can collide. When investigating bind errors, check the component's own defaults (internal telemetry, pprof, health check endpoints) before assuming an external conflict.

**`docker compose restart` reloads the process; `up` reconciles the spec.** Changes to mounted config files are picked up by `restart`. Changes to the compose file itself (ports, env, volumes, image) require `up -d` to recreate the container. Knowing which to use saves a confusing debugging cycle where "the fix is in, why doesn't it work."

**Observability components deserve their own observability.** A crash-looping collector was only visible via `docker ps` because no healthcheck was declared. For the application services the collector monitors, a failing healthcheck would have alerted. Applying the same standard to the observability stack itself closes a meta-monitoring gap — now addressed via the `healthcheck:` block against the collector's `:13133` endpoint.

**Config validation belongs in CI, not in production.** The `file_format` key was invalid and could have been caught by `otelcol validate --config` before merge. Any component with a schema-enforced config should be linted in CI the same way code is.
