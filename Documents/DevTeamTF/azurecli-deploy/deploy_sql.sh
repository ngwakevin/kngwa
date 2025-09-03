#!/bin/zsh
# Enable strict mode and initialize variables for strict mode
set -euo pipefail
# Initialize variables to avoid unbound variable errors
RESOURCE_GROUP=""
LOCATION=""
SQL_SERVER_NAME=""
SQL_ADMIN_USER=""
SQL_ADMIN_PASS=""
SQL_DB_NAME=""
FIREWALL_START_IP=""
FIREWALL_END_IP=""
ENTRA_ADMIN_UPN=""
ENTRA_ADMIN_OBJECT_ID=""
TAG_OWNER=""
TAG_PROJECTNAME=""
TAG_BUSINESSUNIT=""
TAG_DEPLOYBY=""
TAG_APPLICATIONNAME=""
BACKUP_STORAGE_REDUNDANCY=""
SUBSCRIPTION_ID=""
# Deploy Azure SQL Database using Azure CLI

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Helper functions for colored output
info() { echo -e "${YELLOW}$1${NC}"; }
success() { echo -e "${GREEN}$1${NC}"; }
error() { echo -e "${RED}$1${NC}"; }

# Helper: parse human size (e.g. 2GB, 2048MB, 0.5TB) into integer GB (rounded up)
parse_size_gb() {
  local raw="$1"
  local lower
  lower=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  # plain GB like 2GB or 2
  if printf '%s' "$lower" | grep -E -q '^[0-9]+(gb)?$'; then
    printf '%s' "$(printf '%s' "$lower" | sed -E 's/^([0-9]+).*/\1/')"
    return 0
  fi
  # MB -> GB round up
  if printf '%s' "$lower" | grep -E -q '^[0-9]+mb$'; then
    local mb
    mb=$(printf '%s' "$lower" | sed -E 's/^([0-9]+)mb$/\1/')
    printf '%s' $(( (mb + 1023) / 1024 ))
    return 0
  fi
  # TB -> GB (integer TB only)
  if printf '%s' "$lower" | grep -E -q '^[0-9]+(\.[0-9]+)?tb$'; then
    local integer
    integer=$(printf '%s' "$lower" | sed -E 's/^([0-9]+).*/\1/')
    printf '%s' $(( integer * 1024 ))
    return 0
  fi
  # fallback: extract digits
  local digits
  digits=$(printf '%s' "$lower" | tr -cd '0-9')
  if [[ -n "$digits" ]]; then
    printf '%s' "$digits"
    return 0
  fi
  printf '0'
}

# Capability cache and lookup (best-effort)
capability_cache_file() { printf '/tmp/az_sql_caps_%s.json' "$1"; }
get_location_capabilities() {
  local loc="$1" cache
  cache=$(capability_cache_file "$loc")
  if [[ -f "$cache" && $(find "$cache" -mmin -60 2>/dev/null | wc -l) -gt 0 ]]; then
    cat "$cache" && return 0
  fi
  if caps=$(az sql db list-editions -l "$loc" -o json 2>/dev/null); then
    printf '%s' "$caps" > "$cache" 2>/dev/null || true
    printf '%s' "$caps"
    return 0
  fi
  return 1
}

# Check whether a given service objective supports the requested max size (GB)
is_size_valid_for_tier() {
  local service_objective="$1" size_gb="$2" loc="${LOCATION:-}"
  if [[ -n "$loc" ]]; then
    caps=$(get_location_capabilities "$loc" 2>/dev/null || true)
    if [[ -n "$caps" ]]; then
  max_val=$(printf '%s' "$caps" | python3 - "$service_objective" <<'PY'
import sys, json, re
target = sys.argv[1].lower()
try:
    data = json.load(sys.stdin)
except Exception:
    data = None
nums = []
def walk(o):
    if isinstance(o, dict):
        for v in o.values():
            if isinstance(v, str) and target in v.lower():
                for vv in o.values():
                    if isinstance(vv, (int, float)):
                        nums.append(int(vv))
                    elif isinstance(vv, str):
                        for m in re.findall(r"(\d+)", vv):
                            nums.append(int(m))
                break
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for it in o:
            walk(it)
    elif isinstance(o, str):
        for m in re.findall(r"(\d+)", o):
            nums.append(int(m))

if data is not None:
    walk(data)
if nums:
  print(max(nums))
else:
  sys.exit(0)
PY
)
      max_val=${max_val:-}
      if [[ -n "$max_val" ]]; then
        if (( max_val > 1024*1024 )); then
          max_gb=$(( max_val / 1024 / 1024 / 1024 ))
        elif (( max_val > 1024 )); then
          max_gb=$(( (max_val + 1023) / 1024 ))
        else
          max_gb=$max_val
        fi
        if (( size_gb <= max_gb )); then
          return 0
        else
          return 1
        fi
      fi
    fi
  fi
  local tier
  tier=$(printf '%s' "$service_objective" | tr '[:upper:]' '[:lower:]')
  local max_allowed=0
  case "$tier" in
    basic) max_allowed=2 ;;
    s0|s1|s2|s3|s4|standard) max_allowed=250 ;;
    p*|premium) max_allowed=1024 ;;
    *) max_allowed=0 ;;
  esac
  if [[ $max_allowed -eq 0 ]]; then
    return 1
  fi
  if (( size_gb <= max_allowed )); then
    return 0
  else
    return 1
  fi
}

info "=========================================="
info "  Azure SQL Deployment Automation Script  "
info "=========================================="
echo

# Pre-flight checks: ensure az CLI, login, and subscription selection
preflight_checks() {
  if ! command -v az >/dev/null 2>&1; then
    error "Azure CLI (az) not found in PATH. Install it and retry."
    exit 1
  fi

  # Ensure user is logged in
  if ! az account show >/dev/null 2>&1; then
    info "You are not logged into Azure CLI. Opening interactive 'az login'..."
    az login || { error "az login failed. Aborting."; exit 1; }
  fi

  # Show current subscription
  current_name=$(az account show --query name -o tsv 2>/dev/null || true)
  current_id=$(az account show --query id -o tsv 2>/dev/null || true)
  info "Current subscription: ${current_name:-(unknown)} (${current_id:-(unknown)})"

  # Offer to switch subscription if multiple exist
  sub_list=$(az account list --query "[].{name:name,id:id}" -o tsv 2>/dev/null || true)
  sub_count=$(printf '%s
' "$sub_list" | sed '/^$/d' | wc -l | tr -d ' ')
  if [[ ${sub_count:-0} -gt 1 ]]; then
    echo -n "Use current subscription? (Y/n): "
    read -r use_current
    use_current=${use_current:-y}
    if [[ "${use_current:l}" != "y" ]]; then
      info "Available subscriptions:"
      i=1
      while IFS=$'\t' read -r sname sid; do
        printf "  %d) %s (%s)\n" "$i" "$sname" "$sid"
        SUB_NAMES[$i]="$sname"
        SUB_IDS[$i]="$sid"
        i=$((i+1))
      done <<< "$sub_list"
      max=$((i-1))
      while true; do
        echo -n "Enter subscription number [1-$max]: "
        read -r sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= max )); then
          SUBSCRIPTION_ID=${SUB_IDS[$sel]}
          az account set --subscription "$SUBSCRIPTION_ID" || { error "Failed to set subscription"; exit 1; }
          info "Switched to subscription: ${SUB_NAMES[$sel]} ($SUBSCRIPTION_ID)"
          break
        else
          error "Invalid selection"
        fi
      done
    fi
  fi
}

# Run preflight checks before collecting resource details
preflight_checks

# Show a clear plan of resources that will be created/updated and ask for confirmation
show_plan() {
  local rg_exists
  # In DRY_RUN mode we must not call az (avoid network/errors). Assume unknown existence.
  if [[ "${DRY_RUN:-}" == "1" ]]; then
    rg_exists=unknown
  else
    if az group show -n "$RESOURCE_GROUP" >/dev/null 2>&1; then
      rg_exists=true
    else
      rg_exists=false
    fi
  fi

  info "Planned actions (dry-run):"
  echo
  if [[ "$rg_exists" == true ]]; then
    printf "  Resource Group: %s (exists) — will be updated with tags and location %s\n" "$RESOURCE_GROUP" "$LOCATION"
    echo
    info "  Current resources in the existing resource group:"
    az resource list --resource-group "$RESOURCE_GROUP" --output table || true
    echo
  elif [[ "$rg_exists" == unknown ]]; then
    printf "  Resource Group: %s (unknown) — dry-run only; no Azure calls will be made\n" "$RESOURCE_GROUP"
  else
    printf "  Resource Group: %s (will be created) — location: %s\n" "$RESOURCE_GROUP" "$LOCATION"
  fi
  echo
  printf "  SQL Server: %s\n" "$SQL_SERVER_NAME"
  printf "    - Resource group: %s\n" "$RESOURCE_GROUP"
  printf "    - Location: %s\n" "$LOCATION"
  printf "    - Admin user: %s\n" "$SQL_ADMIN_USER"
  # Determine a display value for redundancy even if REDUNDANCY_VAL isn't set yet
  local redundancy_display
  if [[ -n "${REDUNDANCY_VAL:-}" ]]; then
    redundancy_display="$REDUNDANCY_VAL"
  else
    case "$(printf '%s' "${BACKUP_STORAGE_REDUNDANCY:-Local}" | tr '[:upper:]' '[:lower:]')" in
      local) redundancy_display="Local" ;;
      geo) redundancy_display="Geo" ;;
      zone) redundancy_display="Zone" ;;
      *) redundancy_display="${BACKUP_STORAGE_REDUNDANCY:-Local}" ;;
    esac
  fi
  printf "    - Backup storage redundancy: %s\n" "$redundancy_display"
  echo
  printf "  SQL Database: %s\n" "$SQL_DB_NAME"
  printf "    - Service objective: Basic\n"
  printf "    - Max size: 2GB\n"
  echo
  printf "  Firewall rule: AllowPublicAccess\n"
  printf "    - Start IP: %s\n" "$FIREWALL_START_IP"
  printf "    - End IP: %s\n" "$FIREWALL_END_IP"
  echo
  printf "  Azure Entra (AD) admin to assign: %s (Object ID: %s)\n" "$ENTRA_ADMIN_UPN" "$ENTRA_ADMIN_OBJECT_ID"
  echo
  info "Resource Group tags to apply:"
  printf "    Owner: %s\n" "${TAG_OWNER:-}<none>"
  printf "    ProjectName: %s\n" "${TAG_PROJECTNAME:-}<none>"
  printf "    BusinessUnit: %s\n" "${TAG_BUSINESSUNIT:-}<none>"
  printf "    DeployBy: %s\n" "${TAG_DEPLOYBY:-}<none>"
  printf "    ApplicationName: %s\n" "${TAG_APPLICATIONNAME:-}<none>"
  echo
}

# Create SQL server with SQL authentication enabled and backup redundancy, with CLI-flag fallback
create_sql_server() {
  local name="$1" out rc server_out support_flag

  # Detect whether the az cli supports --backup-storage-redundancy on sql server create
  if az sql server create --help 2>&1 | grep -q -- '--backup-storage-redundancy'; then
    support_flag=true
  else
    support_flag=false
  fi

  if [[ "$support_flag" == true ]]; then
    out=$(az sql server create \
      --name "$name" \
      --resource-group "$RESOURCE_GROUP" \
      --location "$LOCATION" \
      --admin-user "$SQL_ADMIN_USER" \
      --admin-password "$SQL_ADMIN_PASS" \
      --backup-storage-redundancy "$REDUNDANCY_VAL" 2>&1) || rc=$?
  else
    out=$(az sql server create \
      --name "$name" \
      --resource-group "$RESOURCE_GROUP" \
      --location "$LOCATION" \
      --admin-user "$SQL_ADMIN_USER" \
      --admin-password "$SQL_ADMIN_PASS" 2>&1) || rc=$?
  fi
  rc=${rc:-0}
  if [[ $rc -eq 0 ]]; then
    echo "$out"
    return 0
  fi

  # If create returned non-zero, check if server already exists (some CLI versions return non-zero despite success)
  if server_out=$(az sql server show --name "$name" --resource-group "$RESOURCE_GROUP" 2>/dev/null); then
    echo "$server_out"
    return 0
  fi

  # If we attempted with flag and failed, try without backup flag as a fallback
  if [[ "$support_flag" == true ]]; then
    out=$(az sql server create --name "$name" --resource-group "$RESOURCE_GROUP" --location "$LOCATION" --admin-user "$SQL_ADMIN_USER" --admin-password "$SQL_ADMIN_PASS" 2>&1) || rc=$?
    rc=${rc:-0}
    if [[ $rc -eq 0 ]]; then
      echo "$out"
      return 0
    fi
    if server_out=$(az sql server show --name "$name" --resource-group "$RESOURCE_GROUP" 2>/dev/null); then
      echo "$server_out"
      return 0
    fi
  fi

  # Final failure: return last output and rc
  echo "$out"
  return ${rc:-1}
}

# Prompt for core resource settings (required)
while [[ -z "$RESOURCE_GROUP" ]]; do
  echo -n "Enter Resource Group name (required): "
  read -r RESOURCE_GROUP
  RESOURCE_GROUP=$(printf '%s' "$RESOURCE_GROUP" | tr -d '[:cntrl:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
done
while [[ -z "$LOCATION" ]]; do
  echo -n "Enter Azure region (e.g. eastus) (required): "
  read -r LOCATION
  LOCATION=$(printf '%s' "$LOCATION" | tr -d '[:cntrl:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
done
while [[ -z "$SQL_SERVER_NAME" ]]; do
  echo -n "Enter SQL Server name (required): "
  read -r SQL_SERVER_NAME
  SQL_SERVER_NAME=$(printf '%s' "$SQL_SERVER_NAME" | tr -d '[:cntrl:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
done
while [[ -z "$SQL_ADMIN_USER" ]]; do
  echo -n "Enter SQL Admin username (required): "
  read -r SQL_ADMIN_USER
  SQL_ADMIN_USER=$(printf '%s' "$SQL_ADMIN_USER" | tr -d '[:cntrl:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
done
while [[ -z "$SQL_ADMIN_PASS" ]]; do
  echo -n "Enter SQL Admin password (required): "
  stty -echo; read -r SQL_ADMIN_PASS; stty echo; echo
done
while [[ -z "$SQL_DB_NAME" ]]; do
  echo -n "Enter SQL Database name (required): "
  read -r SQL_DB_NAME
  SQL_DB_NAME=$(printf '%s' "$SQL_DB_NAME" | tr -d '[:cntrl:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
done

# Validate SQL DB name: allow only letters, digits, dot, underscore, hyphen; length 1-128
is_valid_db_name() {
  local n="$1"
  if [[ -z "$n" ]]; then
    return 1
  fi
  if [[ ${#n} -gt 128 ]]; then
    return 1
  fi
  if printf '%s' "$n" | grep -Eq '^[A-Za-z0-9._-]+$'; then
    return 0
  fi
  return 1
}

# If the provided name is invalid, offer a sanitized suggestion and allow re-entry
while ! is_valid_db_name "$SQL_DB_NAME"; do
  orig_db="$SQL_DB_NAME"
  # Replace groups of invalid chars with a single '-'
  suggested=$(printf '%s' "$orig_db" | sed -E 's/[^A-Za-z0-9._-]+/-/g' | sed -E 's/^-+//; s/-+$//')
  # Truncate to 128 chars if necessary
  if [[ ${#suggested} -gt 128 ]]; then
    suggested=${suggested:0:128}
  fi
  error "The database name you entered ('$orig_db') contains invalid characters or is too long."
  info "Suggested sanitized name: $suggested"
  printf "Use suggested sanitized name? (Y/n): " > /dev/tty
  read -r use_sugg < /dev/tty
  use_sugg=${use_sugg:-y}
  if [[ "${use_sugg:l}" == "y" ]]; then
    SQL_DB_NAME="$suggested"
    success "Using database name: $SQL_DB_NAME"
    break
  else
    # Prompt user to re-enter a valid name
    printf "Enter SQL Database name (required): " > /dev/tty
    read -r SQL_DB_NAME < /dev/tty
    SQL_DB_NAME=$(printf '%s' "$SQL_DB_NAME" | tr -d '[:cntrl:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  fi
done

# Optional firewall settings
echo
echo "Firewall configuration (optional). Press Enter to skip creating a firewall rule; you can add rules later when IPs are known."
echo -n "  Start IP (leave empty to skip): "
read -r FIREWALL_START_IP
FIREWALL_START_IP=$(printf '%s' "$FIREWALL_START_IP" | tr -d '[:cntrl:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
echo -n "  End IP   (leave empty to skip): "
read -r FIREWALL_END_IP
FIREWALL_END_IP=$(printf '%s' "$FIREWALL_END_IP" | tr -d '[:cntrl:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

if [[ "$FIREWALL_START_IP" == "0.0.0.0" || "$FIREWALL_END_IP" == "0.0.0.0" ]]; then
  info "Using 0.0.0.0 is not allowed. Firewall creation will be skipped; you can add firewall rules later when IPs are known."
  FIREWALL_START_IP=""
  FIREWALL_END_IP=""
fi

# Prompt for Azure Entra ID admin (select from list)
echo
info "Select Azure Entra ID admin from the list below (required):"
ADMINS=(
  'MAnnie.Tish@KeminInd.onmicrosoft.com|f5ee6308-5b4e-44f5-8360-79052c4aebec'
  'MLuke.Steinbach@KeminInd.onmicrosoft.com|a4ea5fea-08e2-412d-82d3-89373aba2ddc'
  'MBrent.Stonskas@KeminInd.onmicrosoft.com|d19f2e7b-02a9-4b27-85df-0c0e47c5a9f0'
  'MKevin.Ngwa@KeminInd.onmicrosoft.com|88547dd2-c0cd-4221-b145-da0a698be8b8'
)

num_options=${#ADMINS[@]}
for ((i=1; i<=num_options; i++)); do
  opt=${ADMINS[$i]}
  name=${opt%%|*}
  id=${opt#*|}
  echo "  $i) $name (Object ID: $id)"
done
while true; do
  echo -n "Enter choice [1-${num_options}]: "
  read -r choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= num_options )); then
    selected=${ADMINS[$choice]}
    ENTRA_ADMIN_UPN=${selected%%|*}
    ENTRA_ADMIN_OBJECT_ID=${selected#*|}
    break
  else
    error "Invalid selection. Please try again."
  fi
done

# Resource Group tags (optional)
echo
info "Resource Group tags (optional, press Enter to skip each):"
echo -n "  Owner [none]: ";           read -r TAG_OWNER;           TAG_OWNER=${TAG_OWNER:-}
echo -n "  ProjectName [none]: ";     read -r TAG_PROJECTNAME;     TAG_PROJECTNAME=${TAG_PROJECTNAME:-}
echo -n "  BusinessUnit [none]: ";    read -r TAG_BUSINESSUNIT;    TAG_BUSINESSUNIT=${TAG_BUSINESSUNIT:-}
echo -n "  DeployBy [none]: ";        read -r TAG_DEPLOYBY;        TAG_DEPLOYBY=${TAG_DEPLOYBY:-}
echo -n "  ApplicationName [none]: "; read -r TAG_APPLICATIONNAME; TAG_APPLICATIONNAME=${TAG_APPLICATIONNAME:-}

# Backup storage redundancy for SQL server (Local, Geo, Zone)
echo
echo "Backup storage redundancy options:"
echo "  Local (default), Geo, Zone"
echo -n "Select backup storage redundancy [Local]: "; read -r BACKUP_STORAGE_REDUNDANCY
BACKUP_STORAGE_REDUNDANCY=${BACKUP_STORAGE_REDUNDANCY:-Local}

# Show the plan and confirm with the user before touching Azure
show_plan
printf "Proceed with the planned actions above? (Y/n): " > /dev/tty
read -r proceed < /dev/tty
proceed=${proceed:-y}
if [[ "${proceed:l}" != "y" ]]; then
  info "Aborting per user request. No changes were made."
  exit 0
fi

# If DRY_RUN=1 is set in the environment, print the plan and exit before making Azure changes
if [[ "${DRY_RUN:-}" == "1" ]]; then
  info "DRY_RUN=1 set — exiting before creating resources."
  exit 0
fi

# Now check whether the target resource group exists and create it if necessary
if az group show -n "$RESOURCE_GROUP" >/dev/null 2>&1; then
  info "Resource Group '$RESOURCE_GROUP' already exists — listing current resources:"
  az resource list --resource-group "$RESOURCE_GROUP" --output table || true
  # Confirm action with the user
  printf "Proceed to create/update resources in '%s'? (Y/n): " "$RESOURCE_GROUP" > /dev/tty
  read -r proceed < /dev/tty
  proceed=${proceed:-y}
  if [[ "${proceed:l}" != "y" ]]; then
    info "Aborting per user request. No changes were made."
    exit 0
  fi
else
  printf "Resource Group '%s' will be created. Proceed? (Y/n): " "$RESOURCE_GROUP" > /dev/tty
  read -r proceed < /dev/tty
  proceed=${proceed:-y}
  if [[ "${proceed:l}" != "y" ]]; then
    info "Aborting per user request. No changes were made."
    exit 0
  fi
fi

# Create resource group
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --tags Owner="$TAG_OWNER" ProjectName="$TAG_PROJECTNAME" BusinessUnit="$TAG_BUSINESSUNIT" DeployBy="$TAG_DEPLOYBY" ApplicationName="$TAG_APPLICATIONNAME"


# Create SQL server with SQL authentication enabled and backup redundancy
# Normalize redundancy value to Title case accepted by CLI (Local, Geo, Zone)
BACKUP_LOWER=$(printf '%s' "$BACKUP_STORAGE_REDUNDANCY" | tr '[:upper:]' '[:lower:]')
case "$BACKUP_LOWER" in
  local) REDUNDANCY_VAL="Local" ;;
  geo)   REDUNDANCY_VAL="Geo" ;;
  zone)  REDUNDANCY_VAL="Zone" ;;
  "")    REDUNDANCY_VAL="Local" ;;
  *) REDUNDANCY_VAL="$BACKUP_STORAGE_REDUNDANCY" ;;
esac

create_sql_server() {
  local name="$1"
  local out rc
  # Try with backup flag first
  out=$(az sql server create \
    --name "$name" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --admin-user "$SQL_ADMIN_USER" \
    --admin-password "$SQL_ADMIN_PASS" \
    --backup-storage-redundancy "$REDUNDANCY_VAL" 2>&1)
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "$out"
    return 0

    # Print a clear plan of resources that will be created or updated and ask for confirmation
    show_plan() {
      local rg_exists
      if az group show -n "$RESOURCE_GROUP" >/dev/null 2>&1; then
        rg_exists=true
      else
        rg_exists=false
      fi

      info "Planned actions (dry-run):"
      echo
      if [[ "$rg_exists" == true ]]; then
        printf "  Resource Group: %s (exists) — will be updated with tags and location %s\n" "$RESOURCE_GROUP" "$LOCATION"
        echo
        info "  Current resources in the existing resource group:"
        az resource list --resource-group "$RESOURCE_GROUP" --output table || true
        echo
      else
        printf "  Resource Group: %s (will be created) — location: %s\n" "$RESOURCE_GROUP" "$LOCATION"
      fi
      echo
      printf "  SQL Server: %s\n" "$SQL_SERVER_NAME"
      printf "    - Resource group: %s\n" "$RESOURCE_GROUP"
      printf "    - Location: %s\n" "$LOCATION"
      printf "    - Admin user: %s\n" "$SQL_ADMIN_USER"
      printf "    - Backup storage redundancy: %s\n" "$REDUNDANCY_VAL"
      echo
      printf "  SQL Database: %s\n" "$SQL_DB_NAME"
      printf "    - Service objective: Basic\n"
      printf "    - Max size: 2GB\n"
      echo
      # Firewall display: if both IPs provided and not 0.0.0.0 show them, otherwise indicate skipped
      if [[ -n "${FIREWALL_START_IP:-}" && -n "${FIREWALL_END_IP:-}" && "$FIREWALL_START_IP" != "0.0.0.0" && "$FIREWALL_END_IP" != "0.0.0.0" ]]; then
        printf "  Firewall rule: AllowPublicAccess\n"
        printf "    - Start IP: %s\n" "$FIREWALL_START_IP"
        printf "    - End IP: %s\n" "$FIREWALL_END_IP"
      else
        printf "  Firewall rule: (skipped) — no IPs provided; you can add rules later\n"
      fi
      echo
      printf "  Azure Entra (AD) admin to assign: %s (Object ID: %s)\n" "$ENTRA_ADMIN_UPN" "$ENTRA_ADMIN_OBJECT_ID"
      echo
      info "Resource Group tags to apply:"
      printf "    Owner: %s\n" "${TAG_OWNER:-}<none>"
      printf "    ProjectName: %s\n" "${TAG_PROJECTNAME:-}<none>"
      printf "    BusinessUnit: %s\n" "${TAG_BUSINESSUNIT:-}<none>"
      printf "    DeployBy: %s\n" "${TAG_DEPLOYBY:-}<none>"
      printf "    ApplicationName: %s\n" "${TAG_APPLICATIONNAME:-}<none>"
      echo
    }

    # Show the plan and confirm with the user
    show_plan
    printf "Proceed with the planned actions above? (Y/n): " > /dev/tty
    read -r proceed < /dev/tty
    proceed=${proceed:-y}
    if [[ "${proceed:l}" != "y" ]]; then
      info "Aborting per user request. No changes were made."
      exit 0
    fi
    return 0
  fi
  echo "$out"
  return $rc
}

    # If DRY_RUN=1 is set in the environment, print the planned actions and exit before making Azure changes
    if [[ "${DRY_RUN:-}" == "1" ]]; then
      show_plan
      info "DRY_RUN=1 set — exiting before creating resources."
      exit 0
    fi

info "Creating SQL server '$SQL_SERVER_NAME' in '$RESOURCE_GROUP' (backup redundancy: $REDUNDANCY_VAL)"
while true; do
  out=$(create_sql_server "$SQL_SERVER_NAME") || rc=$?
  if [[ ${rc:-0} -eq 0 ]]; then
    success "SQL server '$SQL_SERVER_NAME' created."
    break
  fi

  # Check for name already exists in output
  if echo "$out" 2>/dev/null | grep -qi "NameAlreadyExists\|already exists"; then
    error "The SQL server name '$SQL_SERVER_NAME' is already taken."
    echo -n "Choose a new name or type 'auto' to append a random suffix [auto]: "
    read -r choice
    choice=${choice:-auto}
    if [[ "$choice" == "auto" ]]; then
      suffix=$(LC_CTYPE=C tr -dc 'a-z0-9' </dev/urandom | head -c4)
      SQL_SERVER_NAME="${SQL_SERVER_NAME%-*}-$suffix"
      info "Trying new server name: $SQL_SERVER_NAME"
      continue
    else
      SQL_SERVER_NAME="$choice"
      continue
    fi
  else
    # Unknown error, print and exit
    error "Failed to create SQL server:"
    echo "$out"
    exit ${rc:-1}
  fi
done

# Enable Azure Entra ID (Azure AD) authentication by setting an Entra admin
az sql server ad-admin create \
  --resource-group $RESOURCE_GROUP \
  --server-name $SQL_SERVER_NAME \
  --display-name $ENTRA_ADMIN_UPN \
  --object-id $ENTRA_ADMIN_OBJECT_ID

# Create SQL database (Basic, 2GB)
az sql db create \
  --resource-group $RESOURCE_GROUP \
  --server $SQL_SERVER_NAME \
  --name $SQL_DB_NAME \
  --service-objective Basic \
  --max-size 2GB

# Configure firewall rule for public access (only if IPs were provided and not skipped)
if [[ -n "${FIREWALL_START_IP:-}" && -n "${FIREWALL_END_IP:-}" && "$FIREWALL_START_IP" != "0.0.0.0" && "$FIREWALL_END_IP" != "0.0.0.0" ]]; then
  az sql server firewall-rule create \
    --resource-group "$RESOURCE_GROUP" \
    --server "$SQL_SERVER_NAME" \
    --name AllowPublicAccess \
    --start-ip-address "$FIREWALL_START_IP" \
    --end-ip-address "$FIREWALL_END_IP"
else
  info "Firewall creation skipped — no valid start/end IP provided. You can add firewall rules later with:"
  info "  az sql server firewall-rule create --resource-group <RG> --server <SERVER> --name <NAME> --start-ip-address <IP> --end-ip-address <IP>"
fi

success "Deployment complete. Both SQL authentication and Azure Entra ID authentication are enabled."
echo
info "Listing all resources in Resource Group '$RESOURCE_GROUP':"
az resource list --resource-group "$RESOURCE_GROUP" --output table
