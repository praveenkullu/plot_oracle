#!/usr/bin/env bash
# Phase 4: Inject deployed contract addresses into .env, install service deps,
# start PM2 services, and verify health endpoints.
#
# Usage:
#   bash scripts/deploy/phase4-services.sh --network base_sepolia
#   bash scripts/deploy/phase4-services.sh --network base_sepolia --start-qdrant

set -euo pipefail
# shellcheck source=00-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"
# shellcheck source=addresses.sh
source "$(dirname "${BASH_SOURCE[0]}")/addresses.sh"

# ── Argument parsing ──────────────────────────────────────────────────────────
NETWORK=""
START_QDRANT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)      NETWORK="$2"; shift 2 ;;
    --start-qdrant) START_QDRANT=true; shift ;;
    *) log_error "Unknown argument: $1"; exit 1 ;;
  esac
done

[[ -z "$NETWORK" ]] && { log_error "Usage: $0 --network <base_sepolia|base_mainnet> [--start-qdrant]"; exit 1; }

load_env_file "$ROOT_DIR/.env"

# ── Step 1: Inject contract addresses into .env ───────────────────────────────
echo ""
log_info "=== [1/4] Injecting contract addresses into .env ==="
inject_addresses_into_env "$NETWORK" "$ROOT_DIR/.env"

# Reload env so rest of script sees new values
load_env_file "$ROOT_DIR/.env"

# ── Step 2: Check PM2-managed service directories ────────────────────────────
echo ""
log_info "=== [2/4] Service directory check ==="

SERVICES_PRESENT=()
SERVICES_MISSING=()

declare -A SERVICE_DIRS=(
  [plot-oracle-3000]="$ROOT_DIR/backend"
  [plot-oracle-8000]="$ROOT_DIR/services/sns"
  [plot-oracle-42069]="$ROOT_DIR/indexer"
)

for name in "${!SERVICE_DIRS[@]}"; do
  dir="${SERVICE_DIRS[$name]}"
  if [[ -d "$dir" ]]; then
    log_info "  [PRESENT] $name → $dir"
    SERVICES_PRESENT+=("$name")
  else
    log_warn ""
    log_warn "  ╔══════════════════════════════════════════════════════════════╗"
    log_warn "  ║  [DORMANT] PM2 app '$name' directory not found:             ║"
    log_warn "  ║  $dir"
    log_warn "  ║                                                              ║"
    log_warn "  ║  This service is listed in ecosystem.config.cjs but not yet ║"
    log_warn "  ║  implemented. PM2 will fail to start it.                    ║"
    log_warn "  ║  This script will skip it — fix ecosystem.config.cjs or     ║"
    log_warn "  ║  create the directory when that service is ready.           ║"
    log_warn "  ╚══════════════════════════════════════════════════════════════╝"
    log_warn ""
    SERVICES_MISSING+=("$name")
  fi
done

if (( ${#SERVICES_MISSING[@]} > 0 )); then
  echo ""
  log_warn "${#SERVICES_MISSING[@]} service(s) skipped: ${SERVICES_MISSING[*]}"
  log_warn "Only ${#SERVICES_PRESENT[@]} service(s) will be started: ${SERVICES_PRESENT[*]}"
fi

# ── Step 3: Install dependencies ─────────────────────────────────────────────
echo ""
log_info "=== [3/4] Installing service dependencies ==="

# SNS Python service
SNS_DIR="$ROOT_DIR/services/sns"
if [[ -d "$SNS_DIR" ]]; then
  REQS_FILE="$SNS_DIR/requirements.txt"
  REQS_HASH_FILE="$SNS_DIR/.reqs_hash"

  if [[ -f "$REQS_FILE" ]]; then
    current_hash=$(md5sum "$REQS_FILE" | cut -d' ' -f1)
    cached_hash=$(cat "$REQS_HASH_FILE" 2>/dev/null || echo "")

    if [[ "$current_hash" != "$cached_hash" ]]; then
      log_info "  requirements.txt changed — installing..."

      # Use venv if it exists
      if [[ -d "$SNS_DIR/.venv" ]]; then
        log_info "  Activating venv at $SNS_DIR/.venv"
        # shellcheck disable=SC1090
        source "$SNS_DIR/.venv/bin/activate"
      fi

      pip3 install -q -r "$REQS_FILE"
      echo "$current_hash" > "$REQS_HASH_FILE"
      log_info "  SNS dependencies installed."
    else
      log_info "  SNS requirements.txt unchanged — skipping pip install."
    fi
  fi
fi

# Node.js backend (when implemented)
BACKEND_DIR="$ROOT_DIR/backend"
if [[ -d "$BACKEND_DIR" ]]; then
  if [[ -f "$BACKEND_DIR/bun.lockb" ]]; then
    log_info "  Installing backend deps with bun..."
    (cd "$BACKEND_DIR" && bun install --frozen-lockfile)
  elif [[ -f "$BACKEND_DIR/package-lock.json" ]]; then
    log_info "  Installing backend deps with npm..."
    (cd "$BACKEND_DIR" && npm ci --silent)
  elif [[ -f "$BACKEND_DIR/package.json" ]]; then
    log_info "  Installing backend deps with npm install..."
    (cd "$BACKEND_DIR" && npm install --silent)
  fi
fi

# Ponder indexer (when implemented)
INDEXER_DIR="$ROOT_DIR/indexer"
if [[ -d "$INDEXER_DIR" ]]; then
  if [[ -f "$INDEXER_DIR/bun.lockb" ]]; then
    log_info "  Installing indexer deps with bun..."
    (cd "$INDEXER_DIR" && bun install --frozen-lockfile)
  elif [[ -f "$INDEXER_DIR/package-lock.json" ]]; then
    log_info "  Installing indexer deps with npm ci..."
    (cd "$INDEXER_DIR" && npm ci --silent)
  fi
fi

# ── Qdrant (optional) ─────────────────────────────────────────────────────────
QDRANT_IN_MEMORY="${QDRANT_IN_MEMORY:-true}"
if [[ "$QDRANT_IN_MEMORY" == "false" ]]; then
  echo ""
  if [[ "$START_QDRANT" == "true" ]]; then
    log_info "=== Starting Qdrant via Docker ==="
    if command -v docker &>/dev/null; then
      if docker ps --filter "name=qdrant" --format "{{.Names}}" 2>/dev/null | grep -q qdrant; then
        log_info "  Qdrant container already running."
      else
        docker run -d \
          --name qdrant \
          -p 6333:6333 \
          -p 6334:6334 \
          -v qdrant_storage:/qdrant/storage \
          qdrant/qdrant
        log_info "  Qdrant started."
        sleep 3
        curl -fsS http://localhost:6333/healthz &>/dev/null && log_info "  Qdrant health: OK"
      fi
    else
      log_warn "  Docker not found. Cannot start Qdrant automatically."
    fi
  else
    echo "  ┌─ INFO: QDRANT_IN_MEMORY=false — persistent Qdrant is required ──────────"
    echo "  │  To start Qdrant locally:"
    echo "  │"
    echo "  │    docker run -d \\"
    echo "  │      --name qdrant \\"
    echo "  │      -p 6333:6333 -p 6334:6334 \\"
    echo "  │      -v qdrant_storage:/qdrant/storage \\"
    echo "  │      qdrant/qdrant"
    echo "  │"
    echo "  │  Or pass --start-qdrant to this script to run that command automatically."
    echo "  │  For production: use Qdrant Cloud — https://cloud.qdrant.io"
    echo "  └──────────────────────────────────────────────────────────────────────────"
  fi
fi

# ── Step 4: Start PM2 and health checks ───────────────────────────────────────
echo ""
log_info "=== [4/4] Starting PM2 services ==="

PM2_RUNNING=$("$PM2" list 2>/dev/null | grep -c "plot-oracle" || echo "0")

if (( PM2_RUNNING > 0 )); then
  log_info "  PM2 processes exist — restarting with updated env..."
  "$PM2" restart all --update-env
else
  log_info "  Starting PM2 from ecosystem.config.cjs..."
  "$PM2" start "$ROOT_DIR/ecosystem.config.cjs" --only "$(IFS=,; echo "${SERVICES_PRESENT[*]}")" 2>/dev/null \
    || "$PM2" start "$ROOT_DIR/ecosystem.config.cjs"
fi

"$PM2" save
log_info "  PM2 process list saved."

# Wait for services to initialize
sleep 5

echo ""
log_info "=== Health Checks ==="

HEALTH_PASS=0
HEALTH_FAIL=0

check_health() {
  local name="$1"
  local url="$2"
  local expected_substr="${3:-}"
  local response
  response=$(curl -fsS --max-time 5 "$url" 2>/dev/null || echo "")
  if [[ -n "$response" ]]; then
    if [[ -z "$expected_substr" ]] || echo "$response" | grep -q "$expected_substr"; then
      echo "  [PASS] $name → $url"
      (( HEALTH_PASS++ )) || true
    else
      echo "  [FAIL] $name → $url (unexpected response: $response)"
      (( HEALTH_FAIL++ )) || true
    fi
  else
    echo "  [FAIL] $name → $url (no response)"
    (( HEALTH_FAIL++ )) || true
  fi
}

# SNS service (always present)
[[ -d "$SNS_DIR" ]] && check_health "SNS FastAPI (8000)" "http://localhost:8000/health" '"status"'

# Backend (when present)
[[ -d "$BACKEND_DIR" ]] && check_health "Node.js API (3000)" "http://localhost:3000/health" '"status"'

# Ponder indexer (when present)
[[ -d "$INDEXER_DIR" ]] && check_health "Ponder indexer (42069)" "http://localhost:42069/status" ""

echo ""
if (( HEALTH_FAIL > 0 )); then
  log_error "$HEALTH_FAIL health check(s) failed."
  log_error "Check PM2 logs: ~/.local/bin/pm2 logs"
  exit 1
fi

log_info "$HEALTH_PASS health check(s) passed."
log_info ""
log_info "Phase 4 complete."
log_info "Run smoke tests: bash scripts/deploy/smoke-test.sh --network $NETWORK"
