#!/usr/bin/env bash
# Phase 1: Verify all prerequisites before any deployment.
# Exit 0 = ready to deploy. Exit non-zero = fix the listed issues first.
#
# Usage: bash scripts/deploy/phase1-prereqs.sh

set -euo pipefail
# shellcheck source=00-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

PASS=0
FAIL=0

check() {
  local label="$1"
  shift
  if "$@" &>/dev/null; then
    echo "  [PASS] $label"
    (( PASS++ )) || true
  else
    echo "  [FAIL] $label"
    (( FAIL++ )) || true
    return 0  # keep running to show all failures
  fi
}

check_version() {
  local label="$1"
  local cmd="$2"
  local min_major="$3"
  local actual
  actual=$($cmd --version 2>&1 | grep -oP '\d+\.\d+' | head -1 | cut -d. -f1) || true
  if [[ -n "$actual" ]] && (( actual >= min_major )); then
    echo "  [PASS] $label (found $($cmd --version 2>&1 | head -1))"
    (( PASS++ )) || true
  else
    echo "  [FAIL] $label — need >= $min_major.x, got: $($cmd --version 2>&1 | head -1 || echo 'not found')"
    (( FAIL++ )) || true
  fi
}

# ── Section 1: Tools ──────────────────────────────────────────────────────────
echo ""
echo "=== [1/5] Tooling ==="
check "forge exists"   test -x "$FORGE"
check "cast exists"    test -x "$CAST"
check "forge version"  "$FORGE" --version
check "cast version"   "$CAST" --version
check "pm2 exists"     test -x "$PM2"
check "pm2 version"    "$PM2" --version
check "jq installed"   command -v jq
check "curl installed" command -v curl

# Node: accept node OR bun
if command -v node &>/dev/null; then
  node_ver=$(node --version 2>&1 | grep -oP '\d+' | head -1)
  if (( node_ver >= 18 )); then
    echo "  [PASS] node >= 18 (found $(node --version))"
    (( PASS++ )) || true
  else
    echo "  [FAIL] node needs >= 18, found $(node --version)"
    (( FAIL++ )) || true
  fi
elif command -v bun &>/dev/null; then
  echo "  [PASS] bun found ($(bun --version)) — Node.js check skipped"
  (( PASS++ )) || true
else
  echo "  [FAIL] Neither node (>= 18) nor bun found"
  (( FAIL++ )) || true
fi

# Python 3.11+
if command -v python3 &>/dev/null; then
  py_minor=$(python3 --version 2>&1 | grep -oP '\d+\.\d+' | head -1 | cut -d. -f2)
  py_major=$(python3 --version 2>&1 | grep -oP '\d+' | head -1)
  if (( py_major >= 3 && py_minor >= 11 )); then
    echo "  [PASS] python3 >= 3.11 (found $(python3 --version))"
    (( PASS++ )) || true
  else
    echo "  [FAIL] python3 >= 3.11 required, found $(python3 --version)"
    (( FAIL++ )) || true
  fi
else
  echo "  [FAIL] python3 not found"
  (( FAIL++ )) || true
fi

check "pip installed" command -v pip3

# ── Section 2: Environment file ───────────────────────────────────────────────
echo ""
echo "=== [2/5] Environment Variables ==="

if [[ ! -f "$ROOT_DIR/.env" ]]; then
  echo "  [FAIL] .env not found at $ROOT_DIR/.env"
  echo ""
  echo "  ┌─ MANUAL ACTION REQUIRED ───────────────────────────────────────────"
  echo "  │  cp $ROOT_DIR/.env.example $ROOT_DIR/.env"
  echo "  │  Then fill in all required values."
  echo "  └──────────────────────────────────────────────────────────────────────"
  (( FAIL++ )) || true
else
  echo "  [PASS] .env exists"
  (( PASS++ )) || true
  load_env_file "$ROOT_DIR/.env"

  REQUIRED_VARS=(
    PRIVATE_KEY
    BASESCAN_API_KEY
    ADMIN_ADDRESS
    FOUNDATION_ADDRESS
    TREASURY_WALLET
    CHAINLINK_PLOT_USD_FEED
    VOTER_POOL_ADDRESS
    BASE_RPC_URL
    SNS_ORACLE_WALLET
    OPERATOR_WALLET
  )

  for var in "${REQUIRED_VARS[@]}"; do
    if [[ -n "${!var:-}" ]]; then
      echo "  [PASS] $var is set"
      (( PASS++ )) || true
    else
      echo "  [FAIL] $var is not set"
      (( FAIL++ )) || true
    fi
  done

  # Check deployer balance on the configured RPC
  echo ""
  echo "  Checking deployer wallet balance..."
  deployer_addr=$("$CAST" wallet address --private-key "$PRIVATE_KEY" 2>/dev/null || echo "")
  if [[ -n "$deployer_addr" ]]; then
    balance=$("$CAST" balance "$deployer_addr" --rpc-url "${BASE_RPC_URL:-https://sepolia.base.org}" 2>/dev/null || echo "0")
    echo "  [INFO] Deployer: $deployer_addr"
    echo "  [INFO] Balance:  $balance wei"
    if [[ "$balance" == "0" ]]; then
      echo ""
      echo "  ┌─ MANUAL ACTION REQUIRED ───────────────────────────────────────────"
      echo "  │  Deployer wallet has 0 balance. Fund it before deploying."
      echo "  │  Base Sepolia faucet: https://faucet.quicknode.com/base/sepolia"
      echo "  └──────────────────────────────────────────────────────────────────────"
    fi
  fi
fi

# ── Section 3: Accounts (informational reminders) ────────────────────────────
echo ""
echo "=== [3/5] Account Setup (manual checklist) ==="
echo "  [ ] Admin multisig (Gnosis Safe) created at: ${ADMIN_ADDRESS:-NOT SET}"
echo "  [ ] Foundation multisig created at:          ${FOUNDATION_ADDRESS:-NOT SET}"
echo "  [ ] SNS oracle wallet configured:            ${SNS_ORACLE_WALLET:-NOT SET}"
echo "  [ ] Operator/keeper wallet configured:       ${OPERATOR_WALLET:-NOT SET}"
echo ""
echo "  To create Gnosis Safe multisigs: https://safe.global"
echo "  BaseScan API key signup:         https://basescan.org/register"

# ── Section 4: Contract build ─────────────────────────────────────────────────
echo ""
echo "=== [4/5] Contract Build ==="
cd "$CONTRACTS_DIR"

if "$FORGE" build --silent 2>/dev/null; then
  echo "  [PASS] forge build succeeded"
  (( PASS++ )) || true
else
  echo "  [FAIL] forge build failed — run: cd contracts && forge build"
  (( FAIL++ )) || true
fi

# ── Section 5: Test suite ─────────────────────────────────────────────────────
echo ""
echo "=== [5/5] Test Suite ==="
echo "  Running forge test (this may take 30-60 seconds)..."

test_output=$("$FORGE" test 2>&1)
test_result=$?

if [[ $test_result -eq 0 ]]; then
  # Parse pass count
  pass_count=$(echo "$test_output" | grep -oP '\d+ passed' | grep -oP '\d+' | tail -1 || echo "?")
  echo "  [PASS] forge test succeeded — $pass_count tests passed"
  (( PASS++ )) || true
else
  echo "  [FAIL] forge test failed"
  echo "$test_output" | tail -20
  (( FAIL++ )) || true
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  Prerequisites: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════"
echo ""

if (( FAIL > 0 )); then
  echo "Fix the $FAIL failing checks above before proceeding."
  exit 1
fi

echo "All prerequisites satisfied. Ready to deploy."
echo "Next step: bash scripts/deploy/phase2-deploy-contracts.sh --network base_sepolia"
