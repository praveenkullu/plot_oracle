#!/usr/bin/env bash
# Shared helpers for all deploy scripts. Source this file; do not execute directly.
# Pinned Foundry version: forge 0.3.x — bump this comment when upgrading.

set -euo pipefail

# ── Tool paths ──────────────────────────────────────────────────────────────
export FORGE="${FORGE:-$HOME/.config/.foundry/bin/forge}"
export CAST="${CAST:-$HOME/.config/.foundry/bin/cast}"
export PM2="${PM2:-$HOME/.local/bin/pm2}"

# ── Directory paths ──────────────────────────────────────────────────────────
export ROOT_DIR
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export CONTRACTS_DIR="$ROOT_DIR/contracts"
export DEPLOYMENTS_DIR="$ROOT_DIR/deployments"
export SCRIPTS_DIR="$ROOT_DIR/scripts"

# ── Logging ──────────────────────────────────────────────────────────────────
log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

# ── Env loading ──────────────────────────────────────────────────────────────
load_env_file() {
  local env_file="${1:-$ROOT_DIR/.env}"
  if [[ ! -f "$env_file" ]]; then
    log_error ".env not found at $env_file"
    log_error "Run: cp $ROOT_DIR/.env.example $ROOT_DIR/.env  then fill in values"
    exit 1
  fi
  # Export vars, skip comments and blank lines
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
  log_info "Loaded $env_file"
}

# ── Requirement checks ────────────────────────────────────────────────────────
require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null && [[ ! -x "$cmd" ]]; then
    log_error "Required command not found: $cmd"
    exit 1
  fi
}

require_env() {
  local var="$1"
  if [[ -z "${!var:-}" ]]; then
    log_error "Required environment variable not set: $var"
    exit 1
  fi
}

# ── Deployment JSON helpers ───────────────────────────────────────────────────
# Write or update a key in deployments/<network>.json
write_deployment_json() {
  local network="$1"   # e.g. base_sepolia
  local key="$2"       # e.g. .contracts.PLOTToken.address
  local value="$3"     # e.g. 0xabc...
  local file="$DEPLOYMENTS_DIR/${network}.json"

  require_cmd jq

  if [[ ! -f "$file" ]]; then
    echo '{}' > "$file"
  fi

  local tmp
  tmp=$(mktemp)
  jq "$key = $value" "$file" > "$tmp" && mv "$tmp" "$file"
}

# Read a key from deployments/<network>.json
read_deployment_json() {
  local network="$1"
  local key="$2"
  local file="$DEPLOYMENTS_DIR/${network}.json"

  if [[ ! -f "$file" ]]; then
    log_error "Deployment file not found: $file  (run phase2 first)"
    exit 1
  fi
  jq -r "$key" "$file"
}

# Export all contract addresses from deployments/<network>.json as env vars
export_deployment_addresses() {
  local network="$1"
  local file="$DEPLOYMENTS_DIR/${network}.json"

  if [[ ! -f "$file" ]]; then
    log_error "Deployment file not found: $file  (run phase2 first)"
    exit 1
  fi

  local contracts
  contracts=$(jq -r '.contracts | to_entries[] | "\(.key)=\(.value.address)"' "$file")

  while IFS= read -r line; do
    local varname="${line%%=*}_ADDRESS"
    local addr="${line#*=}"
    # Convert CamelCase to UPPER_SNAKE: PLOTToken -> PLOT_TOKEN_ADDRESS
    varname=$(echo "$varname" | sed 's/\([A-Z]\)/_\1/g' | sed 's/^_//' | tr '[:lower:]' '[:upper:]')
    export "$varname=$addr"
    log_info "  $varname=$addr"
  done <<< "$contracts"
}

# Idempotently upsert a KEY=VALUE line in a file (atomic write with backup)
upsert_env_var() {
  local file="$1"
  local key="$2"
  local value="$3"

  local backup
  backup="${file}.bak.$(date +%s)"
  cp "$file" "$backup"

  local tmp
  tmp=$(mktemp)

  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed "s|^${key}=.*|${key}=${value}|" "$file" > "$tmp"
  else
    cat "$file" > "$tmp"
    echo "${key}=${value}" >> "$tmp"
  fi

  mv "$tmp" "$file"
}

# Parse forge broadcast JSON and extract addresses by contract name
# Usage: parse_broadcast_addresses <chainId> <scriptName>
# Outputs lines: ContractName=0xaddress
parse_broadcast_addresses() {
  local chain_id="$1"
  local script_name="$2"
  local broadcast_file="$CONTRACTS_DIR/broadcast/${script_name}/${chain_id}/run-latest.json"

  if [[ ! -f "$broadcast_file" ]]; then
    log_error "Broadcast file not found: $broadcast_file"
    log_error "Was --broadcast passed and did the deploy succeed?"
    exit 1
  fi

  # Extract contract_name -> address from transactions array
  jq -r '
    .transactions[]
    | select(.transactionType == "CREATE")
    | "\(.contractName)=\(.contractAddress)"
  ' "$broadcast_file"
}

# Network to chain ID
network_to_chain_id() {
  case "$1" in
    base_sepolia) echo "84532" ;;
    base_mainnet) echo "8453"  ;;
    *)
      log_error "Unknown network: $1 (must be base_sepolia or base_mainnet)"
      exit 1
      ;;
  esac
}

# Network to RPC alias (matches foundry.toml rpc_endpoints keys)
network_to_rpc_alias() {
  echo "$1"  # foundry.toml keys match our network names exactly
}
