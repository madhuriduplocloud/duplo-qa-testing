#!/bin/bash
# Test script for DUPLO-11210: Allow setting replica to zero during duplo service update
# Feature flag required: EnableDuploServiceScalingToZero = true
#
# Uses duploctl for service management.
# Bulk updates send multiple services in a SINGLE API call (processed in parallel server-side).
#
# Usage:
#   ./DUPLO-11210-bulk-update-test.sh
#
# Prerequisites:
#   duplocloud-client (duploctl) installed: pip install duplocloud-client
#   Services sv01 and sv02 must exist in the tenant with >=1 replica

HOST="https://oneclick.duplocloud.net"
TOKEN="AQAAANCMnd8BFdERjHoAwE_Cl-sBAAAAAJ7iw9hJuUKwrot0sNjfvAAAAAACAAAAAAAQZgAAAAEAACAAAACfDd3qz0B3nREQiz8JG5uz5GYQeCbzKeS5M7xaKp3NWwAAAAAOgAAAAAIAACAAAACR_9YZ0RCgqCbdshkozKo7NPkOB90OGvRZnTti9jyCUcAAAAApGzBowBYQey0vpklOlF0FZhP8JI2imoMw-wz__c3psWIfy3AeATqVuf__f0TvfhHrxA3CLT9w_kL0bmRajVAri6_nZ26evawN4T8BIzI1UQ_YZe-dm1gmmgLmJO8lj84AH1f6cGt87JTqzCHgHXWgk9-GAiz_elvvZ_QlO8PElR-SgeLiodNOqUCfU_MWGbPAJ0QJ0Tcb7mOd1XhF8sQdOAkofa2YkLObJYvL7HuVbA1bpCvTLYpVhxBTpVa4g3dAAAAACoShe-MNmA7ihOTabtrQdr_hwZidCPie8ExdykCVy1bUGDxEGAnM01c4Fkb13Pnq45shEjefb0F0VZwoAy8j3w"
TENANT="maja1706"
TENANT_ID="34d7c6cd-45f5-453a-b2bf-43066efa838e"

SVC1="sv01"
SVC2="sv02"

PASS=0
FAIL=0

# ─── Helpers ────────────────────────────────────────────────────────────────

DC="duploctl --host $HOST --token $TOKEN --tenant $TENANT"

get_replicas() {
  $DC service find "$1" --query "Replicas" --output string 2>&1
}

force_replicas() {
  $DC service update_replicas "$1" --replicas "$2" > /dev/null 2>&1
}

# Bulk update via raw API (single call — services updated in parallel server-side)
bulk_update() {
  local endpoint=$1
  local payload=$2
  curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    "${HOST}/subscriptions/${TENANT_ID}/${endpoint}" \
    -d "$payload"
}

check() {
  local label=$1 svc=$2 expected=$3
  local replicas
  replicas=$(get_replicas "$svc")
  if [ "$replicas" -eq "$expected" ] 2>/dev/null; then
    echo "  PASS  $svc: Replicas=$replicas"
    ((PASS++))
  else
    echo "  FAIL  $svc: Expected Replicas=$expected, got Replicas=$replicas"
    ((FAIL++))
  fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────

echo "======================================================"
echo " DUPLO-11210 — Bulk service replica-to-zero tests"
echo " Host  : $HOST"
echo " Tenant: $TENANT"
echo " SVCs  : $SVC1, $SVC2"
echo "======================================================"
echo ""

echo "Resetting both services to 1 replica..."
force_replicas "$SVC1" 1
force_replicas "$SVC2" 1
echo "Done."
echo ""

# ─── Tests ──────────────────────────────────────────────────────────────────

# ── 1. Single service: 1 → 0 via duploctl ────────────────────────────────
echo "[TEST 1] duploctl update_replicas: $SVC1  1 → 0"
$DC service update_replicas "$SVC1" --replicas 0 2>&1 | grep -v "^$"
check "update_replicas 1→0" "$SVC1" 0

# ── 2. Single service: 0 → 1 via duploctl ────────────────────────────────
echo ""
echo "[TEST 2] duploctl update_replicas: $SVC1  0 → 1"
$DC service update_replicas "$SVC1" --replicas 1 2>&1 | grep -v "^$"
check "update_replicas 0→1" "$SVC1" 1

# ── 3. Single: omit replica in update (should stay at 1) ─────────────────
echo ""
echo "[TEST 3] duploctl update image only — Replicas must stay at 1 (omit ≠ 0)"
$DC service update_image "$SVC1" nginx:latest 2>&1 | grep -v "^$"
check "image-only update, replicas unchanged" "$SVC1" 1

# ── 4. Parallel bulk: both services 1 → 0 in ONE API call ─────────────────
echo ""
echo "[TEST 4] BulkChangeAll: PARALLEL — $SVC1 + $SVC2  both 1 → 0  (single API call)"
force_replicas "$SVC1" 1
force_replicas "$SVC2" 1
RESP=$(bulk_update "ReplicationControllerBulkChangeAll" \
  "[{\"Name\":\"${SVC1}\",\"Replicas\":0,\"TenantId\":\"${TENANT_ID}\"},{\"Name\":\"${SVC2}\",\"Replicas\":0,\"TenantId\":\"${TENANT_ID}\"}]")
HTTP=$(echo "$RESP" | tail -1)
echo "  HTTP: $HTTP"
check "BulkChangeAll parallel $SVC1 1→0" "$SVC1" 0
check "BulkChangeAll parallel $SVC2 1→0" "$SVC2" 0

# ── 5. Parallel bulk: both services 0 → 1 via BulkChange ─────────────────
echo ""
echo "[TEST 5] BulkChange: PARALLEL — $SVC1 + $SVC2  both 0 → 1  (single API call)"
RESP=$(bulk_update "ReplicationControllerBulkChange" \
  "[{\"Name\":\"${SVC1}\",\"Replicas\":1,\"TenantId\":\"${TENANT_ID}\"},{\"Name\":\"${SVC2}\",\"Replicas\":1,\"TenantId\":\"${TENANT_ID}\"}]")
HTTP=$(echo "$RESP" | tail -1)
echo "  HTTP: $HTTP"
check "BulkChange parallel $SVC1 0→1" "$SVC1" 1
check "BulkChange parallel $SVC2 0→1" "$SVC2" 1

# ── 6. Parallel bulk: mixed replicas (SVC1→0, SVC2 stays 2) ───────────────
echo ""
echo "[TEST 6] BulkChange: PARALLEL — $SVC1→0, $SVC2→2  (single API call)"
force_replicas "$SVC2" 2
RESP=$(bulk_update "ReplicationControllerBulkChange" \
  "[{\"Name\":\"${SVC1}\",\"Replicas\":0,\"TenantId\":\"${TENANT_ID}\"},{\"Name\":\"${SVC2}\",\"Replicas\":2,\"TenantId\":\"${TENANT_ID}\"}]")
HTTP=$(echo "$RESP" | tail -1)
echo "  HTTP: $HTTP"
check "BulkChange $SVC1→0" "$SVC1" 0
check "BulkChange $SVC2 stays 2" "$SVC2" 2

# ── 7. Partial update (omit Replicas) must not zero out via bulk ──────────
echo ""
echo "[TEST 7] BulkChangeAll: omit Replicas — $SVC2 must stay at 2"
RESP=$(bulk_update "ReplicationControllerBulkChangeAll" \
  "[{\"Name\":\"${SVC2}\",\"Image\":\"nginx:latest\",\"TenantId\":\"${TENANT_ID}\"}]")
HTTP=$(echo "$RESP" | tail -1)
echo "  HTTP: $HTTP"
check "BulkChangeAll omit replicas, no accidental zero" "$SVC2" 2

# ── 8. Already-zero service: scale to 0 again (no-op) ────────────────────
echo ""
echo "[TEST 8] BulkChange: $SVC1 already at 0 → 0 (no-op)"
RESP=$(bulk_update "ReplicationControllerBulkChange" \
  "[{\"Name\":\"${SVC1}\",\"Replicas\":0,\"TenantId\":\"${TENANT_ID}\"}]")
HTTP=$(echo "$RESP" | tail -1)
echo "  HTTP: $HTTP"
check "BulkChange already 0 → 0 no-op" "$SVC1" 0

# ─── Restore ────────────────────────────────────────────────────────────────
echo ""
echo "Restoring both services to 1 replica..."
force_replicas "$SVC1" 1
force_replicas "$SVC2" 1

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "======================================================"
echo " Results: $PASS passed, $FAIL failed"
echo "======================================================"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
