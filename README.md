# Mini Streaming Platform – SRE/DevOps Project

A production-grade microservices platform demonstrating mid-level SRE/DevOps skills: observability, reliability engineering, Kubernetes operations, chaos engineering, and CI/CD with canary deployments.

---

## Architecture

```
                        ┌─────────────────────────────────────────┐
                        │              API Gateway                 │
                        │         Go · Port 8080                   │
                        │  ┌──────────────────────────────────┐   │
                        │  │ Request-ID injection             │   │
                        │  │ Prometheus middleware            │   │
                        │  │ Reverse proxy routing            │   │
                        │  └──────────────────────────────────┘   │
                        └──────┬──────────┬──────────┬────────────┘
                               │          │          │
              ┌────────────────▼─┐  ┌────▼───────┐  ┌▼──────────────────┐
              │  user-service    │  │content-svc │  │ playback-service   │
              │  Python FastAPI  │  │Python+Redis│  │ Go · Port 8083     │
              │  Port 8081       │  │Port 8082   │  │                    │
              │                  │  │  ┌──────┐  │  │ Session store      │
              │ 5 mock users     │  │  │Redis │  │  │ Latency injection  │
              │ CRUD endpoints   │  │  │Cache │  │  │ active_sessions    │
              └──────────────────┘  │  └──────┘  │  └────────────────────┘
                                    │  20 items  │
                                    │  cache TTL │
                                    │  300s      │
                                    └────────────┘

Observability Stack (separate compose):
  Prometheus (9090) → scrapes all 4 services + itself
  Grafana (3000)    → pre-provisioned dashboard (RPS, errors, p95, cache hit rate)
  OTel Collector    → OTLP gRPC 4317, exports traces to stdout
```

---

## Quick Start

### Prerequisites

- Docker + Docker Compose
- Go 1.21+ (for local development / build verification)
- kubectl (for Kubernetes workflows)
- k6 (for load tests — `brew install k6`)

### 1. Start all services

```bash
cd mini-streaming-platform
docker-compose up --build
```

Services will be available at:

| Service           | URL                              |
|-------------------|----------------------------------|
| API Gateway       | http://localhost:8080            |
| User Service      | http://localhost:8081 (direct)   |
| Content Service   | http://localhost:8082 (direct)   |
| Playback Service  | http://localhost:8083 (direct)   |
| Redis             | localhost:6379                   |

### 2. Verify services are healthy

```bash
curl http://localhost:8080/health      # API Gateway
curl http://localhost:8081/health      # User Service
curl http://localhost:8082/health      # Content Service (shows Redis status)
curl http://localhost:8083/health      # Playback Service
```

All should return `{"status":"ok","service":"..."}`.

### 3. Start the observability stack

```bash
docker-compose -f docker-compose.observability.yaml up -d
```

| Tool        | URL                           | Credentials  |
|-------------|-------------------------------|--------------|
| Prometheus  | http://localhost:9090         | —            |
| Grafana     | http://localhost:3000         |admin/admintest123|
| OTel        | grpc://localhost:4317         | —            |

The Grafana **"Mini Streaming Platform"** dashboard is pre-provisioned — no manual setup required.

---

## API Reference

### Through the Gateway (port 8080)

```bash
# User service
GET  /users/u-001                        # Fetch user by ID
POST /users  {"name":"...","email":"..."} # Create user

# Content service
GET  /content/c-001                       # Fetch content by ID (Redis-cached)
GET  /content?page=1&limit=10             # Paginated catalog

# Playback service
POST /playback/start  {"user_id":"u-001","content_id":"c-001"}
GET  /playback/status/{session_id}

# Shared
GET  /health                              # Gateway health
GET  /metrics                             # Prometheus metrics (gateway)
```

### Example requests

```bash
# Start a playback session
curl -X POST http://localhost:8080/playback/start \
  -H 'Content-Type: application/json' \
  -d '{"user_id":"u-002","content_id":"c-007"}'

# Check session status
curl http://localhost:8080/playback/status/<session_id>

# Browse content catalog (page 2)
curl "http://localhost:8080/content?page=2&limit=5"
```

---

## Service Details

| Service           | Language  | Port | Key Features                                      |
|-------------------|-----------|------|---------------------------------------------------|
| api-gateway       | Go        | 8080 | Reverse proxy, request-ID injection, metrics      |
| user-service      | Python    | 8081 | Mock user CRUD, Prometheus instrumentation        |
| content-service   | Python    | 8082 | Redis cache + graceful fallback, cache metrics    |
| playback-service  | Go        | 8083 | Session store, configurable latency spikes        |

### Prometheus Metrics (all services)

Every service exposes at `/metrics`:

| Metric                           | Type      | Description                      |
|----------------------------------|-----------|----------------------------------|
| `http_requests_total`            | Counter   | Requests by method/path/status   |
| `http_request_duration_seconds`  | Histogram | Latency histogram, p50/p95/p99   |
| `service_info`                   | Gauge     | Version/name label, always = 1   |
| `cache_hits_total`               | Counter   | (content-service only) Cache hits|
| `cache_misses_total`             | Counter   | (content-service only) Misses    |
| `active_sessions`                | Gauge     | (playback-service) Live sessions |

---

## SLOs

| SLO               | Target  | Window | Error Budget       |
|-------------------|---------|--------|--------------------|
| Availability      | 99.9%   | 30d    | 43.2 min/month     |
| Latency p95       | < 250ms | 30d    | —                  |
| Error rate        | < 1%    | 30d    | 43.2 min/month     |

Full SLO definitions: [sre/slos.yaml](sre/slos.yaml)  
Error budget policy: [sre/error-budget.md](sre/error-budget.md)

### Prometheus Alert Rules

| Alert                | Severity | Condition                           |
|----------------------|----------|-------------------------------------|
| `HighErrorRate`      | critical | 5xx rate > 1% for 5m               |
| `HighLatencyP95`     | warning  | p95 > 250ms for 5m                 |
| `ServiceDown`        | critical | Instance down > 1m                 |
| `ErrorBudgetBurn`    | critical | Burn rate > 5× (dual window)       |

---

## Load Tests

```bash
# Smoke test — 5 VUs, 30s, all /health endpoints
k6 run load-tests/smoke.js

# Spike test — "release day" — ramps to 500 VUs
k6 run load-tests/spike.js

# Soak test — 50 VUs, 30 minutes (detect memory leaks)
k6 run load-tests/soak.js

# Target a non-local environment
k6 run -e BASE_URL=https://staging.example.com load-tests/smoke.js
```

### Thresholds

| Test  | p95 threshold | Error rate threshold |
|-------|--------------|---------------------|
| Smoke | < 250ms      | < 1%                |
| Spike | < 500ms      | < 5%                |
| Soak  | < 400ms      | < 1%                |

---

## Chaos Engineering

Two environments for chaos experiments — use the right one for each experiment:

| Experiment | Environment | Why |
|---|---|---|
| Latency spike | docker-compose | Prometheus scrapes docker-compose services; alerts fire correctly |
| Cache outage | docker-compose | Redis is a docker-compose service |
| Pod kill | Kubernetes (minikube) | Demonstrates k8s self-healing — requires `kubectl` |

---

### Latency Spike (docker-compose)

Injects 80% latency (500ms–2000ms) into playback-service for 3 minutes. Triggers `HighLatencyP95` alert.

**Requires:** docker-compose stack running (`docker compose up -d`)

Open **3 terminals** from the project root:

**Terminal 1 — generate traffic:**
```bash
docker run --rm -i \
  --network streaming-net \
  -v $(pwd)/load-tests:/load-tests \
  grafana/k6 run --duration 4m \
  -e BASE_URL=http://api-gateway:8080 \
  /load-tests/smoke.js
```

**Terminal 2 — inject latency (~15s after Terminal 1 starts):**
```bash
docker compose stop playback-service && \
LATENCY_SPIKE_PCT=80 docker compose up -d playback-service
```

**Terminal 3 — confirm latency is being injected:**
```bash
docker logs -f playback-service
# Look for: "injecting latency spike: XXXms"
```

**Watch the alert fire** in Prometheus (`http://localhost:9090` → Alerts tab).
Query to visualize in Graph view:
```
histogram_quantile(0.95,
  rate(http_request_duration_seconds_bucket{service="playback-service"}[1m])
)
```

**Reset after experiment:**
```bash
docker compose stop playback-service && \
LATENCY_SPIKE_PCT=5 docker compose up -d playback-service
```

**Key learning:** Scaling replicas does NOT fix this — the synthetic sleep runs in every pod. The correct fix is removing the root cause (patching the env var). Scaling only helps when latency is caused by resource contention, not a per-request code path.

---

### Cache Outage (docker-compose)

Stops Redis for 90 seconds. Verifies content-service falls back to mock DB gracefully — no 5xx errors, availability SLO holds.

**Requires:** docker-compose stack running (`docker compose up -d`)

**Terminal 1 — run the experiment:**
```bash
bash chaos/cache-outage.sh
```

Expected output every 10s during the outage:
```
[14:32:15] [10/90s] health=200 redis=degraded content=200 ✓ fallback active
```

**Terminal 2 — watch the health endpoint change in real time:**
```bash
while true; do curl -s http://localhost:8082/health; echo; sleep 3; done
# During outage:  {"status":"ok","redis":"degraded"}
# After restore:  {"status":"ok","redis":"ok"}
```

**Prometheus queries to watch** (`http://localhost:9090` → Graph):
```
# Cache miss rate — spikes to 100% during outage
rate(cache_misses_total[1m])

# Cache hit ratio — drops to 0, recovers after Redis restores
rate(cache_hits_total[1m]) / (rate(cache_hits_total[1m]) + rate(cache_misses_total[1m]))
```

**Key learning:** The content-service has a fallback path to the mock DB when Redis is unreachable. Availability SLO (error rate < 1%) holds during the outage. The cost is latency — mock DB is slower than Redis. This is a deliberate tradeoff: protect error rate at the expense of p95 latency.

---

### Pod Kill (Kubernetes)

Kills a random pod and verifies Kubernetes self-heals within 60s.

**Requires:** minikube running with manifests applied (see [Kubernetes](#kubernetes) section)

**Terminal 1 — watch pods:**
```bash
kubectl -n streaming get pods -w
```

**Terminal 2 — kill a pod:**
```bash
# Random pod
bash chaos/pod-kill.sh

# Target a specific service
bash chaos/pod-kill.sh --service content-service
```

Watch the killed pod go `Terminating` → new pod appear `ContainerCreating` → `Running 1/1` — typically under 15 seconds on minikube.

---

### Expected Outcomes

| Experiment    | Expected Behavior                                           |
|---------------|-------------------------------------------------------------|
| Latency spike | `HighLatencyP95` alert fires within 2m; p95 drops on reset |
| Cache outage  | Cache hit rate → 0%; requests still succeed via fallback    |
| Pod kill      | Replacement pod running within 60s; replica count restored  |

---

## Kubernetes

### Apply all manifests

```bash
# Dry run first
kubectl apply --dry-run=client -f infra/k8s/ -R

# Apply to cluster
kubectl apply -f infra/k8s/namespace.yaml
kubectl apply -f infra/k8s/ -R
```

### Resource profile (per pod)

| Service         | CPU request | CPU limit | Memory request | Memory limit |
|-----------------|-------------|-----------|----------------|--------------|
| All services    | 50m         | 100m      | 64Mi           | 128Mi        |

### HPA

All services: min=2 replicas, max=10, scale-up at 70% CPU.

### Canary Deployment

```bash
# Deploy canary (10% traffic — 1 canary : 9 stable pods)
kubectl apply -f infra/k8s/canary/

# Monitor canary error rate
kubectl exec -n streaming deploy/prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=sum(rate(http_requests_total{status=~"5..",track="canary"}[5m]))/sum(rate(http_requests_total{track="canary"}[5m]))'

# Promote: update stable image, scale down canary
kubectl set image deployment/content-service content-service=ghcr.io/.../content-service:new-tag -n streaming
kubectl scale deployment/content-service-canary --replicas=0 -n streaming

# Rollback canary
kubectl rollout undo deployment/content-service-canary -n streaming
```

---

## CI/CD

### Pipeline overview

```
Push to branch → lint (Go + Python) → tests → validate-observability → build Docker images
                                                                               │
                                                                        Push to main?
                                                                               │
                                                                        push to GHCR
                                                                               │
                                                                   deploy.yaml triggers
                                                                               │
                                                                   kubectl set image (canary)
                                                                               │
                                                                        wait 5 minutes
                                                                               │
                                                             query Prometheus error rate
                                                                  /          \
                                                             < 1%            >= 1%
                                                            promote          rollback
```

`validate-observability` runs `otelcol validate --config` against `observability/otel-collector.yaml` on every push — catches schema errors before they reach any environment.

### Deploy gate

The deploy job is gated behind a repository variable `CLUSTER_READY`. Without it the job is skipped cleanly — no kubectl errors, no cascading failures.

To enable deployments when a real cluster is available:
1. GitHub repo → **Settings → Variables → Actions → New repository variable**
2. Name: `CLUSTER_READY` / Value: `true`
3. Set the `KUBECONFIG` secret (base64-encoded kubeconfig for the target cluster)

### Required secrets and variables

| Name | Type | Description |
|---|---|---|
| `KUBECONFIG` | Secret | Base64-encoded kubeconfig for production cluster |
| `GITHUB_TOKEN` | Secret | Auto-provided by GitHub Actions (GHCR push) |
| `CLUSTER_READY` | Variable | Set to `true` to enable the deploy job |

---

## Development

### Local Go development

```bash
cd services/api-gateway
go mod tidy
go build ./...
go run main.go
```

### Local Python development

```bash
cd services/user-service
pip install -r requirements.txt
uvicorn main:app --reload --port 8081
```

### VSCode

Open the workspace in VSCode. Recommended extensions will be suggested automatically ([.vscode/extensions.json](.vscode/extensions.json)).

Available tasks (Ctrl+Shift+P → "Tasks: Run Task"):
- **Start all services** — `docker-compose up --build`
- **Start observability** — starts Prometheus + Grafana + OTel
- **Run smoke test** — k6 smoke
- **Run spike test** — k6 spike
- **Kill random pod** — chaos experiment
- **Inject latency spike** — chaos experiment
- **Simulate cache outage** — chaos experiment

---

## Project Structure

```
mini-streaming-platform/
├── services/
│   ├── api-gateway/          # Go — reverse proxy, port 8080
│   ├── user-service/         # Python FastAPI, port 8081
│   ├── content-service/      # Python FastAPI + Redis, port 8082
│   └── playback-service/     # Go — sessions + latency spikes, port 8083
├── infra/
│   ├── k8s/                  # Kubernetes manifests (namespace, deployments, HPAs, ingress)
│   │   └── canary/           # Canary deployment for content-service
│   ├── prometheus/           # prometheus.yml + alerts.yaml
│   └── grafana/              # Auto-provisioned datasource + dashboard
├── observability/
│   ├── otel-collector.yaml        # OpenTelemetry Collector config
│   ├── Dockerfile.otel-collector  # Custom image — adds wget to distroless vendor image for healthcheck
│   └── README.md                  # Port reservations + troubleshooting guide
├── chaos/                    # Chaos experiment shell scripts
├── load-tests/               # k6 scripts: smoke, spike, soak
├── sre/
│   ├── slos.yaml             # SLO definitions
│   ├── error-budget.md       # Error budget policy and math
│   ├── postmortems/
│   │   ├── incident-001.md   # Redis connection pool exhaustion
│   │   └── incident-002.md   # OTel Collector crash loop — port collision + config schema
│   └── runbooks/
│       └── otel-collector.md # On-call runbook: restart loop diagnosis + fix patterns
├── .github/workflows/
│   ├── ci.yaml               # lint + test + build
│   └── deploy.yaml           # canary → promote/rollback
├── .vscode/                  # tasks, launch configs, extensions
├── docker-compose.yaml       # All 4 services + Redis
└── docker-compose.observability.yaml  # Prometheus + Grafana + OTel
```

---

## Postmortems

- [INC-001 — Elevated P95 Latency During Traffic Spike](sre/postmortems/incident-001.md)
  - Redis connection pool exhaustion caused content-service cache fallback to overload mock DB
  - Resolution: increased `max_connections=50`, added cache miss rate alerting, added chaos experiment to rotation

- [INC-002 — OTel Collector Crash Loop](sre/postmortems/incident-002.md)
  - Two misconfigurations: stale `file_format` key + port `:8888` collision between prometheus exporter and collector's internal telemetry server
  - Resolution: moved exporter to `:8889`, added CI config validation, added compose healthcheck via custom distroless-compatible image, documented port reservations

---

## Dashboard Screenshots

> _Start Grafana (`docker-compose -f docker-compose.observability.yaml up -d`) and navigate to http://localhost:3000 with admin/admintest123. The **"Mini Streaming Platform"** dashboard loads automatically._

Panels:
- **Requests Per Second** — by service, 2-minute rate
- **Error Rate 5xx** — by service, with 1% SLO threshold line
- **Latency p95 / p50** — by service, with 250ms SLO threshold line
- **Cache Hit Rate** — content-service Redis hit ratio
- **Service Up/Down** — live health status for all targets
- **Active Playback Sessions** — real-time session gauge
- **Cache Hit/Miss Rate** — hits vs misses per second

---

## License

MIT — built as a portfolio project demonstrating SRE/DevOps practices for a streaming platform environment.
