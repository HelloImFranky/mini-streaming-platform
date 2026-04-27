#!/usr/bin/env bash
# chaos/cache-outage.sh
#
# Chaos experiment: Simulate Redis cache outage.
# Stops the Redis container for 90 seconds, then restores it.
# Verifies that content-service degrades gracefully (serves from mock DB)
# rather than returning 5xx errors.
#
# Expected behavior:
#   - cache_misses_total counter spikes (all requests are cache misses)
#   - cache_hits_total counter drops to 0
#   - /health returns {"redis":"degraded"} but overall status remains "ok"
#   - /content/* continues to return 200 responses (fallback active)
#   - No 5xx errors on content endpoints
#
# Usage: bash chaos/cache-outage.sh
#
# Requirements: docker-compose stack running (docker compose up -d)

set -euo pipefail

CONTENT_SERVICE_URL="${CONTENT_SERVICE_URL:-http://localhost:8082}"
OUTAGE_DURATION=90  # seconds
PROBE_INTERVAL=10

echo "=========================================="
echo "  CHAOS: Redis Cache Outage"
echo "  Duration: ${OUTAGE_DURATION}s"
echo "  Content service: ${CONTENT_SERVICE_URL}"
echo "=========================================="

# Verify Redis is currently running
if ! docker inspect redis --format='{{.State.Status}}' 2>/dev/null | grep -q "running"; then
  echo "ERROR: Redis container is not running. Start the stack with: docker compose up -d"
  exit 1
fi

echo "[$(date -u '+%H:%M:%S')] Redis is running. Verifying content-service is healthy before outage..."
PRE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${CONTENT_SERVICE_URL}/health" 2>/dev/null || echo "000")
if [[ "${PRE_STATUS}" != "200" ]]; then
  echo "ERROR: content-service not reachable at ${CONTENT_SERVICE_URL}/health (status: ${PRE_STATUS})"
  exit 1
fi
echo "[$(date -u '+%H:%M:%S')] Pre-flight check passed."

# Take Redis down
echo ""
echo "[$(date -u '+%H:%M:%S')] Stopping Redis container (simulating cache outage)..."
docker compose stop redis

sleep 3

echo "[$(date -u '+%H:%M:%S')] Redis is down. Probing content-service fallback for ${OUTAGE_DURATION}s..."
echo "   Watch Prometheus: rate(cache_misses_total[1m]) should spike to 100%"
echo "   Watch Prometheus: rate(cache_hits_total[1m]) should drop to 0"
echo ""

# Probe content-service during outage
ELAPSED=0
ERRORS=0
SUCCESSES=0

while [[ $ELAPSED -lt $OUTAGE_DURATION ]]; do
  sleep "${PROBE_INTERVAL}"
  ELAPSED=$((ELAPSED + PROBE_INTERVAL))

  HEALTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    "${CONTENT_SERVICE_URL}/health" 2>/dev/null || echo "000")

  HEALTH_BODY=$(curl -s "${CONTENT_SERVICE_URL}/health" 2>/dev/null || echo "{}")

  CONTENT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    "${CONTENT_SERVICE_URL}/content/c-001" 2>/dev/null || echo "000")

  REDIS_STATE=$(echo "${HEALTH_BODY}" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('redis','unknown'))" 2>/dev/null || echo "unknown")

  if [[ "${CONTENT_STATUS}" == "200" ]]; then
    SUCCESSES=$((SUCCESSES + 1))
    echo "[$(date -u '+%H:%M:%S')] [${ELAPSED}/${OUTAGE_DURATION}s] health=${HEALTH_STATUS} redis=${REDIS_STATE} content=${CONTENT_STATUS} ✓ fallback active"
  else
    ERRORS=$((ERRORS + 1))
    echo "[$(date -u '+%H:%M:%S')] [${ELAPSED}/${OUTAGE_DURATION}s] health=${HEALTH_STATUS} redis=${REDIS_STATE} content=${CONTENT_STATUS} ✗ fallback FAILED"
  fi
done

# Restore Redis
echo ""
echo "[$(date -u '+%H:%M:%S')] Restoring Redis..."
docker compose start redis

# Wait for Redis to be healthy
WAIT=0
until docker inspect redis --format='{{.State.Health.Status}}' 2>/dev/null | grep -q "healthy" || [[ $WAIT -ge 30 ]]; do
  sleep 2
  WAIT=$((WAIT + 2))
done

echo "[$(date -u '+%H:%M:%S')] Redis restored. Cache will warm up over the next few requests."

# Results
echo ""
echo "=========================================="
echo "  Experiment Results"
echo "=========================================="
echo "  Duration:           ${OUTAGE_DURATION}s"
echo "  Fallback successes: ${SUCCESSES}"
echo "  Fallback failures:  ${ERRORS}"
echo ""

if [[ "${ERRORS}" -eq 0 ]]; then
  echo "  ✅ PASS — content-service served all requests during Redis outage."
  echo "            Graceful degradation is working. Availability SLO held."
else
  echo "  ❌ FAIL — ${ERRORS} request(s) returned non-200 during Redis outage."
  echo "            Investigate content-service error handling."
fi

echo ""
echo "  Prometheus queries to review:"
echo "  • rate(cache_misses_total[1m])  — should show spike during outage window"
echo "  • rate(cache_hits_total[1m])    — should show drop to 0 during outage"
echo "  • rate(cache_hits_total[1m]) / (rate(cache_hits_total[1m]) + rate(cache_misses_total[1m]))"
echo "    → cache hit ratio — recovery curve visible after Redis restores"
