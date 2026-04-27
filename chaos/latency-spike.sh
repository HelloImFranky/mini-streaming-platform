#!/usr/bin/env bash
# chaos/latency-spike.sh
#
# Chaos experiment: Inject extreme latency into the playback-service.
# Sets LATENCY_SPIKE_PCT=80 (80% of requests get 500ms–2000ms delays).
# Observes system behavior for 2 minutes, then resets to baseline (5%).
#
# Purpose:
#   - Verify that gateway timeouts fire correctly
#   - Confirm that p95 latency alerts trigger in Prometheus
#   - Ensure error budget burn rate alert fires
#
# Usage: bash chaos/latency-spike.sh
#
# Requirements: kubectl configured with streaming namespace access.

set -euo pipefail

NAMESPACE="streaming"
DEPLOYMENT="playback-service"
CONTAINER="playback-service"
SPIKE_PCT=80
BASELINE_PCT=5
CHAOS_DURATION=180  # seconds

echo "=========================================="
echo "  CHAOS: Latency Spike Injection"
echo "  Target:   ${DEPLOYMENT}"
echo "  Spike:    LATENCY_SPIKE_PCT=${SPIKE_PCT}%"
echo "  Duration: ${CHAOS_DURATION}s"
echo "  Baseline: LATENCY_SPIKE_PCT=${BASELINE_PCT}%"
echo "=========================================="

# Record current replica count for rollback verification
REPLICAS=$(kubectl get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.replicas}')
echo "[$(date -u '+%H:%M:%S')] Current replicas: ${REPLICAS}"

# Inject spike
echo ""
echo "[$(date -u '+%H:%M:%S')] Injecting latency spike (${SPIKE_PCT}%)..."

kubectl set env deployment/"${DEPLOYMENT}" \
  LATENCY_SPIKE_PCT="${SPIKE_PCT}" \
  -n "${NAMESPACE}"

kubectl rollout status deployment/"${DEPLOYMENT}" \
  -n "${NAMESPACE}" --timeout=60s

echo "[$(date -u '+%H:%M:%S')] Spike active. Monitoring for ${CHAOS_DURATION}s..."
echo "   Observe Prometheus at http://localhost:9090:"
echo "   histogram_quantile(0.95, rate(http_request_duration_seconds_bucket{service=\"playback-service\"}[1m]))"
echo ""

# Monitor during chaos window
INTERVAL=15
ELAPSED=0
while [[ $ELAPSED -lt $CHAOS_DURATION ]]; do
  sleep "${INTERVAL}"
  ELAPSED=$((ELAPSED + INTERVAL))
  echo "[$(date -u '+%H:%M:%S')] Chaos in progress (${ELAPSED}/${CHAOS_DURATION}s)"
done

# Reset to baseline
echo ""
echo "[$(date -u '+%H:%M:%S')] Resetting latency spike to baseline (${BASELINE_PCT}%)..."

kubectl set env deployment/"${DEPLOYMENT}" \
  LATENCY_SPIKE_PCT="${BASELINE_PCT}" \
  -n "${NAMESPACE}"

kubectl rollout status deployment/"${DEPLOYMENT}" \
  -n "${NAMESPACE}" --timeout=60s

echo "[$(date -u '+%H:%M:%S')] Reset complete."
echo ""
echo "Experiment complete."
echo "Expected observations:"
echo "  • HighLatencyP95 alert fired in Prometheus during chaos window"
echo "  • ErrorBudgetBurn alert fired if error rate spiked"
echo "  • Service recovered automatically after reset"
echo ""
echo "Post-experiment pod status:"
kubectl get pods -n "${NAMESPACE}" -l "app=${DEPLOYMENT}" -o wide
