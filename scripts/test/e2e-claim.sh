#!/usr/bin/env bash
# End-to-end claim flow test.
# Submits a claim via the backend API and verifies it appears in the Ponder indexer.
#
# Pre-requisites:
#   1. All 3 PM2 services are running (pm2 status → all online)
#   2. Relay wallet (PRIVATE_KEY in .env) has test USDC on Base Sepolia
#      Faucet: https://faucet.circle.com  (select "Base Sepolia", token "USDC")
#
# Usage:
#   bash scripts/test/e2e-claim.sh [--api-url http://localhost:3000]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
API_URL="http://localhost:3000"
INDEXER_URL="http://localhost:42069"
CAST="${CAST:-}"
[[ -z "$CAST" ]] && CAST=$(command -v cast 2>/dev/null || echo "")
[[ -z "$CAST" ]] && CAST=$(ls "$HOME"/.config/.foundry/bin/cast "$HOME"/.foundry/bin/cast 2>/dev/null | head -1 || echo "")
[[ -z "$CAST" ]] && { echo "[error] cast not found. Install Foundry: https://getfoundry.sh"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-url) API_URL="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# Load .env for RPC and addresses
if [[ -f "$ROOT_DIR/.env" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source <(grep -v '^#' "$ROOT_DIR/.env" | grep -v '^[[:space:]]*$')
  set +o allexport
fi

PASS=0; FAIL=0

ok()   { echo "  [PASS] $1"; (( PASS++ )) || true; }
fail() { echo "  [FAIL] $1"; (( FAIL++ )) || true; }

# ── 0. Pre-flight: check service health ──────────────────────────────────────

echo ""
echo "=== [0/4] Pre-flight checks ==="

backend_health=$(curl -fsS --max-time 5 "$API_URL/health" 2>/dev/null || echo "")
if echo "$backend_health" | grep -q '"status":"ok"'; then
  ok "Backend API healthy ($API_URL)"
else
  fail "Backend API not responding at $API_URL/health"
  echo "       Run: ~/.local/bin/pm2 status"
  exit 1
fi

indexer_status=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "$INDEXER_URL/health" 2>/dev/null || echo "000")
if [[ "$indexer_status" == "200" ]]; then
  ok "Ponder indexer healthy ($INDEXER_URL)"
else
  fail "Ponder indexer not responding at $INDEXER_URL/health (HTTP $indexer_status)"
  exit 1
fi

# ── 1. Check relay wallet USDC balance ───────────────────────────────────────

echo ""
echo "=== [1/4] Relay wallet USDC balance ==="

if [[ -z "${USDC_ADDRESS:-}" ]]; then
  fail "USDC_ADDRESS not set in .env"
  exit 1
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  fail "PRIVATE_KEY not set in .env (relay signer required)"
  exit 1
fi

RPC_URL="${BASE_RPC_URL:-https://sepolia.base.org}"
RELAY_ADDR=$("$CAST" wallet address "$PRIVATE_KEY" 2>/dev/null || echo "")
if [[ -z "$RELAY_ADDR" ]]; then
  fail "Could not derive relay wallet address from PRIVATE_KEY"
  exit 1
fi

echo "  Relay wallet: $RELAY_ADDR"

raw_balance=$("$CAST" call "$USDC_ADDRESS" "balanceOf(address)(uint256)" "$RELAY_ADDR" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
# strip cast annotation "123 [1.23e5]"
usdc_balance="${raw_balance%% [*}"
usdc_human=$(echo "scale=2; $usdc_balance / 1000000" | bc 2>/dev/null || echo "?")

if (( usdc_balance > 0 )); then
  ok "Relay USDC balance: $usdc_human USDC ($usdc_balance raw)"
else
  fail "Relay wallet has 0 USDC on Base Sepolia"
  echo ""
  echo "  Get test USDC from the Circle faucet:"
  echo "    https://faucet.circle.com  (select Base Sepolia, token USDC)"
  echo "    Address: $RELAY_ADDR"
  echo ""
  exit 1
fi

# ── 2. Submit a test claim ────────────────────────────────────────────────────

echo ""
echo "=== [2/4] Submitting test claim ==="

TIMESTAMP=$(date +%s)
CLAIM_TEXT="Test claim submitted by e2e-claim.sh at ${TIMESTAMP}. The boiling point of water at sea level is 100 degrees Celsius."

response=$(curl -fsS --max-time 30 \
  -X POST "$API_URL/claims" \
  -H "Content-Type: application/json" \
  -d "{
    \"claim_text\": \"$CLAIM_TEXT\",
    \"domain\": \"Science\",
    \"complexity\": \"LOW\",
    \"sources\": [\"https://en.wikipedia.org/wiki/Boiling_point\"],
    \"submitter_address\": \"$RELAY_ADDR\"
  }" 2>/dev/null || echo "")

if [[ -z "$response" ]]; then
  fail "POST /claims returned no response (timeout or connection refused)"
  exit 1
fi

echo "  Response: $response"

claim_id=$(echo "$response" | grep -o '"claim_id":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
tx_hash=$(echo "$response" | grep -o '"tx_hash":"[^"]*"' | cut -d'"' -f4 || echo "")
bond_required=$(echo "$response" | grep -o '"bond_required":"[^"]*"' | cut -d'"' -f4 || echo "")

if [[ -n "$claim_id" && "$claim_id" != "null" ]]; then
  ok "Claim submitted: $claim_id"
  ok "Tx hash: $tx_hash"
  bond_human=$(echo "scale=2; ${bond_required:-0} / 1000000" | bc 2>/dev/null || echo "?")
  echo "  Bond locked: $bond_human USDC"
else
  fail "No claim_id in response"
  echo "  Full response: $response"
  exit 1
fi

# ── 3. Verify on-chain (direct read) ─────────────────────────────────────────

echo ""
echo "=== [3/4] Verifying claim on-chain ==="

sleep 3  # let the tx settle

chain_claim=$(curl -fsS --max-time 10 "$API_URL/claims/$claim_id" 2>/dev/null || echo "")
echo "  On-chain read: $chain_claim"

chain_status=$(echo "$chain_claim" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "")
if [[ "$chain_status" == "Submitted" || "$chain_status" == "Pending" || "$chain_status" == "Rejected" ]]; then
  ok "On-chain status: $chain_status"
else
  fail "Unexpected on-chain status: '$chain_status' (expected 'Submitted', 'Pending', or 'Rejected')"
fi

# ── 4. Verify in Ponder indexer ───────────────────────────────────────────────

echo ""
echo "=== [4/4] Verifying claim in Ponder indexer ==="

# Ponder may need a few seconds to index the new block
INDEXED=false
for attempt in 1 2 3 4 5; do
  sleep 5
  gql_response=$(curl -fsS --max-time 10 \
    -X POST "$INDEXER_URL/graphql" \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"{claim(id:\\\"$claim_id\\\"){id status submitter}}\"}" \
    2>/dev/null || echo "")
  indexed_id=$(echo "$gql_response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
  if [[ "$indexed_id" == "$claim_id" ]]; then
    INDEXED=true
    break
  fi
  echo "  attempt $attempt/5 — not yet indexed, waiting..."
done

if $INDEXED; then
  ok "Claim indexed in Ponder: $claim_id"
  echo "  GraphQL response: $gql_response"
else
  fail "Claim not found in Ponder after 25s — indexer may still be syncing"
  echo "  Run: curl -s -X POST $INDEXER_URL/graphql -H 'Content-Type: application/json'"
  echo "       -d '{\"query\":\"{claim(id:\\\"$claim_id\\\"){id status}}\"}'"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=============================="
echo "  PASS: $PASS  FAIL: $FAIL"
echo "=============================="

if (( FAIL > 0 )); then
  echo ""
  echo "Troubleshoot with:"
  echo "  ~/.local/bin/pm2 logs plot-oracle-3000 --lines 50"
  echo "  ~/.local/bin/pm2 logs plot-oracle-42069 --lines 50"
  exit 1
fi

echo ""
echo "End-to-end claim flow: OK"
