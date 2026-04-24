#!/usr/bin/env bash
# Address registry helpers. Source this file; do not execute directly.
# Backed by deployments/<network>.json written by phase2.

# Usage: get_address base_sepolia PLOTToken
get_address() {
  local network="$1"
  local contract="$2"
  read_deployment_json "$network" ".contracts.${contract}.address"
}

# Usage: set_address base_sepolia PLOTToken 0xabc...
set_address() {
  local network="$1"
  local contract="$2"
  local address="$3"
  write_deployment_json "$network" ".contracts.${contract}.address" "\"$address\""
}

# Export all addresses as <CONTRACT>_ADDRESS env vars + TIMELOCK_ADDRESS, GOVERNOR_ADDRESS
# Handles CamelCase -> UPPER_SNAKE conversion for the 13 known contracts.
export_all_addresses() {
  local network="$1"
  local file="$DEPLOYMENTS_DIR/${network}.json"

  [[ -f "$file" ]] || { log_error "No deployment found for $network"; exit 1; }

  declare -A name_map=(
    [PLOTToken]="PLOT_TOKEN_ADDRESS"
    [BondCalculator]="BOND_CALCULATOR_ADDRESS"
    [BondEscrow]="BOND_ESCROW_ADDRESS"
    [ClaimRegistry]="CLAIM_REGISTRY_ADDRESS"
    [NoveltyGate]="NOVELTY_GATE_ADDRESS"
    [ChallengeWindow]="CHALLENGE_WINDOW_ADDRESS"
    [ConfidenceScorer]="CONFIDENCE_SCORER_ADDRESS"
    [OracleRouter]="ORACLE_ROUTER_ADDRESS"
    [InternalVote]="INTERNAL_VOTE_ADDRESS"
    [EmissionController]="EMISSION_CONTROLLER_ADDRESS"
    [TimelockController]="TIMELOCK_ADDRESS"
    [GovernorPlot]="GOVERNOR_ADDRESS"
    [Treasury]="TREASURY_ADDRESS"
  )

  for contract in "${!name_map[@]}"; do
    local varname="${name_map[$contract]}"
    local addr
    addr=$(jq -r ".contracts.${contract}.address // empty" "$file")
    if [[ -n "$addr" && "$addr" != "null" ]]; then
      export "$varname=$addr"
      log_info "  $varname=$addr"
    else
      log_warn "  $contract not found in $file — $varname not exported"
    fi
  done
}

# Inject all 13 contract addresses into the .env file (idempotent)
inject_addresses_into_env() {
  local network="$1"
  local env_file="${2:-$ROOT_DIR/.env}"

  export_all_addresses "$network"

  local addr_vars=(
    "PLOT_TOKEN_ADDRESS"
    "BOND_CALCULATOR_ADDRESS"
    "BOND_ESCROW_ADDRESS"
    "CLAIM_REGISTRY_ADDRESS"
    "NOVELTY_GATE_ADDRESS"
    "CHALLENGE_WINDOW_ADDRESS"
    "CONFIDENCE_SCORER_ADDRESS"
    "ORACLE_ROUTER_ADDRESS"
    "INTERNAL_VOTE_ADDRESS"
    "EMISSION_CONTROLLER_ADDRESS"
    "TIMELOCK_ADDRESS"
    "GOVERNOR_ADDRESS"
    "TREASURY_ADDRESS"
  )

  for var in "${addr_vars[@]}"; do
    if [[ -n "${!var:-}" ]]; then
      upsert_env_var "$env_file" "$var" "${!var}"
    fi
  done

  log_info "Contract addresses injected into $env_file"
  log_info "Backup saved alongside .env (timestamped)"
}
