# Keeper Scripts

**Location:** `scripts/keepers/`
**Technology:** Bash + Foundry `cast`
**Purpose:** Advance claim lifecycle steps that cannot run autonomously on-chain

---

## Why Keepers Are Needed

The challenge window and bond release steps are *permissionless* — anyone may call them — but they
need an off-chain trigger to know *when* to fire. Without a keeper:

- Claims stay `Pending` forever even after the 2-hour window expires (never become `Verified`)
- The relay wallet's USDC bond stays locked in BondEscrow, depleting the testnet balance over time

For production, these are replaced by Chainlink Automation upkeeps. For testnet and demo, run the
bash scripts manually or in a polling loop.

---

## Scripts

### `finalize-claims.sh`

Finds expired unchallenged windows and releases submitter bonds.

```bash
# Usage
bash scripts/keepers/finalize-claims.sh --network base_sepolia
bash scripts/keepers/finalize-claims.sh --network base_mainnet [--ponder-url http://localhost:42069]
```

**What it does:**

**Phase 1 — Finalize:**
1. Queries Ponder GraphQL (`/graphql`) for `challengeWindows` where `finalized=false`
2. Filters to those with `expiresAt ≤ now` and `challenger=null` (unchallenged)
3. Calls `ChallengeWindow.finalizeUnchallenged(bytes32 claimId)` for each
4. This advances the claim to `Verified` with `confidenceScore=100`

**Phase 2 — Release bonds:**
1. Queries Ponder GraphQL for `claims` where `status=Verified`
2. Checks `BondEscrow.lockedBond(claimId)` on-chain for each — skips if already `0`
3. Calls `OracleRouter.releaseSubmitterBond(bytes32 claimId)` for each with a locked bond
4. USDC is returned to the relay wallet (the original bond payer)

**Requirements:**
- Ponder indexer must be running at `PONDER_URL` (default: `http://localhost:42069`)
- `OPERATOR_PRIVATE_KEY` in `.env` (falls back to `PRIVATE_KEY` on testnet)
- `CHALLENGE_WINDOW_ADDRESS`, `ORACLE_ROUTER_ADDRESS`, `BOND_ESCROW_ADDRESS` in `.env`

---

### `run-keeper-loop.sh`

Continuous polling wrapper for testnet demo use. Runs `finalize-claims.sh` on a fixed interval.

```bash
# Usage
bash scripts/keepers/run-keeper-loop.sh --network base_sepolia [--interval 60]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--network` | required | `base_sepolia` or `base_mainnet` |
| `--interval` | 60 | Seconds between keeper runs |

Press `Ctrl+C` to stop. Each run prints a timestamped header and the finalize/release summary.

---

### `record-snapshots.sh`

Records Chainlink price snapshots on `EmissionController`. Required for the emission circuit breaker.

```bash
# Usage
bash scripts/keepers/record-snapshots.sh --network base_mainnet --interval 24h
bash scripts/keepers/record-snapshots.sh --network base_mainnet --interval 7d
```

| Interval | Function | Cron |
|----------|----------|------|
| `24h` | `recordSnapshot24h()` | `0 0 * * *` |
| `7d` | `recordSnapshot7d()` | `0 0 * * 0` |

Also calls `checkCircuitBreaker()` (permissionless) after each snapshot.

Requires `OPERATOR_PRIVATE_KEY` and `EMISSION_CONTROLLER_ADDRESS` in `.env`.

---

## Demo Quickstart

Start the keeper loop after services are up, then submit a claim and wait ~2h:

```bash
# Terminal 1 — keeper loop (every 60s)
bash scripts/keepers/run-keeper-loop.sh --network base_sepolia --interval 60

# Terminal 2 — submit a claim
curl -X POST http://localhost:3000/claims \
  -H "Content-Type: application/json" \
  -d '{"claim_text":"Gold is trading above $2000/oz","domain":"Finance","complexity":"LOW","submitter_address":"0x..."}'

# After ~2h, keeper loop will call finalizeUnchallenged → releaseSubmitterBond
# Check claim status
curl http://localhost:3000/claims/<claim_id>
# Expect: "status": "Verified"
```

---

## Cron Setup (Production)

Add to crontab (`crontab -e`) on the server running the keeper wallet:

```cron
# Finalize unchallenged claims every 5 minutes
*/5 * * * * bash /path/to/plot_oracle/scripts/keepers/finalize-claims.sh --network base_mainnet >> /var/log/keeper-finalize.log 2>&1

# Daily price snapshot
0 0 * * * bash /path/to/plot_oracle/scripts/keepers/record-snapshots.sh --network base_mainnet --interval 24h >> /var/log/keeper-snapshot.log 2>&1

# Weekly price snapshot
0 0 * * 0 bash /path/to/plot_oracle/scripts/keepers/record-snapshots.sh --network base_mainnet --interval 7d >> /var/log/keeper-snapshot.log 2>&1
```

---

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `OPERATOR_PRIVATE_KEY` | Yes (falls back to `PRIVATE_KEY`) | Signs keeper transactions |
| `PONDER_URL` | No (default: `http://localhost:42069`) | Ponder GraphQL endpoint |
| `CHALLENGE_WINDOW_ADDRESS` | Yes | Auto-exported from `deployments/<network>.json` |
| `ORACLE_ROUTER_ADDRESS` | Yes | Auto-exported |
| `BOND_ESCROW_ADDRESS` | Yes | Auto-exported |
| `EMISSION_CONTROLLER_ADDRESS` | Yes (record-snapshots only) | Auto-exported |
