#!/usr/bin/env bash
# chaos/cache-outage.sh
#
# Chaos experiment: Simulate Redis cache outage.
# Scales Redis to 0 replicas for 90 seconds, then restores.
# Verifies that content-service degrades gracefully (serves from mock DB)
# rather than returning 5xx errors.
#
# Expected behavior:
#   - cache_misses_total counter spikes (all requests are cache misses)
#   - cache_hits_total counter drops to 0
#   - /health returns {"redis":"degraded"} but status remains "ok"
#   - /content/* continues to return 200 responses (fallback active)
#   - No 5xx errors on content endpoints
#
# Usage: bash chaos/cache-outage.sh
#
# Requirements: kubectl configured with streaming namespace access.

set -euo pipefail

NAMESPACE="streaming"
REDIS_DEPLOYMENT="redis"
CONTENT_SERVICE_URL="${CONTENT_SERVICE_URL:-http://localhost:8082}"
OUTAGE_DURATION=90  # seconds

echo "=========================================="
echo "  CHAOS: Redis Cache Outage"
echo "  Duration: ${OUTAGE_DURATION}s"
echo "  Content service: ${CONTENT_SERVICE_URL}"
echo "=========================================="

# Verify Redis is currently running
CURRENT_REPLICAS=$(kubectl get deployment "${REDIS_DEPLOYMENT}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
echo "[$(date -u '+%H:%M:%S')] Current Redis replicas: ${CURRENT_REPLICAS}"

echo ""
echo "[$(date -u '+%H:%M:%S')] Scaling Redis to 0 (simulating cache outage)..."
kubectl scale deployment "${REDIS_DEPLOYMENT}" \
  --replicas=0 \
  -n "${NAMESPACE}"

# Wait for Redis pod to terminate
sleep 5

echo "[$(date -u '+%H:%M:%S')] Redis is down. Testing content-service fallback behavior..."
echo ""

# Probe content-service during outage
PROBE_INTERVAL=15
ELAPSED=0
ERRORS=0
SUCCESSES=0

while [[ $ELAPSED -lt $OUTAGE_DURATION ]]; do
  sleep "${PROBE_INTERVAL}"
  ELAPSED=$((ELAPSED + PROBE_INTERVAL))

  # Check health endpoint
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    "${CONTENT_SERVICE_URL}/health" 2>/dev/null || echo "000")

  # Check content endpoint (should still work via fallback)
  CONTENT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    "${CONTENT_SERVICE_URL}/content/c-001" 2>/dev/null || echo "000")

  if [[ "${CONTENT_STATUS}" == "200" ]]; then
    SUCCESSES=$((SUCCESSES + 1))
    echo "[$(date -u '+%H:%M:%S')] [${ELAPSED}/${OUTAGE_DURATION}s] health=${HTTP_STATUS} content=${CONTENT_STATUS} ✓ (fallback active)"
  else
    ERRORS=$((ERRORS + 1))
    echo "[$(date -u '+%H:%M:%S')] [${ELAPSED}/${OUTAGE_DURATION}s] health=${HTTP_STATUS} content=${CONTENT_STATUS} ✗ (fallback failed!)"
  fi
done

# Restore Redis
echo ""
echo "[$(date -u '+%H:%M:%S')] Restoring Redis (scaling to ${CURRENT_REPLICAS} replica(s))..."
kubectl scale deployment "${REDIS_DEPLOYMENT}" \
  --replicas="${CURRENT_REPLICAS}" \
  -n "${NAMESPACE}"

kubectl rollout status deployment/"${REDIS_DEPLOYMENT}" \
  -n "${NAMESPACE}" --timeout=60s

echo "[$(date -u '+%H:%M:%S')] Redis restored."
echo ""

# Results
echo "=========================================="
echo "  Experiment Results"
echo "=========================================="
echo "  Fallback successes: ${SUCCESSES}"
echo "  Fallback failures:  ${ERRORS}"
echo ""

if [[ "${ERRORS}" -eq 0 ]]; then
  echo "  ✅ PASS — content-service served all requests during Redis outage."
  echo "            Cache fallback is working correctly."
else
  echo "  ❌ FAIL — ${ERRORS} requests failed during Redis outage."
  echo "            Investigate content-service error handling."
fi

echo ""
echo "  Check Prometheus for:"
echo "  • rate(cache_misses_total[5m]) — should spike during outage"
echo "  • rate(cache_hits_total[5m])   — should drop to 0 during outage"
echo ""
echo "Post-experiment pod status:"
kubectl get pods -n "${NAMESPACE}" -o wide
