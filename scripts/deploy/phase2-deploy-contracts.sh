#!/usr/bin/env bash
# Phase 2: Deploy all 13 Plot Protocol contracts to Base Sepolia or Base Mainnet.
# Defaults to dry-run (simulation). Pass --broadcast to actually send transactions.
#
# Usage:
#   bash scripts/deploy/phase2-deploy-contracts.sh --network base_sepolia
#   bash scripts/deploy/phase2-deploy-contracts.sh --network base_sepolia --broadcast

set -euo pipefail
# shellcheck source=00-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

# ── Argument parsing ──────────────────────────────────────────────────────────
NETWORK=""
BROADCAST=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)   NETWORK="$2"; shift 2 ;;
    --broadcast) BROADCAST=true; shift ;;
    *) log_error "Unknown argument: $1"; exit 1 ;;
  esac
done

[[ -z "$NETWORK" ]] && { log_error "Usage: $0 --network <base_sepolia|base_mainnet> [--broadcast]"; exit 1; }
CHAIN_ID=$(network_to_chain_id "$NETWORK")

# ── Load environment ──────────────────────────────────────────────────────────
load_env_file "$ROOT_DIR/.env"

REQUIRED_VARS=(PRIVATE_KEY BASESCAN_API_KEY ADMIN_ADDRESS FOUNDATION_ADDRESS
               TREASURY_WALLET VOTER_POOL_ADDRESS CHAINLINK_PLOT_USD_FEED)
for var in "${REQUIRED_VARS[@]}"; do require_env "$var"; done

# ── Confirm contracts build cleanly ──────────────────────────────────────────
log_info "Building contracts..."
cd "$CONTRACTS_DIR"
"$FORGE" build --silent

# ── Dry run ───────────────────────────────────────────────────────────────────
log_info "=== DRY RUN (simulation) ==="
"$FORGE" script script/Deploy.s.sol \
  --rpc-url "$NETWORK" \
  --sender "$ADMIN_ADDRESS" \
  -vvvv

if [[ "$BROADCAST" == "false" ]]; then
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  Dry run complete. No transactions sent."
  echo "  Review the simulation above, then re-run with --broadcast"
  echo "  to deploy for real."
  echo "════════════════════════════════════════════════════════════════"
  exit 0
fi

# ── Broadcast ─────────────────────────────────────────────────────────────────
log_info "=== BROADCASTING DEPLOYMENT to $NETWORK ==="

FORGE_ARGS=(
  script script/Deploy.s.sol
  --rpc-url "$NETWORK"
  --private-key "$PRIVATE_KEY"
  --broadcast
  --verify
  --etherscan-api-key "$BASESCAN_API_KEY"
  -vvvv
)

# --slow sends one tx at a time (safer, required on mainnet)
if [[ "$NETWORK" == "base_mainnet" ]]; then
  FORGE_ARGS+=(--slow)
fi

"$FORGE" "${FORGE_ARGS[@]}"

# ── Parse broadcast output and write deployments/<network>.json ───────────────
log_info "Parsing broadcast artifacts..."

BROADCAST_FILE="$CONTRACTS_DIR/broadcast/Deploy.s.sol/${CHAIN_ID}/run-latest.json"

if [[ ! -f "$BROADCAST_FILE" ]]; then
  log_error "Broadcast file not found: $BROADCAST_FILE"
  log_error "Did forge script succeed with --broadcast?"
  exit 1
fi

mkdir -p "$DEPLOYMENTS_DIR"
DEPLOYMENT_FILE="$DEPLOYMENTS_DIR/${NETWORK}.json"

DEPLOYER_ADDR=$("$CAST" wallet address --private-key "$PRIVATE_KEY")
DEPLOY_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Build JSON with all CREATE transactions
python3 - "$BROADCAST_FILE" "$DEPLOYMENT_FILE" "$NETWORK" "$CHAIN_ID" "$DEPLOYER_ADDR" "$DEPLOY_TIME" <<'PYEOF'
import sys, json

broadcast_file, output_file, network, chain_id, deployer, deploy_time = sys.argv[1:]

with open(broadcast_file) as f:
    data = json.load(f)

contracts = {}
for tx in data.get("transactions", []):
    if tx.get("transactionType") == "CREATE" and tx.get("contractName"):
        name = tx["contractName"]
        contracts[name] = {
            "address": tx["contractAddress"],
            "txHash":  tx["hash"],
            "verified": False
        }

# Try to read existing file to preserve rolesWired / adminHandedOff flags
try:
    with open(output_file) as f:
        existing = json.load(f)
    roles_wired     = existing.get("rolesWired", False)
    admin_handed_off = existing.get("adminHandedOff", False)
except Exception:
    roles_wired     = False
    admin_handed_off = False

output = {
    "network":        network,
    "chainId":        int(chain_id),
    "deployedAt":     deploy_time,
    "deployer":       deployer,
    "contracts":      contracts,
    "rolesWired":     roles_wired,
    "adminHandedOff": admin_handed_off,
}

with open(output_file, "w") as f:
    json.dump(output, f, indent=2)

print(f"Wrote {len(contracts)} contracts to {output_file}")
PYEOF

log_info "Deployment artifact: $DEPLOYMENT_FILE"
log_info ""
log_info "Deployed contracts:"
jq -r '.contracts | to_entries[] | "  \(.key): \(.value.address)"' "$DEPLOYMENT_FILE"

# ── BaseScan verification fallback instructions ────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  If any contract shows 'failed to verify' above, you can"
echo "  re-run verification manually using the tx hashes below:"
echo ""
jq -r '.contracts | to_entries[] | "  forge verify-contract \(.value.address) \(.key) --chain-id '"$CHAIN_ID"' --etherscan-api-key $BASESCAN_API_KEY"' "$DEPLOYMENT_FILE"
echo "════════════════════════════════════════════════════════════════"

log_info ""
log_info "Phase 2 complete."
log_info "Next step: bash scripts/deploy/phase3-wire-roles.sh --network $NETWORK --broadcast"
