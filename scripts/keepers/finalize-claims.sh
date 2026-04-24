#!/usr/bin/env bash
# Keeper: Finalize unchallenged claims whose challenge windows have expired.
# Permissionless — anyone can call these functions.
# Run every few minutes (e.g. cron: */5 * * * *).
#
# Requires: deployments/<network>.json with CLAIM_REGISTRY, CHALLENGE_WINDOW, ORACLE_ROUTER.
# Requires: BASE_RPC_URL in .env (or --rpc-url override).
#
# Usage:
#   bash scripts/keepers/finalize-claims.sh --network base_mainnet
#   bash scripts/keepers/finalize-claims.sh --network base_mainnet --max-claims 20

set -euo pipefail
# shellcheck source=../deploy/00-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../deploy/00-common.sh"
# shellcheck source=../deploy/addresses.sh
source "$(dirname "${BASH_SOURCE[0]}")/../deploy/addresses.sh"

NETWORK=""
MAX_CLAIMS=50

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)    NETWORK="$2"; shift 2 ;;
    --max-claims) MAX_CLAIMS="$2"; shift 2 ;;
    *) log_error "Unknown argument: $1"; exit 1 ;;
  esac
done

[[ -z "$NETWORK" ]] && { log_error "Usage: $0 --network <base_sepolia|base_mainnet> [--max-claims N]"; exit 1; }

load_env_file "$ROOT_DIR/.env"
require_env "OPERATOR_PRIVATE_KEY"
export_all_addresses "$NETWORK"
require_env "CLAIM_REGISTRY_ADDRESS"
require_env "CHALLENGE_WINDOW_ADDRESS"
require_env "ORACLE_ROUTER_ADDRESS"

NOW=$(date +%s)
FINALIZED=0
RELEASED=0

log_info "Scanning for finalizeable claims (max $MAX_CLAIMS)..."

# Fetch the latest claim count from ClaimRegistry
total_claims=$("$CAST" call "$CLAIM_REGISTRY_ADDRESS" "claimCount()(uint256)" \
  --rpc-url "$NETWORK" 2>/dev/null || echo "0")

if [[ "$total_claims" == "0" ]]; then
  log_info "No claims found. Exiting."
  exit 0
fi

log_info "Total claims: $total_claims"

# Iterate backwards from latest (most recently submitted = most likely to be finalizeable)
start=$(( total_claims - 1 ))
checked=0

for (( id=start; id>=0 && checked<MAX_CLAIMS; id-- )); do
  checked=$(( checked + 1 ))

  # Check claim status: 0=Pending, 1=Verified, 2=Disputed, 3=Finalized, 4=Rejected
  status=$("$CAST" call "$CLAIM_REGISTRY_ADDRESS" "getClaimStatus(uint256)(uint8)" "$id" \
    --rpc-url "$NETWORK" 2>/dev/null || echo "99")

  # Only act on Pending (0) claims
  [[ "$status" != "0" ]] && continue

  # Check if challenge window expired
  window_end=$("$CAST" call "$CHALLENGE_WINDOW_ADDRESS" "windowEnd(uint256)(uint256)" "$id" \
    --rpc-url "$NETWORK" 2>/dev/null || echo "0")

  [[ "$window_end" == "0" ]] && continue
  (( NOW <= window_end )) && continue

  # Check no challenge was opened
  challenged=$("$CAST" call "$CHALLENGE_WINDOW_ADDRESS" "isChallenged(uint256)(bool)" "$id" \
    --rpc-url "$NETWORK" 2>/dev/null || echo "true")
  [[ "$challenged" == "true" ]] && continue

  log_info "  Finalizing claim $id (window ended $(( NOW - window_end ))s ago)..."
  tx=$("$CAST" send "$CHALLENGE_WINDOW_ADDRESS" \
    "finalizeUnchallenged(uint256)" "$id" \
    --private-key "$OPERATOR_PRIVATE_KEY" \
    --rpc-url "$NETWORK" \
    --json 2>/dev/null | jq -r '.transactionHash' || echo "failed")

  if [[ "$tx" != "failed" && -n "$tx" ]]; then
    log_info "    finalizeUnchallenged($id) → $tx"
    FINALIZED=$(( FINALIZED + 1 ))

    # Attempt to release submitter bond immediately after finalization
    release_tx=$("$CAST" send "$ORACLE_ROUTER_ADDRESS" \
      "releaseSubmitterBond(uint256)" "$id" \
      --private-key "$OPERATOR_PRIVATE_KEY" \
      --rpc-url "$NETWORK" \
      --json 2>/dev/null | jq -r '.transactionHash' || echo "")

    if [[ -n "$release_tx" ]]; then
      log_info "    releaseSubmitterBond($id) → $release_tx"
      RELEASED=$(( RELEASED + 1 ))
    fi
  else
    log_warn "    finalizeUnchallenged($id) failed — may already be finalized"
  fi
done

log_info "Done. Finalized: $FINALIZED claims, released $RELEASED bonds. Checked $checked of $total_claims."
