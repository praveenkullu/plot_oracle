#!/usr/bin/env bash
# Phase 5: Deploy to Base Mainnet with full pre-flight safety gates.
# This script wraps Phases 2–4 with extra checks specific to mainnet.
#
# Usage:
#   bash scripts/deploy/phase5-mainnet.sh --confirm-mainnet
#   bash scripts/deploy/phase5-mainnet.sh --confirm-mainnet --ledger
#
# The --confirm-mainnet flag is required and will trigger an interactive prompt.
# The --ledger flag swaps --private-key for --ledger in all forge commands.

set -euo pipefail
# shellcheck source=00-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

CONFIRM_MAINNET=false
USE_LEDGER=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm-mainnet) CONFIRM_MAINNET=true; shift ;;
    --ledger)          USE_LEDGER=true; shift ;;
    *) log_error "Unknown argument: $1"; exit 1 ;;
  esac
done

if [[ "$CONFIRM_MAINNET" == "false" ]]; then
  echo ""
  echo "  ╔══════════════════════════════════════════════════════════════════╗"
  echo "  ║  MAINNET DEPLOYMENT REQUIRES: --confirm-mainnet                 ║"
  echo "  ║                                                                  ║"
  echo "  ║  This script deploys REAL contracts with REAL funds.            ║"
  echo "  ║  There is no undo. Add --confirm-mainnet to proceed.            ║"
  echo "  ╚══════════════════════════════════════════════════════════════════╝"
  echo ""
  exit 1
fi

load_env_file "$ROOT_DIR/.env"

PASS=0; FAIL=0

preflight_pass() { echo "  [PASS] $*"; (( PASS++ )) || true; }
preflight_fail() { echo "  [FAIL] $*"; (( FAIL++ )) || true; }

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "   PLOT ORACLE — MAINNET PRE-FLIGHT CHECKLIST"
echo "═══════════════════════════════════════════════════════════════"

# ── 1. All tests pass ─────────────────────────────────────────────────────────
echo ""
echo "[1] Full test suite (forge test + fuzz 10000 runs)..."
cd "$CONTRACTS_DIR"
if "$FORGE" test --fuzz-runs 10000 --silent 2>/dev/null; then
  preflight_pass "forge test --fuzz-runs 10000 passed"
else
  preflight_fail "forge test failed — do not deploy"
fi

# ── 2. No compiler warnings ───────────────────────────────────────────────────
echo ""
echo "[2] Compiler warnings check..."
build_output=$("$FORGE" build 2>&1)
if echo "$build_output" | grep -qi "warning"; then
  preflight_fail "forge build produced warnings — review before mainnet"
  echo "$build_output" | grep -i "warning" | head -10
else
  preflight_pass "No compiler warnings"
fi

# ── 3. Testnet deployment artifact exists ────────────────────────────────────
echo ""
echo "[3] Testnet deployment artifact..."
SEPOLIA_FILE="$DEPLOYMENTS_DIR/base-sepolia.json"
# Also accept base_sepolia.json (underscore variant)
[[ ! -f "$SEPOLIA_FILE" ]] && SEPOLIA_FILE="$DEPLOYMENTS_DIR/base_sepolia.json"

if [[ -f "$SEPOLIA_FILE" ]]; then
  roles_wired=$(jq -r '.rolesWired' "$SEPOLIA_FILE" 2>/dev/null || echo "false")
  if [[ "$roles_wired" == "true" ]]; then
    preflight_pass "Sepolia deployment found with rolesWired=true"
  else
    preflight_fail "Sepolia deployment exists but rolesWired=false (run phase3 on testnet first)"
  fi
else
  preflight_fail "No Sepolia deployment found — complete testnet deployment before mainnet"
fi

# ── 4. Admin address is a contract (multisig), not an EOA ────────────────────
echo ""
echo "[4] Admin address is a contract (Safe)..."
require_env "ADMIN_ADDRESS"
admin_code=$("$CAST" code "$ADMIN_ADDRESS" --rpc-url base_mainnet 2>/dev/null || echo "")
if [[ -n "$admin_code" && "$admin_code" != "0x" ]]; then
  preflight_pass "ADMIN_ADDRESS ($ADMIN_ADDRESS) is a contract"
else
  preflight_fail "ADMIN_ADDRESS ($ADMIN_ADDRESS) is an EOA — must be a Gnosis Safe for mainnet"
fi

# ── 5. Foundation address is a contract (multisig) ────────────────────────────
echo ""
echo "[5] Foundation address is a contract (Safe)..."
require_env "FOUNDATION_ADDRESS"
foundation_code=$("$CAST" code "$FOUNDATION_ADDRESS" --rpc-url base_mainnet 2>/dev/null || echo "")
if [[ -n "$foundation_code" && "$foundation_code" != "0x" ]]; then
  preflight_pass "FOUNDATION_ADDRESS ($FOUNDATION_ADDRESS) is a contract"
else
  preflight_fail "FOUNDATION_ADDRESS ($FOUNDATION_ADDRESS) is an EOA — must be a 3-of-5 Gnosis Safe"
fi

# ── 6. Chainlink price feed responds ─────────────────────────────────────────
echo ""
echo "[6] Chainlink price feed ($CHAINLINK_PLOT_USD_FEED)..."
require_env "CHAINLINK_PLOT_USD_FEED"
feed_result=$("$CAST" call "$CHAINLINK_PLOT_USD_FEED" "latestRoundData()(uint80,int256,uint256,uint256,uint80)" \
  --rpc-url base_mainnet 2>/dev/null | head -1 || echo "")
if [[ -n "$feed_result" ]]; then
  preflight_pass "Chainlink feed responds: $feed_result"
else
  preflight_fail "Chainlink feed at $CHAINLINK_PLOT_USD_FEED does not respond"
  echo ""
  echo "  ┌─ NOTE ────────────────────────────────────────────────────────────"
  echo "  │  PLOT/USD feed must be registered at https://data.chain.link"
  echo "  │  after PLOTToken is deployed. Use the ETH/USD placeholder until"
  echo "  │  the PLOT feed is live: 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70"
  echo "  └──────────────────────────────────────────────────────────────────"
fi

# ── 7. Deployer balance ───────────────────────────────────────────────────────
echo ""
echo "[7] Deployer wallet balance..."
if [[ "$USE_LEDGER" == "false" ]]; then
  require_env "PRIVATE_KEY"
  deployer=$("$CAST" wallet address --private-key "$PRIVATE_KEY")
else
  deployer=$("$CAST" wallet address --ledger 2>/dev/null || echo "")
fi
balance=$("$CAST" balance "$deployer" --rpc-url base_mainnet 2>/dev/null || echo "0")
# Require at least 0.05 ETH (50000000000000000 wei) for gas
if (( balance > 50000000000000000 )); then
  preflight_pass "Deployer ($deployer) has sufficient ETH: $balance wei"
else
  preflight_fail "Deployer ($deployer) has insufficient ETH: $balance wei (need > 0.05 ETH)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "   Pre-flight: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════════════"
echo ""

if (( FAIL > 0 )); then
  log_error "$FAIL pre-flight check(s) failed. Fix all issues before deploying to mainnet."
  exit 1
fi

# ── Interactive confirmation ───────────────────────────────────────────────────
echo "  All pre-flight checks passed."
echo ""
echo "  Mainnet governor parameters:"
echo "    GOVERNOR_VOTING_DELAY  = ${GOVERNOR_VOTING_DELAY:-172800} blocks"
echo "    GOVERNOR_VOTING_PERIOD = ${GOVERNOR_VOTING_PERIOD:-1209600} blocks"
echo "    GOVERNOR_PROP_THRESHOLD= ${GOVERNOR_PROP_THRESHOLD:-10000} PLOT"
echo "    GOVERNOR_QUORUM_NUM    = ${GOVERNOR_QUORUM_NUM:-4}%"
echo "    TIMELOCK_DELAY         = ${TIMELOCK_DELAY:-172800} seconds (2 days)"
echo ""
echo "  You are about to deploy to BASE MAINNET."
echo "  This will spend real ETH and cannot be undone."
echo ""
printf "  Type exactly 'DEPLOY MAINNET' to continue: "
read -r confirmation

if [[ "$confirmation" != "DEPLOY MAINNET" ]]; then
  echo "  Aborted."
  exit 1
fi

# ── Set mainnet defaults if not in .env ──────────────────────────────────────
export GOVERNOR_VOTING_DELAY="${GOVERNOR_VOTING_DELAY:-172800}"
export GOVERNOR_VOTING_PERIOD="${GOVERNOR_VOTING_PERIOD:-1209600}"
export GOVERNOR_PROP_THRESHOLD="${GOVERNOR_PROP_THRESHOLD:-10000}"
export GOVERNOR_QUORUM_NUM="${GOVERNOR_QUORUM_NUM:-4}"
export TIMELOCK_DELAY="${TIMELOCK_DELAY:-172800}"
export USDC_ADDRESS="${USDC_ADDRESS:-0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913}"  # Base Mainnet USDC

# ── Inject --ledger into forge if requested ───────────────────────────────────
if [[ "$USE_LEDGER" == "true" ]]; then
  export FORGE_LEDGER=true
  log_warn "Ledger mode enabled. Forge commands will use --ledger instead of --private-key."
  log_warn "Confirm each transaction on your hardware wallet when prompted."

  # Patch PRIVATE_KEY to be empty (forge will error if both are passed)
  unset PRIVATE_KEY

  # Override forge call in phases via env var that phase scripts check
  export FORGE_EXTRA_ARGS="--ledger"
else
  export FORGE_EXTRA_ARGS="--private-key ${PRIVATE_KEY}"
fi

# ── Run phase 2: deploy contracts ─────────────────────────────────────────────
log_info "=== Running Phase 2: Deploy Contracts (mainnet) ==="
bash "$SCRIPTS_DIR/deploy/phase2-deploy-contracts.sh" --network base_mainnet --broadcast

# ── Run phase 3: wire roles ───────────────────────────────────────────────────
log_info "=== Running Phase 3: Wire Roles (mainnet) ==="
bash "$SCRIPTS_DIR/deploy/phase3-wire-roles.sh" --network base_mainnet --broadcast

# ── Run smoke tests ───────────────────────────────────────────────────────────
log_info "=== Running Smoke Tests (mainnet) ==="
bash "$SCRIPTS_DIR/deploy/smoke-test.sh" --network base_mainnet

# ── Run phase 4: services ─────────────────────────────────────────────────────
log_info "=== Running Phase 4: Services ==="
bash "$SCRIPTS_DIR/deploy/phase4-services.sh" --network base_mainnet

# ── Post-deploy manual actions ────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "  MAINNET DEPLOYMENT COMPLETE"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""
echo "  MANUAL ACTIONS REQUIRED:"
echo ""
echo "  1. Admin handoff (CRITICAL — do this immediately):"
echo "     Run: bash scripts/deploy/phase3-wire-roles.sh \\"
echo "            --network base_mainnet --broadcast --admin-handoff"
echo "     Then: Gnosis Safe ($ADMIN_ADDRESS) must sign revokeRole txns"
echo "     for the deployer on all 13 contracts."
echo ""
echo "  2. Register Chainlink Automation upkeeps:"
echo "     URL: https://automation.chain.link"
echo "     Network: Base Mainnet"
echo "     Upkeep 1 — EmissionController: recordSnapshot24h() daily, recordSnapshot7d() weekly"
echo "     Upkeep 2 — EmissionController: checkCircuitBreaker() hourly"
echo "     Funding: ~10 LINK for snapshots, ~50 LINK for circuit breaker"
echo ""
echo "  3. Register PLOT/USD Chainlink data feed:"
echo "     URL: https://data.chain.link"
echo "     The placeholder ETH/USD feed is currently set."
echo "     After PLOT feed is live, call via governance:"
echo "       EmissionController.setPriceFeed(<new_feed_address>)"
echo ""
echo "  4. Fund operator/keeper wallet with ETH for daily gas"
echo "     Wallet: $OPERATOR_WALLET"
echo ""
echo "  5. Set up Qdrant production cluster or Qdrant Cloud"
echo "     Update .env: QDRANT_IN_MEMORY=false, QDRANT_HOST=<host>"
echo ""
echo "  See docs/deployment/04-post-deploy-setup.md for full details."
echo "═══════════════════════════════════════════════════════════════════════"
