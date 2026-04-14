# Postmortem: Elevated P95 Latency During Traffic Spike

**Incident ID:** INC-001  
**Date:** 2024-03-15  
**Severity:** SEV-2  
**Duration:** 18 minutes (14:32 – 14:50 UTC)  
**Status:** Resolved  
**Author:** On-Call SRE  
**Last Updated:** 2024-03-16  

---

## Impact

- **P95 latency** on the content-service spiked from ~85ms to **620ms** at peak
- **Cache hit rate** dropped from ~78% to 0% for 12 minutes
- ~4,200 content requests served with degraded latency (still 200 OK — no data loss)
- No user-visible errors; SLO error rate remained under 1%
- **4.8 minutes** of error budget consumed against the 43.2-minute 30-day allowance

---

## Timeline

| Time (UTC) | Event |
|------------|-------|
| 14:20      | Marketing sends push notification to 1.2M users for new content drop |
| 14:25      | Traffic to content-service begins rising — 3× normal RPS |
| 14:28      | Redis `INFO stats` shows `connected_clients` at 9/10 (pool limit) |
| 14:32      | `HighLatencyP95` alert fires — p95 = 280ms, rising |
| 14:33      | On-call SRE paged. Checks Grafana dashboard |
| 14:34      | `cache_hit_rate` panel shows hit rate collapsing to 0% |
| 14:35      | `cache_misses_total` counter spiking; all requests hitting mock DB fallback |
| 14:37      | On-call identifies Redis `max_connections` default (10) as bottleneck |
| 14:38      | `ErrorBudgetBurn` alert fires — burn rate 7.2× |
| 14:40      | Decision: increase Redis pool size and restart content-service pods |
| 14:42      | `REDIS_MAX_CONNECTIONS=50` env var patched into Kubernetes deployment |
| 14:44      | Rolling restart begins: content-service pods recycled |
| 14:46      | New pods up; Redis connections now distributed across pool of 50 |
| 14:47      | `cache_hit_rate` recovers to 65% (cache warming in progress) |
| 14:50      | P95 latency returns to baseline (~90ms); `HighLatencyP95` alert clears |
| 14:52      | `ErrorBudgetBurn` alert clears |
| 15:05      | Cache warm-up complete; hit rate recovers to 79% |

---

## Root Cause

The Redis Python client default `max_connections=10` was retained from the initial development configuration. Under the traffic spike (3× normal RPS), the content-service exhausted the 10-connection pool within seconds. New requests could not acquire a Redis connection and immediately fell through to the mock DB fallback path, causing:

1. All Redis reads to fail silently (exception caught, falls back to DB)
2. No new cache entries written (Redis write also fails silently)
3. Mock DB fallback path, not optimized for high concurrency, saturating at ~120ms per request
4. P95 climbing from 85ms → 620ms as mock DB queuing built up

---

## Contributing Factors

1. **No alert on Redis connection pool saturation** — `redis_connected_clients` metric was not scraped or alerted on
2. **Fallback path not load tested** — `soak.js` and `spike.js` load tests assumed cache was operational; no test explicitly exercised the Redis-down path
3. **Silent failure design** — the `except Exception: pass` in `content-service/main.py` consumed Redis errors without exposing them in metrics; `cache_misses_total` counter was the only signal, and it had no alert threshold
4. **Traffic spike not coordinated with SRE** — marketing push notification timing was not included in the deployment/change calendar

---

## What Went Well

- The graceful degradation (fallback to mock DB) prevented 5xx errors — availability SLO was maintained
- Grafana's cache hit rate panel made the root cause immediately visible to the on-call engineer
- Prometheus `HighLatencyP95` and `ErrorBudgetBurn` alerts fired correctly and within expected windows
- Rollout of the fix (env var patch) completed via `kubectl set env` in under 4 minutes

---

## Action Items

| # | Action | Owner | Status | Reference |
|---|--------|-------|--------|-----------|
| 1 | Increase Redis `max_connections` to 50 in content-service | SRE | Done | `services/content-service/main.py` — `max_connections=50` in `get_redis()` |
| 2 | Add alert for high `cache_miss_rate` (> 90% miss rate for 2m → warning) | SRE | Done | `infra/prometheus/alerts.yaml` — `HighCacheMissRate` alert |
| 3 | Update `spike.js` to exercise fallback path with Redis offline | Engineering | In Progress | `load-tests/spike.js` — add `cache-outage.sh` as pre-test setup |
| 4 | Add `chaos/cache-outage.sh` to weekly chaos rotation | SRE | Done | `chaos/cache-outage.sh` |
| 5 | Add marketing push notifications to change calendar as SRE-visible events | Marketing + SRE | In Progress | Runbook to be linked in Slack #releases |
| 6 | Instrument `REDIS_POOL_ACQUIRED` and `REDIS_POOL_WAIT_TIME` metrics | Engineering | Pending | Future sprint |

---

## Lessons Learned

**Silent failures need metrics, not just fallbacks.** The `except Exception: pass` pattern in `content-service/main.py` protected availability but hid a critical signal. The fix was to increment `cache_misses_total` on every fallback path and add a `CacheFallbackActive` gauge that flips to 1 when Redis is unreachable — giving operators immediate visibility before latency climbs.

**Load test your fallback paths.** A fallback that works at 10 req/s may fail at 300 req/s. `chaos/cache-outage.sh` now runs as part of the monthly chaos rotation.

**Pool sizes are config, not code.** The Redis `max_connections` was hardcoded in the initial implementation. It is now exposed as an environment variable (`REDIS_MAX_CONNECTIONS`) so it can be tuned via Kubernetes deployment patches without a code deploy.
