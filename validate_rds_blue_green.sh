#!/usr/bin/env bash
# =============================================================================
# validate_rds_blue_green.sh  v2
# Aurora PostgreSQL Blue/Green Deployment E2E Validator
# Happy-path, AWS API only (no psql required). macOS bash 3.2 safe.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# COLOR CODES
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD_BLUE='\033[1;34m'
BOLD='\033[1m'
RESET='\033[0m'

# ---------------------------------------------------------------------------
# DEFAULTS
# ---------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE_NAME="${AWS_PROFILE:-}"
DUPLO_HOST=""
DUPLO_BEARER_TOKEN=""
DUPLO_TENANT=""

BLUE_CLUSTER=""
DEPLOYMENT_ID=""
TARGET_ENGINE_VERSION="16.10"

# RDS creation (Phase 0 / create-rds)
RDS_IDENTIFIER="pg-serverless"
RDS_MASTER_USER="pgadmin"
RDS_MASTER_PASSWORD=""
RDS_ENGINE_VERSION="16.6"
RDS_MIN_ACU="0.5"
RDS_MAX_ACU="8"

SWITCHOVER_TIMEOUT="300"
DELETE_RDS=false
PHASE="e2e"
REPORT_DIR="${TMPDIR:-/tmp}/rds_bg_reports"

# ---------------------------------------------------------------------------
# COUNTERS
# ---------------------------------------------------------------------------
pass_count=0
fail_count=0
warn_count=0
info_count=0

# ---------------------------------------------------------------------------
# REPORT
# ---------------------------------------------------------------------------
mkdir -p "$REPORT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_TXT="${REPORT_DIR}/bg_e2e_${TIMESTAMP}.txt"
touch "$REPORT_TXT"

# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
${BOLD}validate_rds_blue_green.sh v2${RESET} — Aurora PostgreSQL Blue/Green E2E Validator

${BOLD}USAGE:${RESET}
  $0 [OPTIONS]

${BOLD}PHASE FLAGS:${RESET}
  --phase PHASE        e2e | create-rds | create-bg | switchover | validate | cleanup
                       (default: e2e — runs the full flow)

${BOLD}CLUSTER / DEPLOYMENT:${RESET}
  --blue-cluster ID          Existing Blue cluster identifier (skips Phase 0 if set)
  --deployment-id ID         Existing B/G deployment ID (skips Phase 1 if set)
  --target-engine-version V  Target Aurora PostgreSQL version (default: 16.10)
  --switchover-timeout SECS  Switchover timeout (default: 300)

${BOLD}RDS CREATION (Phase 0 / create-rds):${RESET}
  --rds-identifier NAME      RDS cluster/instance base name (default: pg-serverless)
  --rds-master-user USER     Master username (default: pgadmin)
  --rds-master-pass PASS     Master password (required for RDS creation)
  --rds-engine-version VER   Source engine version (default: 16.6)
  --rds-min-acu NUM          Serverless v2 min ACU (default: 0.5)
  --rds-max-acu NUM          Serverless v2 max ACU (default: 8)

${BOLD}DUPLOCLOUD / AWS:${RESET}
  --aws-profile PROFILE      AWS profile (used to auto-derive DuploCloud token)
  --duplo-host HOST          DuploCloud host URL
  --duplo-token TOKEN        DuploCloud bearer token (overrides auto-detection)
  --duplo-tenant NAME        DuploCloud tenant name
  --region REGION            AWS region (default: \$AWS_REGION or us-east-1)

${BOLD}CLEANUP:${RESET}
  --delete-rds               During cleanup, also delete the RDS cluster

${BOLD}REPORTING:${RESET}
  --report-dir DIR           Directory for reports (default: /tmp/rds_bg_reports)

${BOLD}PHASES:${RESET}
  e2e         Full flow: create-rds → create-bg → switchover → validate → cleanup
  create-rds  Phase 0: Create Aurora Serverless v2 cluster via AWS CLI
  create-bg   Phase 1: Create B/G deployment via DuploCloud API + monitor to AVAILABLE
  switchover  Phase 2: Initiate switchover + wait for SWITCHOVER_COMPLETED
  validate    Phase 3: Post-switchover validation (AWS API only)
  cleanup     Phase 4: Delete B/G deployment (optionally delete RDS)

${BOLD}EXAMPLES:${RESET}
  # Full E2E flow (creates everything from scratch):
  $0 --aws-profile myprofile --duplo-tenant maja2205 \\
     --rds-master-pass MyPass123 --region us-east-1

  # E2E with existing cluster (skip Phase 0):
  $0 --aws-profile myprofile --duplo-tenant maja2205 \\
     --blue-cluster pg-serverless-cluster --region us-east-1

  # Just validate post-switchover state:
  $0 --aws-profile myprofile --blue-cluster pg-serverless-cluster \\
     --deployment-id bgd-abc123 --phase validate

EOF
  exit 0
}

# ---------------------------------------------------------------------------
# ARGUMENT PARSING
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)                usage ;;
    --phase)                  PHASE="$2";                shift 2 ;;
    --blue-cluster)           BLUE_CLUSTER="$2";         shift 2 ;;
    --deployment-id)          DEPLOYMENT_ID="$2";        shift 2 ;;
    --target-engine-version)  TARGET_ENGINE_VERSION="$2"; shift 2 ;;
    --switchover-timeout)     SWITCHOVER_TIMEOUT="$2";   shift 2 ;;
    --rds-identifier)         RDS_IDENTIFIER="$2";       shift 2 ;;
    --rds-master-user)        RDS_MASTER_USER="$2";      shift 2 ;;
    --rds-master-pass)        RDS_MASTER_PASSWORD="$2";  shift 2 ;;
    --rds-engine-version)     RDS_ENGINE_VERSION="$2";   shift 2 ;;
    --rds-min-acu)            RDS_MIN_ACU="$2";          shift 2 ;;
    --rds-max-acu)            RDS_MAX_ACU="$2";          shift 2 ;;
    --aws-profile)            AWS_PROFILE_NAME="$2";     shift 2 ;;
    --duplo-host)             DUPLO_HOST="$2";           shift 2 ;;
    --duplo-token)            DUPLO_BEARER_TOKEN="$2";   shift 2 ;;
    --duplo-tenant)           DUPLO_TENANT="$2";         shift 2 ;;
    --region)                 AWS_REGION="$2";           shift 2 ;;
    --delete-rds)             DELETE_RDS=true;           shift ;;
    --report-dir)             REPORT_DIR="$2";           shift 2 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

mkdir -p "$REPORT_DIR"

# ---------------------------------------------------------------------------
# LOGGING HELPERS
# ---------------------------------------------------------------------------
log_to_file() { echo "$*" >> "$REPORT_TXT"; }

print_section() {
  local title="$1"
  echo ""
  echo -e "${BOLD_BLUE}================================================================${RESET}"
  echo -e "${BOLD_BLUE}  $title${RESET}"
  echo -e "${BOLD_BLUE}================================================================${RESET}"
  log_to_file ""
  log_to_file "================================================================"
  log_to_file "  $title"
  log_to_file "================================================================"
}

print_subsection() {
  local title="$1"
  echo ""
  echo -e "${BOLD}--- $title ---${RESET}"
  log_to_file ""
  log_to_file "--- $title ---"
}

record_check() {
  local status="$1"
  local message="$2"
  local detail="${3:-}"
  local color="$RESET"
  # Bug 3 fix: use if/elif instead of declare -A (bash 3.2 safe)
  if [[ "$status" == "PASS" ]]; then
    color="$GREEN";  pass_count=$((pass_count+1))
  elif [[ "$status" == "FAIL" ]]; then
    color="$RED";    fail_count=$((fail_count+1))
  elif [[ "$status" == "WARN" ]]; then
    color="$YELLOW"; warn_count=$((warn_count+1))
  elif [[ "$status" == "INFO" ]]; then
    color="$CYAN";   info_count=$((info_count+1))
  fi
  local line="[$status] $message"
  [[ -n "$detail" ]] && line="$line — $detail"
  echo -e "${color}${line}${RESET}"
  log_to_file "$line"
}

info() {
  echo -e "${CYAN}$*${RESET}"
  log_to_file "$*"
}

warn_msg() {
  echo -e "${YELLOW}WARN: $*${RESET}"
  log_to_file "WARN: $*"
}

# ---------------------------------------------------------------------------
# DATE HELPERS (macOS + Linux)
# ---------------------------------------------------------------------------
now_epoch() { date +%s; }

# ---------------------------------------------------------------------------
# AWS HELPERS
# ---------------------------------------------------------------------------
# Bug 2 fix: always use aws_cmd (not bare aws) so AWS_PROFILE_NAME is honoured
aws_cmd() {
  if [[ -n "${AWS_PROFILE_NAME:-}" ]]; then
    AWS_PROFILE="$AWS_PROFILE_NAME" aws "$@" --region "$AWS_REGION" 2>/dev/null || true
  else
    aws "$@" --region "$AWS_REGION" 2>/dev/null || true
  fi
}

aws_rds() {
  if [[ -n "${AWS_PROFILE_NAME:-}" ]]; then
    AWS_PROFILE="$AWS_PROFILE_NAME" aws rds "$@"
  else
    aws rds "$@"
  fi
}

# ---------------------------------------------------------------------------
# DUPLOCLOUD TOKEN AUTO-DETECTION FROM ~/.aws/config
# ---------------------------------------------------------------------------
get_duplo_token_from_aws_config() {
  local profile="${1:-${AWS_PROFILE_NAME:-}}"
  local aws_config="${HOME}/.aws/config"

  if [[ -z "$profile" ]]; then
    warn_msg "No --aws-profile specified; skipping DuploCloud token auto-detection"
    return 0
  fi
  if [[ ! -f "$aws_config" ]]; then
    warn_msg "~/.aws/config not found; cannot auto-detect DuploCloud token"
    return 0
  fi

  info "Extracting DuploCloud token from ~/.aws/config profile: $profile"

  local cred_process
  cred_process=$(python3 - "$aws_config" "$profile" <<'PYEOF'
import sys, configparser
cfg_file, profile = sys.argv[1], sys.argv[2]
cp = configparser.ConfigParser()
cp.read(cfg_file)
section = f"profile {profile}"
if section not in cp and profile == "default":
    section = "default"
if section not in cp:
    print("")
    sys.exit(0)
print(cp[section].get("credential_process", ""))
PYEOF
  )

  if [[ -z "$cred_process" ]]; then
    warn_msg "No credential_process found for profile '$profile' in ~/.aws/config"
    return 0
  fi

  info "  credential_process: $cred_process"

  local duplo_host encrypted_token
  duplo_host=$(echo "$cred_process" | grep -oE '\-\-host [^ ]+' | awk '{print $2}' | head -1)
  encrypted_token=$(echo "$cred_process" | grep -oE '\-\-token [^ ]+' | awk '{print $2}' | head -1)

  if [[ -z "$duplo_host" ]]; then
    warn_msg "Could not parse --host from credential_process for profile '$profile'"
    return 0
  fi
  if [[ -z "$encrypted_token" ]]; then
    warn_msg "No --token in credential_process for profile '$profile'; skipping auto-detection"
    return 0
  fi

  [[ -z "$DUPLO_HOST" ]] && DUPLO_HOST="$duplo_host"
  info "  DuploCloud host: $DUPLO_HOST"

  if ! command -v duplo-jit &>/dev/null; then
    warn_msg "duplo-jit not found in PATH; cannot auto-detect DuploCloud bearer token"
    return 0
  fi

  local raw_output bearer
  raw_output=$(duplo-jit duplo --host "$DUPLO_HOST" --token "$encrypted_token" 2>/dev/null || true)
  if [[ -z "$raw_output" ]]; then
    warn_msg "duplo-jit duplo returned empty output for profile '$profile'"
    return 0
  fi

  bearer=$(echo "$raw_output" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('DuploToken', ''))
except Exception:
    print(sys.stdin.read().strip())
" 2>/dev/null || true)

  if [[ -z "$bearer" ]]; then
    warn_msg "Could not extract DuploToken from duplo-jit output"
    return 0
  fi

  DUPLO_BEARER_TOKEN="$bearer"
  info "  DuploCloud bearer token obtained (length: ${#DUPLO_BEARER_TOKEN})"
}

# Auto-detect token if not already set
if [[ -z "$DUPLO_BEARER_TOKEN" && -n "$AWS_PROFILE_NAME" ]]; then
  get_duplo_token_from_aws_config "$AWS_PROFILE_NAME"
fi
[[ -z "$DUPLO_BEARER_TOKEN" && -n "${DUPLO_TOKEN:-}" ]] && DUPLO_BEARER_TOKEN="$DUPLO_TOKEN"

# ---------------------------------------------------------------------------
# DUPLOCLOUD API HELPER
# ---------------------------------------------------------------------------
duplo_api() {
  local method="${1:-GET}"
  local path="$2"
  local body="${3:-}"
  local url="${DUPLO_HOST}${path}"

  if [[ -z "$DUPLO_BEARER_TOKEN" || -z "$DUPLO_HOST" ]]; then
    echo ""
    return 1
  fi

  if [[ -n "$body" ]]; then
    curl -s --max-time 30 -X "$method" \
      -H "Authorization: Bearer $DUPLO_BEARER_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$body" "$url" 2>/dev/null || true
  else
    curl -s --max-time 30 -X "$method" \
      -H "Authorization: Bearer $DUPLO_BEARER_TOKEN" \
      "$url" 2>/dev/null || true
  fi
}

resolve_tenant_id() {
  local tenant_name="$1"
  duplo_api GET "/v3/admin/tenant" | python3 -c "
import json, sys
try:
    for t in json.load(sys.stdin):
        if t.get('AccountName','').lower() == '${tenant_name}'.lower():
            print(t['TenantId'])
            break
except: pass
" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# PRINT HEADER
# ---------------------------------------------------------------------------
print_header() {
  echo ""
  echo -e "${BOLD_BLUE}#############################################################${RESET}"
  echo -e "${BOLD_BLUE}#   RDS Aurora PostgreSQL Blue/Green E2E Validator  v2      #${RESET}"
  echo -e "${BOLD_BLUE}#############################################################${RESET}"
  echo -e "${CYAN}  Run Time      : $(date)${RESET}"
  echo -e "${CYAN}  Phase         : $PHASE${RESET}"
  echo -e "${CYAN}  Region        : $AWS_REGION${RESET}"
  echo -e "${CYAN}  Blue Cluster  : ${BLUE_CLUSTER:-(will be created)}${RESET}"
  echo -e "${CYAN}  Deployment ID : ${DEPLOYMENT_ID:-(will be created)}${RESET}"
  echo -e "${CYAN}  Target Version: $TARGET_ENGINE_VERSION${RESET}"
  echo -e "${CYAN}  Report        : $REPORT_TXT${RESET}"
  echo ""
  log_to_file "RDS Aurora PostgreSQL Blue/Green E2E Validator v2"
  log_to_file "Run Time: $(date)"
  log_to_file "Phase: $PHASE  Region: $AWS_REGION"
}

# ===========================================================================
# PHASE 0 — CREATE AURORA SERVERLESS V2 CLUSTER (via AWS CLI)
# ===========================================================================
phase0_create_rds() {
  print_section "PHASE 0 — CREATE AURORA SERVERLESS V2 (AWS CLI)"

  if [[ -n "$BLUE_CLUSTER" ]]; then
    record_check "INFO" "Skipping Phase 0" "--blue-cluster provided: $BLUE_CLUSTER"
    return 0
  fi

  if [[ -z "$RDS_MASTER_PASSWORD" ]]; then
    record_check "FAIL" "Phase 0: --rds-master-pass is required" ""
    return 1
  fi

  local cluster_id="${RDS_IDENTIFIER}-cluster"
  local instance_id="${RDS_IDENTIFIER}"

  # Check if cluster already exists
  print_subsection "0.1  Check for Existing Cluster"
  local existing_status
  existing_status=$(aws_cmd rds describe-db-clusters \
    --db-cluster-identifier "$cluster_id" \
    --query 'DBClusters[0].Status' \
    --output text 2>/dev/null || echo "")

  if [[ -n "$existing_status" && "$existing_status" != "None" ]]; then
    record_check "INFO" "Cluster already exists: $cluster_id (status=$existing_status)" "Reusing existing cluster"
    BLUE_CLUSTER="$cluster_id"
    return 0
  fi

  # Create custom cluster parameter group (required for logical replication / B/G)
  print_subsection "0.2  Create Cluster Parameter Group"
  local pg_family="aurora-postgresql${RDS_ENGINE_VERSION%%.*}"
  local pg_name="${RDS_IDENTIFIER}-pg"

  info "  Parameter group: $pg_name (family: $pg_family)"

  local pg_out
  pg_out=$(aws_rds create-db-cluster-parameter-group \
    --region "$AWS_REGION" \
    --db-cluster-parameter-group-name "$pg_name" \
    --db-parameter-group-family "$pg_family" \
    --description "Aurora PG for ${RDS_IDENTIFIER} — logical replication enabled" \
    --output json 2>&1) || true

  if echo "$pg_out" | grep -q '"DBClusterParameterGroupArn"'; then
    record_check "PASS" "Cluster parameter group created: $pg_name" ""
  elif echo "$pg_out" | grep -qi "already exists\|AlreadyExists"; then
    record_check "INFO" "Cluster parameter group already exists: $pg_name" ""
  else
    record_check "FAIL" "Could not create cluster parameter group" "$pg_out"
    return 1
  fi

  # Enable logical replication
  local mod_out
  mod_out=$(aws_rds modify-db-cluster-parameter-group \
    --region "$AWS_REGION" \
    --db-cluster-parameter-group-name "$pg_name" \
    --parameters "ParameterName=rds.logical_replication,ParameterValue=1,ApplyMethod=pending-reboot" \
    --output json 2>&1) || true

  if echo "$mod_out" | grep -q "DBClusterParameterGroupName"; then
    record_check "PASS" "rds.logical_replication=1 set in parameter group" ""
  else
    record_check "FAIL" "Failed to set rds.logical_replication" "$mod_out"
    return 1
  fi

  # Look up subnet group and security group from existing DuploCloud clusters
  print_subsection "0.3  Discover Subnet Group and Security Group"

  local subnet_group sg_id

  subnet_group=$(aws_cmd rds describe-db-clusters \
    --query "DBClusters[?starts_with(DBClusterIdentifier,\`duplo\`)].DBSubnetGroup | [0]" \
    --output text 2>/dev/null || echo "")

  if [[ -z "$subnet_group" || "$subnet_group" == "None" ]]; then
    record_check "FAIL" "Could not determine RDS subnet group from DuploCloud-managed clusters" ""
    return 1
  fi

  # Bug 2 fix: use aws_cmd (not bare aws) for EC2 security group lookup
  sg_id=$(aws_cmd ec2 describe-security-groups \
    --filters "Name=group-name,Values=duploservices-${DUPLO_TENANT}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "")

  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    record_check "FAIL" "Could not find security group duploservices-${DUPLO_TENANT}" ""
    return 1
  fi

  record_check "INFO" "Subnet group: $subnet_group  SG: $sg_id" ""

  # Bug 1 fix: create Aurora Serverless v2 cluster with correct engine-mode,
  # serverless-v2-scaling-configuration, and db.serverless instance class
  print_subsection "0.4  Create Aurora Serverless v2 Cluster"
  info "  Cluster:    $cluster_id"
  info "  Engine:     aurora-postgresql $RDS_ENGINE_VERSION"
  info "  Min ACU:    $RDS_MIN_ACU  Max ACU: $RDS_MAX_ACU"

  local create_cluster_out
  create_cluster_out=$(aws_rds create-db-cluster \
    --region "$AWS_REGION" \
    --db-cluster-identifier "$cluster_id" \
    --engine aurora-postgresql \
    --engine-version "$RDS_ENGINE_VERSION" \
    --engine-mode provisioned \
    --serverless-v2-scaling-configuration "MinCapacity=${RDS_MIN_ACU},MaxCapacity=${RDS_MAX_ACU}" \
    --master-username "$RDS_MASTER_USER" \
    --master-user-password "$RDS_MASTER_PASSWORD" \
    --db-cluster-parameter-group-name "$pg_name" \
    --db-subnet-group-name "$subnet_group" \
    --vpc-security-group-ids "$sg_id" \
    --backup-retention-period 7 \
    --no-deletion-protection \
    --output json 2>&1) || true

  if echo "$create_cluster_out" | grep -q '"DBClusterIdentifier"'; then
    record_check "PASS" "Aurora Serverless v2 cluster created: $cluster_id" ""
  else
    record_check "FAIL" "Failed to create Aurora cluster" "$create_cluster_out"
    return 1
  fi

  # Bug 1 fix: use db.serverless instance class (not db.t3.medium)
  print_subsection "0.5  Create Serverless v2 Instance"
  local create_instance_out
  create_instance_out=$(aws_rds create-db-instance \
    --region "$AWS_REGION" \
    --db-instance-identifier "$instance_id" \
    --db-cluster-identifier "$cluster_id" \
    --db-instance-class db.serverless \
    --engine aurora-postgresql \
    --output json 2>&1) || true

  if echo "$create_instance_out" | grep -q '"DBInstanceIdentifier"'; then
    record_check "PASS" "Serverless v2 instance created: $instance_id" ""
  else
    record_check "FAIL" "Failed to create Aurora instance" "$create_instance_out"
    return 1
  fi

  # Wait for cluster to become available
  print_subsection "0.6  Wait for Cluster Available"
  local elapsed=0 max_wait=900
  while (( elapsed < max_wait )); do
    local status
    status=$(aws_cmd rds describe-db-clusters \
      --db-cluster-identifier "$cluster_id" \
      --query 'DBClusters[0].Status' \
      --output text 2>/dev/null || echo "not-found")
    info "  [${elapsed}s] Cluster status: $status"
    if [[ "$status" == "available" ]]; then
      record_check "PASS" "Cluster available: $cluster_id" ""
      break
    fi
    sleep 30; elapsed=$((elapsed+30))
  done
  if (( elapsed >= max_wait )); then
    record_check "FAIL" "Cluster did not become available within ${max_wait}s" ""
    return 1
  fi

  BLUE_CLUSTER="$cluster_id"
  record_check "PASS" "Phase 0 complete" "Blue cluster: $BLUE_CLUSTER"
}

# ===========================================================================
# PHASE 1 — CREATE B/G DEPLOYMENT VIA DUPLOCLOUD + MONITOR
# Includes GC deletion detection (DUPLO-43111)
# ===========================================================================
phase1_create_bg() {
  print_section "PHASE 1 — CREATE BLUE/GREEN DEPLOYMENT (DuploCloud) + MONITOR"

  if [[ -n "$DEPLOYMENT_ID" ]]; then
    record_check "INFO" "Skipping Phase 1 creation" "--deployment-id provided: $DEPLOYMENT_ID"
    return 0
  fi

  if [[ -z "$DUPLO_BEARER_TOKEN" || -z "$DUPLO_HOST" ]]; then
    record_check "FAIL" "No DuploCloud credentials" "Provide --aws-profile or --duplo-token + --duplo-host"
    return 1
  fi
  if [[ -z "$DUPLO_TENANT" ]]; then
    record_check "FAIL" "Phase 1: --duplo-tenant required" ""
    return 1
  fi
  if [[ -z "$BLUE_CLUSTER" ]]; then
    record_check "FAIL" "Phase 1: --blue-cluster or Phase 0 must set BLUE_CLUSTER" ""
    return 1
  fi

  # Resolve tenant ID
  print_subsection "1.1  Resolve Tenant ID"
  local tenant_id
  tenant_id=$(resolve_tenant_id "$DUPLO_TENANT")
  if [[ -z "$tenant_id" ]]; then
    record_check "FAIL" "Could not resolve tenant ID for '$DUPLO_TENANT'" ""
    return 1
  fi
  record_check "PASS" "Tenant '$DUPLO_TENANT' resolved" "TenantId: $tenant_id"

  # Create the B/G deployment via DuploCloud API
  print_subsection "1.2  Create Blue/Green Deployment"
  info "  Blue cluster: $BLUE_CLUSTER"
  info "  Target engine version: $TARGET_ENGINE_VERSION"

  # Strip "duplo" prefix for DuploCloud resource name
  local duplo_cluster_name="${BLUE_CLUSTER#duplo}"
  local bg_payload
  bg_payload=$(python3 -c "
import json
print(json.dumps({
  'Name': '${duplo_cluster_name}-bg',
  'Source': '${BLUE_CLUSTER}',
  'TargetEngineVersion': '${TARGET_ENGINE_VERSION}'
}))
")

  local create_resp
  create_resp=$(duplo_api POST "/v3/subscriptions/${tenant_id}/aws/rds/blueGreenDeployment" "$bg_payload" || echo "")

  if [[ -z "$create_resp" ]]; then
    record_check "FAIL" "DuploCloud B/G deployment create returned empty response" ""
    return 1
  fi

  DEPLOYMENT_ID=$(echo "$create_resp" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    # Try common field names
    for k in ('BlueGreenDeploymentIdentifier','DeploymentId','Name','Id','Identifier'):
        if k in d:
            print(d[k])
            sys.exit(0)
    # If it's a string directly
    print(d)
except: pass
" 2>/dev/null || echo "")

  if [[ -z "$DEPLOYMENT_ID" ]]; then
    record_check "FAIL" "Could not extract deployment ID from response" "${create_resp:0:200}"
    return 1
  fi
  record_check "PASS" "B/G deployment creation initiated" "ID: $DEPLOYMENT_ID"

  # Monitor until AVAILABLE, tracking GC deletions (DUPLO-43111)
  print_subsection "1.3  Monitor Deployment Until AVAILABLE (GC deletion tracking)"
  info "  Polling every 30s. Tracking Green cluster for GC deletions..."

  local gc_deletion_count=0
  local last_green_cluster=""
  local poll_elapsed=0
  local max_poll=3600  # 60 min max

  while (( poll_elapsed < max_poll )); do
    local bg_json bg_status
    bg_json=$(aws_cmd rds describe-blue-green-deployments \
      --blue-green-deployment-identifier "$DEPLOYMENT_ID" \
      --query 'BlueGreenDeployments[0]' \
      --output json 2>/dev/null || echo "{}")
    bg_status=$(echo "$bg_json" | python3 -c \
      "import sys,json; print(json.load(sys.stdin).get('Status','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")

    # Find current Green cluster: starts_with(blue_cluster + "-green-")
    local current_green
    current_green=$(aws_cmd rds describe-db-clusters \
      --query "DBClusters[?starts_with(DBClusterIdentifier,\`${BLUE_CLUSTER}-green-\`)].DBClusterIdentifier | [0]" \
      --output text 2>/dev/null || echo "")
    [[ "$current_green" == "None" ]] && current_green=""

    # GC deletion detection
    if [[ -n "$last_green_cluster" ]]; then
      if [[ -z "$current_green" ]]; then
        gc_deletion_count=$((gc_deletion_count+1))
        warn_msg "GC DELETION DETECTED: Green cluster $last_green_cluster disappeared! (count=$gc_deletion_count)"
        last_green_cluster=""
      elif [[ "$current_green" != "$last_green_cluster" ]]; then
        gc_deletion_count=$((gc_deletion_count+1))
        warn_msg "GC DELETION DETECTED: Green cluster changed $last_green_cluster -> $current_green (count=$gc_deletion_count)"
        last_green_cluster="$current_green"
      fi
    elif [[ -n "$current_green" ]]; then
      last_green_cluster="$current_green"
      info "  [${poll_elapsed}s] Green cluster found: $last_green_cluster"
    fi

    info "  [${poll_elapsed}s] Deployment status: $bg_status  Green: ${current_green:-(not yet visible)}"

    if [[ "$bg_status" == "AVAILABLE" ]]; then
      if (( gc_deletion_count > 0 )); then
        record_check "FAIL" "DUPLO-43111: GC deleted Green cluster ${gc_deletion_count} time(s)" \
          "Green cluster was deleted and recreated during provisioning — deployment may be unstable"
      else
        record_check "PASS" "B/G deployment reached AVAILABLE" "No GC deletions detected"
      fi
      return 0
    fi

    if [[ "$bg_status" == "INVALID_CONFIGURATION" || "$bg_status" == "FAILED" ]]; then
      local fail_msg="Deployment status: $bg_status"
      if (( gc_deletion_count > 0 )); then
        fail_msg="$fail_msg — likely caused by GC deletion (${gc_deletion_count} deletion(s) detected)"
      fi
      record_check "FAIL" "B/G deployment $bg_status" "$fail_msg"
      return 1
    fi

    sleep 30
    poll_elapsed=$((poll_elapsed+30))
  done

  record_check "FAIL" "Deployment did not reach AVAILABLE within ${max_poll}s" "Status: $bg_status"
  return 1
}

# ===========================================================================
# PHASE 2 — SWITCHOVER
# ===========================================================================
phase2_switchover() {
  print_section "PHASE 2 — SWITCHOVER"

  if [[ -z "$DEPLOYMENT_ID" ]]; then
    record_check "FAIL" "Phase 2: --deployment-id required" ""
    return 1
  fi

  # Verify deployment is AVAILABLE before switching
  print_subsection "2.1  Pre-Switchover Status Check"
  local bg_status
  bg_status=$(aws_cmd rds describe-blue-green-deployments \
    --blue-green-deployment-identifier "$DEPLOYMENT_ID" \
    --query 'BlueGreenDeployments[0].Status' \
    --output text 2>/dev/null || echo "UNKNOWN")

  if [[ "$bg_status" != "AVAILABLE" ]]; then
    record_check "FAIL" "Deployment must be AVAILABLE to switchover" "Current: $bg_status"
    return 1
  fi
  record_check "PASS" "Deployment is AVAILABLE — initiating switchover" ""

  # Initiate switchover
  print_subsection "2.2  Initiate Switchover"
  info "  Deployment: $DEPLOYMENT_ID  Timeout: ${SWITCHOVER_TIMEOUT}s"

  local sw_out
  sw_out=$(aws_cmd rds switchover-blue-green-deployment \
    --blue-green-deployment-identifier "$DEPLOYMENT_ID" \
    --switchover-timeout "$SWITCHOVER_TIMEOUT" \
    --output json 2>/dev/null || echo "")

  if [[ -z "$sw_out" ]]; then
    record_check "FAIL" "Switchover command returned no output" ""
    return 1
  fi
  record_check "PASS" "Switchover initiated" ""

  # Poll until SWITCHOVER_COMPLETED
  print_subsection "2.3  Wait for SWITCHOVER_COMPLETED"
  local sw_elapsed=0
  local sw_max=1800  # 30 min max
  local sw_interval=30

  while (( sw_elapsed < sw_max )); do
    local sw_status
    sw_status=$(aws_cmd rds describe-blue-green-deployments \
      --blue-green-deployment-identifier "$DEPLOYMENT_ID" \
      --query 'BlueGreenDeployments[0].Status' \
      --output text 2>/dev/null || echo "UNKNOWN")

    info "  [${sw_elapsed}s] Status: $sw_status"

    if [[ "$sw_status" == "SWITCHOVER_COMPLETED" ]]; then
      record_check "PASS" "Switchover completed" "Elapsed: ${sw_elapsed}s"
      return 0
    fi

    if [[ "$sw_status" == "FAILED" || "$sw_status" == "INVALID_CONFIGURATION" ]]; then
      record_check "FAIL" "Switchover failed" "Status: $sw_status"
      return 1
    fi

    sleep "$sw_interval"
    sw_elapsed=$((sw_elapsed+sw_interval))
  done

  record_check "FAIL" "Switchover did not complete within ${sw_max}s" ""
  return 1
}

# ===========================================================================
# PHASE 3 — POST-SWITCHOVER VALIDATION (AWS API only, happy path)
# ===========================================================================
phase3_validate() {
  print_section "PHASE 3 — POST-SWITCHOVER VALIDATION (AWS API)"

  if [[ -z "$DEPLOYMENT_ID" ]]; then
    record_check "FAIL" "Phase 3: --deployment-id required" ""
    return 1
  fi
  if [[ -z "$BLUE_CLUSTER" ]]; then
    record_check "FAIL" "Phase 3: --blue-cluster required" ""
    return 1
  fi

  # 3.1 Deployment status = SWITCHOVER_COMPLETED
  print_subsection "3.1  Deployment Status"
  local bg_json
  bg_json=$(aws_cmd rds describe-blue-green-deployments \
    --blue-green-deployment-identifier "$DEPLOYMENT_ID" \
    --query 'BlueGreenDeployments[0]' \
    --output json 2>/dev/null || echo "{}")
  local bg_status
  bg_status=$(echo "$bg_json" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('Status','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")

  if [[ "$bg_status" == "SWITCHOVER_COMPLETED" ]]; then
    record_check "PASS" "Deployment status = SWITCHOVER_COMPLETED" ""
  else
    record_check "FAIL" "Expected SWITCHOVER_COMPLETED" "Actual: $bg_status"
  fi

  # Identify Green cluster (was created as ${BLUE_CLUSTER}-green-XXXXX)
  local green_cluster
  green_cluster=$(aws_cmd rds describe-db-clusters \
    --query "DBClusters[?starts_with(DBClusterIdentifier,\`${BLUE_CLUSTER}-green-\`)].DBClusterIdentifier | [0]" \
    --output text 2>/dev/null || echo "")
  [[ "$green_cluster" == "None" ]] && green_cluster=""

  # Fallback: find via SwitchoverDetails TargetMember
  if [[ -z "$green_cluster" ]]; then
    green_cluster=$(echo "$bg_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('SwitchoverDetails', []):
    tgt = s.get('TargetMember', '')
    if ':cluster:' in tgt:
        print(tgt.split(':cluster:')[-1])
        break
" 2>/dev/null || echo "")
  fi

  info "  Blue cluster (original, now replica): $BLUE_CLUSTER"
  info "  Green cluster (new primary): ${green_cluster:-(not found)}"

  # 3.2 Green cluster status = available
  print_subsection "3.2  Green Cluster Status"
  if [[ -n "$green_cluster" ]]; then
    local green_status
    green_status=$(aws_cmd rds describe-db-clusters \
      --db-cluster-identifier "$green_cluster" \
      --query 'DBClusters[0].Status' \
      --output text 2>/dev/null || echo "unknown")
    if [[ "$green_status" == "available" ]]; then
      record_check "PASS" "Green cluster available" "$green_cluster = $green_status"
    else
      record_check "FAIL" "Green cluster not available" "$green_cluster = $green_status"
    fi
  else
    record_check "WARN" "Could not identify Green cluster" "Check AWS console"
  fi

  # 3.3 Blue cluster status = available (retained as replica)
  print_subsection "3.3  Blue Cluster Status (Retained as Replica)"
  local blue_status
  blue_status=$(aws_cmd rds describe-db-clusters \
    --db-cluster-identifier "$BLUE_CLUSTER" \
    --query 'DBClusters[0].Status' \
    --output text 2>/dev/null || echo "unknown")
  if [[ "$blue_status" == "available" ]]; then
    record_check "PASS" "Blue cluster retained and available" "$BLUE_CLUSTER = $blue_status"
  else
    record_check "FAIL" "Blue cluster not available" "$BLUE_CLUSTER = $blue_status"
  fi

  # 3.4 Verify Blue has ReplicationSourceIdentifier set (confirms replica)
  print_subsection "3.4  Blue Cluster is a Replica"
  local blue_replication_source
  blue_replication_source=$(aws_cmd rds describe-db-clusters \
    --db-cluster-identifier "$BLUE_CLUSTER" \
    --query 'DBClusters[0].ReplicationSourceIdentifier' \
    --output text 2>/dev/null || echo "")
  [[ "$blue_replication_source" == "None" ]] && blue_replication_source=""

  if [[ -n "$blue_replication_source" ]]; then
    record_check "PASS" "Blue cluster has ReplicationSourceIdentifier set" "$blue_replication_source"
  else
    record_check "WARN" "Blue cluster ReplicationSourceIdentifier not set" \
      "May still be propagating post-switchover — check again shortly"
  fi

  # 3.5 Green engine version = TARGET_ENGINE_VERSION
  print_subsection "3.5  Green Engine Version"
  if [[ -n "$green_cluster" ]]; then
    local green_engine_ver
    green_engine_ver=$(aws_cmd rds describe-db-clusters \
      --db-cluster-identifier "$green_cluster" \
      --query 'DBClusters[0].EngineVersion' \
      --output text 2>/dev/null || echo "unknown")
    if [[ "$green_engine_ver" == "$TARGET_ENGINE_VERSION" ]]; then
      record_check "PASS" "Green engine version = $TARGET_ENGINE_VERSION" ""
    else
      record_check "FAIL" "Green engine version mismatch" \
        "Expected $TARGET_ENGINE_VERSION, got $green_engine_ver"
    fi

    # 3.6 Show Green writer endpoint
    print_subsection "3.6  Green Writer Endpoint"
    local green_endpoint
    green_endpoint=$(aws_cmd rds describe-db-clusters \
      --db-cluster-identifier "$green_cluster" \
      --query 'DBClusters[0].Endpoint' \
      --output text 2>/dev/null || echo "unknown")
    record_check "INFO" "Green writer endpoint" "${green_endpoint}"
    info ""
    info "  Update your application DB_HOST to:"
    info "    $green_endpoint"
    info ""
  else
    record_check "WARN" "Phase 3.5/3.6 skipped" "Green cluster not identified"
  fi

  # 3.7 SwitchoverDetails summary
  print_subsection "3.7  SwitchoverDetails Summary"
  echo "$bg_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for s in d.get('SwitchoverDetails', []):
    src = s.get('SourceMember','?')
    tgt = s.get('TargetMember','?')
    st  = s.get('SwitchoverStatus','?')
    print(f'  {src} -> {tgt} : {st}')
" 2>/dev/null || true
  record_check "INFO" "SwitchoverDetails printed above" ""
}

# ===========================================================================
# PHASE 4 — CLEANUP
# ===========================================================================
phase4_cleanup() {
  print_section "PHASE 4 — CLEANUP"

  if [[ -z "$DEPLOYMENT_ID" ]]; then
    record_check "INFO" "No --deployment-id provided" "Skipping deployment deletion"
  else
    # 4.1 Delete B/G deployment
    print_subsection "4.1  Delete Blue/Green Deployment"
    local del_status
    del_status=$(aws_cmd rds describe-blue-green-deployments \
      --blue-green-deployment-identifier "$DEPLOYMENT_ID" \
      --query 'BlueGreenDeployments[0].Status' \
      --output text 2>/dev/null || echo "")

    if [[ -z "$del_status" || "$del_status" == "None" ]]; then
      record_check "INFO" "Deployment already deleted or not found" "$DEPLOYMENT_ID"
    else
      info "  Deployment $DEPLOYMENT_ID status: $del_status — issuing delete"
      aws_cmd rds delete-blue-green-deployment \
        --blue-green-deployment-identifier "$DEPLOYMENT_ID" \
        --no-delete-target 2>/dev/null || true

      # Wait for deletion
      local del_elapsed=0 del_max=600
      while (( del_elapsed < del_max )); do
        local check_status
        check_status=$(aws_cmd rds describe-blue-green-deployments \
          --blue-green-deployment-identifier "$DEPLOYMENT_ID" \
          --query 'BlueGreenDeployments[0].Status' \
          --output text 2>/dev/null || echo "")
        if [[ -z "$check_status" || "$check_status" == "None" ]]; then
          record_check "PASS" "B/G deployment deleted" "$DEPLOYMENT_ID (${del_elapsed}s)"
          break
        fi
        info "  [${del_elapsed}s] Deployment status: $check_status"
        sleep 20; del_elapsed=$((del_elapsed+20))
      done
      if (( del_elapsed >= del_max )); then
        record_check "WARN" "Deployment still exists after ${del_max}s" "Check AWS console"
      fi
    fi
  fi

  # 4.2 Optionally delete RDS cluster
  if [[ "$DELETE_RDS" == "true" && -n "$BLUE_CLUSTER" ]]; then
    print_subsection "4.2  Delete Blue Cluster (--delete-rds)"
    info "  Deleting cluster: $BLUE_CLUSTER"

    # Delete instances first
    local cluster_instances
    cluster_instances=$(aws_cmd rds describe-db-clusters \
      --db-cluster-identifier "$BLUE_CLUSTER" \
      --query 'DBClusters[0].DBClusterMembers[*].DBInstanceIdentifier' \
      --output text 2>/dev/null || echo "")

    # Bug 5 fix: use herestring instead of echo | while to avoid subshell counter loss
    # (here we just iterate directly as we don't need to update counters from within)
    while IFS= read -r inst_id; do
      [[ -z "$inst_id" || "$inst_id" == "None" ]] && continue
      info "  Deleting instance: $inst_id"
      aws_cmd rds delete-db-instance \
        --db-instance-identifier "$inst_id" \
        --skip-final-snapshot 2>/dev/null || true
    done <<< "$cluster_instances"

    # Brief wait for instances
    sleep 10

    aws_cmd rds delete-db-cluster \
      --db-cluster-identifier "$BLUE_CLUSTER" \
      --skip-final-snapshot 2>/dev/null || true
    record_check "INFO" "Blue cluster delete issued" "$BLUE_CLUSTER (async — check AWS console)"
  fi

  record_check "INFO" "Cleanup complete" ""
}

# ===========================================================================
# SUMMARY
# ===========================================================================
print_summary() {
  local total=$(( pass_count + fail_count + warn_count ))
  echo ""
  print_section "E2E VALIDATION SUMMARY"
  echo -e "${GREEN}  PASS  : $pass_count${RESET}"
  echo -e "${RED}  FAIL  : $fail_count${RESET}"
  echo -e "${YELLOW}  WARN  : $warn_count${RESET}"
  echo -e "${CYAN}  INFO  : $info_count${RESET}"
  echo -e "${BOLD}  TOTAL : $total checks${RESET}"
  echo ""
  if (( fail_count > 0 )); then
    echo -e "${RED}${BOLD}  RESULT: FAILED — $fail_count critical issue(s) found${RESET}"
  elif (( warn_count > 0 )); then
    echo -e "${YELLOW}${BOLD}  RESULT: PASSED WITH WARNINGS — $warn_count warning(s)${RESET}"
  else
    echo -e "${GREEN}${BOLD}  RESULT: ALL CHECKS PASSED${RESET}"
  fi
  echo ""
  echo -e "${CYAN}  Report: $REPORT_TXT${RESET}"
  echo ""
  log_to_file "SUMMARY: PASS=$pass_count FAIL=$fail_count WARN=$warn_count INFO=$info_count"
}

# ===========================================================================
# MAIN ENTRY POINT
# ===========================================================================
main() {
  print_header

  case "$PHASE" in
    e2e)
      phase0_create_rds
      phase1_create_bg
      phase2_switchover
      phase3_validate
      phase4_cleanup
      ;;
    create-rds)
      phase0_create_rds
      ;;
    create-bg)
      phase1_create_bg
      ;;
    switchover)
      phase2_switchover
      ;;
    validate)
      phase3_validate
      ;;
    cleanup)
      phase4_cleanup
      ;;
    *)
      echo -e "${RED}Unknown phase: $PHASE${RESET}"
      usage
      ;;
  esac

  print_summary

  if (( fail_count > 0 )); then
    exit 1
  fi
  exit 0
}

main "$@"
