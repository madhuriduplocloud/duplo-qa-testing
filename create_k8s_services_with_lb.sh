#!/usr/bin/env bash
# Creates N Kubernetes services in a DuploCloud tenant and attaches an ALB
# with an ACM certificate to each one.
#
# Required env vars:
#   DUPLO_HOST     - DuploCloud portal URL   (e.g. https://perf.duplocloud.net)
#   DUPLO_TOKEN    - DuploCloud Bearer token
#   TENANT_ID      - Tenant UUID
#   CERT_ARN       - ACM certificate ARN
#
# Optional env vars:
#   SERVICE_PREFIX - Name prefix             (default: serv)
#   SERVICE_COUNT  - Number of services      (default: 20)
#   IMAGE          - Container image         (default: nginx:alpine)
#   CONTAINER_PORT - Container port          (default: 80)
#   EXTERNAL_PORT  - LB external port        (default: 443)
#   PROTOCOL       - LB protocol             (default: https)
#   HEALTH_CHECK   - Health check path       (default: /)
#
# Usage:
#   export DUPLO_HOST=https://perf.duplocloud.net
#   export DUPLO_TOKEN=<token>
#   export TENANT_ID=<uuid>
#   export CERT_ARN=arn:aws:acm:us-east-2:123456789:certificate/xxxx
#   ./create_k8s_services_with_lb.sh
#
# To delete services:
#   ./create_k8s_services_with_lb.sh --delete

set -euo pipefail

DUPLO_HOST="${DUPLO_HOST:-}"
DUPLO_TOKEN="${DUPLO_TOKEN:-}"
TENANT_ID="${TENANT_ID:-}"
CERT_ARN="${CERT_ARN:-}"
SERVICE_PREFIX="${SERVICE_PREFIX:-serv}"
SERVICE_COUNT="${SERVICE_COUNT:-20}"
IMAGE="${IMAGE:-nginx:alpine}"
CONTAINER_PORT="${CONTAINER_PORT:-80}"
EXTERNAL_PORT="${EXTERNAL_PORT:-443}"
PROTOCOL="${PROTOCOL:-https}"
HEALTH_CHECK="${HEALTH_CHECK:-/}"
DELETE_MODE=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --delete) DELETE_MODE=true ;;
    --help|-h) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

[[ -z "$DUPLO_HOST"   ]] && die "DUPLO_HOST is required"
[[ -z "$DUPLO_TOKEN"  ]] && die "DUPLO_TOKEN is required"
[[ -z "$TENANT_ID"    ]] && die "TENANT_ID is required"
[[ "$DELETE_MODE" == "false" && "$PROTOCOL" == "https" && -z "$CERT_ARN" ]] && \
  die "CERT_ARN is required for HTTPS protocol"

# ─── API call ─────────────────────────────────────────────────────────────────

duplo_post() {
  local path="$1"
  local body="$2"
  local response http_code body_out

  response=$(curl -s -w "\n%{http_code}" \
    -X POST "${DUPLO_HOST}/${path}" \
    -H "Authorization: Bearer ${DUPLO_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$body")

  http_code=$(echo "$response" | tail -1)
  body_out=$(echo "$response" | sed '$d')

  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
    echo "$body_out"
    return 0
  else
    echo "HTTP $http_code: $body_out" >&2
    return 1
  fi
}

# ─── Service operations ───────────────────────────────────────────────────────

create_service() {
  local name="$1"
  duplo_post "subscriptions/${TENANT_ID}/ReplicationControllerUpdate" \
    "{
      \"Name\": \"${name}\",
      \"Replicas\": 1,
      \"DockerImage\": \"${IMAGE}\",
      \"AgentPlatform\": 7,
      \"Cloud\": 0,
      \"Template\": {
        \"Name\": \"${name}\",
        \"Containers\": [{\"Name\": \"${name}\", \"Image\": \"${IMAGE}\"}],
        \"AgentPlatform\": 7,
        \"Cloud\": 0,
        \"LBConfigurations\": {}
      }
    }"
}

attach_lb() {
  local name="$1"
  duplo_post "subscriptions/${TENANT_ID}/LBConfigurationUpdate" \
    "{
      \"ReplicationControllerName\": \"${name}\",
      \"LbType\": 1,
      \"Protocol\": \"${PROTOCOL}\",
      \"Port\": \"${CONTAINER_PORT}\",
      \"ExternalPort\": ${EXTERNAL_PORT},
      \"IsInternal\": false,
      \"IsNative\": false,
      \"CertificateArn\": \"${CERT_ARN}\",
      \"HealthCheckUrl\": \"${HEALTH_CHECK}\",
      \"BeProtocolVersion\": \"HTTP1\"
    }"
}

delete_service() {
  local name="$1"
  duplo_post "subscriptions/${TENANT_ID}/ReplicationControllerUpdate" \
    "{\"Name\": \"${name}\", \"State\": \"delete\"}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
log "Host:     $DUPLO_HOST"
log "Tenant:   $TENANT_ID"
log "Services: ${SERVICE_PREFIX}1 – ${SERVICE_PREFIX}${SERVICE_COUNT}"
[[ "$DELETE_MODE" == "false" ]] && \
  log "LB:       ALB ${PROTOCOL}:${EXTERNAL_PORT} → ${CONTAINER_PORT}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

success=0; failed=0

for i in $(seq 1 "$SERVICE_COUNT"); do
  name="${SERVICE_PREFIX}${i}"

  if [[ "$DELETE_MODE" == "true" ]]; then
    if delete_service "$name" &>/dev/null; then
      ok "Deleted $name"; success=$((success + 1))
    else
      err "Failed to delete $name"; failed=$((failed + 1))
    fi
  else
    if create_service "$name" &>/dev/null; then
      ok "Created $name"
      success=$((success + 1))
      if attach_lb "$name" &>/dev/null; then
        ok "  └─ ALB attached  [${PROTOCOL}:${EXTERNAL_PORT}]"
      else
        warn "  └─ $name created but LB attachment failed"
      fi
    else
      err "Failed to create $name"; failed=$((failed + 1))
    fi
  fi
done

echo ""
log "Done — success: ${success}  failed: ${failed}"
[[ "$DELETE_MODE" == "false" && $success -gt 0 ]] && \
  log "ALBs are provisioning in AWS (~2-3 min for DNS names to appear)"
[[ $failed -gt 0 ]] && exit 1
exit 0
