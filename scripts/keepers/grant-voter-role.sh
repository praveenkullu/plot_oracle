#!/usr/bin/env bash
# One-time setup: grant VOTER_ROLE on InternalVote and optionally lower quorumWeight.
# Idempotent — skips role grant if already held.
#
# Usage:
#   bash scripts/keepers/grant-voter-role.sh --network base_sepolia --voter 0xADDR
#   bash scripts/keepers/grant-voter-role.sh --network base_sepolia --set-quorum 1
#   bash scripts/keepers/grant-voter-role.sh --network base_sepolia  # grants to PRIVATE_KEY wallet

set -euo pipefail
# shellcheck source=../deploy/00-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../deploy/00-common.sh"
# shellcheck source=../deploy/addresses.sh
source "$(dirname "${BASH_SOURCE[0]}")/../deploy/addresses.sh"

NETWORK=""
VOTER_ADDR=""
SET_QUORUM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)    NETWORK="$2"; shift 2 ;;
    --voter)      VOTER_ADDR="$2"; shift 2 ;;
    --set-quorum) SET_QUORUM="$2"; shift 2 ;;
    *) log_error "Unknown argument: $1"; exit 1 ;;
  esac
done

[[ -z "$NETWORK" ]] && { log_error "Usage: $0 --network <base_sepolia|base_mainnet> [--voter 0xADDR] [--set-quorum N]"; exit 1; }

load_env_file "$ROOT_DIR/.env"

if [[ -z "${OPERATOR_PRIVATE_KEY:-}" && -n "${PRIVATE_KEY:-}" ]]; then
  OPERATOR_PRIVATE_KEY="$PRIVATE_KEY"
fi
require_env "OPERATOR_PRIVATE_KEY"

RPC_URL=$(network_to_rpc_url "$NETWORK")
export_all_addresses "$NETWORK"
require_env "INTERNAL_VOTE_ADDRESS"

# Default voter to the operator wallet if not specified
if [[ -z "$VOTER_ADDR" ]]; then
  VOTER_ADDR=$("$CAST" wallet address "$OPERATOR_PRIVATE_KEY" 2>/dev/null || echo "")
  [[ -z "$VOTER_ADDR" ]] && { log_error "Could not derive wallet address from OPERATOR_PRIVATE_KEY"; exit 1; }
  log_info "Defaulting --voter to operator wallet: $VOTER_ADDR"
fi

VOTER_ROLE=$("$CAST" keccak "VOTER_ROLE" 2>/dev/null || echo "")
[[ -z "$VOTER_ROLE" ]] && { log_error "Failed to compute VOTER_ROLE keccak"; exit 1; }
log_info "VOTER_ROLE: $VOTER_ROLE"

# ── Grant VOTER_ROLE if not already held ─────────────────────────────────────

has_role=$("$CAST" call "$INTERNAL_VOTE_ADDRESS" \
  "hasRole(bytes32,address)(bool)" "$VOTER_ROLE" "$VOTER_ADDR" \
  --rpc-url "$RPC_URL" 2>/dev/null || echo "false")

if [[ "$has_role" == "true" ]]; then
  log_info "VOTER_ROLE already granted to $VOTER_ADDR — skipping"
else
  log_info "Granting VOTER_ROLE to $VOTER_ADDR on InternalVote ($INTERNAL_VOTE_ADDRESS)..."
  tx=$("$CAST" send "$INTERNAL_VOTE_ADDRESS" \
    "grantRole(bytes32,address)" "$VOTER_ROLE" "$VOTER_ADDR" \
    --private-key "$OPERATOR_PRIVATE_KEY" \
    --rpc-url "$RPC_URL" \
    2>/dev/null | awk '/transactionHash/{print $2}' || echo "")

  if [[ -n "$tx" ]]; then
    log_info "  VOTER_ROLE granted: $tx"
  else
    log_error "grantRole() tx failed — operator may not have DEFAULT_ADMIN_ROLE on InternalVote"
    exit 1
  fi
fi

# ── Set quorumWeight if requested ─────────────────────────────────────────────

if [[ -n "$SET_QUORUM" ]]; then
  current_quorum=$("$CAST" call "$INTERNAL_VOTE_ADDRESS" "quorumWeight()(uint256)" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "?")

  if [[ "$current_quorum" == "$SET_QUORUM" ]]; then
    log_info "quorumWeight already $SET_QUORUM — skipping"
  else
    log_info "Setting quorumWeight: $current_quorum → $SET_QUORUM..."
    tx=$("$CAST" send "$INTERNAL_VOTE_ADDRESS" \
      "setQuorumWeight(uint256)" "$SET_QUORUM" \
      --private-key "$OPERATOR_PRIVATE_KEY" \
      --rpc-url "$RPC_URL" \
      2>/dev/null | awk '/transactionHash/{print $2}' || echo "")

    if [[ -n "$tx" ]]; then
      log_info "  quorumWeight set to $SET_QUORUM: $tx"
    else
      log_error "setQuorumWeight() tx failed"
      exit 1
    fi
  fi
fi

# ── Verify ────────────────────────────────────────────────────────────────────

echo ""
final_has_role=$("$CAST" call "$INTERNAL_VOTE_ADDRESS" \
  "hasRole(bytes32,address)(bool)" "$VOTER_ROLE" "$VOTER_ADDR" \
  --rpc-url "$RPC_URL" 2>/dev/null || echo "false")
final_quorum=$("$CAST" call "$INTERNAL_VOTE_ADDRESS" "quorumWeight()(uint256)" \
  --rpc-url "$RPC_URL" 2>/dev/null || echo "?")

log_info "VOTER_ROLE on $VOTER_ADDR: $final_has_role"
log_info "quorumWeight: $final_quorum"

if [[ "$final_has_role" == "true" ]]; then
  log_info "Done. $VOTER_ADDR can now vote on disputed claims."
  log_info "Run the dispute e2e test: bash scripts/test/e2e-dispute.sh"
else
  log_error "Role verification failed"
  exit 1
fi
