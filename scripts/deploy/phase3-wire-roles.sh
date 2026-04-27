#!/usr/bin/env bash
# Phase 3: Wire cross-contract roles and optionally hand off admin to a multisig.
# Reads contract addresses from deployments/<network>.json written by phase2.
# Defaults to dry-run. Pass --broadcast to send transactions.
#
# Usage:
#   bash scripts/deploy/phase3-wire-roles.sh --network base_sepolia
#   bash scripts/deploy/phase3-wire-roles.sh --network base_sepolia --broadcast
#   bash scripts/deploy/phase3-wire-roles.sh --network base_mainnet --broadcast
#   # Mainnet admin handoff (run after broadcast + verification):
#   bash scripts/deploy/phase3-wire-roles.sh --network base_mainnet --broadcast --admin-handoff

set -euo pipefail
# shellcheck source=00-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"
# shellcheck source=addresses.sh
source "$(dirname "${BASH_SOURCE[0]}")/addresses.sh"

# ── Argument parsing ──────────────────────────────────────────────────────────
NETWORK=""
BROADCAST=false
ADMIN_HANDOFF=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)       NETWORK="$2"; shift 2 ;;
    --broadcast)     BROADCAST=true; shift ;;
    --admin-handoff) ADMIN_HANDOFF=true; shift ;;
    *) log_error "Unknown argument: $1"; exit 1 ;;
  esac
done

[[ -z "$NETWORK" ]] && { log_error "Usage: $0 --network <base_sepolia|base_mainnet> [--broadcast] [--admin-handoff]"; exit 1; }

# ── Load environment and addresses ────────────────────────────────────────────
load_env_file "$ROOT_DIR/.env"

REQUIRED_VARS=(PRIVATE_KEY SNS_ORACLE_WALLET OPERATOR_WALLET)
for var in "${REQUIRED_VARS[@]}"; do require_env "$var"; done

RPC_URL=$(network_to_rpc_url "$NETWORK")

log_info "Loading deployed contract addresses from deployments/${NETWORK}.json..."
export_all_addresses "$NETWORK"

# Validate all expected addresses are present
ADDR_VARS=(
  CLAIM_REGISTRY_ADDRESS BOND_ESCROW_ADDRESS CHALLENGE_WINDOW_ADDRESS
  ORACLE_ROUTER_ADDRESS INTERNAL_VOTE_ADDRESS NOVELTY_GATE_ADDRESS
  PLOT_TOKEN_ADDRESS EMISSION_CONTROLLER_ADDRESS TIMELOCK_ADDRESS
  GOVERNOR_ADDRESS
)
for var in "${ADDR_VARS[@]}"; do
  require_env "$var"
done

# ── Pre-flight: check which roles are already granted (skip if re-running) ────
log_info "Checking existing role bindings..."

has_role() {
  local contract_addr="$1"
  local role_hash="$2"
  local grantee="$3"
  "$CAST" call "$contract_addr" "hasRole(bytes32,address)(bool)" \
    "$role_hash" "$grantee" --rpc-url "$RPC_URL" 2>/dev/null || echo "false"
}

NOVELTY_GATE_ROLE=$("$CAST" call "$CLAIM_REGISTRY_ADDRESS" "NOVELTY_GATE_ROLE()(bytes32)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
ORACLE_ROUTER_ROLE_CR=$("$CAST" call "$CLAIM_REGISTRY_ADDRESS" "ORACLE_ROUTER_ROLE()(bytes32)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
CLAIM_REGISTRY_ROLE=$("$CAST" call "$BOND_ESCROW_ADDRESS" "CLAIM_REGISTRY_ROLE()(bytes32)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
ORACLE_ROUTER_ROLE_BE=$("$CAST" call "$BOND_ESCROW_ADDRESS" "ORACLE_ROUTER_ROLE()(bytes32)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
ORACLE_ROUTER_ROLE_CW=$("$CAST" call "$CHALLENGE_WINDOW_ADDRESS" "ORACLE_ROUTER_ROLE()(bytes32)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
INTERNAL_VOTE_ROLE=$("$CAST" call "$ORACLE_ROUTER_ADDRESS" "INTERNAL_VOTE_ROLE()(bytes32)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
SNS_ORACLE_ROLE=$("$CAST" keccak "SNS_ORACLE_ROLE" 2>/dev/null || echo "")
MINTER_ROLE=$("$CAST" call "$PLOT_TOKEN_ADDRESS" "MINTER_ROLE()(bytes32)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
OPERATOR_ROLE=$("$CAST" keccak "OPERATOR_ROLE" 2>/dev/null || echo "")
PROPOSER_ROLE=$("$CAST" call "$TIMELOCK_ADDRESS" "PROPOSER_ROLE()(bytes32)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
EXECUTOR_ROLE=$("$CAST" call "$TIMELOCK_ADDRESS" "EXECUTOR_ROLE()(bytes32)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
CANCELLER_ROLE=$("$CAST" call "$TIMELOCK_ADDRESS" "CANCELLER_ROLE()(bytes32)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")

print_role_status() {
  local label="$1"; local result="$2"
  if [[ "$result" == "true" ]]; then
    echo "  [ALREADY] $label"
  else
    echo "  [PENDING] $label"
  fi
}

echo ""
echo "=== Current role bindings ==="
print_role_status "ClaimRegistry → NoveltyGate (NOVELTY_GATE_ROLE)"   "$(has_role "$CLAIM_REGISTRY_ADDRESS"  "$NOVELTY_GATE_ROLE"      "$NOVELTY_GATE_ADDRESS")"
print_role_status "ClaimRegistry → OracleRouter (ORACLE_ROUTER_ROLE)" "$(has_role "$CLAIM_REGISTRY_ADDRESS"  "$ORACLE_ROUTER_ROLE_CR"  "$ORACLE_ROUTER_ADDRESS")"
print_role_status "BondEscrow → ClaimRegistry (CLAIM_REGISTRY_ROLE)"  "$(has_role "$BOND_ESCROW_ADDRESS"     "$CLAIM_REGISTRY_ROLE"    "$CLAIM_REGISTRY_ADDRESS")"
print_role_status "BondEscrow → OracleRouter (ORACLE_ROUTER_ROLE)"    "$(has_role "$BOND_ESCROW_ADDRESS"     "$ORACLE_ROUTER_ROLE_BE"  "$ORACLE_ROUTER_ADDRESS")"
print_role_status "ChallengeWindow → OracleRouter (ORACLE_ROUTER_ROLE)" "$(has_role "$CHALLENGE_WINDOW_ADDRESS" "$ORACLE_ROUTER_ROLE_CW" "$ORACLE_ROUTER_ADDRESS")"
print_role_status "OracleRouter → InternalVote (INTERNAL_VOTE_ROLE)"  "$(has_role "$ORACLE_ROUTER_ADDRESS"   "$INTERNAL_VOTE_ROLE"     "$INTERNAL_VOTE_ADDRESS")"
print_role_status "NoveltyGate → SNS oracle (SNS_ORACLE_ROLE)"        "$(has_role "$NOVELTY_GATE_ADDRESS"    "$SNS_ORACLE_ROLE"        "$SNS_ORACLE_WALLET")"
print_role_status "PLOTToken → EmissionController (MINTER_ROLE)"      "$(has_role "$PLOT_TOKEN_ADDRESS"      "$MINTER_ROLE"            "$EMISSION_CONTROLLER_ADDRESS")"
print_role_status "EmissionController → operator (OPERATOR_ROLE)"     "$(has_role "$EMISSION_CONTROLLER_ADDRESS" "$OPERATOR_ROLE"     "$OPERATOR_WALLET")"
print_role_status "Timelock → Governor (PROPOSER_ROLE)"               "$(has_role "$TIMELOCK_ADDRESS"        "$PROPOSER_ROLE"          "$GOVERNOR_ADDRESS")"
print_role_status "Timelock → Governor (EXECUTOR_ROLE)"               "$(has_role "$TIMELOCK_ADDRESS"        "$EXECUTOR_ROLE"          "$GOVERNOR_ADDRESS")"
print_role_status "Timelock → Governor (CANCELLER_ROLE)"              "$(has_role "$TIMELOCK_ADDRESS"        "$CANCELLER_ROLE"         "$GOVERNOR_ADDRESS")"

# ── Dry-run mode ───────────────────────────────────────────────────────────────
if [[ "$BROADCAST" == "false" ]]; then
  echo ""
  log_info "=== DRY RUN (simulation) ==="
  cd "$CONTRACTS_DIR"
  "$FORGE" script script/WireRoles.s.sol \
    --rpc-url "$NETWORK" \
    --sender "$ADMIN_ADDRESS" \
    -vvvv
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  Dry run complete. No transactions sent."
  echo "  Re-run with --broadcast to wire roles for real."
  echo "════════════════════════════════════════════════════════════════"
  exit 0
fi

# ── Broadcast role wiring ─────────────────────────────────────────────────────
log_info "=== BROADCASTING ROLE WIRING to $NETWORK ==="
cd "$CONTRACTS_DIR"
"$FORGE" script script/WireRoles.s.sol \
  --rpc-url "$NETWORK" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv

# ── Post-wiring verification ──────────────────────────────────────────────────
echo ""
log_info "=== Verifying role bindings on-chain ==="

PASS=0; FAIL=0

verify_role() {
  local label="$1"; local contract="$2"; local role="$3"; local grantee="$4"
  local result
  result=$("$CAST" call "$contract" "hasRole(bytes32,address)(bool)" "$role" "$grantee" --rpc-url "$RPC_URL" 2>/dev/null || echo "false")
  if [[ "$result" == "true" ]]; then
    echo "  [PASS] $label"
    (( PASS++ )) || true
  else
    echo "  [FAIL] $label — hasRole returned: $result"
    (( FAIL++ )) || true
  fi
}

verify_role "ClaimRegistry.NOVELTY_GATE_ROLE → NoveltyGate"      "$CLAIM_REGISTRY_ADDRESS"      "$NOVELTY_GATE_ROLE"      "$NOVELTY_GATE_ADDRESS"
verify_role "ClaimRegistry.ORACLE_ROUTER_ROLE → OracleRouter"    "$CLAIM_REGISTRY_ADDRESS"      "$ORACLE_ROUTER_ROLE_CR"  "$ORACLE_ROUTER_ADDRESS"
verify_role "BondEscrow.CLAIM_REGISTRY_ROLE → ClaimRegistry"     "$BOND_ESCROW_ADDRESS"         "$CLAIM_REGISTRY_ROLE"    "$CLAIM_REGISTRY_ADDRESS"
verify_role "BondEscrow.ORACLE_ROUTER_ROLE → OracleRouter"       "$BOND_ESCROW_ADDRESS"         "$ORACLE_ROUTER_ROLE_BE"  "$ORACLE_ROUTER_ADDRESS"
verify_role "ChallengeWindow.ORACLE_ROUTER_ROLE → OracleRouter"  "$CHALLENGE_WINDOW_ADDRESS"    "$ORACLE_ROUTER_ROLE_CW"  "$ORACLE_ROUTER_ADDRESS"
verify_role "OracleRouter.INTERNAL_VOTE_ROLE → InternalVote"     "$ORACLE_ROUTER_ADDRESS"       "$INTERNAL_VOTE_ROLE"     "$INTERNAL_VOTE_ADDRESS"
verify_role "NoveltyGate.SNS_ORACLE_ROLE → SNS wallet"           "$NOVELTY_GATE_ADDRESS"        "$SNS_ORACLE_ROLE"        "$SNS_ORACLE_WALLET"
verify_role "PLOTToken.MINTER_ROLE → EmissionController"         "$PLOT_TOKEN_ADDRESS"          "$MINTER_ROLE"            "$EMISSION_CONTROLLER_ADDRESS"
verify_role "EmissionController.OPERATOR_ROLE → operator wallet" "$EMISSION_CONTROLLER_ADDRESS" "$OPERATOR_ROLE"          "$OPERATOR_WALLET"
verify_role "Timelock.PROPOSER_ROLE → Governor"                  "$TIMELOCK_ADDRESS"            "$PROPOSER_ROLE"          "$GOVERNOR_ADDRESS"
verify_role "Timelock.EXECUTOR_ROLE → Governor"                  "$TIMELOCK_ADDRESS"            "$EXECUTOR_ROLE"          "$GOVERNOR_ADDRESS"
verify_role "Timelock.CANCELLER_ROLE → Governor"                 "$TIMELOCK_ADDRESS"            "$CANCELLER_ROLE"         "$GOVERNOR_ADDRESS"

echo ""
if (( FAIL > 0 )); then
  log_error "$FAIL role(s) failed verification. Do not proceed. Investigate above."
  exit 1
fi
log_info "All $PASS role bindings verified on-chain."

# Mark rolesWired=true in deployment artifact
write_deployment_json "$NETWORK" ".rolesWired" "true"

# ── Admin handoff (mainnet only) ───────────────────────────────────────────────
if [[ "$ADMIN_HANDOFF" == "true" ]]; then
  require_env "GNOSIS_SAFE_ADDRESS"

  CONTRACTS_LIST=(
    "$CLAIM_REGISTRY_ADDRESS"
    "$BOND_ESCROW_ADDRESS"
    "$CHALLENGE_WINDOW_ADDRESS"
    "$ORACLE_ROUTER_ADDRESS"
    "$NOVELTY_GATE_ADDRESS"
    "$PLOT_TOKEN_ADDRESS"
    "$EMISSION_CONTROLLER_ADDRESS"
    "$CONFIDENCE_SCORER_ADDRESS"
    "$INTERNAL_VOTE_ADDRESS"
    "$TIMELOCK_ADDRESS"
    "$GOVERNOR_ADDRESS"
    "$TREASURY_ADDRESS"
  )

  DEFAULT_ADMIN_ROLE="0x0000000000000000000000000000000000000000000000000000000000000000"
  DEPLOYER_ADDR=$("$CAST" wallet address --private-key "$PRIVATE_KEY")

  log_info "=== ADMIN HANDOFF: granting DEFAULT_ADMIN_ROLE to Gnosis Safe ==="
  log_info "Safe address: $GNOSIS_SAFE_ADDRESS"

  for contract in "${CONTRACTS_LIST[@]}"; do
    log_info "  Granting DEFAULT_ADMIN_ROLE on $contract → Safe..."
    "$CAST" send "$contract" \
      "grantRole(bytes32,address)" \
      "$DEFAULT_ADMIN_ROLE" "$GNOSIS_SAFE_ADDRESS" \
      --private-key "$PRIVATE_KEY" \
      --rpc-url "$RPC_URL"
  done

  write_deployment_json "$NETWORK" ".adminHandedOff" "\"partial\""

  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  MANUAL ACTION REQUIRED — Gnosis Safe must revoke deployer"
  echo ""
  echo "  The deployer ($DEPLOYER_ADDR) still holds DEFAULT_ADMIN_ROLE"
  echo "  on all contracts. The Gnosis Safe must now sign and execute"
  echo "  revokeRole transactions to complete the handoff."
  echo ""
  echo "  For each contract below, submit a transaction from the Safe:"
  echo "  Function: revokeRole(bytes32,address)"
  echo "  Arg 0: 0x0000000000000000000000000000000000000000000000000000000000000000"
  echo "  Arg 1: $DEPLOYER_ADDR"
  echo ""
  echo "  Contracts:"
  for contract in "${CONTRACTS_LIST[@]}"; do
    echo "    $contract"
  done
  echo ""
  echo "  Open the Safe at: https://app.safe.global"
  echo "  After revoking, run: bash scripts/deploy/smoke-test.sh --network $NETWORK"
  echo "════════════════════════════════════════════════════════════════"
fi

echo ""
log_info "Phase 3 complete."
log_info "Next step: bash scripts/deploy/phase4-services.sh --network $NETWORK"
