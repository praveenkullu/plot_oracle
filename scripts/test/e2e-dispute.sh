#!/usr/bin/env bash
# End-to-end adversarial claim path test.
# Submits a claim, waits for it to reach Pending, then challenges it,
# opens a vote, casts a vote, finalizes, and verifies the disputed resolution.
#
# Pre-requisites:
#   1. All 3 PM2 services running (pm2 status → all online)
#   2. Relay wallet has VOTER_ROLE on InternalVote and quorumWeight=1
#      Run: bash scripts/keepers/grant-voter-role.sh --network base_sepolia
#   3. Relay wallet has test USDC on Base Sepolia (challenger bond)
#
# Usage:
#   bash scripts/test/e2e-dispute.sh [--api-url http://localhost:3000]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
API_URL="http://localhost:3000"
INDEXER_URL="http://localhost:42069"
RPC_URL="https://sepolia.base.org"

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

if [[ -f "$ROOT_DIR/.env" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source <(grep -v '^#' "$ROOT_DIR/.env" | grep -v '^[[:space:]]*$')
  set +o allexport
fi

PASS=0; FAIL=0

ok()   { echo "  [PASS] $1"; (( PASS++ )) || true; }
fail() { echo "  [FAIL] $1"; (( FAIL++ )) || true; }

# ── 0. Pre-flight ─────────────────────────────────────────────────────────────

echo ""
echo "=== [0/6] Pre-flight checks ==="

backend_health=$(curl -fsS --max-time 5 "$API_URL/health" 2>/dev/null || echo "")
if echo "$backend_health" | grep -q '"status":"ok"'; then
  ok "Backend API healthy ($API_URL)"
else
  fail "Backend API not responding at $API_URL/health"
  exit 1
fi

indexer_status=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "$INDEXER_URL/health" 2>/dev/null || echo "000")
if [[ "$indexer_status" == "200" ]]; then
  ok "Ponder indexer healthy ($INDEXER_URL)"
else
  fail "Ponder indexer not responding at $INDEXER_URL/health (HTTP $indexer_status)"
  exit 1
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  fail "PRIVATE_KEY not set in .env"
  exit 1
fi

RELAY_ADDR=$("$CAST" wallet address "$PRIVATE_KEY" 2>/dev/null || echo "")
if [[ -z "$RELAY_ADDR" ]]; then
  fail "Could not derive relay wallet address from PRIVATE_KEY"
  exit 1
fi
echo "  Relay wallet: $RELAY_ADDR"

VOTER_ROLE=$("$CAST" keccak "VOTER_ROLE" 2>/dev/null || echo "")
has_voter=$(  "$CAST" call "$INTERNAL_VOTE_ADDRESS" "hasRole(bytes32,address)(bool)" \
              "$VOTER_ROLE" "$RELAY_ADDR" --rpc-url "$RPC_URL" 2>/dev/null || echo "false")
if [[ "$has_voter" == "true" ]]; then
  ok "Relay wallet has VOTER_ROLE on InternalVote"
else
  fail "Relay wallet lacks VOTER_ROLE — run: bash scripts/keepers/grant-voter-role.sh --network base_sepolia"
  exit 1
fi

quorum=$("$CAST" call "$INTERNAL_VOTE_ADDRESS" "quorumWeight()(uint256)" \
          --rpc-url "$RPC_URL" 2>/dev/null || echo "999")
echo "  InternalVote quorumWeight: $quorum"
if [[ "$quorum" -le 1 ]]; then
  ok "quorumWeight=1 (single voter can finalize)"
else
  fail "quorumWeight=$quorum — relay wallet weight=1 cannot reach quorum alone"
  echo "       Run: bash scripts/keepers/grant-voter-role.sh --network base_sepolia --set-quorum 1"
  exit 1
fi

# ── 1. Relay wallet USDC balance ──────────────────────────────────────────────

echo ""
echo "=== [1/6] Relay wallet USDC balance ==="

if [[ -z "${USDC_ADDRESS:-}" ]]; then
  fail "USDC_ADDRESS not set in .env"
  exit 1
fi

raw_balance=$("$CAST" call "$USDC_ADDRESS" "balanceOf(address)(uint256)" "$RELAY_ADDR" \
              --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
usdc_balance="${raw_balance%% [*}"
usdc_human=$(echo "scale=2; $usdc_balance / 1000000" | bc 2>/dev/null || echo "?")

CHALLENGER_BOND=1000000  # 1 USDC (6 decimals)

if (( usdc_balance >= CHALLENGER_BOND )); then
  ok "Relay USDC balance: $usdc_human USDC (challenger bond: 1.00 USDC)"
else
  fail "Relay wallet has insufficient USDC (need ≥1 USDC, have $usdc_human)"
  exit 1
fi

# ── 2. Submit a test claim ────────────────────────────────────────────────────

echo ""
echo "=== [2/6] Submitting test claim ==="

TIMESTAMP=$(date +%s)
CLAIM_TEXT="Adversarial dispute test ${TIMESTAMP}: claim text for e2e dispute path validation."

response=$(curl -fsS --max-time 30 \
  -X POST "$API_URL/claims" \
  -H "Content-Type: application/json" \
  -d "{
    \"claim_text\": \"$CLAIM_TEXT\",
    \"domain\": \"Science\",
    \"complexity\": \"LOW\",
    \"sources\": [\"https://en.wikipedia.org/wiki/Speed_of_light\"],
    \"submitter_address\": \"$RELAY_ADDR\"
  }" 2>/dev/null || echo "")

if [[ -z "$response" ]]; then
  fail "POST /claims returned no response"
  exit 1
fi
echo "  Response: $response"

claim_id=$(echo "$response" | grep -o '"claim_id":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
tx_hash=$(echo "$response"  | grep -o '"tx_hash":"[^"]*"'  | cut -d'"' -f4 || echo "")

if [[ -n "$claim_id" && "$claim_id" != "null" ]]; then
  ok "Claim submitted: $claim_id"
  ok "Tx hash: $tx_hash"
else
  fail "No claim_id in response"
  echo "  Full response: $response"
  exit 1
fi

# Wait for claim to become Pending and for backend to open challenge window
echo ""
echo "  Waiting for claim to reach Pending status + challenge window open..."
PENDING=false
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  sleep 6
  chain_claim=$(curl -fsS --max-time 10 "$API_URL/claims/$claim_id" 2>/dev/null || echo "")
  chain_status=$(echo "$chain_claim" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "")
  echo "  attempt $attempt/10 — status: $chain_status"
  if [[ "$chain_status" == "Pending" ]]; then
    PENDING=true
    break
  fi
  if [[ "$chain_status" == "Rejected" ]]; then
    fail "Claim unexpectedly rejected before challenge window — check backend logs"
    exit 1
  fi
done

if $PENDING; then
  ok "Claim reached Pending status"
else
  fail "Claim did not reach Pending after 60s (status: $chain_status)"
  echo "  Check: ~/.local/bin/pm2 logs plot-oracle-3000 --lines 30"
  exit 1
fi

# Verify challenge window is open on-chain
window_data=$("$CAST" call "$CHALLENGE_WINDOW_ADDRESS" \
  "getWindow(bytes32)((uint256,uint256,address,uint256,bool))" \
  "$claim_id" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
echo "  Window data: $window_data"
opened_at=$(echo "$window_data" | tr ',' '\n' | head -1 | tr -d '( )' || echo "0")
if [[ "${opened_at:-0}" != "0" && "${opened_at:-0}" != "" ]]; then
  ok "Challenge window is open on-chain"
else
  fail "Challenge window not yet open on-chain — backend may not have called openWindow()"
  echo "  Check: ~/.local/bin/pm2 logs plot-oracle-3000 --lines 30"
  exit 1
fi

# ── 3. Challenge the claim ────────────────────────────────────────────────────

echo ""
echo "=== [3/6] Challenging the claim ==="

# Approve USDC allowance to ChallengeWindow
echo "  Approving 1 USDC to ChallengeWindow ($CHALLENGE_WINDOW_ADDRESS)..."
approve_tx=$("$CAST" send "$USDC_ADDRESS" \
  "approve(address,uint256)" "$CHALLENGE_WINDOW_ADDRESS" "$CHALLENGER_BOND" \
  --private-key "$PRIVATE_KEY" \
  --rpc-url "$RPC_URL" \
  2>/dev/null | awk '/transactionHash/{print $2}' || echo "")

if [[ -n "$approve_tx" ]]; then
  ok "USDC approved: $approve_tx"
else
  fail "USDC approval failed"
  exit 1
fi

sleep 3

# Call challenge()
echo "  Calling ChallengeWindow.challenge($claim_id, $CHALLENGER_BOND)..."
challenge_tx=$("$CAST" send "$CHALLENGE_WINDOW_ADDRESS" \
  "challenge(bytes32,uint256)" "$claim_id" "$CHALLENGER_BOND" \
  --private-key "$PRIVATE_KEY" \
  --rpc-url "$RPC_URL" \
  2>/dev/null | awk '/transactionHash/{print $2}' || echo "")

if [[ -n "$challenge_tx" ]]; then
  ok "Challenge submitted: $challenge_tx"
else
  fail "challenge() tx failed — window may have expired or already challenged"
  exit 1
fi

sleep 5

# Verify status is Disputed
chain_claim=$(curl -fsS --max-time 10 "$API_URL/claims/$claim_id" 2>/dev/null || echo "")
chain_status=$(echo "$chain_claim" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "")
if [[ "$chain_status" == "Disputed" ]]; then
  ok "Claim status is Disputed"
else
  fail "Expected Disputed, got: '$chain_status'"
fi

# ── 4. Open vote + cast vote + finalize ──────────────────────────────────────

echo ""
echo "=== [4/6] Vote: open → cast → finalize ==="

# Open vote
echo "  Calling InternalVote.openVote($claim_id)..."
open_tx=$("$CAST" send "$INTERNAL_VOTE_ADDRESS" \
  "openVote(bytes32)" "$claim_id" \
  --private-key "$PRIVATE_KEY" \
  --rpc-url "$RPC_URL" \
  2>/dev/null | awk '/transactionHash/{print $2}' || echo "")

if [[ -n "$open_tx" ]]; then
  ok "Vote opened: $open_tx"
else
  fail "openVote() tx failed — claim may not be Disputed on-chain yet"
  exit 1
fi

sleep 3

# Cast vote: support=true (submitter wins — claim is valid)
echo "  Calling InternalVote.castVote($claim_id, true)..."
vote_tx=$("$CAST" send "$INTERNAL_VOTE_ADDRESS" \
  "castVote(bytes32,bool)" "$claim_id" "true" \
  --private-key "$PRIVATE_KEY" \
  --rpc-url "$RPC_URL" \
  2>/dev/null | awk '/transactionHash/{print $2}' || echo "")

if [[ -n "$vote_tx" ]]; then
  ok "Vote cast (support=true): $vote_tx"
else
  fail "castVote() tx failed"
  exit 1
fi

sleep 3

# Finalize vote
echo "  Calling InternalVote.finalizeVote($claim_id)..."
finalize_tx=$("$CAST" send "$INTERNAL_VOTE_ADDRESS" \
  "finalizeVote(bytes32)" "$claim_id" \
  --private-key "$PRIVATE_KEY" \
  --rpc-url "$RPC_URL" \
  2>/dev/null | awk '/transactionHash/{print $2}' || echo "")

if [[ -n "$finalize_tx" ]]; then
  ok "Vote finalized: $finalize_tx"
else
  fail "finalizeVote() tx failed — quorum may not be reached"
  exit 1
fi

sleep 5

# ── 5. Verify final on-chain status ──────────────────────────────────────────

echo ""
echo "=== [5/6] Verify final on-chain status ==="

chain_claim=$(curl -fsS --max-time 10 "$API_URL/claims/$claim_id" 2>/dev/null || echo "")
echo "  On-chain read: $chain_claim"
chain_status=$(echo "$chain_claim" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "")

if [[ "$chain_status" == "Verified" || "$chain_status" == "Rejected" ]]; then
  ok "Dispute resolved — final status: $chain_status"
else
  fail "Unexpected status: '$chain_status' (expected Verified or Rejected)"
fi

# ── 6. Verify in Ponder indexer ───────────────────────────────────────────────

echo ""
echo "=== [6/6] Verifying resolution in Ponder indexer ==="

INDEXED=false
for attempt in 1 2 3 4 5; do
  sleep 5
  gql_response=$(curl -fsS --max-time 10 \
    -X POST "$INDEXER_URL/graphql" \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"{claim(id:\\\"$claim_id\\\"){id status confidenceScore}}\"}" \
    2>/dev/null || echo "")
  indexed_status=$(echo "$gql_response" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "")
  if [[ "$indexed_status" == "Verified" || "$indexed_status" == "Rejected" ]]; then
    INDEXED=true
    break
  fi
  echo "  attempt $attempt/5 — indexed status: '${indexed_status:-not found}', waiting..."
done

if $INDEXED; then
  ok "Dispute resolution indexed in Ponder: $indexed_status"
  echo "  GraphQL response: $gql_response"
else
  fail "Claim not showing resolved status in Ponder after 25s"
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
echo "Adversarial claim path: OK"
