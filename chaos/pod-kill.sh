#!/usr/bin/env bash
# chaos/pod-kill.sh
#
# Chaos experiment: Kill a random pod in the streaming namespace.
# Observes whether Kubernetes self-heals within 60 seconds.
#
# Usage:
#   bash chaos/pod-kill.sh [--service <name>]
#
# Options:
#   --service  Target a specific service (e.g., content-service).
#              Default: random pod from any service.
#
# Requirements: kubectl configured with access to the streaming namespace.

set -euo pipefail

NAMESPACE="streaming"
WAIT_SECONDS=60
TARGET_SERVICE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) TARGET_SERVICE="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

echo "=========================================="
echo "  CHAOS: Pod Kill Experiment"
echo "  Namespace: ${NAMESPACE}"
echo "  Wait time: ${WAIT_SECONDS}s"
echo "=========================================="

# List candidate pods
if [[ -n "${TARGET_SERVICE}" ]]; then
  PODS=$(kubectl get pods -n "${NAMESPACE}" \
    -l "app=${TARGET_SERVICE}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].metadata.name}')
else
  PODS=$(kubectl get pods -n "${NAMESPACE}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].metadata.name}')
fi

if [[ -z "${PODS}" ]]; then
  echo "ERROR: No running pods found in namespace ${NAMESPACE}."
  exit 1
fi

# Pick a random pod
POD_ARRAY=(${PODS})
RANDOM_INDEX=$((RANDOM % ${#POD_ARRAY[@]}))
TARGET_POD="${POD_ARRAY[$RANDOM_INDEX]}"

echo ""
echo "[$(date -u '+%H:%M:%S')] Target pod: ${TARGET_POD}"
echo "[$(date -u '+%H:%M:%S')] Recording pod count before kill..."

# Count pods before
BEFORE_COUNT=$(kubectl get pods -n "${NAMESPACE}" \
  --field-selector=status.phase=Running \
  --no-headers | wc -l | tr -d ' ')
echo "[$(date -u '+%H:%M:%S')] Running pods before: ${BEFORE_COUNT}"

# Kill the pod
echo "[$(date -u '+%H:%M:%S')] Deleting pod ${TARGET_POD}..."
kubectl delete pod "${TARGET_POD}" -n "${NAMESPACE}" --grace-period=0

echo "[$(date -u '+%H:%M:%S')] Pod deleted. Waiting ${WAIT_SECONDS}s for recovery..."
sleep "${WAIT_SECONDS}"

# Check recovery
AFTER_COUNT=$(kubectl get pods -n "${NAMESPACE}" \
  --field-selector=status.phase=Running \
  --no-headers | wc -l | tr -d ' ')

echo ""
echo "[$(date -u '+%H:%M:%S')] Running pods after: ${AFTER_COUNT}"
echo "[$(date -u '+%H:%M:%S')] Expected:           ${BEFORE_COUNT}"

if [[ "${AFTER_COUNT}" -ge "${BEFORE_COUNT}" ]]; then
  echo ""
  echo "✅ RECOVERED — Kubernetes replaced the killed pod within ${WAIT_SECONDS}s."
  echo "   Deployment is healthy."
else
  echo ""
  echo "❌ NOT RECOVERED — Pod count dropped from ${BEFORE_COUNT} to ${AFTER_COUNT}."
  echo "   Investigate: kubectl get pods -n ${NAMESPACE}"
  echo "                kubectl describe pod -n ${NAMESPACE} | tail -30"
  exit 1
fi

# Show current pod state
echo ""
echo "Current pod status:"
kubectl get pods -n "${NAMESPACE}" -o wide
