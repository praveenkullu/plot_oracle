#!/usr/bin/env bash
# Keeper: Finalize unchallenged claims and release submitter bonds.
# Permissionless — anyone can call these functions.
# Run every few minutes (e.g. cron: */5 * * * *).
#
# Phase 1: Query Ponder for challenge windows where finalized=false and expiresAt < now
#          → call ChallengeWindow.finalizeUnchallenged(bytes32 claimId)
#
# Phase 2: Query Ponder for claims where status=Verified
#          → check BondEscrow.lockedBond — if non-zero, call OracleRouter.releaseSubmitterBond(bytes32)
#
# Usage:
#   bash scripts/keepers/finalize-claims.sh --network base_sepolia
#   bash scripts/keepers/finalize-claims.sh --network base_sepolia --ponder-url http://localhost:42069

set -euo pipefail
# shellcheck source=../deploy/00-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../deploy/00-common.sh"
# shellcheck source=../deploy/addresses.sh
source "$(dirname "${BASH_SOURCE[0]}")/../deploy/addresses.sh"

NETWORK=""
PONDER_URL_FLAG=""  # from --ponder-url CLI flag

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)    NETWORK="$2"; shift 2 ;;
    --ponder-url) PONDER_URL_FLAG="$2"; shift 2 ;;
    *) log_error "Unknown argument: $1"; exit 1 ;;
  esac
done

[[ -z "$NETWORK" ]] && { log_error "Usage: $0 --network <base_sepolia|base_mainnet> [--ponder-url URL]"; exit 1; }

load_env_file "$ROOT_DIR/.env"

# Allow OPERATOR_PRIVATE_KEY to fall back to PRIVATE_KEY for testnet
if [[ -z "${OPERATOR_PRIVATE_KEY:-}" && -n "${PRIVATE_KEY:-}" ]]; then
  OPERATOR_PRIVATE_KEY="$PRIVATE_KEY"
fi
export OPERATOR_PRIVATE_KEY
require_env "OPERATOR_PRIVATE_KEY"

# CLI flag > env var from .env > default
PONDER_URL="${PONDER_URL_FLAG:-${PONDER_URL:-http://localhost:42069}}"

export_all_addresses "$NETWORK"
require_env "CHALLENGE_WINDOW_ADDRESS"
require_env "ORACLE_ROUTER_ADDRESS"
require_env "BOND_ESCROW_ADDRESS"

NOW=$(date +%s)
FINALIZED=0
RELEASED=0

# ── Phase 1: Finalize expired unchallenged windows ──────────────────────────

log_info "Phase 1: Querying Ponder ($PONDER_URL) for expired unchallenged windows..."

ponder_query() {
  local query="$1"
  curl -sf -X POST "$PONDER_URL/graphql" \
    -H "Content-Type: application/json" \
    --max-time 10 \
    -d "{\"query\":\"$query\"}" 2>/dev/null
}

window_response=$(ponder_query \
  '{ challengeWindows(where: { finalized: false }, limit: 100) { items { id expiresAt challenger } } }' \
  ) || window_response=""

if [[ -n "$window_response" ]]; then
  # Select windows that have expired and have no challenger (null or zero address)
  expired_ids=$(echo "$window_response" | jq -r \
    --argjson now "$NOW" \
    '.data.challengeWindows.items[]
     | select(.expiresAt != null)
     | select((.expiresAt | tonumber) <= $now)
     | select(.challenger == null or .challenger == "0x0000000000000000000000000000000000000000")
     | .id' 2>/dev/null || echo "")

  if [[ -z "$expired_ids" ]]; then
    log_info "  No expired unchallenged windows found."
  fi

  for claim_id in $expired_ids; do
    log_info "  Finalizing claim $claim_id..."
    tx=$("$CAST" send "$CHALLENGE_WINDOW_ADDRESS" \
      "finalizeUnchallenged(bytes32)" "$claim_id" \
      --private-key "$OPERATOR_PRIVATE_KEY" \
      --rpc-url "$NETWORK" \
      --json 2>/dev/null | jq -r '.transactionHash // empty' || echo "")

    if [[ -n "$tx" ]]; then
      log_info "    → $tx"
      FINALIZED=$(( FINALIZED + 1 ))
    else
      log_warn "    finalizeUnchallenged($claim_id) skipped — may already be finalized or window not expired on-chain yet"
    fi
  done
else
  log_warn "Phase 1 skipped — Ponder GraphQL not reachable at $PONDER_URL"
fi

# ── Phase 2: Release submitter bonds for Verified claims ────────────────────

log_info "Phase 2: Querying Ponder for Verified claims with locked bonds..."

claim_response=$(ponder_query \
  '{ claims(where: { status: "Verified" }, limit: 100) { items { id } } }' \
  ) || claim_response=""

if [[ -n "$claim_response" ]]; then
  verified_ids=$(echo "$claim_response" | jq -r '.data.claims.items[].id' 2>/dev/null || echo "")

  if [[ -z "$verified_ids" ]]; then
    log_info "  No Verified claims found."
  fi

  for claim_id in $verified_ids; do
    # Check if bond is still locked — skip if already released
    locked=$("$CAST" call "$BOND_ESCROW_ADDRESS" \
      "lockedBond(bytes32)(uint256)" "$claim_id" \
      --rpc-url "$NETWORK" 2>/dev/null || echo "0")

    [[ "$locked" == "0" || -z "$locked" ]] && continue

    log_info "  Releasing bond for claim $claim_id (locked: $locked wei)..."
    tx=$("$CAST" send "$ORACLE_ROUTER_ADDRESS" \
      "releaseSubmitterBond(bytes32)" "$claim_id" \
      --private-key "$OPERATOR_PRIVATE_KEY" \
      --rpc-url "$NETWORK" \
      --json 2>/dev/null | jq -r '.transactionHash // empty' || echo "")

    if [[ -n "$tx" ]]; then
      log_info "    → $tx"
      RELEASED=$(( RELEASED + 1 ))
    else
      log_warn "    releaseSubmitterBond($claim_id) failed — disputed claim or already released"
    fi
  done
else
  log_warn "Phase 2 skipped — Ponder GraphQL not reachable at $PONDER_URL"
fi

log_info "Done. Finalized: $FINALIZED windows, released: $RELEASED bonds."
