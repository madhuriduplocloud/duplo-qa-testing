#!/usr/bin/env bash
# =============================================================================
# validate_rds_blue_green.sh
# Comprehensive AWS RDS Aurora PostgreSQL Blue/Green Deployment Validator
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
BLUE_INSTANCE=""
GREEN_INSTANCE=""
DEPLOYMENT_ID=""
DB_NAME="postgres"
DB_USER="postgres"
DB_PORT="5432"
DB_SCHEMA="public"
AWS_REGION="${AWS_REGION:-us-east-1}"
LAG_THRESHOLD=30          # seconds
MONITOR_DURATION=3600     # 60 minutes
MONITOR_INTERVAL=60       # seconds
PHASE="all"
REPORT_DIR="${TMPDIR:-/tmp}/rds_bg_reports"
CONN_THRESHOLD=200        # connections alert threshold

# ---------------------------------------------------------------------------
# COUNTERS
# ---------------------------------------------------------------------------
pass_count=0
fail_count=0
warn_count=0
info_count=0
alert_count=0

# ---------------------------------------------------------------------------
# REPORT FILES
# ---------------------------------------------------------------------------
mkdir -p "$REPORT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_TXT="${REPORT_DIR}/bg_validate_${TIMESTAMP}.txt"
REPORT_JSON="${REPORT_DIR}/bg_validate_${TIMESTAMP}.json"
touch "$REPORT_TXT"

# ---------------------------------------------------------------------------
# HELP
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
${BOLD}validate_rds_blue_green.sh${RESET} — AWS RDS Aurora PostgreSQL Blue/Green Deployment Validator

${BOLD}USAGE:${RESET}
  $0 [OPTIONS]

${BOLD}REQUIRED FLAGS:${RESET}
  --blue-instance ID       Blue (original) DB instance identifier
  --green-instance ID      Green (new) DB instance identifier
  --deployment-id ID       Blue/Green deployment ID

${BOLD}OPTIONAL FLAGS:${RESET}
  --db-name NAME           Database name           (default: postgres)
  --db-user USER           PostgreSQL user         (default: postgres)
  --db-port PORT           PostgreSQL port         (default: 5432)
  --schema SCHEMA          Schema to inspect       (default: public)
  --region REGION          AWS region              (default: \$AWS_REGION or us-east-1)
  --lag-threshold SECS     ReplicaLag threshold    (default: 30)
  --monitor-duration SECS  Phase 3 duration        (default: 3600)
  --monitor-interval SECS  Phase 3 poll interval   (default: 60)
  --phase PHASE            Phase to run: pre|post|monitor|post+monitor|all (default: all)
  --report-dir DIR         Directory for reports   (default: /tmp/rds_bg_reports)

${BOLD}PHASES:${RESET}
  pre          Phase 1: Pre-switchover checks
  post         Phase 2: Post-switchover checks
  monitor      Phase 3: Continuous monitoring only
  post+monitor Phase 2 + Phase 3
  all          Phase 1 only, then prints switchover command and advises re-run with --phase post+monitor

${BOLD}ENVIRONMENT:${RESET}
  AWS_REGION        AWS region (overridden by --region)
  PGPASSWORD        PostgreSQL password (required for DB checks; skipped if unset)
  AWS_PROFILE       AWS CLI profile (optional)

${BOLD}EXAMPLES:${RESET}
  # Run pre-switchover checks
  PGPASSWORD=secret $0 --blue-instance mydb-blue --green-instance mydb-green \\
    --deployment-id bgd-abc123 --phase pre

  # Run post-switchover checks + monitoring
  PGPASSWORD=secret $0 --blue-instance mydb-blue --green-instance mydb-green \\
    --deployment-id bgd-abc123 --phase post+monitor --monitor-duration 1800

EOF
  exit 0
}

# ---------------------------------------------------------------------------
# ARGUMENT PARSING
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)           usage ;;
    --blue-instance)     BLUE_INSTANCE="$2";    shift 2 ;;
    --green-instance)    GREEN_INSTANCE="$2";   shift 2 ;;
    --deployment-id)     DEPLOYMENT_ID="$2";    shift 2 ;;
    --db-name)           DB_NAME="$2";          shift 2 ;;
    --db-user)           DB_USER="$2";          shift 2 ;;
    --db-port)           DB_PORT="$2";          shift 2 ;;
    --schema)            DB_SCHEMA="$2";        shift 2 ;;
    --region)            AWS_REGION="$2";       shift 2 ;;
    --lag-threshold)     LAG_THRESHOLD="$2";    shift 2 ;;
    --monitor-duration)  MONITOR_DURATION="$2"; shift 2 ;;
    --monitor-interval)  MONITOR_INTERVAL="$2"; shift 2 ;;
    --phase)             PHASE="$2";            shift 2 ;;
    --report-dir)        REPORT_DIR="$2";       shift 2 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# Validate required args
if [[ -z "$BLUE_INSTANCE" || -z "$GREEN_INSTANCE" || -z "$DEPLOYMENT_ID" ]]; then
  echo -e "${RED}ERROR: --blue-instance, --green-instance, and --deployment-id are required.${RESET}"
  usage
fi

# Recreate report dir in case --report-dir was overridden
mkdir -p "$REPORT_DIR"

# ---------------------------------------------------------------------------
# LOGGING HELPERS
# ---------------------------------------------------------------------------
log_to_file() {
  echo "$*" >> "$REPORT_TXT"
}

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
  local status="$1"   # PASS | FAIL | WARN | INFO
  local message="$2"
  local detail="${3:-}"
  local color="$RESET"
  case "$status" in
    PASS) color="$GREEN";  ((pass_count++)) ;;
    FAIL) color="$RED";    ((fail_count++)) ;;
    WARN) color="$YELLOW"; ((warn_count++)) ;;
    INFO) color="$CYAN";   ((info_count++)) ;;
  esac
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
# PORTABLE DATE HELPERS (macOS + Linux)
# ---------------------------------------------------------------------------
date_add_seconds() {
  # date_add_seconds <epoch> <seconds_to_add> → new epoch
  local base_epoch="$1"
  local add_secs="$2"
  echo $(( base_epoch + add_secs ))
}

epoch_to_human() {
  local epoch="$1"
  if date -r "$epoch" +"%Y-%m-%d %H:%M:%S" 2>/dev/null; then
    : # macOS
  else
    date -d "@$epoch" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown"
  fi
}

now_epoch() {
  date +%s
}

seconds_between() {
  # seconds_between <epoch1> <epoch2> → difference (epoch2 - epoch1)
  echo $(( $2 - $1 ))
}

iso8601_to_epoch() {
  local iso="$1"
  # Try GNU date first, fall back to macOS date
  if date -d "$iso" +%s 2>/dev/null; then
    :
  else
    # macOS: replace Z with +0000, use -j -f
    local cleaned
    cleaned=$(echo "$iso" | sed 's/Z$/+0000/' | sed 's/\.[0-9]*+/+/')
    date -j -f "%Y-%m-%dT%H:%M:%S%z" "$cleaned" +%s 2>/dev/null || echo "0"
  fi
}

# ---------------------------------------------------------------------------
# AWS HELPERS
# ---------------------------------------------------------------------------
aws_cmd() {
  aws "$@" --region "$AWS_REGION" 2>/dev/null || true
}

get_instance_info() {
  local id="$1"
  aws_cmd rds describe-db-instances --db-instance-identifier "$id" \
    --query 'DBInstances[0]' --output json 2>/dev/null || echo "{}"
}

get_endpoint() {
  local id="$1"
  aws_cmd rds describe-db-instances --db-instance-identifier "$id" \
    --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || echo ""
}

get_cloudwatch_stat() {
  # get_cloudwatch_stat <instance_id> <metric> <stat> <period_minutes>
  local instance_id="$1"
  local metric="$2"
  local stat="$3"
  local period_minutes="${4:-15}"
  local period_secs=$(( period_minutes * 60 ))

  local end_time
  end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

  local start_time
  if date -v "-${period_minutes}M" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null; then
    start_time=$(date -v "-${period_minutes}M" +"%Y-%m-%dT%H:%M:%SZ")
  else
    local start_epoch=$(( $(date +%s) - period_secs ))
    start_time=$(date -d "@$start_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
  fi

  if [[ -z "$start_time" ]]; then
    echo "N/A"
    return
  fi

  local result
  result=$(aws_cmd cloudwatch get-metric-statistics \
    --namespace "AWS/RDS" \
    --metric-name "$metric" \
    --dimensions Name=DBInstanceIdentifier,Value="$instance_id" \
    --start-time "$start_time" \
    --end-time "$end_time" \
    --period "$period_secs" \
    --statistics "$stat" \
    --query "Datapoints[0].${stat}" \
    --output text 2>/dev/null) || true
  echo "${result:-N/A}"
}

# ---------------------------------------------------------------------------
# PSQL HELPERS
# ---------------------------------------------------------------------------
PSQL_AVAILABLE=false
if command -v psql &>/dev/null; then
  PSQL_AVAILABLE=true
fi

psql_query() {
  # psql_query <host> <query> [<extra_psql_args>]
  local host="$1"
  local query="$2"
  local extra="${3:--t -A}"

  if [[ -z "${PGPASSWORD:-}" ]]; then
    echo "PGPASSWORD_NOT_SET"
    return 1
  fi
  if [[ "$PSQL_AVAILABLE" != "true" ]]; then
    echo "PSQL_NOT_AVAILABLE"
    return 1
  fi
  if [[ -z "$host" || "$host" == "None" || "$host" == "null" ]]; then
    echo "NO_HOST"
    return 1
  fi

  PGCONNECT_TIMEOUT=10 PGPASSWORD="$PGPASSWORD" psql \
    -h "$host" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    $extra -c "$query" 2>/dev/null || echo "PSQL_ERROR"
}

psql_query_csv() {
  local host="$1"
  local query="$2"
  if [[ -z "${PGPASSWORD:-}" ]]; then echo "PGPASSWORD_NOT_SET"; return 1; fi
  if [[ "$PSQL_AVAILABLE" != "true" ]]; then echo "PSQL_NOT_AVAILABLE"; return 1; fi
  if [[ -z "$host" || "$host" == "None" ]]; then echo "NO_HOST"; return 1; fi
  PGCONNECT_TIMEOUT=10 PGPASSWORD="$PGPASSWORD" psql \
    -h "$host" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -t -A -F',' -c "$query" 2>/dev/null || echo "PSQL_ERROR"
}

check_psql_prereqs() {
  if [[ -z "${PGPASSWORD:-}" ]]; then
    record_check "WARN" "PGPASSWORD not set" "All psql checks will be skipped"
    return 1
  fi
  if [[ "$PSQL_AVAILABLE" != "true" ]]; then
    record_check "WARN" "psql not found in PATH" "All psql checks will be skipped"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# PRINT HEADER
# ---------------------------------------------------------------------------
print_header() {
  echo ""
  echo -e "${BOLD_BLUE}#############################################################${RESET}"
  echo -e "${BOLD_BLUE}#   RDS Aurora PostgreSQL Blue/Green Deployment Validator   #${RESET}"
  echo -e "${BOLD_BLUE}#############################################################${RESET}"
  echo -e "${CYAN}  Run Time   : $(date)${RESET}"
  echo -e "${CYAN}  Phase      : $PHASE${RESET}"
  echo -e "${CYAN}  Blue       : $BLUE_INSTANCE${RESET}"
  echo -e "${CYAN}  Green      : $GREEN_INSTANCE${RESET}"
  echo -e "${CYAN}  Deployment : $DEPLOYMENT_ID${RESET}"
  echo -e "${CYAN}  Region     : $AWS_REGION${RESET}"
  echo -e "${CYAN}  Report TXT : $REPORT_TXT${RESET}"
  echo -e "${CYAN}  Report JSON: $REPORT_JSON${RESET}"
  echo ""
  log_to_file "RDS Aurora PostgreSQL Blue/Green Deployment Validator"
  log_to_file "Run Time   : $(date)"
  log_to_file "Phase      : $PHASE"
  log_to_file "Blue       : $BLUE_INSTANCE"
  log_to_file "Green      : $GREEN_INSTANCE"
  log_to_file "Deployment : $DEPLOYMENT_ID"
  log_to_file "Region     : $AWS_REGION"
}

# ===========================================================================
# PHASE 1 — PRE-SWITCHOVER
# ===========================================================================

phase1_pre_switchover() {
  print_section "PHASE 1 — PRE-SWITCHOVER CHECKS"

  # -------------------------------------------------------------------------
  # 1.1 Blue/Green Deployment Status
  # -------------------------------------------------------------------------
  print_subsection "1.1 Blue/Green Deployment Status"

  local bg_json
  bg_json=$(aws_cmd rds describe-blue-green-deployments \
    --blue-green-deployment-identifier "$DEPLOYMENT_ID" \
    --query 'BlueGreenDeployments[0]' --output json 2>/dev/null) || bg_json="{}"

  if [[ -z "$bg_json" || "$bg_json" == "null" || "$bg_json" == "{}" ]]; then
    record_check "FAIL" "Blue/Green deployment not found" "$DEPLOYMENT_ID"
    return 1
  fi

  local bg_status
  bg_status=$(echo "$bg_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Status','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")

  if [[ "$bg_status" == "AVAILABLE" ]]; then
    record_check "PASS" "Blue/Green deployment status" "$bg_status"
  else
    record_check "FAIL" "Blue/Green deployment status must be AVAILABLE" "Current: $bg_status"
  fi

  # StatusDetails
  local status_details
  status_details=$(echo "$bg_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for item in d.get('StatusDetails', []):
    print(f\"  {item.get('Identifier','?')}: {item.get('Status','?')} — {item.get('StatusDetails','')}\")
" 2>/dev/null || echo "  (none)")
  info "  StatusDetails:"
  echo "$status_details"
  log_to_file "$status_details"

  # SwitchoverDetails
  local sw_details
  sw_details=$(echo "$bg_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
sd = d.get('SwitchoverDetails', [])
for s in sd:
    print(f\"  SourceMember: {s.get('SourceMember','?')} → TargetMember: {s.get('TargetMember','?')} Status: {s.get('SwitchoverStatus','?')}\")
if not sd:
    print('  (none yet)')
" 2>/dev/null || echo "  (none)")
  info "  SwitchoverDetails:"
  echo "$sw_details"
  log_to_file "$sw_details"

  # Blue replica retention / deletion window
  local delete_time
  delete_time=$(echo "$bg_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# Check various possible fields
for field in ['DeleteBlueInstancesOnSwitchover','SwitchoverTimeout','BlueInstanceRetentionPeriod']:
    val = d.get(field)
    if val is not None:
        print(f'{field}={val}')
# Also check SwitchoverDetails for timing
for s in d.get('SwitchoverDetails', []):
    if 'SwitchoverCompleteTime' in s:
        print(f'SwitchoverCompleteTime={s[\"SwitchoverCompleteTime\"]}')
" 2>/dev/null || echo "")

  local bg_create_time
  bg_create_time=$(echo "$bg_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('CreateTime',''))
" 2>/dev/null || echo "")

  echo -e "${CYAN}  Blue Replica Retention Info:${RESET}"
  if [[ -n "$delete_time" ]]; then
    info "    $delete_time"
  else
    info "    Retention window not yet set (set at switchover time by RDS)"
    info "    Typical RDS Blue retention: the Blue instance is kept as a read replica until you manually delete it or switchover is finalized"
  fi
  info "    Deployment Created: ${bg_create_time:-unknown}"
  record_check "INFO" "Blue replica retention window" "Check AWS Console after switchover for exact deletion deadline"

  # -------------------------------------------------------------------------
  # 1.2 Instance Health
  # -------------------------------------------------------------------------
  print_subsection "1.2 Instance Health"

  for INST_LABEL in "Blue:$BLUE_INSTANCE" "Green:$GREEN_INSTANCE"; do
    local label="${INST_LABEL%%:*}"
    local inst_id="${INST_LABEL##*:}"
    local inst_json
    inst_json=$(get_instance_info "$inst_id")

    local inst_status
    inst_status=$(echo "$inst_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('DBInstanceStatus','unknown'))" 2>/dev/null || echo "unknown")

    if [[ "$inst_status" == "available" ]]; then
      record_check "PASS" "$label instance status" "$inst_id = $inst_status"
    else
      record_check "FAIL" "$label instance must be available" "$inst_id = $inst_status"
    fi

    # StatusInfos
    local status_infos
    status_infos=$(echo "$inst_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('StatusInfos', []):
    print(f\"    [{s.get('StatusType','?')}] Normal={s.get('Normal','?')} Message={s.get('Message','')}\")
" 2>/dev/null || echo "    (none)")
    info "  $label StatusInfos:"
    echo "$status_infos"
    log_to_file "$status_infos"
  done

  # -------------------------------------------------------------------------
  # 1.3 Replication Health on Green
  # -------------------------------------------------------------------------
  print_subsection "1.3 Replication Health on Green"

  local green_json
  green_json=$(get_instance_info "$GREEN_INSTANCE")

  # StatusInfos replication check
  local rep_normal
  rep_normal=$(echo "$green_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('StatusInfos', []):
    if s.get('StatusType','').lower() == 'read replication':
        print(str(s.get('Normal', False)))
        sys.exit(0)
print('not_found')
" 2>/dev/null || echo "not_found")

  if [[ "$rep_normal" == "True" ]]; then
    record_check "PASS" "Green read replication StatusInfo" "Normal=True"
  elif [[ "$rep_normal" == "not_found" ]]; then
    record_check "WARN" "Green read replication StatusInfo not found" "May not yet be replicating"
  else
    record_check "FAIL" "Green read replication StatusInfo" "Normal=$rep_normal"
  fi

  # CloudWatch ReplicaLag (15 min)
  local replica_lag_avg
  replica_lag_avg=$(get_cloudwatch_stat "$GREEN_INSTANCE" "ReplicaLag" "Average" 15)
  local replica_lag_max
  replica_lag_max=$(get_cloudwatch_stat "$GREEN_INSTANCE" "ReplicaLag" "Maximum" 15)

  if [[ "$replica_lag_avg" != "N/A" && "$replica_lag_avg" != "None" ]]; then
    local lag_int
    lag_int=$(python3 -c "print(int(float('$replica_lag_avg')))" 2>/dev/null || echo "999")
    if (( lag_int <= LAG_THRESHOLD )); then
      record_check "PASS" "Green ReplicaLag (15m avg)" "${replica_lag_avg}s ≤ threshold ${LAG_THRESHOLD}s"
    else
      record_check "FAIL" "Green ReplicaLag EXCEEDS threshold — BLOCKING SWITCHOVER" "Avg=${replica_lag_avg}s Max=${replica_lag_max}s threshold=${LAG_THRESHOLD}s"
    fi
  else
    record_check "WARN" "Green ReplicaLag" "No CloudWatch data in last 15 min (avg=$replica_lag_avg)"
  fi
  info "    ReplicaLag: Avg=${replica_lag_avg}s  Max=${replica_lag_max}s  Threshold=${LAG_THRESHOLD}s"

  # CloudWatch AuroraReplicaLag (ms)
  local aurora_lag_avg
  aurora_lag_avg=$(get_cloudwatch_stat "$GREEN_INSTANCE" "AuroraReplicaLag" "Average" 15)
  local aurora_lag_max
  aurora_lag_max=$(get_cloudwatch_stat "$GREEN_INSTANCE" "AuroraReplicaLag" "Maximum" 15)
  info "    AuroraReplicaLag (ms): Avg=${aurora_lag_avg}  Max=${aurora_lag_max}"
  record_check "INFO" "AuroraReplicaLag (ms)" "Avg=${aurora_lag_avg} Max=${aurora_lag_max}"

  # psql checks on Blue
  local blue_endpoint
  blue_endpoint=$(get_endpoint "$BLUE_INSTANCE")
  info "  Blue endpoint: $blue_endpoint"

  if check_psql_prereqs; then
    # pg_stat_replication on Blue
    print_subsection "1.3a pg_stat_replication on Blue"
    local rep_stat
    rep_stat=$(psql_query "$blue_endpoint" \
      "SELECT application_name, state, sent_lsn, write_lsn, flush_lsn, replay_lsn,
              (sent_lsn - replay_lsn) AS lag_bytes,
              sync_state
       FROM pg_stat_replication;" \
      "--no-align --field-separator='|' -t" 2>/dev/null || echo "PSQL_ERROR")

    if [[ "$rep_stat" == "PSQL_ERROR" || "$rep_stat" == "PGPASSWORD_NOT_SET" || "$rep_stat" == "NO_HOST" ]]; then
      record_check "WARN" "pg_stat_replication query" "$rep_stat"
    else
      if [[ -z "$rep_stat" ]]; then
        record_check "WARN" "pg_stat_replication" "No replication slots found on Blue (may be normal pre-BGD)"
      else
        local streaming_count
        streaming_count=$(echo "$rep_stat" | grep -c "streaming" 2>/dev/null || echo "0")
        if (( streaming_count > 0 )); then
          record_check "PASS" "pg_stat_replication" "$streaming_count streaming connections found"
        else
          record_check "WARN" "pg_stat_replication" "No streaming state found"
        fi
        info "  Replication connections:"
        echo "$rep_stat" | while IFS='|' read -r app_name state sent_lsn write_lsn flush_lsn replay_lsn lag_bytes sync_state; do
          info "    app=$app_name state=$state lag_bytes=$lag_bytes sync=$sync_state"
        done
      fi
    fi

    # pg_replication_slots on Blue
    print_subsection "1.3b pg_replication_slots on Blue"
    local rep_slots
    rep_slots=$(psql_query "$blue_endpoint" \
      "SELECT slot_name, plugin, slot_type, active, restart_lsn, confirmed_flush_lsn,
              pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS lag_bytes
       FROM pg_replication_slots;" \
      "--no-align --field-separator='|' -t" 2>/dev/null || echo "PSQL_ERROR")

    if [[ "$rep_slots" == "PSQL_ERROR" || "$rep_slots" == "PGPASSWORD_NOT_SET" || "$rep_slots" == "NO_HOST" ]]; then
      record_check "WARN" "pg_replication_slots query" "$rep_slots"
    else
      if [[ -z "$rep_slots" ]]; then
        record_check "WARN" "pg_replication_slots" "No replication slots on Blue"
      else
        local inactive_slots
        inactive_slots=$(echo "$rep_slots" | grep -c "^.*|.*|.*|f|" 2>/dev/null || echo "0")
        if (( inactive_slots > 0 )); then
          record_check "WARN" "pg_replication_slots" "$inactive_slots inactive slot(s) — may accumulate WAL"
        else
          record_check "PASS" "pg_replication_slots" "All slots active"
        fi
        echo "$rep_slots" | while IFS='|' read -r slot_name plugin slot_type active restart_lsn flush_lsn lag_bytes; do
          info "    slot=$slot_name type=$slot_type active=$active lag_bytes=$lag_bytes"
        done
        # Check for excessive lag_bytes (> 1GB = 1073741824)
        echo "$rep_slots" | while IFS='|' read -r slot_name plugin slot_type active restart_lsn flush_lsn lag_bytes; do
          if [[ "$lag_bytes" =~ ^[0-9]+$ ]] && (( lag_bytes > 1073741824 )); then
            record_check "WARN" "Replication slot $slot_name has excessive lag" "${lag_bytes} bytes > 1GB"
          fi
        done
      fi
    fi

    # wal_level
    print_subsection "1.3c WAL Configuration on Blue"
    local wal_level
    wal_level=$(psql_query "$blue_endpoint" "SHOW wal_level;" 2>/dev/null || echo "PSQL_ERROR")
    wal_level=$(echo "$wal_level" | tr -d '[:space:]')
    if [[ "$wal_level" == "logical" ]]; then
      record_check "PASS" "wal_level on Blue" "logical (required for logical replication)"
    elif [[ "$wal_level" == "PSQL_ERROR" || "$wal_level" == "PGPASSWORD_NOT_SET" || "$wal_level" == "NO_HOST" ]]; then
      record_check "WARN" "wal_level check" "$wal_level"
    else
      record_check "FAIL" "wal_level on Blue must be logical" "Current: $wal_level"
    fi

    # max_replication_slots
    local max_rep_slots
    max_rep_slots=$(psql_query "$blue_endpoint" "SHOW max_replication_slots;" 2>/dev/null | tr -d '[:space:]' || echo "PSQL_ERROR")
    info "    max_replication_slots: $max_rep_slots"
    record_check "INFO" "max_replication_slots on Blue" "$max_rep_slots"

    # max_wal_senders
    local max_wal_senders
    max_wal_senders=$(psql_query "$blue_endpoint" "SHOW max_wal_senders;" 2>/dev/null | tr -d '[:space:]' || echo "PSQL_ERROR")
    info "    max_wal_senders: $max_wal_senders"
    record_check "INFO" "max_wal_senders on Blue" "$max_wal_senders"
  fi

  # -------------------------------------------------------------------------
  # 1.4 Schema & Data Consistency
  # -------------------------------------------------------------------------
  print_subsection "1.4 Schema & Data Consistency (Blue vs Green)"

  local green_endpoint
  green_endpoint=$(get_endpoint "$GREEN_INSTANCE")
  info "  Green endpoint: $green_endpoint"

  if check_psql_prereqs && [[ -n "$blue_endpoint" ]] && [[ -n "$green_endpoint" ]]; then

    # Schema object counts
    declare -A count_queries=(
      ["tables"]="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_SCHEMA}' AND table_type='BASE TABLE';"
      ["columns"]="SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='${DB_SCHEMA}';"
      ["routines"]="SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema='${DB_SCHEMA}';"
      ["triggers"]="SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema='${DB_SCHEMA}';"
      ["indexes"]="SELECT COUNT(*) FROM pg_indexes WHERE schemaname='${DB_SCHEMA}';"
      ["sequences"]="SELECT COUNT(*) FROM information_schema.sequences WHERE sequence_schema='${DB_SCHEMA}';"
      ["views"]="SELECT COUNT(*) FROM information_schema.views WHERE table_schema='${DB_SCHEMA}';"
      ["extensions"]="SELECT COUNT(*) FROM pg_extension;"
    )

    for obj_type in tables columns routines triggers indexes sequences views extensions; do
      local query="${count_queries[$obj_type]}"
      local blue_count green_count
      blue_count=$(psql_query "$blue_endpoint" "$query" 2>/dev/null | tr -d '[:space:]' || echo "ERR")
      green_count=$(psql_query "$green_endpoint" "$query" 2>/dev/null | tr -d '[:space:]' || echo "ERR")

      if [[ "$blue_count" == "ERR" || "$blue_count" == "PSQL_ERROR" || "$green_count" == "ERR" || "$green_count" == "PSQL_ERROR" ]]; then
        record_check "WARN" "Schema count [$obj_type]" "Unable to query — Blue=$blue_count Green=$green_count"
      elif [[ "$blue_count" == "$green_count" ]]; then
        record_check "PASS" "Schema count [$obj_type]" "Blue=$blue_count Green=$green_count"
      else
        record_check "FAIL" "Schema count mismatch [$obj_type]" "Blue=$blue_count Green=$green_count"
      fi
    done

    # Per-table row comparison using n_live_tup
    print_subsection "1.4a Per-Table Row Counts (n_live_tup fast check)"
    local blue_tables
    blue_tables=$(psql_query_csv "$blue_endpoint" \
      "SELECT relname, n_live_tup FROM pg_stat_user_tables WHERE schemaname='${DB_SCHEMA}' ORDER BY relname;" \
      2>/dev/null || echo "PSQL_ERROR")

    local green_tables
    green_tables=$(psql_query_csv "$green_endpoint" \
      "SELECT relname, n_live_tup FROM pg_stat_user_tables WHERE schemaname='${DB_SCHEMA}' ORDER BY relname;" \
      2>/dev/null || echo "PSQL_ERROR")

    local mismatched_tables=()
    if [[ "$blue_tables" != "PSQL_ERROR" && "$green_tables" != "PSQL_ERROR" && \
          "$blue_tables" != "PGPASSWORD_NOT_SET" && "$green_tables" != "PGPASSWORD_NOT_SET" ]]; then

      while IFS=',' read -r tbl blue_count; do
        if [[ -z "$tbl" ]]; then continue; fi
        local g_count
        g_count=$(echo "$green_tables" | awk -F',' -v t="$tbl" '$1==t{print $2}' | head -1)
        g_count="${g_count:-0}"
        if [[ "$blue_count" != "$g_count" ]]; then
          mismatched_tables+=("$tbl:blue=$blue_count:green=$g_count")
        fi
      done <<< "$blue_tables"

      if (( ${#mismatched_tables[@]} == 0 )); then
        record_check "PASS" "n_live_tup row counts match across all tables" ""
      else
        record_check "WARN" "n_live_tup mismatch on ${#mismatched_tables[@]} table(s)" "Running exact COUNT(*) on mismatched tables"

        # Exact COUNT(*) for mismatched tables
        for entry in "${mismatched_tables[@]}"; do
          local tbl="${entry%%:*}"
          local exact_blue exact_green
          exact_blue=$(psql_query "$blue_endpoint" "SELECT COUNT(*) FROM \"${DB_SCHEMA}\".\"${tbl}\";" 2>/dev/null | tr -d '[:space:]' || echo "ERR")
          exact_green=$(psql_query "$green_endpoint" "SELECT COUNT(*) FROM \"${DB_SCHEMA}\".\"${tbl}\";" 2>/dev/null | tr -d '[:space:]' || echo "ERR")

          if [[ "$exact_blue" == "$exact_green" ]]; then
            record_check "PASS" "Table [$tbl] exact COUNT(*)" "Blue=$exact_blue Green=$exact_green (n_live_tup was stale)"
          else
            record_check "WARN" "Table [$tbl] COUNT(*) differs" "Blue=$exact_blue Green=$exact_green (replication may be lagging)"
          fi
        done
      fi
    else
      record_check "WARN" "Per-table row comparison skipped" "Query error"
    fi

    # Sequence current values comparison
    print_subsection "1.4b Sequence Value Drift Check"
    local blue_seqs
    blue_seqs=$(psql_query_csv "$blue_endpoint" \
      "SELECT sequence_schema, sequence_name, last_value FROM pg_sequences WHERE sequence_schema='${DB_SCHEMA}' ORDER BY sequence_name;" \
      2>/dev/null || echo "PSQL_ERROR")
    local green_seqs
    green_seqs=$(psql_query_csv "$green_endpoint" \
      "SELECT sequence_schema, sequence_name, last_value FROM pg_sequences WHERE sequence_schema='${DB_SCHEMA}' ORDER BY sequence_name;" \
      2>/dev/null || echo "PSQL_ERROR")

    if [[ "$blue_seqs" != "PSQL_ERROR" && "$green_seqs" != "PSQL_ERROR" && \
          "$blue_seqs" != "PGPASSWORD_NOT_SET" && "$green_seqs" != "PGPASSWORD_NOT_SET" ]]; then
      local seq_drift_count=0
      while IFS=',' read -r sch seq_name blue_last; do
        if [[ -z "$seq_name" ]]; then continue; fi
        local g_last
        g_last=$(echo "$green_seqs" | awk -F',' -v s="$seq_name" '$2==s{print $3}' | head -1)
        g_last="${g_last:-unknown}"
        if [[ "$blue_last" != "$g_last" ]]; then
          ((seq_drift_count++))
          record_check "WARN" "Sequence drift: $seq_name" "Blue last_value=$blue_last Green last_value=$g_last — post-switchover inserts may fail if Green is behind"
        fi
      done <<< "$blue_seqs"
      if (( seq_drift_count == 0 )); then
        record_check "PASS" "Sequence values match between Blue and Green" ""
      fi
    else
      record_check "WARN" "Sequence comparison skipped" "Query error"
    fi

    # REPLICA IDENTITY check
    print_subsection "1.4c REPLICA IDENTITY Check"
    local rep_identity
    rep_identity=$(psql_query_csv "$blue_endpoint" \
      "SELECT c.relname, c.relreplident
       FROM pg_class c
       JOIN pg_namespace n ON c.relnamespace = n.oid
       WHERE n.nspname = '${DB_SCHEMA}' AND c.relkind = 'r'
         AND c.relreplident = 'n'
       ORDER BY c.relname;" \
      2>/dev/null || echo "PSQL_ERROR")

    if [[ "$rep_identity" == "PSQL_ERROR" || "$rep_identity" == "PGPASSWORD_NOT_SET" ]]; then
      record_check "WARN" "REPLICA IDENTITY check skipped" "$rep_identity"
    elif [[ -z "$rep_identity" ]]; then
      record_check "PASS" "All tables have REPLICA IDENTITY set" ""
    else
      while IFS=',' read -r tbl_name rep_id; do
        [[ -z "$tbl_name" ]] && continue
        record_check "WARN" "Table $tbl_name has REPLICA IDENTITY NOTHING" "Deletes/updates won't replicate via logical replication"
      done <<< "$rep_identity"
    fi

    # Tables without primary keys
    print_subsection "1.4d Tables Without Primary Keys"
    local no_pk_tables
    no_pk_tables=$(psql_query_csv "$blue_endpoint" \
      "SELECT t.tablename
       FROM pg_tables t
       WHERE t.schemaname = '${DB_SCHEMA}'
         AND t.tablename NOT IN (
           SELECT tc.table_name
           FROM information_schema.table_constraints tc
           WHERE tc.constraint_type = 'PRIMARY KEY'
             AND tc.table_schema = '${DB_SCHEMA}'
         )
       ORDER BY t.tablename;" \
      2>/dev/null || echo "PSQL_ERROR")

    if [[ "$no_pk_tables" == "PSQL_ERROR" || "$no_pk_tables" == "PGPASSWORD_NOT_SET" ]]; then
      record_check "WARN" "Tables-without-PK check skipped" "$no_pk_tables"
    elif [[ -z "$no_pk_tables" ]]; then
      record_check "PASS" "All tables have primary keys" ""
    else
      local count
      count=$(echo "$no_pk_tables" | grep -c '[^[:space:]]' 2>/dev/null || echo "?")
      record_check "WARN" "$count table(s) lack primary keys" "Logical replication requires PK or REPLICA IDENTITY FULL for DML replication"
      echo "$no_pk_tables" | while IFS=',' read -r tbl; do
        [[ -n "$tbl" ]] && info "    No PK: $tbl"
      done
    fi

    # Unlogged tables
    print_subsection "1.4e Unlogged Tables"
    local unlogged_tables
    unlogged_tables=$(psql_query_csv "$blue_endpoint" \
      "SELECT n.nspname, c.relname
       FROM pg_class c
       JOIN pg_namespace n ON c.relnamespace = n.oid
       WHERE c.relpersistence = 'u' AND c.relkind = 'r'
         AND n.nspname = '${DB_SCHEMA}'
       ORDER BY c.relname;" \
      2>/dev/null || echo "PSQL_ERROR")

    if [[ "$unlogged_tables" == "PSQL_ERROR" || "$unlogged_tables" == "PGPASSWORD_NOT_SET" ]]; then
      record_check "WARN" "Unlogged tables check skipped" "$unlogged_tables"
    elif [[ -z "$unlogged_tables" ]]; then
      record_check "PASS" "No unlogged tables found" ""
    else
      local count
      count=$(echo "$unlogged_tables" | grep -c '[^[:space:]]' 2>/dev/null || echo "?")
      record_check "WARN" "$count unlogged table(s) found" "Unlogged tables are NOT replicated via logical replication — data may differ on Green"
      echo "$unlogged_tables" | while IFS=',' read -r sch tbl; do
        [[ -n "$tbl" ]] && info "    Unlogged: $sch.$tbl"
      done
    fi

    # Large objects
    print_subsection "1.4f Large Objects (pg_largeobject)"
    local lo_count
    lo_count=$(psql_query "$blue_endpoint" \
      "SELECT COUNT(DISTINCT loid) FROM pg_largeobject;" \
      2>/dev/null | tr -d '[:space:]' || echo "PSQL_ERROR")

    if [[ "$lo_count" == "PSQL_ERROR" || "$lo_count" == "PGPASSWORD_NOT_SET" ]]; then
      record_check "WARN" "Large objects check skipped" "$lo_count"
    elif [[ "$lo_count" == "0" ]]; then
      record_check "PASS" "No large objects found" ""
    else
      record_check "WARN" "$lo_count large object(s) in pg_largeobject" "Large objects are NOT replicated by logical replication — manual copy required"
    fi

    # DDL notice
    record_check "INFO" "DDL during replication window" "Any DDL run on Blue after Green replication started must be re-run manually on Green before switchover"

  else
    record_check "WARN" "Schema consistency checks skipped" "psql not available or endpoints missing"
  fi

  # -------------------------------------------------------------------------
  # 1.5 Parameter Groups
  # -------------------------------------------------------------------------
  print_subsection "1.5 Parameter Groups"

  for INST_LABEL in "Blue:$BLUE_INSTANCE" "Green:$GREEN_INSTANCE"; do
    local label="${INST_LABEL%%:*}"
    local inst_id="${INST_LABEL##*:}"
    local inst_json
    inst_json=$(get_instance_info "$inst_id")

    local pg_list
    pg_list=$(echo "$inst_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for pg in d.get('DBParameterGroups', []):
    status = pg.get('ParameterApplyStatus','')
    name = pg.get('DBParameterGroupName','')
    print(f'  {name}  apply_status={status}')
    if status == 'pending-reboot':
        print(f'  *** WARNING: pending-reboot detected on {name} — a reboot during switchover causes extra downtime ***')
" 2>/dev/null || echo "  (unable to read)")
    info "  $label parameter groups:"
    echo "$pg_list"
    log_to_file "$pg_list"

    local pending_reboot_count
    pending_reboot_count=$(echo "$pg_list" | grep -c "pending-reboot" 2>/dev/null || echo "0")
    if (( pending_reboot_count > 0 )); then
      record_check "WARN" "$label has parameter(s) with pending-reboot status" "Resolve before switchover to avoid unplanned reboot"
    else
      record_check "PASS" "$label parameter group status" "No pending-reboot"
    fi
  done

  # -------------------------------------------------------------------------
  # 1.6 Engine Versions
  # -------------------------------------------------------------------------
  print_subsection "1.6 Engine Versions"

  local blue_engine green_engine blue_version green_version
  local blue_json green_json
  blue_json=$(get_instance_info "$BLUE_INSTANCE")
  green_json=$(get_instance_info "$GREEN_INSTANCE")

  blue_engine=$(echo "$blue_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Engine','unknown'))" 2>/dev/null || echo "unknown")
  blue_version=$(echo "$blue_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('EngineVersion','unknown'))" 2>/dev/null || echo "unknown")
  green_engine=$(echo "$green_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Engine','unknown'))" 2>/dev/null || echo "unknown")
  green_version=$(echo "$green_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('EngineVersion','unknown'))" 2>/dev/null || echo "unknown")

  info "  Blue:  Engine=$blue_engine  Version=$blue_version"
  info "  Green: Engine=$green_engine  Version=$green_version"
  record_check "INFO" "Engine versions" "Blue=$blue_version Green=$green_version"

  if [[ "$blue_version" == "$green_version" ]]; then
    record_check "INFO" "Engine versions match" "(same version — not an upgrade deployment)"
  else
    record_check "INFO" "Engine versions differ" "Blue=$blue_version → Green=$green_version (version upgrade)"
  fi

  # -------------------------------------------------------------------------
  # 1.7 Instance Configuration Match
  # -------------------------------------------------------------------------
  print_subsection "1.7 Instance Configuration Match"

  python3 - <<PYEOF 2>/dev/null || true
import json, sys

blue_raw = """${blue_json}"""
green_raw = """${green_json}"""

try:
    blue = json.loads(blue_raw)
    green = json.loads(green_raw)
except:
    print("  ERROR: Could not parse instance JSON")
    sys.exit(0)

def compare(label, bval, gval, must_match=True, warn_only=False):
    match = str(bval) == str(gval)
    status = "PASS" if match else ("WARN" if warn_only else "FAIL")
    if not must_match:
        status = "INFO"
    print(f"  [{status}] {label}: Blue={bval}  Green={gval}")

compare("InstanceClass",    blue.get('DBInstanceClass','?'),    green.get('DBInstanceClass','?'))
compare("AllocatedStorage", blue.get('AllocatedStorage','?'),   green.get('AllocatedStorage','?'), warn_only=True)
compare("StorageType",      blue.get('StorageType','?'),        green.get('StorageType','?'))
compare("MultiAZ",          blue.get('MultiAZ','?'),            green.get('MultiAZ','?'), warn_only=True)
compare("Iops",             blue.get('Iops','?'),               green.get('Iops','?'), warn_only=True)

# Security groups
b_sgs = sorted([sg['VpcSecurityGroupId'] for sg in blue.get('VpcSecurityGroups',[])])
g_sgs = sorted([sg['VpcSecurityGroupId'] for sg in green.get('VpcSecurityGroups',[])])
compare("SecurityGroups", ','.join(b_sgs), ','.join(g_sgs), warn_only=True)

# Subnet group
compare("SubnetGroup",          blue.get('DBSubnetGroup',{}).get('DBSubnetGroupName','?'),
                                 green.get('DBSubnetGroup',{}).get('DBSubnetGroupName','?'), warn_only=True)

# DeletionProtection — must be ON for Green
g_dp = green.get('DeletionProtection', False)
status = "PASS" if g_dp else "WARN"
print(f"  [{status}] DeletionProtection on Green: {g_dp} (should be True for new primary)")

# BackupRetentionPeriod — must be > 0 on Green
g_brp = green.get('BackupRetentionPeriod', 0)
status = "PASS" if int(g_brp) > 0 else "FAIL"
print(f"  [{status}] BackupRetentionPeriod Green: {g_brp} (must be > 0)")

# AutoMinorVersionUpgrade
compare("AutoMinorVersionUpgrade", blue.get('AutoMinorVersionUpgrade','?'),
                                    green.get('AutoMinorVersionUpgrade','?'), warn_only=True)

# StorageEncrypted — must match
b_enc = blue.get('StorageEncrypted', False)
g_enc = green.get('StorageEncrypted', False)
status = "PASS" if b_enc == g_enc else "FAIL"
print(f"  [{status}] StorageEncrypted: Blue={b_enc} Green={g_enc}")

# CloudWatch logs exports
b_logs = sorted(blue.get('EnabledCloudwatchLogsExports', []))
g_logs = sorted(green.get('EnabledCloudwatchLogsExports', []))
compare("EnabledCloudwatchLogsExports", ','.join(b_logs) or '(none)', ','.join(g_logs) or '(none)', warn_only=True)
PYEOF

  # -------------------------------------------------------------------------
  # 1.8 CloudWatch Key Metrics (baseline)
  # -------------------------------------------------------------------------
  print_subsection "1.8 CloudWatch Key Metrics (15-min baseline)"

  for INST_LABEL in "Blue:$BLUE_INSTANCE" "Green:$GREEN_INSTANCE"; do
    local label="${INST_LABEL%%:*}"
    local inst_id="${INST_LABEL##*:}"
    info "  $label ($inst_id):"

    for metric in CPUUtilization FreeStorageSpace DatabaseConnections WriteIOPS ReadIOPS; do
      local avg
      avg=$(get_cloudwatch_stat "$inst_id" "$metric" "Average" 15)
      info "    $metric: avg=$avg"
      record_check "INFO" "$label $metric (15m avg)" "$avg"

      # Storage almost full check
      if [[ "$metric" == "FreeStorageSpace" && "$avg" != "N/A" && "$avg" != "None" ]]; then
        local inst_json_tmp
        inst_inst_json_tmp=$(get_instance_info "$inst_id")
        local alloc_gb
        alloc_gb=$(echo "$inst_inst_json_tmp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('AllocatedStorage',0))" 2>/dev/null || echo "0")
        local alloc_bytes=$(( alloc_gb * 1073741824 ))
        if (( alloc_bytes > 0 )); then
          local pct
          pct=$(python3 -c "print(round(float('$avg') / $alloc_bytes * 100, 1))" 2>/dev/null || echo "0")
          local pct_int
          pct_int=$(python3 -c "print(int(float('$avg') / $alloc_bytes * 100))" 2>/dev/null || echo "100")
          if (( pct_int < 10 )); then
            record_check "FAIL" "$label FreeStorageSpace < 10% of total" "${pct}% free — ${avg} bytes free of ${alloc_bytes}"
          elif (( pct_int < 20 )); then
            record_check "WARN" "$label FreeStorageSpace < 20% of total" "${pct}% free"
          fi
        fi
      fi
    done
  done

  # -------------------------------------------------------------------------
  # 1.9 Pre-Switchover Active Transaction Check
  # -------------------------------------------------------------------------
  print_subsection "1.9 Active Transactions on Blue (edge case)"

  if check_psql_prereqs && [[ -n "$blue_endpoint" ]]; then
    # Long-running transactions (> 5 minutes)
    local long_txns
    long_txns=$(psql_query "$blue_endpoint" \
      "SELECT pid, usename, state, query_start,
              EXTRACT(EPOCH FROM (now() - query_start))::int AS duration_secs,
              left(query, 100) AS query_snippet
       FROM pg_stat_activity
       WHERE state != 'idle'
         AND query_start < now() - interval '5 minutes'
         AND pid != pg_backend_pid()
       ORDER BY query_start;" \
      "--no-align --field-separator='|' -t" 2>/dev/null || echo "PSQL_ERROR")

    if [[ "$long_txns" == "PSQL_ERROR" || "$long_txns" == "PGPASSWORD_NOT_SET" ]]; then
      record_check "WARN" "Long-running transaction check skipped" "$long_txns"
    elif [[ -z "$long_txns" ]]; then
      record_check "PASS" "No long-running transactions on Blue" "(> 5 min)"
    else
      local count
      count=$(echo "$long_txns" | grep -c '[^[:space:]]' 2>/dev/null || echo "?")
      record_check "WARN" "$count long-running transaction(s) > 5 min on Blue" "Can block logical replication catchup"
      echo "$long_txns" | while IFS='|' read -r pid user state qstart dur qtext; do
        info "    pid=$pid user=$user state=$state duration=${dur}s query=${qtext}"
      done
    fi

    # Idle-in-transaction
    local idle_txns
    idle_txns=$(psql_query "$blue_endpoint" \
      "SELECT pid, usename, state, query_start,
              EXTRACT(EPOCH FROM (now() - query_start))::int AS duration_secs
       FROM pg_stat_activity
       WHERE state = 'idle in transaction'
         AND pid != pg_backend_pid()
       ORDER BY query_start;" \
      "--no-align --field-separator='|' -t" 2>/dev/null || echo "PSQL_ERROR")

    if [[ "$idle_txns" == "PSQL_ERROR" || "$idle_txns" == "PGPASSWORD_NOT_SET" ]]; then
      record_check "WARN" "Idle-in-transaction check skipped" "$idle_txns"
    elif [[ -z "$idle_txns" ]]; then
      record_check "PASS" "No idle-in-transaction sessions on Blue" ""
    else
      local count
      count=$(echo "$idle_txns" | grep -c '[^[:space:]]' 2>/dev/null || echo "?")
      record_check "WARN" "$count idle-in-transaction session(s) on Blue" "Can hold locks and block replication slot advancement"
      echo "$idle_txns" | while IFS='|' read -r pid user state qstart dur; do
        info "    pid=$pid user=$user duration=${dur}s"
      done
    fi
  else
    record_check "WARN" "Active transaction checks skipped" "psql not available"
  fi

  # -------------------------------------------------------------------------
  # 1.10 Pending Maintenance
  # -------------------------------------------------------------------------
  print_subsection "1.10 Pending Maintenance Actions"

  for INST_LABEL in "Blue:$BLUE_INSTANCE" "Green:$GREEN_INSTANCE"; do
    local label="${INST_LABEL%%:*}"
    local inst_id="${INST_LABEL##*:}"
    local maint_json
    maint_json=$(aws_cmd rds describe-pending-maintenance-actions \
      --filters "Name=db-instance-id,Values=$inst_id" \
      --query 'PendingMaintenanceActions' --output json 2>/dev/null || echo "[]")

    local maint_count
    maint_count=$(echo "$maint_json" | python3 -c "
import sys, json
actions = json.load(sys.stdin)
total = sum(len(r.get('PendingMaintenanceActionDetails',[])) for r in actions)
print(total)
" 2>/dev/null || echo "0")

    if [[ "$maint_count" == "0" ]]; then
      record_check "PASS" "$label pending maintenance" "None"
    else
      record_check "WARN" "$label has $maint_count pending maintenance action(s)" "Resolve before switchover"
      echo "$maint_json" | python3 -c "
import sys, json
actions = json.load(sys.stdin)
for r in actions:
    for a in r.get('PendingMaintenanceActionDetails',[]):
        print(f\"    {a.get('Action','?')}: AutoApplied={a.get('AutoAppliedAfterDate','N/A')} ForcedApplied={a.get('ForcedApplyDate','N/A')}\")
" 2>/dev/null || true
    fi
  done

  # -------------------------------------------------------------------------
  # Multi-AZ Failover Risk
  # -------------------------------------------------------------------------
  print_subsection "1.11 Multi-AZ Failover Risk"
  blue_json=$(get_instance_info "$BLUE_INSTANCE")
  local blue_multiaz
  blue_multiaz=$(echo "$blue_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('MultiAZ',False))" 2>/dev/null || echo "False")

  if [[ "$blue_multiaz" == "True" ]]; then
    record_check "WARN" "Blue is Multi-AZ" "A failover on Blue during switchover can disrupt logical replication — monitor closely"
  else
    record_check "PASS" "Blue Multi-AZ" "Not Multi-AZ (no failover risk)"
  fi

  # -------------------------------------------------------------------------
  # Certificate Expiry
  # -------------------------------------------------------------------------
  print_subsection "1.12 Certificate Expiry"

  for INST_LABEL in "Blue:$BLUE_INSTANCE" "Green:$GREEN_INSTANCE"; do
    local label="${INST_LABEL%%:*}"
    local inst_id="${INST_LABEL##*:}"
    local inst_j
    inst_j=$(get_instance_info "$inst_id")

    local cert_id valid_till
    cert_id=$(echo "$inst_j" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('CACertificateIdentifier','unknown'))" 2>/dev/null || echo "unknown")
    valid_till=$(echo "$inst_j" | python3 -c "
import sys, json
d = json.load(sys.stdin)
cd = d.get('CertificateDetails', {})
print(cd.get('ValidTill', ''))
" 2>/dev/null || echo "")

    info "  $label Certificate: $cert_id  ValidTill: ${valid_till:-not available}"

    if [[ -n "$valid_till" ]]; then
      local cert_epoch now_ep days_left
      cert_epoch=$(iso8601_to_epoch "$valid_till")
      now_ep=$(now_epoch)
      days_left=$(python3 -c "print(max(0, int(($cert_epoch - $now_ep) / 86400)))" 2>/dev/null || echo "0")
      if (( days_left < 30 )); then
        record_check "WARN" "$label certificate expires in $days_left days" "$cert_id valid till $valid_till"
      else
        record_check "PASS" "$label certificate valid" "$cert_id expires in $days_left days"
      fi
    else
      record_check "INFO" "$label certificate validity" "Could not determine expiry date"
    fi
  done

  # -------------------------------------------------------------------------
  # 1.10 (last) Pre-Switchover Rollback Prep
  # -------------------------------------------------------------------------
  print_subsection "1.13 Pre-Switchover Rollback Preparation"

  echo ""
  echo -e "${BOLD}================================================================${RESET}"
  echo -e "${BOLD}  ROLLBACK PROCEDURE (Promote Read Replica)${RESET}"
  echo -e "${BOLD}  Read and save this BEFORE initiating switchover${RESET}"
  echo -e "${BOLD}================================================================${RESET}"
  cat <<ROLLBACK
  If you need to roll back after switchover:

  Step 1 — Verify Blue is still a read replica and has low lag:
    aws rds describe-db-instances \\
      --db-instance-identifier ${BLUE_INSTANCE} \\
      --query 'DBInstances[0].ReadReplicaSourceDBInstanceIdentifier'

  Step 2 — Promote Blue (former primary) back to standalone:
    aws rds promote-read-replica \\
      --db-instance-identifier ${BLUE_INSTANCE} \\
      --region ${AWS_REGION}
    # Wait for status = available

  Step 3 — Update your application's DB endpoint to point back to Blue:
    Blue endpoint: $(get_endpoint "$BLUE_INSTANCE")

  Step 4 — Verify Blue accepts writes:
    psql -h $(get_endpoint "$BLUE_INSTANCE") -U ${DB_USER} -d ${DB_NAME} \\
      -c "SELECT pg_is_in_recovery();"
    # Must return 'f' (false)

  Step 5 — Monitor for data divergence (transactions committed to Green
           after switchover will NOT be on Blue — review application logs)

  WARNINGS:
  - Promotion is IRREVERSIBLE once complete
  - Any transactions committed to Green after switchover are LOST on Blue
  - Blue retention window: check deployment status for deletion deadline
  - Re-enabling Multi-AZ and backups on Blue must be done manually

  BLUE/GREEN DEPLOYMENT RETENTION:
  The Blue replica will be available for rollback until:
    - RDS auto-deletes it (check deployment status for timing)
    - You manually delete it
  Run --phase post to see remaining rollback window after switchover.
ROLLBACK

  echo -e "${BOLD}================================================================${RESET}"
  log_to_file "ROLLBACK PROCEDURE printed above"
  record_check "INFO" "Rollback procedure displayed" "Save the above before proceeding with switchover"
}

# ===========================================================================
# PHASE 2 — POST-SWITCHOVER
# ===========================================================================

phase2_post_switchover() {
  print_section "PHASE 2 — POST-SWITCHOVER CHECKS"

  local blue_json green_json
  blue_json=$(get_instance_info "$BLUE_INSTANCE")
  green_json=$(get_instance_info "$GREEN_INSTANCE")
  local blue_endpoint green_endpoint
  blue_endpoint=$(get_endpoint "$BLUE_INSTANCE")
  green_endpoint=$(get_endpoint "$GREEN_INSTANCE")

  # -------------------------------------------------------------------------
  # 2.1 Endpoint Resolution
  # -------------------------------------------------------------------------
  print_subsection "2.1 Endpoint Resolution"

  for INST_LABEL in "Blue:$BLUE_INSTANCE" "Green:$GREEN_INSTANCE"; do
    local label="${INST_LABEL%%:*}"
    local inst_id="${INST_LABEL##*:}"
    local inst_j
    if [[ "$inst_id" == "$BLUE_INSTANCE" ]]; then
      inst_j="$blue_json"
    else
      inst_j="$green_json"
    fi

    python3 - <<PYEOF 2>/dev/null || true
import json, sys
d = json.loads("""$inst_j""")
ep = d.get('Endpoint', {})
print(f"  $label ($inst_id):")
print(f"    Engine:             {d.get('Engine','?')} {d.get('EngineVersion','?')}")
print(f"    Endpoint:           {ep.get('Address','N/A')}:{ep.get('Port','N/A')}")
print(f"    ReplicaSource:      {d.get('ReadReplicaSourceDBInstanceIdentifier','(none — primary)')}")
print(f"    ReadReplicas:       {', '.join(d.get('ReadReplicaDBInstanceIdentifiers',[]) or ['(none)'])}")
PYEOF
  done

  # -------------------------------------------------------------------------
  # 2.2 Instance Status
  # -------------------------------------------------------------------------
  print_subsection "2.2 Instance Status Post-Switchover"

  for INST_LABEL in "Blue:$BLUE_INSTANCE" "Green:$GREEN_INSTANCE"; do
    local label="${INST_LABEL%%:*}"
    local inst_id="${INST_LABEL##*:}"
    local inst_j
    if [[ "$inst_id" == "$BLUE_INSTANCE" ]]; then inst_j="$blue_json"; else inst_j="$green_json"; fi

    local st
    st=$(echo "$inst_j" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('DBInstanceStatus','unknown'))" 2>/dev/null || echo "unknown")
    if [[ "$st" == "available" ]]; then
      record_check "PASS" "$label instance status" "$inst_id = $st"
    else
      record_check "FAIL" "$label instance not available" "$inst_id = $st"
    fi
  done

  # -------------------------------------------------------------------------
  # 2.3 Former Blue is Now a Read Replica
  # -------------------------------------------------------------------------
  print_subsection "2.3 Former Blue is Now a Read Replica"

  local blue_replica_source
  blue_replica_source=$(echo "$blue_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('ReadReplicaSourceDBInstanceIdentifier',''))
" 2>/dev/null || echo "")

  if [[ -n "$blue_replica_source" ]]; then
    record_check "PASS" "Former Blue is a read replica" "ReplicaSourceDBInstanceIdentifier=$blue_replica_source"
  else
    record_check "FAIL" "Former Blue does NOT have ReadReplicaSourceDBInstanceIdentifier set" "Expected post-switchover"
  fi

  # Cross-check via pg_stat_replication on new primary (Green)
  if check_psql_prereqs && [[ -n "$green_endpoint" ]]; then
    local rep_stat
    rep_stat=$(psql_query "$green_endpoint" \
      "SELECT application_name, state, sent_lsn, replay_lsn,
              (sent_lsn - replay_lsn) AS lag_bytes
       FROM pg_stat_replication;" \
      "--no-align --field-separator='|' -t" 2>/dev/null || echo "PSQL_ERROR")

    if [[ "$rep_stat" == "PSQL_ERROR" || "$rep_stat" == "PGPASSWORD_NOT_SET" ]]; then
      record_check "WARN" "pg_stat_replication on new primary" "$rep_stat"
    elif [[ -z "$rep_stat" ]]; then
      record_check "WARN" "No connected standbys in pg_stat_replication on new primary" "Blue may not have reconnected yet"
    else
      local streaming_count
      streaming_count=$(echo "$rep_stat" | grep -c "streaming" 2>/dev/null || echo "0")
      if (( streaming_count > 0 )); then
        record_check "PASS" "Former Blue appears in pg_stat_replication on new primary" "$streaming_count streaming connection(s)"
      else
        record_check "WARN" "No streaming connections from pg_stat_replication on new primary" "Blue may not be replicating yet"
      fi
      echo "$rep_stat" | while IFS='|' read -r app_name state sent_lsn replay_lsn lag_bytes; do
        info "    app=$app_name state=$state lag_bytes=${lag_bytes}"
      done
    fi
  fi

  # -------------------------------------------------------------------------
  # 2.4 Blue Replication Lag (rollback lifeline)
  # -------------------------------------------------------------------------
  print_subsection "2.4 Blue Replication Lag (Rollback Lifeline)"

  local blue_lag_avg blue_lag_max
  blue_lag_avg=$(get_cloudwatch_stat "$BLUE_INSTANCE" "ReplicaLag" "Average" 15)
  blue_lag_max=$(get_cloudwatch_stat "$BLUE_INSTANCE" "ReplicaLag" "Maximum" 15)

  info "  Blue ReplicaLag: Avg=${blue_lag_avg}s  Max=${blue_lag_max}s"

  if [[ "$blue_lag_avg" != "N/A" && "$blue_lag_avg" != "None" ]]; then
    local lag_int
    lag_int=$(python3 -c "print(int(float('$blue_lag_avg')))" 2>/dev/null || echo "999")
    local rollback_lag_threshold=$(( LAG_THRESHOLD * 3 ))
    if (( lag_int <= rollback_lag_threshold )); then
      record_check "PASS" "Blue ReplicaLag for rollback" "Avg=${blue_lag_avg}s ≤ 3x threshold ${rollback_lag_threshold}s"
    else
      record_check "WARN" "Blue ReplicaLag HIGH" "Avg=${blue_lag_avg}s — rolling back would miss transactions. Max=${blue_lag_max}s"
    fi
  else
    record_check "WARN" "Blue ReplicaLag" "No CloudWatch data available"
  fi

  # pg_stat_replication replay_lag on new primary for Blue
  if check_psql_prereqs && [[ -n "$green_endpoint" ]]; then
    local replay_lag
    replay_lag=$(psql_query "$green_endpoint" \
      "SELECT application_name, state, write_lag, flush_lag, replay_lag
       FROM pg_stat_replication;" \
      "--no-align --field-separator='|' -t" 2>/dev/null || echo "PSQL_ERROR")

    if [[ "$replay_lag" != "PSQL_ERROR" && "$replay_lag" != "PGPASSWORD_NOT_SET" && -n "$replay_lag" ]]; then
      info "  pg_stat_replication lag details on new primary:"
      echo "$replay_lag" | while IFS='|' read -r app state wl fl rl; do
        info "    app=$app state=$state write_lag=$wl flush_lag=$fl replay_lag=$rl"
      done
    fi
  fi

  # -------------------------------------------------------------------------
  # 2.5 Engine Version & Parameter Group on New Primary
  # -------------------------------------------------------------------------
  print_subsection "2.5 Engine Version & Parameter Group on New Primary (Green)"

  local green_version
  green_version=$(echo "$green_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('EngineVersion','unknown'))" 2>/dev/null || echo "unknown")
  record_check "INFO" "New primary engine version" "$green_version"

  # Parameter group apply status
  local pg_status_issues
  pg_status_issues=$(echo "$green_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
issues = 0
for pg in d.get('DBParameterGroups', []):
    status = pg.get('ParameterApplyStatus','')
    name = pg.get('DBParameterGroupName','')
    print(f'  {name}: apply_status={status}')
    if status not in ('in-sync', ''):
        issues += 1
        if status == 'pending-reboot':
            print(f'  *** WARNING: {name} has pending-reboot — reboot required to apply ***')
print(f'ISSUES:{issues}')
" 2>/dev/null || echo "ISSUES:0")

  echo "$pg_status_issues" | grep -v "^ISSUES:" | while read -r line; do info "  $line"; done
  local issues_count
  issues_count=$(echo "$pg_status_issues" | grep "^ISSUES:" | cut -d: -f2 | tr -d '[:space:]' || echo "0")
  if [[ "$issues_count" == "0" ]]; then
    record_check "PASS" "New primary parameter groups" "All in-sync"
  else
    record_check "WARN" "New primary parameter group(s) not in-sync" "$issues_count group(s) need attention"
  fi

  # -------------------------------------------------------------------------
  # 2.6 Connectivity & Write Tests
  # -------------------------------------------------------------------------
  print_subsection "2.6 Connectivity & Write Tests"

  if check_psql_prereqs; then
    # SELECT version() on new primary
    local pg_version
    pg_version=$(psql_query "$green_endpoint" "SELECT version();" 2>/dev/null | tr -d '\n' || echo "PSQL_ERROR")
    if [[ "$pg_version" == "PSQL_ERROR" || "$pg_version" == "PGPASSWORD_NOT_SET" || "$pg_version" == "NO_HOST" ]]; then
      record_check "FAIL" "Cannot connect to new primary (Green)" "$pg_version"
    else
      record_check "PASS" "New primary connectivity" "${pg_version:0:80}"
    fi

    # pg_is_in_recovery() on new primary — must be FALSE
    local recovery_green
    recovery_green=$(psql_query "$green_endpoint" "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d '[:space:]' || echo "PSQL_ERROR")
    if [[ "$recovery_green" == "f" ]]; then
      record_check "PASS" "New primary pg_is_in_recovery()" "false — confirmed primary mode"
    elif [[ "$recovery_green" == "t" ]]; then
      record_check "FAIL" "New primary is in recovery mode" "pg_is_in_recovery()=true — should be false on primary"
    else
      record_check "WARN" "pg_is_in_recovery() on new primary" "$recovery_green"
    fi

    # pg_is_in_recovery() on former Blue — must be TRUE
    local recovery_blue
    recovery_blue=$(psql_query "$blue_endpoint" "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d '[:space:]' || echo "PSQL_ERROR")
    if [[ "$recovery_blue" == "t" ]]; then
      record_check "PASS" "Former Blue pg_is_in_recovery()" "true — confirmed replica mode"
    elif [[ "$recovery_blue" == "f" ]]; then
      record_check "FAIL" "Former Blue is NOT in recovery mode" "pg_is_in_recovery()=false — unexpected"
    else
      record_check "WARN" "pg_is_in_recovery() on former Blue" "$recovery_blue"
    fi

    # Temp table write test on new primary
    local write_test
    write_test=$(psql_query "$green_endpoint" \
      "BEGIN; CREATE TEMP TABLE _bg_validate_test (id INT, val TEXT); INSERT INTO _bg_validate_test VALUES (1,'ok'); SELECT val FROM _bg_validate_test WHERE id=1; ROLLBACK;" \
      "-t -A" 2>/dev/null || echo "PSQL_ERROR")

    if echo "$write_test" | grep -q "^ok$"; then
      record_check "PASS" "Write test on new primary" "Temp table create/insert/select/rollback succeeded"
    else
      record_check "FAIL" "Write test on new primary failed" "$write_test"
    fi

    # transaction_read_only on former Blue — must be ON
    local read_only_blue
    read_only_blue=$(psql_query "$blue_endpoint" "SHOW transaction_read_only;" 2>/dev/null | tr -d '[:space:]' || echo "PSQL_ERROR")
    if [[ "$read_only_blue" == "on" ]]; then
      record_check "PASS" "Former Blue transaction_read_only" "on — read-only as expected"
    elif [[ "$read_only_blue" == "PSQL_ERROR" || "$read_only_blue" == "PGPASSWORD_NOT_SET" ]]; then
      record_check "WARN" "Former Blue read-only check" "$read_only_blue"
    else
      record_check "WARN" "Former Blue transaction_read_only" "$read_only_blue (expected 'on')"
    fi

    # Write attempt on former Blue — must be rejected
    local write_attempt
    write_attempt=$(PGCONNECT_TIMEOUT=10 PGPASSWORD="${PGPASSWORD:-}" psql \
      -h "$blue_endpoint" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
      -t -A -c "CREATE TABLE _bg_test_write (id int); DROP TABLE IF EXISTS _bg_test_write;" \
      2>&1 || true)

    if echo "$write_attempt" | grep -qi "read-only\|cannot execute\|not allowed\|recovery"; then
      record_check "PASS" "Write rejected on former Blue" "Read-only enforcement confirmed"
    elif [[ -z "${PGPASSWORD:-}" ]]; then
      record_check "WARN" "Write rejection test skipped" "PGPASSWORD not set"
    else
      record_check "WARN" "Write test on former Blue — unexpected result" "${write_attempt:0:120}"
    fi

    # Sequence usability on new primary
    print_subsection "2.6a Sequence Test on New Primary"
    local first_seq
    first_seq=$(psql_query "$green_endpoint" \
      "SELECT sequence_schema || '.' || sequence_name FROM information_schema.sequences WHERE sequence_schema='${DB_SCHEMA}' LIMIT 1;" \
      2>/dev/null | tr -d '[:space:]' || echo "")

    if [[ -n "$first_seq" && "$first_seq" != "PSQL_ERROR" && "$first_seq" != "PGPASSWORD_NOT_SET" ]]; then
      local nextval_result
      nextval_result=$(psql_query "$green_endpoint" "SELECT nextval('${first_seq}');" 2>/dev/null | tr -d '[:space:]' || echo "PSQL_ERROR")
      if [[ "$nextval_result" =~ ^[0-9]+$ ]]; then
        record_check "PASS" "Sequence NEXTVAL on new primary" "Sequence $first_seq → $nextval_result"
      else
        record_check "WARN" "Sequence NEXTVAL test" "$nextval_result"
      fi
    else
      record_check "INFO" "No sequences found in schema $DB_SCHEMA" "Sequence test skipped"
    fi

  else
    record_check "WARN" "Connectivity & write tests skipped" "psql not available or PGPASSWORD not set"
  fi

  # -------------------------------------------------------------------------
  # 2.7 Blue Replica Retention Window
  # -------------------------------------------------------------------------
  print_subsection "2.7 Blue Replica Retention Window (Rollback Deadline)"

  local bg_json_post
  bg_json_post=$(aws_cmd rds describe-blue-green-deployments \
    --blue-green-deployment-identifier "$DEPLOYMENT_ID" \
    --query 'BlueGreenDeployments[0]' --output json 2>/dev/null) || bg_json_post="{}"

  local bg_status_post
  bg_status_post=$(echo "$bg_json_post" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Status','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
  info "  Deployment status: $bg_status_post"

  # Check switchover complete time and compute rollback window
  python3 - <<PYEOF 2>/dev/null || true
import json, sys, time

bg_raw = """$bg_json_post"""
try:
    d = json.loads(bg_raw)
except:
    print("  Unable to parse deployment JSON")
    sys.exit(0)

sw_details = d.get('SwitchoverDetails', [])
if sw_details:
    for s in sw_details:
        sc_time = s.get('SwitchoverCompleteTime', '')
        status = s.get('SwitchoverStatus', '')
        print(f"  SwitchoverStatus: {status}  CompletedAt: {sc_time}")
else:
    print("  SwitchoverDetails not yet populated")

# Display any deletion/retention info
delete_on_switchover = d.get('DeleteBlueInstancesOnSwitchover', False)
print(f"  DeleteBlueInstancesOnSwitchover: {delete_on_switchover}")
if delete_on_switchover:
    print("  WARNING: Blue will be DELETED automatically on switchover — no rollback window!")
else:
    print("  Blue instance will be RETAINED post-switchover (rollback possible until manually deleted)")
PYEOF

  record_check "INFO" "Blue replica retention" "Check deployment status — retention window starts at switchover completion"

  # Warn if < 30 minutes of rollback time (approximate)
  # Note: RDS doesn't expose a hard deadline — we note this to the operator
  record_check "INFO" "Rollback deadline" "Periodically run: aws rds describe-blue-green-deployments --blue-green-deployment-identifier $DEPLOYMENT_ID to monitor status"

  # -------------------------------------------------------------------------
  # 2.8 CloudWatch Alarms
  # -------------------------------------------------------------------------
  print_subsection "2.8 CloudWatch Alarms in ALARM State"

  for INST_LABEL in "Blue:$BLUE_INSTANCE" "Green:$GREEN_INSTANCE"; do
    local label="${INST_LABEL%%:*}"
    local inst_id="${INST_LABEL##*:}"

    local alarms_json
    alarms_json=$(aws_cmd cloudwatch describe-alarms \
      --alarm-name-prefix "$inst_id" \
      --state-value ALARM \
      --query 'MetricAlarms[*].{Name:AlarmName,State:StateValue,Reason:StateReason}' \
      --output json 2>/dev/null) || alarms_json="[]"

    local alarm_count
    alarm_count=$(echo "$alarms_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    if [[ "$alarm_count" == "0" ]]; then
      record_check "PASS" "$label CloudWatch alarms" "No alarms in ALARM state"
    else
      record_check "WARN" "$label has $alarm_count CloudWatch alarm(s) in ALARM state" "Investigate immediately"
      echo "$alarms_json" | python3 -c "
import sys, json
for a in json.load(sys.stdin):
    print(f\"    ALARM: {a['Name']} — {a['Reason'][:100]}\")
" 2>/dev/null || true
    fi
  done

  # -------------------------------------------------------------------------
  # 2.9 Connection Count Normalization
  # -------------------------------------------------------------------------
  print_subsection "2.9 Connection Count Normalization on New Primary"

  local conn_avg
  conn_avg=$(get_cloudwatch_stat "$GREEN_INSTANCE" "DatabaseConnections" "Average" 5)
  info "  New primary DatabaseConnections (5m avg): $conn_avg"

  if check_psql_prereqs && [[ -n "$green_endpoint" ]]; then
    local max_conn
    max_conn=$(psql_query "$green_endpoint" "SHOW max_connections;" 2>/dev/null | tr -d '[:space:]' || echo "PSQL_ERROR")

    if [[ "$max_conn" =~ ^[0-9]+$ ]]; then
      record_check "INFO" "New primary max_connections" "$max_conn"
      if [[ "$conn_avg" != "N/A" && "$conn_avg" != "None" ]]; then
        local conn_pct
        conn_pct=$(python3 -c "print(round(float('$conn_avg') / $max_conn * 100, 1))" 2>/dev/null || echo "0")
        local conn_pct_int
        conn_pct_int=$(python3 -c "print(int(float('$conn_avg') / $max_conn * 100))" 2>/dev/null || echo "0")
        if (( conn_pct_int > 80 )); then
          record_check "WARN" "Connection utilization high on new primary" "${conn_pct}% of max_connections ($conn_avg / $max_conn)"
        else
          record_check "PASS" "Connection utilization normal" "${conn_pct}% of max_connections ($conn_avg / $max_conn)"
        fi
      fi
    else
      record_check "WARN" "max_connections query" "$max_conn"
    fi

    # Verify max_connections matches Blue's original
    local blue_max_conn
    blue_max_conn=$(psql_query "$blue_endpoint" "SHOW max_connections;" 2>/dev/null | tr -d '[:space:]' || echo "PSQL_ERROR")
    if [[ "$max_conn" =~ ^[0-9]+$ && "$blue_max_conn" =~ ^[0-9]+$ ]]; then
      if [[ "$max_conn" == "$blue_max_conn" ]]; then
        record_check "PASS" "max_connections matches Blue" "Both: $max_conn"
      else
        record_check "WARN" "max_connections differs" "Blue=$blue_max_conn New_Primary(Green)=$max_conn"
      fi
    fi

    # Sequence exhaustion check on new primary
    print_subsection "2.9a Sequence Exhaustion Check on New Primary"
    local seq_exhaustion
    seq_exhaustion=$(psql_query_csv "$green_endpoint" \
      "SELECT sequence_schema, sequence_name, last_value, maximum_value,
              ROUND(last_value::numeric / NULLIF(maximum_value,0) * 100, 2) AS pct_used
       FROM pg_sequences
       WHERE sequence_schema = '${DB_SCHEMA}'
         AND maximum_value > 0
         AND ROUND(last_value::numeric / maximum_value * 100, 2) > 80
       ORDER BY pct_used DESC;" \
      2>/dev/null || echo "PSQL_ERROR")

    if [[ "$seq_exhaustion" == "PSQL_ERROR" || "$seq_exhaustion" == "PGPASSWORD_NOT_SET" ]]; then
      record_check "WARN" "Sequence exhaustion check skipped" "$seq_exhaustion"
    elif [[ -z "$seq_exhaustion" ]]; then
      record_check "PASS" "No sequences near exhaustion (< 80% used)" ""
    else
      while IFS=',' read -r sch seq_name last_val max_val pct_used; do
        [[ -z "$seq_name" ]] && continue
        record_check "WARN" "Sequence $seq_name near exhaustion" "${pct_used}% used (last_value=$last_val max=$max_val)"
      done <<< "$seq_exhaustion"
    fi
  fi

  # -------------------------------------------------------------------------
  # 2.10 Deployment Final State
  # -------------------------------------------------------------------------
  print_subsection "2.10 Deployment Final State"

  local final_status
  final_status=$(echo "$bg_json_post" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Status','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
  info "  Deployment final status: $final_status"
  record_check "INFO" "Deployment final status" "$final_status"

  # SwitchoverDetails
  python3 - <<PYEOF 2>/dev/null || true
import json
d = json.loads("""$bg_json_post""")
for s in d.get('SwitchoverDetails', []):
    print(f"  {s.get('SourceMember','?')} → {s.get('TargetMember','?')}: {s.get('SwitchoverStatus','?')}")
PYEOF

  # -------------------------------------------------------------------------
  # 2.11 Rollback Readiness
  # -------------------------------------------------------------------------
  print_subsection "2.11 Rollback Readiness Summary"

  local blue_st
  blue_st=$(echo "$blue_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('DBInstanceStatus','unknown'))" 2>/dev/null || echo "unknown")
  local blue_lag_final
  blue_lag_final=$(get_cloudwatch_stat "$BLUE_INSTANCE" "ReplicaLag" "Average" 5)

  if [[ "$blue_st" == "available" ]]; then
    record_check "PASS" "Former Blue is available for rollback" "Status: $blue_st"
  else
    record_check "WARN" "Former Blue status for rollback" "$blue_st"
  fi

  info "  Blue lag: ${blue_lag_final}s  Threshold: ${LAG_THRESHOLD}s"
  if [[ "$blue_lag_final" != "N/A" && "$blue_lag_final" != "None" ]]; then
    local lag_int
    lag_int=$(python3 -c "print(int(float('$blue_lag_final')))" 2>/dev/null || echo "999")
    if (( lag_int <= LAG_THRESHOLD )); then
      record_check "PASS" "Former Blue lag acceptable for rollback" "${blue_lag_final}s"
    else
      record_check "WARN" "Former Blue lag is HIGH — rollback would miss transactions" "${blue_lag_final}s > ${LAG_THRESHOLD}s"
    fi
  fi

  echo ""
  echo -e "${BOLD}================================================================${RESET}"
  echo -e "${BOLD}  ROLLBACK PROCEDURE (Post-Switchover)${RESET}"
  echo -e "${BOLD}================================================================${RESET}"
  cat <<ROLLBACK2

  ROLLBACK STEPS — run these if you need to revert:

  1. Promote former Blue back to standalone:
     aws rds promote-read-replica \\
       --db-instance-identifier ${BLUE_INSTANCE} \\
       --region ${AWS_REGION}

  2. Wait for status = available:
     aws rds wait db-instance-available \\
       --db-instance-identifier ${BLUE_INSTANCE} \\
       --region ${AWS_REGION}

  3. Update application connection strings back to:
     Endpoint: ${blue_endpoint}

  4. Verify writes work on former Blue (pg_is_in_recovery() = 'f')

  5. Optionally delete the Green instance once rollback confirmed:
     aws rds delete-db-instance \\
       --db-instance-identifier ${GREEN_INSTANCE} \\
       --skip-final-snapshot \\
       --region ${AWS_REGION}

  *** WARNING: Promotion is IRREVERSIBLE — transactions on Green after
      switchover will be LOST. Analyze application logs for gap. ***

ROLLBACK2
  echo -e "${BOLD}================================================================${RESET}"
}

# ===========================================================================
# PHASE 3 — POST-SWITCHOVER MONITORING
# ===========================================================================

phase3_monitoring() {
  print_section "PHASE 3 — POST-SWITCHOVER MONITORING"

  info "  Duration: ${MONITOR_DURATION}s  Interval: ${MONITOR_INTERVAL}s"
  info "  Lag threshold: ${LAG_THRESHOLD}s  Connection alert: ${CONN_THRESHOLD}"
  info "  Monitoring new primary: $GREEN_INSTANCE"
  info "  Monitoring former Blue: $BLUE_INSTANCE"
  echo ""

  # Table header
  local header
  header=$(printf "%-20s %-12s %-12s %-14s %-14s %-18s %-30s" \
    "TIMESTAMP" "BLUE_STATUS" "GREEN_STATUS" "BLUE_LAG(s)" "GREEN_CPU%" "GREEN_CONNS" "ALERTS")
  echo -e "${BOLD}${header}${RESET}"
  echo "$(printf '%0.s-' {1..110})"
  log_to_file "$header"

  local start_epoch
  start_epoch=$(now_epoch)
  local end_epoch=$(( start_epoch + MONITOR_DURATION ))
  local iteration=0
  local phase3_alerts=0

  while true; do
    local current_epoch
    current_epoch=$(now_epoch)
    if (( current_epoch >= end_epoch )); then
      break
    fi

    ((iteration++))
    local ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")

    # Instance statuses
    local blue_status green_status
    blue_status=$(aws_cmd rds describe-db-instances \
      --db-instance-identifier "$BLUE_INSTANCE" \
      --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "unknown")
    green_status=$(aws_cmd rds describe-db-instances \
      --db-instance-identifier "$GREEN_INSTANCE" \
      --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "unknown")

    # Metrics (last interval window)
    local period_m=$(( (MONITOR_INTERVAL + 59) / 60 ))
    [[ $period_m -lt 1 ]] && period_m=1
    local blue_lag_m green_cpu_m green_conn_m
    blue_lag_m=$(get_cloudwatch_stat "$BLUE_INSTANCE" "ReplicaLag" "Average" "$period_m")
    green_cpu_m=$(get_cloudwatch_stat "$GREEN_INSTANCE" "CPUUtilization" "Average" "$period_m")
    green_conn_m=$(get_cloudwatch_stat "$GREEN_INSTANCE" "DatabaseConnections" "Average" "$period_m")

    # Storage check
    local green_storage
    green_storage=$(get_cloudwatch_stat "$GREEN_INSTANCE" "FreeStorageSpace" "Average" "$period_m")

    # Alert logic
    local alerts_this_tick=()
    local row_color="$RESET"

    # New primary not available
    if [[ "$green_status" != "available" ]]; then
      alerts_this_tick+=("NEW_PRIMARY_DOWN")
      row_color="$RED"
      ((phase3_alerts++))
      ((alert_count++))
    fi

    # Blue lag > 3x threshold
    if [[ "$blue_lag_m" != "N/A" && "$blue_lag_m" != "None" ]]; then
      local lag_v
      lag_v=$(python3 -c "print(int(float('$blue_lag_m')))" 2>/dev/null || echo "0")
      local high_lag_thresh=$(( LAG_THRESHOLD * 3 ))
      if (( lag_v > high_lag_thresh )); then
        alerts_this_tick+=("HIGH_BLUE_LAG")
        row_color="$YELLOW"
        ((phase3_alerts++))
        ((alert_count++))
      fi
    fi

    # Green CPU > 85%
    if [[ "$green_cpu_m" != "N/A" && "$green_cpu_m" != "None" ]]; then
      local cpu_v
      cpu_v=$(python3 -c "print(int(float('$green_cpu_m')))" 2>/dev/null || echo "0")
      if (( cpu_v > 85 )); then
        alerts_this_tick+=("HIGH_CPU")
        [[ "$row_color" == "$RESET" ]] && row_color="$YELLOW"
        ((phase3_alerts++))
        ((alert_count++))
      fi
    fi

    # Green connections > threshold
    if [[ "$green_conn_m" != "N/A" && "$green_conn_m" != "None" ]]; then
      local conn_v
      conn_v=$(python3 -c "print(int(float('$green_conn_m')))" 2>/dev/null || echo "0")
      if (( conn_v > CONN_THRESHOLD )); then
        alerts_this_tick+=("HIGH_CONNECTIONS")
        [[ "$row_color" == "$RESET" ]] && row_color="$YELLOW"
        ((phase3_alerts++))
        ((alert_count++))
      fi
    fi

    # Storage check
    if [[ "$green_storage" != "N/A" && "$green_storage" != "None" ]]; then
      local green_alloc_gb
      green_alloc_gb=$(aws_cmd rds describe-db-instances \
        --db-instance-identifier "$GREEN_INSTANCE" \
        --query 'DBInstances[0].AllocatedStorage' --output text 2>/dev/null || echo "0")
      if [[ "$green_alloc_gb" =~ ^[0-9]+$ ]] && (( green_alloc_gb > 0 )); then
        local alloc_bytes_g=$(( green_alloc_gb * 1073741824 ))
        local pct_free_int
        pct_free_int=$(python3 -c "print(int(float('$green_storage') / $alloc_bytes_g * 100))" 2>/dev/null || echo "100")
        if (( pct_free_int < 10 )); then
          alerts_this_tick+=("LOW_STORAGE")
          row_color="$RED"
          ((phase3_alerts++))
          ((alert_count++))
        fi
      fi
    fi

    local alert_str
    if (( ${#alerts_this_tick[@]} > 0 )); then
      alert_str=$(IFS=','; echo "${alerts_this_tick[*]}")
    else
      alert_str="OK"
    fi

    local row
    row=$(printf "%-20s %-12s %-12s %-14s %-14s %-18s %-30s" \
      "$ts" \
      "${blue_status:0:12}" \
      "${green_status:0:12}" \
      "${blue_lag_m}" \
      "${green_cpu_m}" \
      "${green_conn_m}" \
      "$alert_str")

    echo -e "${row_color}${row}${RESET}"
    log_to_file "$row"

    # Wait for next interval
    local elapsed=$(( $(now_epoch) - current_epoch ))
    local sleep_time=$(( MONITOR_INTERVAL - elapsed ))
    if (( sleep_time > 0 )); then
      sleep "$sleep_time"
    fi
  done

  echo ""
  echo "$(printf '%0.s-' {1..110})"
  echo ""
  if (( phase3_alerts > 0 )); then
    record_check "FAIL" "Phase 3 monitoring" "$phase3_alerts alert(s) fired during monitoring"
  else
    record_check "PASS" "Phase 3 monitoring" "No alerts fired during ${MONITOR_DURATION}s monitoring window"
  fi
}

# ===========================================================================
# SUMMARY REPORT
# ===========================================================================

print_summary() {
  local total=$(( pass_count + fail_count + warn_count ))
  echo ""
  print_section "VALIDATION SUMMARY"
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
  echo -e "${CYAN}  JSON:   $REPORT_JSON${RESET}"
  echo ""

  log_to_file ""
  log_to_file "SUMMARY: PASS=$pass_count FAIL=$fail_count WARN=$warn_count INFO=$info_count"

  # Write JSON summary
  python3 - <<PYEOF > "$REPORT_JSON" 2>/dev/null || true
import json, datetime
summary = {
    "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
    "phase": "$PHASE",
    "blue_instance": "$BLUE_INSTANCE",
    "green_instance": "$GREEN_INSTANCE",
    "deployment_id": "$DEPLOYMENT_ID",
    "region": "$AWS_REGION",
    "counts": {
        "pass": $pass_count,
        "fail": $fail_count,
        "warn": $warn_count,
        "info": $info_count,
        "alerts": $alert_count
    },
    "result": "FAIL" if $fail_count > 0 else ("WARN" if $warn_count > 0 else "PASS"),
    "report_txt": "$REPORT_TXT",
    "lag_threshold_secs": $LAG_THRESHOLD,
    "monitor_duration_secs": $MONITOR_DURATION,
    "monitor_interval_secs": $MONITOR_INTERVAL
}
print(json.dumps(summary, indent=2))
PYEOF

  info "  JSON summary written to $REPORT_JSON"
}

# ===========================================================================
# MAIN ENTRY POINT
# ===========================================================================

main() {
  print_header

  case "$PHASE" in
    pre)
      phase1_pre_switchover
      ;;
    post)
      phase2_post_switchover
      ;;
    monitor)
      phase3_monitoring
      ;;
    "post+monitor")
      phase2_post_switchover
      phase3_monitoring
      ;;
    all)
      phase1_pre_switchover
      echo ""
      print_section "PRE-SWITCHOVER CHECKS COMPLETE"
      echo ""
      echo -e "${BOLD_BLUE}================================================================${RESET}"
      echo -e "${BOLD_BLUE}  NEXT STEPS${RESET}"
      echo -e "${BOLD_BLUE}================================================================${RESET}"
      echo ""
      echo -e "${BOLD}  If all pre-checks PASS, initiate switchover with:${RESET}"
      echo ""
      echo -e "${CYAN}  aws rds switchover-blue-green-deployment \\${RESET}"
      echo -e "${CYAN}    --blue-green-deployment-identifier ${DEPLOYMENT_ID} \\${RESET}"
      echo -e "${CYAN}    --switchover-timeout 300 \\${RESET}"
      echo -e "${CYAN}    --region ${AWS_REGION}${RESET}"
      echo ""
      echo -e "${BOLD}  Monitor switchover progress:${RESET}"
      echo -e "${CYAN}  aws rds describe-blue-green-deployments \\${RESET}"
      echo -e "${CYAN}    --blue-green-deployment-identifier ${DEPLOYMENT_ID} \\${RESET}"
      echo -e "${CYAN}    --region ${AWS_REGION} \\${RESET}"
      echo -e "${CYAN}    --query 'BlueGreenDeployments[0].{Status:Status,Details:SwitchoverDetails}'${RESET}"
      echo ""
      echo -e "${BOLD}  After switchover completes, run post-switchover validation:${RESET}"
      echo ""
      echo -e "${CYAN}  $0 \\${RESET}"
      echo -e "${CYAN}    --blue-instance $BLUE_INSTANCE \\${RESET}"
      echo -e "${CYAN}    --green-instance $GREEN_INSTANCE \\${RESET}"
      echo -e "${CYAN}    --deployment-id $DEPLOYMENT_ID \\${RESET}"
      echo -e "${CYAN}    --phase post+monitor \\${RESET}"
      echo -e "${CYAN}    --monitor-duration ${MONITOR_DURATION} \\${RESET}"
      echo -e "${CYAN}    --monitor-interval ${MONITOR_INTERVAL} \\${RESET}"
      echo -e "${CYAN}    --region ${AWS_REGION}${RESET}"
      echo ""
      echo -e "${BOLD_BLUE}================================================================${RESET}"
      log_to_file "Phase 'all': Pre-checks done. Switchover command and post+monitor re-run command printed above."
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
