#!/usr/bin/env bash
# Keeper: Record Chainlink price snapshots on EmissionController.
# Run daily (24h snapshot) and weekly (7d snapshot).
# Replace with Chainlink Automation upkeeps in production.
#
# Usage:
#   bash scripts/keepers/record-snapshots.sh --network base_mainnet --interval 24h
#   bash scripts/keepers/record-snapshots.sh --network base_mainnet --interval 7d
#
# Cron examples:
#   0 0 * * *   bash /path/to/scripts/keepers/record-snapshots.sh --network base_mainnet --interval 24h
#   0 0 * * 0   bash /path/to/scripts/keepers/record-snapshots.sh --network base_mainnet --interval 7d

set -euo pipefail
# shellcheck source=../deploy/00-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../deploy/00-common.sh"
# shellcheck source=../deploy/addresses.sh
source "$(dirname "${BASH_SOURCE[0]}")/../deploy/addresses.sh"

NETWORK=""
INTERVAL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)  NETWORK="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    *) log_error "Unknown argument: $1"; exit 1 ;;
  esac
done

[[ -z "$NETWORK" || -z "$INTERVAL" ]] && {
  log_error "Usage: $0 --network <base_sepolia|base_mainnet> --interval <24h|7d>"
  exit 1
}

load_env_file "$ROOT_DIR/.env"
require_env "OPERATOR_PRIVATE_KEY"
export_all_addresses "$NETWORK"
require_env "EMISSION_CONTROLLER_ADDRESS"

case "$INTERVAL" in
  24h)
    log_info "Recording 24h price snapshot on EmissionController ($EMISSION_CONTROLLER_ADDRESS)..."
    tx=$("$CAST" send "$EMISSION_CONTROLLER_ADDRESS" \
      "recordSnapshot24h()" \
      --private-key "$OPERATOR_PRIVATE_KEY" \
      --rpc-url "$NETWORK" \
      --json 2>/dev/null | jq -r '.transactionHash' || echo "")
    log_info "recordSnapshot24h txHash: $tx"
    ;;
  7d)
    log_info "Recording 7d price snapshot on EmissionController ($EMISSION_CONTROLLER_ADDRESS)..."
    tx=$("$CAST" send "$EMISSION_CONTROLLER_ADDRESS" \
      "recordSnapshot7d()" \
      --private-key "$OPERATOR_PRIVATE_KEY" \
      --rpc-url "$NETWORK" \
      --json 2>/dev/null | jq -r '.transactionHash' || echo "")
    log_info "recordSnapshot7d txHash: $tx"
    ;;
  *)
    log_error "Unknown interval: $INTERVAL (must be 24h or 7d)"
    exit 1
    ;;
esac

# Also check circuit breaker (permissionless — anyone can call)
log_info "Checking circuit breaker..."
"$CAST" send "$EMISSION_CONTROLLER_ADDRESS" \
  "checkCircuitBreaker()" \
  --private-key "$OPERATOR_PRIVATE_KEY" \
  --rpc-url "$NETWORK" \
  --json 2>/dev/null | jq -r '"checkCircuitBreaker txHash: \(.transactionHash)"' || true

log_info "Snapshot recorded."
