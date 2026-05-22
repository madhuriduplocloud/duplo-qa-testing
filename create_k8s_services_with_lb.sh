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

# ─── Auth: resolve DuploCloud Bearer token ────────────────────────────────────

get_duplo_token() {
  # Prefer duploctl (Python SDK) for interactive/cached token resolution
  if command -v duploctl &>/dev/null; then
    python3 - <<'PYEOF'
import sys, os
# Locate duplocloud-client package (pipx or system)
import subprocess, json

result = subprocess.run(
  ["duploctl", "--host", os.environ["DUPLO_HOST"],
   "--interactive", "--admin", "--tenant", os.environ["DUPLO_TENANT"],
   "--output", "json", "tenant", "find"],
  capture_output=True, text=True
)
# We don't need the tenant output; we just want to trigger auth.
# Now read the cached token that duploctl wrote.
import pathlib, json as _json
cache_host = os.environ["DUPLO_HOST"].replace("https://","").replace("http://","")
cache_file = pathlib.Path.home() / ".duplo" / "cache" / f"{cache_host},duplo-creds.json"
if cache_file.exists():
    data = _json.loads(cache_file.read_text())
    print(data.get("DuploToken",""))
PYEOF
  else
    die "duploctl not found. Install with: pip install duplocloud-client"
  fi
}

# ─── Core API helpers ─────────────────────────────────────────────────────────

DUPLO_TOKEN=""
TENANT_ID=""

init_auth() {
  log "Authenticating with $DUPLO_HOST ..."

  if [[ -n "$AWS_PROFILE" ]]; then
    export AWS_PROFILE
  fi

  # Use Python SDK directly for reliable token + tenant-id resolution
  eval "$(python3 - <<'PYEOF'
import sys, os, json
sys.path.insert(0, '')
# Try to find duplocloud-client in pipx or system
import importlib.util, subprocess

def find_site():
    try:
        r = subprocess.run(["python3","-c","import duplocloud; print(duplocloud.__file__)"],
                           capture_output=True, text=True)
        if r.returncode == 0:
            import pathlib
            return str(pathlib.Path(r.stdout.strip()).parent.parent)
    except Exception:
        pass
    return None

site = find_site()
if site:
    sys.path.insert(0, site)

from duplocloud.controller import DuploCtl
duplo = DuploCtl(host=os.environ["DUPLO_HOST"], interactive=True, isadmin=True,
                 tenant=os.environ["DUPLO_TENANT"])
svc = duplo.load("service")
token = svc.client.token
tenant_id = svc.tenant_id
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
  body_out=$(echo "$response" | head -n -1)

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
  local is_internal="false"
  [[ "$INTERNAL_LB" == "true" ]] && is_internal="true"

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
