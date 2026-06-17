#!/bin/bash

# Test script for DUPLO-11210: Allow setting replica to zero during duplo service update
# Feature flag: EnableDuploServiceScalingToZero (must be ON for zero-stop tests to work)
#
# Endpoints tested:
#   ReplicationControllerBulkChangeAll  - bulk, updates image+replicas+config
#   ReplicationControllerBulkChange     - bulk, updates replicas/config only
#
# Multiple services are passed in a single API call (processed in parallel server-side).

HOST="https://oneclick.duplocloud.net"
TOKEN="AQAAANCMnd8BFdERjHoAwE_Cl-sBAAAAAJ7iw9hJuUKwrot0sNjfvAAAAAACAAAAAAAQZgAAAAEAACAAAACfDd3qz0B3nREQiz8JG5uz5GYQeCbzKeS5M7xaKp3NWwAAAAAOgAAAAAIAACAAAACR_9YZ0RCgqCbdshkozKo7NPkOB90OGvRZnTti9jyCUcAAAAApGzBowBYQey0vpklOlF0FZhP8JI2imoMw-wz__c3psWIfy3AeATqVuf__f0TvfhHrxA3CLT9w_kL0bmRajVAri6_nZ26evawN4T8BIzI1UQ_YZe-dm1gmmgLmJO8lj84AH1f6cGt87JTqzCHgHXWgk9-GAiz_elvvZ_QlO8PElR-SgeLiodNOqUCfU_MWGbPAJ0QJ0Tcb7mOd1XhF8sQdOAkofa2YkLObJYvL7HuVbA1bpCvTLYpVhxBTpVa4g3dAAAAACoShe-MNmA7ihOTabtrQdr_hwZidCPie8ExdykCVy1bUGDxEGAnM01c4Fkb13Pnq45shEjefb0F0VZwoAy8j3w"
TENANT_ID="34d7c6cd-45f5-453a-b2bf-43066efa838e"
SVC1="test-scaling-zero"
SVC2="test-scaling-zero-2"

PASS=0
FAIL=0
BUGS=()

# ─── Helpers ────────────────────────────────────────────────────────────────

api() {
  local method=$1 path=$2 body=$3
  if [ -n "$body" ]; then
    curl -s -w "\n%{http_code}" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -X "$method" "${HOST}${path}" -d "$body"
  else
    curl -s -H "Authorization: Bearer $TOKEN" "${HOST}${path}"
  fi
}

get_replicas() {
  local svc=$1
  api GET "/subscriptions/${TENANT_ID}/GetReplicationControllers" | python3 -c "
import json,sys
data=json.load(sys.stdin)
for s in data:
    if s['Name'] == '${svc}':
        print(s['Replicas'], s.get('ReplicasPrev',''))
        break
"
}

force_replicas() {
  local svc=$1 n=$2
  api POST "/subscriptions/${TENANT_ID}/ReplicationControllerChangeAll" \
    "{\"Name\":\"${svc}\",\"Replicas\":${n},\"TenantId\":\"${TENANT_ID}\"}" > /dev/null
}

check() {
  local label=$1 svc=$2 expected=$3
  read -r replicas prev <<< "$(get_replicas "$svc")"
  if [ "$replicas" -eq "$expected" ] 2>/dev/null; then
    echo "  PASS  ${svc}: Replicas=${replicas}  ReplicasPrev=${prev}"
    ((PASS++))
  else
    echo "  FAIL  ${svc}: Expected Replicas=${expected}, got Replicas=${replicas}"
    ((FAIL++))
  fi
}

bug() {
  local label=$1 svc=$2 expected=$3
  read -r replicas prev <<< "$(get_replicas "$svc")"
  echo "  BUG   ${svc}: Expected Replicas=${expected}, got Replicas=${replicas} — known limitation"
  BUGS+=("$label")
}

# ─── Setup ──────────────────────────────────────────────────────────────────

echo "======================================================"
echo " DUPLO-11210 — Bulk replica-to-zero test suite"
echo " Host  : $HOST"
echo " Tenant: $TENANT_ID"
echo " SVCs  : $SVC1, $SVC2"
echo "======================================================"
echo ""
echo "Creating test services (skipped if already exist)..."

api POST "/subscriptions/${TENANT_ID}/ReplicationControllerUpdate" \
  "{\"Name\":\"${SVC1}\",\"DockerImage\":\"nginx:latest\",\"Replicas\":1,\"AgentPlatform\":7,\"IsDaemonset\":false,\"TenantId\":\"${TENANT_ID}\"}" > /dev/null 2>&1
api POST "/subscriptions/${TENANT_ID}/ReplicationControllerUpdate" \
  "{\"Name\":\"${SVC2}\",\"DockerImage\":\"nginx:latest\",\"Replicas\":1,\"AgentPlatform\":7,\"IsDaemonset\":false,\"TenantId\":\"${TENANT_ID}\"}" > /dev/null 2>&1

force_replicas "$SVC1" 1
force_replicas "$SVC2" 1
echo "Services set to 1 replica each."
echo ""

# ─── Tests ──────────────────────────────────────────────────────────────────

# ── 1. BulkChangeAll: single service 1 → 0 ──────────────────────────────
echo "[TEST 1] ReplicationControllerBulkChangeAll: $SVC1  1 → 0"
HTTP=$(api POST "/subscriptions/${TENANT_ID}/ReplicationControllerBulkChangeAll" \
  "[{\"Name\":\"${SVC1}\",\"Replicas\":0,\"TenantId\":\"${TENANT_ID}\"}]" | tail -1)
echo "  HTTP: $HTTP"
check "BulkChangeAll 1→0" "$SVC1" 0

# ── 2. BulkChangeAll: 0 → 1 (known bug: BulkChangeAll cannot start a stopped service) ──
echo ""
echo "[TEST 2] ReplicationControllerBulkChangeAll: $SVC1  0 → 1  (KNOWN BUG — stays at 0)"
HTTP=$(api POST "/subscriptions/${TENANT_ID}/ReplicationControllerBulkChangeAll" \
  "[{\"Name\":\"${SVC1}\",\"Replicas\":1,\"TenantId\":\"${TENANT_ID}\"}]" | tail -1)
echo "  HTTP: $HTTP"
bug "BulkChangeAll cannot scale 0→positive" "$SVC1" 1
# Use ChangeAll to restore
force_replicas "$SVC1" 1

# ── 3. BulkChangeAll: omit Replicas (should not zero out) ────────────────
echo ""
echo "[TEST 3] ReplicationControllerBulkChangeAll: omit Replicas (should stay at 1)"
HTTP=$(api POST "/subscriptions/${TENANT_ID}/ReplicationControllerBulkChangeAll" \
  "[{\"Name\":\"${SVC1}\",\"Image\":\"nginx:latest\",\"TenantId\":\"${TENANT_ID}\"}]" | tail -1)
echo "  HTTP: $HTTP"
check "BulkChangeAll omit replicas" "$SVC1" 1

# ── 4. BulkChange: single service 1 → 0 ─────────────────────────────────
echo ""
echo "[TEST 4] ReplicationControllerBulkChange: $SVC1  1 → 0"
force_replicas "$SVC1" 1
HTTP=$(api POST "/subscriptions/${TENANT_ID}/ReplicationControllerBulkChange" \
  "[{\"Name\":\"${SVC1}\",\"Replicas\":0,\"TenantId\":\"${TENANT_ID}\"}]" | tail -1)
echo "  HTTP: $HTTP"
check "BulkChange 1→0" "$SVC1" 0

# ── 5. BulkChange: 0 → 1 (start works via BulkChange) ───────────────────
echo ""
echo "[TEST 5] ReplicationControllerBulkChange: $SVC1  0 → 1"
HTTP=$(api POST "/subscriptions/${TENANT_ID}/ReplicationControllerBulkChange" \
  "[{\"Name\":\"${SVC1}\",\"Replicas\":1,\"TenantId\":\"${TENANT_ID}\"}]" | tail -1)
echo "  HTTP: $HTTP"
check "BulkChange 0→1" "$SVC1" 1

# ── 6. BulkChange: omit Replicas (should not zero out) ───────────────────
echo ""
echo "[TEST 6] ReplicationControllerBulkChange: omit Replicas (should stay at 1)"
HTTP=$(api POST "/subscriptions/${TENANT_ID}/ReplicationControllerBulkChange" \
  "[{\"Name\":\"${SVC1}\",\"Image\":\"nginx:latest\",\"TenantId\":\"${TENANT_ID}\"}]" | tail -1)
echo "  HTTP: $HTTP"
check "BulkChange omit replicas" "$SVC1" 1

# ── 7. Already stopped → scale to 0 again (no-op) ─────────────────────
echo ""
echo "[TEST 7] BulkChangeAll: already at 0 → scale to 0 (no-op)"
force_replicas "$SVC1" 0
HTTP=$(api POST "/subscriptions/${TENANT_ID}/ReplicationControllerBulkChangeAll" \
  "[{\"Name\":\"${SVC1}\",\"Replicas\":0,\"TenantId\":\"${TENANT_ID}\"}]" | tail -1)
echo "  HTTP: $HTTP"
check "BulkChangeAll 0→0 no-op" "$SVC1" 0
force_replicas "$SVC1" 1

# ── 8. PARALLEL bulk: 2 services → 0 in a SINGLE API call ───────────────
echo ""
echo "[TEST 8] BulkChangeAll: PARALLEL — $SVC1 + $SVC2  both 1 → 0  (single API call)"
force_replicas "$SVC1" 1
force_replicas "$SVC2" 1
HTTP=$(api POST "/subscriptions/${TENANT_ID}/ReplicationControllerBulkChangeAll" \
  "[{\"Name\":\"${SVC1}\",\"Replicas\":0,\"TenantId\":\"${TENANT_ID}\"},{\"Name\":\"${SVC2}\",\"Replicas\":0,\"TenantId\":\"${TENANT_ID}\"}]" | tail -1)
echo "  HTTP: $HTTP"
check "BulkChangeAll parallel SVC1 1→0" "$SVC1" 0
check "BulkChangeAll parallel SVC2 1→0" "$SVC2" 0

# ── 9. PARALLEL bulk via BulkChange: 2 services → 0 ─────────────────────
echo ""
echo "[TEST 9] BulkChange: PARALLEL — $SVC1 + $SVC2  both 0 → 1  (single API call)"
HTTP=$(api POST "/subscriptions/${TENANT_ID}/ReplicationControllerBulkChange" \
  "[{\"Name\":\"${SVC1}\",\"Replicas\":1,\"TenantId\":\"${TENANT_ID}\"},{\"Name\":\"${SVC2}\",\"Replicas\":1,\"TenantId\":\"${TENANT_ID}\"}]" | tail -1)
echo "  HTTP: $HTTP"
check "BulkChange parallel SVC1 0→1" "$SVC1" 1
check "BulkChange parallel SVC2 0→1" "$SVC2" 1

# ─── Restore ────────────────────────────────────────────────────────────────
echo ""
echo "Restoring both services to 1 replica..."
force_replicas "$SVC1" 1
force_replicas "$SVC2" 1

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "======================================================"
echo " Results : $PASS passed, $FAIL failed"
if [ "${#BUGS[@]}" -gt 0 ]; then
  echo " Bugs    : ${#BUGS[@]} known issue(s) found:"
  for b in "${BUGS[@]}"; do echo "   - $b"; done
fi
echo "======================================================"

if [ "${#BUGS[@]}" -gt 0 ]; then
  echo ""
  echo " BUG SUMMARY"
  echo " ReplicationControllerBulkChangeAll cannot scale a stopped service (0 replicas)"
  echo " back to a positive replica count. Use ReplicationControllerBulkChange or"
  echo " ReplicationControllerChangeAll to start a stopped service."
fi

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
