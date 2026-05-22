#!/usr/bin/env bash
# Creates N Kubernetes services in a DuploCloud tenant and attaches an ALB with
# an ACM certificate to each one.
#
# Required env vars (or edit defaults below):
#   DUPLO_HOST      - DuploCloud portal URL  (e.g. https://perf.duplocloud.net)
#   DUPLO_TENANT    - Tenant name            (e.g. mj1)
#   CERT_ARN        - ACM certificate ARN
#
# Optional env vars:
#   SERVICE_PREFIX  - Name prefix            (default: serv)
#   SERVICE_COUNT   - Number of services     (default: 20)
#   IMAGE           - Container image        (default: nginx:alpine)
#   CONTAINER_PORT  - Container port         (default: 80)
#   EXTERNAL_PORT   - LB external port       (default: 443)
#   PROTOCOL        - LB protocol            (default: https)
#   HEALTH_CHECK    - Health check path      (default: /)
#   INTERNAL_LB     - true/false             (default: false)
#   AWS_PROFILE     - AWS profile for duplo-jit auth (optional)
#
# Usage:
#   export DUPLO_HOST=https://perf.duplocloud.net
#   export DUPLO_TENANT=mj1
#   export CERT_ARN=arn:aws:acm:us-east-2:123456789:certificate/xxxx
#   ./create_k8s_services_with_lb.sh
#
# To delete the created services pass --delete:
#   ./create_k8s_services_with_lb.sh --delete

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

DUPLO_HOST="${DUPLO_HOST:-https://perf.duplocloud.net}"
DUPLO_TENANT="${DUPLO_TENANT:-mj1}"
CERT_ARN="${CERT_ARN:-}"
SERVICE_PREFIX="${SERVICE_PREFIX:-serv}"
SERVICE_COUNT="${SERVICE_COUNT:-20}"
IMAGE="${IMAGE:-nginx:alpine}"
CONTAINER_PORT="${CONTAINER_PORT:-80}"
EXTERNAL_PORT="${EXTERNAL_PORT:-443}"
PROTOCOL="${PROTOCOL:-https}"
HEALTH_CHECK="${HEALTH_CHECK:-/}"
INTERNAL_LB="${INTERNAL_LB:-false}"
AWS_PROFILE="${AWS_PROFILE:-}"
DELETE_MODE=false

# ─── Helpers ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

# ─── Parse args ───────────────────────────────────────────────────────────────

for arg in "$@"; do
  case "$arg" in
    --delete) DELETE_MODE=true ;;
    --help|-h)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

# ─── Validate inputs ──────────────────────────────────────────────────────────

[[ -z "$DUPLO_HOST" ]]   && die "DUPLO_HOST is required"
[[ -z "$DUPLO_TENANT" ]] && die "DUPLO_TENANT is required"
if [[ "$DELETE_MODE" == "false" && "$PROTOCOL" == "https" && -z "$CERT_ARN" ]]; then
  die "CERT_ARN is required for HTTPS protocol"
fi

# ─── Core API helpers ─────────────────────────────────────────────────────────

DUPLO_TOKEN=""
TENANT_ID=""

init_auth() {
  log "Authenticating with $DUPLO_HOST ..."

  if [[ -n "$AWS_PROFILE" ]]; then
    export AWS_PROFILE
  fi

  # Use duploctl to trigger interactive auth, then read the cached token + resolve tenant ID
  command -v duploctl &>/dev/null || die "duploctl not found. Install with: pipx install duplocloud-client"

  # Trigger auth and cache credentials
  duploctl --host "$DUPLO_HOST" --interactive --admin \
    --tenant "$DUPLO_TENANT" tenant list &>/dev/null || true

  # Read decrypted token and tenant ID from cache via duploctl jit
  eval "$(python3 - <<PYEOF
import os, sys, subprocess, json, pathlib

host = os.environ["DUPLO_HOST"]
tenant = os.environ["DUPLO_TENANT"]

# Read cached encrypted token
cache_host = host.replace("https://","").replace("http://","")
cache_file = pathlib.Path.home() / ".duplo" / "cache" / f"{cache_host},duplo-creds.json"
if not cache_file.exists():
    print("echo 'ERROR: No cached credentials found. Run duploctl login first.' >&2", flush=True)
    sys.exit(1)

# Use duploctl to list tenants and extract token + tenant ID
r = subprocess.run(
    ["duploctl", "--host", host, "--interactive", "--admin",
     "--tenant", tenant, "--output", "json", "tenant", "list"],
    capture_output=True, text=True
)
if r.returncode != 0:
    print(f"echo 'ERROR: duploctl auth failed: {r.stderr[:200]}' >&2", flush=True)
    sys.exit(1)

tenants = json.loads(r.stdout)
tenant_id = next((t["TenantId"] for t in tenants if t.get("AccountName","").lower() == tenant.lower()), "")
if not tenant_id:
    print(f"echo 'ERROR: Tenant {tenant!r} not found' >&2", flush=True)
    sys.exit(1)

# Get token via jit
r2 = subprocess.run(
    ["duploctl", "--host", host, "--interactive", "--admin",
     "--tenant", tenant, "--output", "json", "jit", "aws"],
    capture_output=True, text=True
)
# Extract Bearer token from cache (jit call refreshes it)
cache_data = json.loads(cache_file.read_text())
token = cache_data.get("DuploToken", "")
if not token:
    print("echo 'ERROR: Could not read token from cache' >&2", flush=True)
    sys.exit(1)

print(f"export DUPLO_TOKEN={token!r}")
print(f"export TENANT_ID={tenant_id!r}")
PYEOF
  )"

  [[ -z "$DUPLO_TOKEN" ]] && die "Could not resolve DuploCloud token"
  [[ -z "$TENANT_ID"   ]] && die "Could not resolve tenant ID for '$DUPLO_TENANT'"
  ok "Authenticated. Tenant ID: $TENANT_ID"
}

duplo_post() {
  local path="$1"
  local body="$2"
  local http_code
  local response

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
  local payload
  payload=$(python3 -c "
import json, sys
d = {
  'Name': '$name',
  'Replicas': 1,
  'DockerImage': '$IMAGE',
  'AgentPlatform': 7,
  'Cloud': 0,
  'Template': {
    'Name': '$name',
    'Containers': [{'Name': '$name', 'Image': '$IMAGE'}],
    'AgentPlatform': 7,
    'Cloud': 0,
    'LBConfigurations': {}
  }
}
print(json.dumps(d))
")
  duplo_post "subscriptions/${TENANT_ID}/ReplicationControllerUpdate" "$payload"
}

attach_lb() {
  local name="$1"
  local is_internal="False"
  [[ "$INTERNAL_LB" == "true" ]] && is_internal="True"

  local payload
  payload=$(python3 -c "
import json
d = {
  'LbType': 1,
  'Port': '$CONTAINER_PORT',
  'ExternalPort': $EXTERNAL_PORT,
  'IsInternal': $is_internal,
  'IsNative': False,
  'Protocol': '$PROTOCOL',
  'CertificateArn': '$CERT_ARN',
  'HealthCheckUrl': '$HEALTH_CHECK',
  'BeProtocolVersion': 'HTTP1',
  'ReplicationControllerName': '$name'
}
print(json.dumps(d))
")
  duplo_post "subscriptions/${TENANT_ID}/LBConfigurationUpdate" "$payload"
}

delete_service() {
  local name="$1"
  local payload="{\"Name\":\"${name}\",\"State\":\"delete\"}"
  duplo_post "subscriptions/${TENANT_ID}/ReplicationControllerUpdate" "$payload"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

print_summary() {
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  log "Host:       $DUPLO_HOST"
  log "Tenant:     $DUPLO_TENANT ($TENANT_ID)"
  log "Services:   ${SERVICE_PREFIX}1 – ${SERVICE_PREFIX}${SERVICE_COUNT}"
  if [[ "$DELETE_MODE" == "false" ]]; then
    log "Image:      $IMAGE"
    log "LB:         ALB  ${PROTOCOL}:${EXTERNAL_PORT} → ${CONTAINER_PORT}"
    [[ -n "$CERT_ARN" ]] && log "Cert ARN:   $CERT_ARN"
  fi
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

main() {
  init_auth
  print_summary

  local success=0 failed=0

  if [[ "$DELETE_MODE" == "true" ]]; then
    log "Deleting ${SERVICE_COUNT} services ..."
    for i in $(seq 1 "$SERVICE_COUNT"); do
      local name="${SERVICE_PREFIX}${i}"
      if delete_service "$name" &>/dev/null; then
        ok "Deleted $name"
        ((success++))
      else
        err "Failed to delete $name"
        ((failed++))
      fi
    done
  else
    log "Creating ${SERVICE_COUNT} services ..."
    for i in $(seq 1 "$SERVICE_COUNT"); do
      local name="${SERVICE_PREFIX}${i}"
      if create_service "$name" &>/dev/null; then
        ok "Created service $name"
        ((success++))
      else
        err "Failed to create $name"
        ((failed++))
        continue
      fi

      if attach_lb "$name" &>/dev/null; then
        ok "Attached ALB to $name  [${PROTOCOL}:${EXTERNAL_PORT}]"
      else
        warn "Service $name created but LB attachment failed"
      fi
    done
  fi

  echo ""
  if [[ "$DELETE_MODE" == "true" ]]; then
    log "Delete complete — success: ${success}  failed: ${failed}"
  else
    log "Create complete — success: ${success}  failed: ${failed}"
    [[ $success -gt 0 ]] && log "ALBs are provisioning in AWS (DNS names appear in ~2-3 min)"
  fi
  [[ $failed -gt 0 ]] && exit 1
  return 0
}

main "$@"
