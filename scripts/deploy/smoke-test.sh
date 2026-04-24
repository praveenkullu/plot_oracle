#!/usr/bin/env bash
# Smoke test: verify key on-chain invariants after deployment.
# All checks are read-only (cast call). No transactions sent.
#
# Usage:
#   bash scripts/deploy/smoke-test.sh --network base_sepolia
#   bash scripts/deploy/smoke-test.sh --network base_mainnet

set -euo pipefail
# shellcheck source=00-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"
# shellcheck source=addresses.sh
source "$(dirname "${BASH_SOURCE[0]}")/addresses.sh"

# ── Argument parsing ──────────────────────────────────────────────────────────
NETWORK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --network) NETWORK="$2"; shift 2 ;;
    *) log_error "Unknown argument: $1"; exit 1 ;;
  esac
done
[[ -z "$NETWORK" ]] && { log_error "Usage: $0 --network <base_sepolia|base_mainnet>"; exit 1; }

load_env_file "$ROOT_DIR/.env"
export_all_addresses "$NETWORK"

PASS=0; FAIL=0

check_eq() {
  local label="$1"; local actual="$2"; local expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  [PASS] $label"
    echo "         expected: $expected"
    (( PASS++ )) || true
  else
    echo "  [FAIL] $label"
    echo "         expected: $expected"
    echo "         actual:   $actual"
    (( FAIL++ )) || true
  fi
}

check_nonzero() {
  local label="$1"; local actual="$2"
  if [[ -n "$actual" && "$actual" != "0" && "$actual" != "null" ]]; then
    echo "  [PASS] $label = $actual"
    (( PASS++ )) || true
  else
    echo "  [FAIL] $label is zero or empty"
    (( FAIL++ )) || true
  fi
}

check_gt() {
  local label="$1"; local actual="$2"; local min="$3"
  if (( actual > min )); then
    echo "  [PASS] $label = $actual (> $min)"
    (( PASS++ )) || true
  else
    echo "  [FAIL] $label = $actual (must be > $min)"
    (( FAIL++ )) || true
  fi
}

echo ""
echo "=== Plot Protocol Smoke Tests ($NETWORK) ==="

# PLOTToken
echo ""
echo "--- PLOTToken ($PLOT_TOKEN_ADDRESS) ---"
max_supply=$("$CAST" call "$PLOT_TOKEN_ADDRESS" "MAX_SUPPLY()(uint256)" --rpc-url "$NETWORK" 2>/dev/null || echo "0")
check_eq "PLOTToken.MAX_SUPPLY" "$max_supply" "1000000000000000000000000000"  # 1B * 1e18

treasury_balance=$("$CAST" call "$PLOT_TOKEN_ADDRESS" "balanceOf(address)(uint256)" "$TREASURY_WALLET" --rpc-url "$NETWORK" 2>/dev/null || echo "0")
check_eq "Treasury received 200M PLOT" "$treasury_balance" "200000000000000000000000000"

# EmissionController
echo ""
echo "--- EmissionController ($EMISSION_CONTROLLER_ADDRESS) ---"
rate=$("$CAST" call "$EMISSION_CONTROLLER_ADDRESS" "currentRateBps()(uint256)" --rpc-url "$NETWORK" 2>/dev/null || echo "0")
check_eq "EmissionController.currentRateBps (Year 0 = 100%)" "$rate" "10000"

# Treasury
echo ""
echo "--- Treasury ($TREASURY_ADDRESS) ---"
veto_expires=$("$CAST" call "$TREASURY_ADDRESS" "vetoExpiresAt()(uint256)" --rpc-url "$NETWORK" 2>/dev/null || echo "0")
now=$(date +%s)
veto_min=$(( now + 729 * 86400 ))   # must be at least 729 days out (allow 1-day drift)
check_gt "Treasury.vetoExpiresAt (~730 days from deploy)" "$veto_expires" "$veto_min"

# GovernorPlot
echo ""
echo "--- GovernorPlot ($GOVERNOR_ADDRESS) ---"
gov_name=$("$CAST" call "$GOVERNOR_ADDRESS" "name()(string)" --rpc-url "$NETWORK" 2>/dev/null || echo "")
check_eq "Governor.name" "$gov_name" "GovernorPlot"

# Role bindings
echo ""
echo "--- Role Bindings ---"
has_role_check() {
  local label="$1"; local contract="$2"; local role="$3"; local grantee="$4"
  local result
  result=$("$CAST" call "$contract" "hasRole(bytes32,address)(bool)" "$role" "$grantee" --rpc-url "$NETWORK" 2>/dev/null || echo "false")
  check_eq "$label" "$result" "true"
}

NOVELTY_GATE_ROLE=$("$CAST" call "$CLAIM_REGISTRY_ADDRESS" "NOVELTY_GATE_ROLE()(bytes32)" --rpc-url "$NETWORK" 2>/dev/null || echo "")
ORACLE_ROUTER_ROLE=$("$CAST" call "$CLAIM_REGISTRY_ADDRESS" "ORACLE_ROUTER_ROLE()(bytes32)" --rpc-url "$NETWORK" 2>/dev/null || echo "")
MINTER_ROLE=$("$CAST" call "$PLOT_TOKEN_ADDRESS" "MINTER_ROLE()(bytes32)" --rpc-url "$NETWORK" 2>/dev/null || echo "")

[[ -n "$NOVELTY_GATE_ROLE" ]]  && has_role_check "ClaimRegistry.NOVELTY_GATE_ROLE → NoveltyGate"      "$CLAIM_REGISTRY_ADDRESS" "$NOVELTY_GATE_ROLE"  "$NOVELTY_GATE_ADDRESS"
[[ -n "$ORACLE_ROUTER_ROLE" ]] && has_role_check "ClaimRegistry.ORACLE_ROUTER_ROLE → OracleRouter"    "$CLAIM_REGISTRY_ADDRESS" "$ORACLE_ROUTER_ROLE" "$ORACLE_ROUTER_ADDRESS"
[[ -n "$MINTER_ROLE" ]]        && has_role_check "PLOTToken.MINTER_ROLE → EmissionController"         "$PLOT_TOKEN_ADDRESS"     "$MINTER_ROLE"        "$EMISSION_CONTROLLER_ADDRESS"

# Contract addresses non-zero
echo ""
echo "--- Contract Addresses Non-Zero ---"
for name in PLOT_TOKEN BOND_CALCULATOR BOND_ESCROW CLAIM_REGISTRY NOVELTY_GATE \
            CHALLENGE_WINDOW CONFIDENCE_SCORER ORACLE_ROUTER INTERNAL_VOTE \
            EMISSION_CONTROLLER TIMELOCK GOVERNOR TREASURY; do
  var="${name}_ADDRESS"
  check_nonzero "$var" "${!var:-}"
done

# Summary
echo ""
echo "════════════════════════════════════════"
echo "  Smoke tests: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════"
echo ""

if (( FAIL > 0 )); then
  log_error "$FAIL test(s) failed. Investigate before proceeding."
  exit 1
fi

log_info "All smoke tests passed."
