#!/usr/bin/env bash
# Testnet keeper loop — runs finalize-claims.sh on a fixed interval.
# Replaces Chainlink Automation for testnet demo purposes.
#
# Usage:
#   bash scripts/keepers/run-keeper-loop.sh --network base_sepolia
#   bash scripts/keepers/run-keeper-loop.sh --network base_sepolia --interval 60

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK=""
INTERVAL=60   # seconds between keeper runs

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)  NETWORK="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    *) echo "[keeper-loop] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$NETWORK" ]] && { echo "[keeper-loop] Usage: $0 --network <base_sepolia|base_mainnet> [--interval N]" >&2; exit 1; }

echo "[keeper-loop] Starting keeper loop (network=$NETWORK, interval=${INTERVAL}s). Press Ctrl+C to stop."

run=0
while true; do
  run=$(( run + 1 ))
  echo ""
  echo "[keeper-loop] === Run #$run at $(date '+%Y-%m-%d %H:%M:%S') ==="
  bash "$SCRIPT_DIR/finalize-claims.sh" --network "$NETWORK" || true
  echo "[keeper-loop] Sleeping ${INTERVAL}s..."
  sleep "$INTERVAL"
done
