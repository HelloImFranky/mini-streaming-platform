# Runbook: otel-collector in Restart Loop

**Service:** OpenTelemetry Collector (`otel-collector`)
**Severity Guide:** SEV-4 (observability-only; no user impact). Escalate to SEV-3 only if prolonged and tracing is on the critical path for an active incident investigation.
**On-call Expected Resolution:** 15 minutes
**Related Postmortem:** [INC-002](../postmortems/incident-002.md)

---

## Symptoms

One or more of:

- `docker ps` shows `otel-collector` with status `Restarting (1) N seconds ago`
- `docker compose ps` shows `otel-collector` with status `exited (1)` cycling
- Kubernetes: pod `otel-collector-*` in `CrashLoopBackOff` state
- Grafana trace panels show no data; Prometheus `/metrics` continues to work
- Alert: `ObservabilityComponentDown` fires (if configured)

---

## First Steps (2 minutes)

### 1. Get the error

**Docker:**
```bash
docker logs otel-collector --tail 50
```

**Kubernetes:**
```bash
kubectl -n streaming logs -l app=otel-collector --tail=50 --previous
# --previous is important: current pod is crashing, last error is in the previous container
```

### 2. Match the error to one of these patterns

| Error Pattern | Root Cause | Jump To |
|---|---|---|
| `invalid keys: <name>` | Stale/unknown config key rejected by schema | [Fix A](#fix-a-invalid-config-key) |
| `unknown type: "<name>" for id: "<name>"` | Component type doesn't exist in this distribution | [Fix B](#fix-b-unknown-component-type) |
| `listen tcp 0.0.0.0:XXXX: bind: address already in use` | Port collision | [Fix C](#fix-c-port-collision) |
| `failed to get config: cannot unmarshal` | YAML syntax error | [Fix D](#fix-d-yaml-syntax) |
| `no such host` or DNS errors | Network/DNS issue, often with exporter endpoints | [Fix E](#fix-e-network-dns) |
| `OOMKilled` (status code 137) | Memory limit too low | [Fix F](#fix-f-memory-pressure) |

If the error matches none of the above, [escalate](#escalation).

---

## Fix A: Invalid Config Key

**Error:** `'' has invalid keys: <key_name>`

**What it means:** The config contains a key that the OTel Collector's schema does not recognize in that context. Common causes: config written against an older/newer version of the collector, or a typo.

**Steps:**

1. Identify the invalid key from the error message.
2. Open `observability/otel-collector.yaml` and locate the key.
3. Decide: is this key misplaced (valid elsewhere) or stale (remove it entirely)?
   - Cross-reference with the [OTel Collector config spec](https://opentelemetry.io/docs/collector/configuration/) for the version in use.
4. Remove or relocate the key.
5. Validate locally before restart:
   ```bash
   docker run --rm \
     -v "$(pwd)/observability/otel-collector.yaml:/config.yaml:ro" \
     otel/opentelemetry-collector-contrib:0.96.0 \
     validate --config=/config.yaml
   ```
   Exit code 0 with no output = valid.
6. Restart: `docker compose -f docker-compose.observability.yaml restart otel-collector`

---

## Fix B: Unknown Component Type

**Error:** `unknown type: "<name>" for id: "<name>" (valid values: [...])`

**What it means:** You referenced a receiver/processor/exporter type that doesn't exist in the `contrib` distribution being used. The error message lists all valid values.

**Steps:**

1. Identify which component type is unknown (receiver, processor, or exporter — check the error prefix).
2. Review the list of valid values in the error message.
3. Common confusions:
   - `file` → doesn't exist. Use `filelog` (for log ingestion) or `otlpjsonfile` (for OTLP JSON files).
   - `logging` exporter → deprecated in newer versions. Use `debug` exporter instead.
4. Update `observability/otel-collector.yaml` with a valid type from the list.
5. Validate and restart (same commands as [Fix A](#fix-a-invalid-config-key) steps 5-6).

---

## Fix C: Port Collision

**Error:** `listen tcp 0.0.0.0:XXXX: bind: address already in use`

**What it means:** Two listeners want the same port. This can happen:
- **Between two containers** on the same Docker network (most common case)
- **Within a single process** — the OTel Collector has multiple internal listeners and their defaults can collide (see INC-002)

**Steps:**

1. Note the port number from the error (`XXXX`).
2. Check if the port is `:8888`:
   - **Yes** → This is the internal telemetry vs prometheus exporter collision. Move the `prometheus` exporter to `:8889`:
     ```yaml
     # observability/otel-collector.yaml
     exporters:
       prometheus:
         endpoint: "0.0.0.0:8889"   # NOT :8888
     ```
3. Check the port reservation table in [observability/README.md](../../observability/README.md#port-reservations--otel-collector) to confirm which listener owns this port.
4. If the port is used by another container:
   ```bash
   docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep ":XXXX"
   ```
   Stop the conflicting container or reassign the collector's port.
5. If you change the collector's port, **also update**:
   - `docker-compose.observability.yaml` `ports:` list
   - `infra/prometheus/prometheus.yml` scrape target (if it was the Prometheus exporter port)
6. Apply changes:
   ```bash
   # Port change is a compose-spec change, not just a config change:
   docker compose -f docker-compose.observability.yaml up -d otel-collector
   ```

---

## Fix D: YAML Syntax

**Error:** `failed to get config: cannot unmarshal the configuration` or similar parse errors

**What it means:** The YAML itself doesn't parse — bad indentation, missing colon, unquoted special characters.

**Steps:**

1. Validate YAML syntax independently:
   ```bash
   python3 -c "import yaml; yaml.safe_load(open('observability/otel-collector.yaml'))"
   ```
   Errors point at a specific line.
2. Common issues:
   - Tabs mixed with spaces
   - Missing space after `:` in key-value pairs
   - Unquoted values starting with `*`, `&`, or `!`
3. Fix and re-validate with the OTel binary as in [Fix A](#fix-a-invalid-config-key) step 5.

---

## Fix E: Network / DNS

**Error:** `no such host` or `connection refused` pointing at an exporter endpoint (e.g., a remote OTLP backend)

**What it means:** The collector can parse the config but can't reach a downstream exporter target.

**Steps:**

1. Identify the unreachable host from the error.
2. Test DNS from inside the collector's network:
   ```bash
   docker run --rm --network streaming-net busybox nslookup <hostname>
   ```
3. If the target is another compose service, confirm it's on the same `streaming-net` network.
4. If the target is external (a managed observability backend), confirm network egress is allowed from the host.
5. For k8s, check the pod's DNS config: `kubectl -n streaming exec <otel-pod> -- nslookup <hostname>`.

---

## Fix F: Memory Pressure

**Error:** Container exits with status code 137 (`docker ps -a` shows `Exited (137)`). No log output from the collector itself — it was killed by the kernel/orchestrator.

**What it means:** The collector exceeded its memory limit and was OOMKilled.

**Steps:**

1. Check current limits:
   ```bash
   # Docker
   docker inspect otel-collector --format '{{.HostConfig.Memory}}'
   
   # Kubernetes
   kubectl -n streaming get pod <otel-pod> -o jsonpath='{.spec.containers[0].resources}'
   ```
2. Review `memory_limiter` processor config in `otel-collector.yaml`:
   ```yaml
   processors:
     memory_limiter:
       limit_mib: 256       # soft limit — start dropping data above this
       spike_limit_mib: 64  # hard limit = limit_mib - spike_limit_mib
   ```
3. Raise the container memory limit **above** `limit_mib`. A good rule: container limit = `limit_mib * 1.5`.
4. Also investigate: high trace volume might require scaling the collector horizontally rather than vertically. Check `rate(otelcol_receiver_accepted_spans[5m])` in Prometheus.

---

## Verifying Recovery

After any fix:

```bash
# Docker
docker ps --filter name=otel-collector --format 'table {{.Names}}\t{{.Status}}'
# Expect: "Up N seconds (healthy)" after ~15-30 seconds

# Confirm health endpoint responds
curl -s http://localhost:13133/ -o /dev/null -w "%{http_code}\n"
# Expect: 200

# Confirm Prometheus is scraping the collector
curl -s "http://localhost:9090/api/v1/query?query=up{job=\"otel-collector\"}" | jq '.data.result'
# Expect: value of "1"
```

---

## Escalation

If none of the fixes above match, or the collector is healthy but traces still aren't flowing:

1. **Collect diagnostic bundle:**
   ```bash
   mkdir -p /tmp/otel-diag && cd /tmp/otel-diag
   docker logs otel-collector --tail 500 > logs.txt 2>&1
   docker inspect otel-collector > inspect.json
   cp /path/to/observability/otel-collector.yaml .
   tar czf otel-diag.tar.gz .
   ```

2. **Escalate to:** Platform/observability team — `#platform-oncall` Slack
3. **Include:** the diagnostic bundle, a link to this runbook, the specific fix steps already tried, and the exact error message.

---

## Prevention

- **Pre-merge validation:** CI runs `otelcol validate --config` on every PR (`.github/workflows/ci.yaml` → `validate-observability` job). This catches 90%+ of misconfig incidents before merge.
- **Healthcheck:** `docker-compose.observability.yaml` declares a healthcheck against `:13133`. A crash-loop is now visible via `docker compose ps` health column, not just `Restarting` status.
- **Port reservations:** [observability/README.md](../../observability/README.md) documents all reserved ports, including the `:8888` trap.

---

## Change Log

| Date | Change | Author |
|------|--------|--------|
| 2026-04-15 | Initial runbook — created from INC-002 resolution patterns | SRE |
