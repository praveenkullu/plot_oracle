# Deploy to Base Sepolia (Testnet)

Base Sepolia uses the same scripts as mainnet but with free testnet ETH and no real funds at risk.
Run the full testnet sequence before attempting mainnet.

---

## Before You Start

1. Complete [Prerequisites](01-prerequisites.md) — tooling, accounts, `.env`
2. Fund your deployer wallet with testnet ETH: [Base Sepolia Faucet](https://faucet.quicknode.com/base/sepolia)
3. Run `bash scripts/deploy/phase1-prereqs.sh` — it will catch any missing configuration

---

## Step 1: Validate Prerequisites

```bash
bash scripts/deploy/phase1-prereqs.sh
```

This checks:
- forge, cast, pm2, jq, curl are installed
- Node.js ≥18 or bun is available
- Python 3.11+ and pip are available
- `.env` exists and all 10 required variables are set
- Deployer wallet has enough ETH for gas
- `forge build` succeeds (no compilation errors)
- `forge test` passes (expected: 138 tests)

**Manual action required if:**
- Deployer wallet is unfunded → get ETH from the faucet linked above
- Missing Gnosis Safe → set up at [safe.global](https://safe.global) (for admin/foundation roles)
- Missing BaseScan API key → register free at [basescan.org](https://basescan.org/register)

---

## Step 2: Dry Run (Simulate Deployment)

Always simulate before broadcasting. No gas spent, no real transactions:

```bash
bash scripts/deploy/phase2-deploy-contracts.sh --network base_sepolia
```

This runs `forge script Deploy.s.sol` without `--broadcast`. Review the output to confirm all
13 contracts would deploy correctly.

---

## Step 3: Deploy Contracts

```bash
bash scripts/deploy/phase2-deploy-contracts.sh --network base_sepolia --broadcast
```

What happens:
- Runs `forge script Deploy.s.sol --broadcast --verify --etherscan-api-key ...`
- Parses `broadcast/Deploy.s.sol/84532/run-latest.json` to extract all addresses
- Writes `deployments/base_sepolia.json` with contract addresses and tx hashes
- Prints fallback `forge verify-contract` commands if BaseScan rate-limits

The deployment artifact is saved at:
```
deployments/base_sepolia.json
```

---

## Step 4: Wire Roles

```bash
# Dry run first (shows current role state)
bash scripts/deploy/phase3-wire-roles.sh --network base_sepolia

# Broadcast
bash scripts/deploy/phase3-wire-roles.sh --network base_sepolia --broadcast
```

This grants 12 AccessControl role bindings across all contracts and verifies each one
on-chain with `cast call hasRole(...)`. Fails loudly if any role binding is missing.

Sets `rolesWired: true` in `deployments/base_sepolia.json` on success.

---

## Step 5: Smoke Test

Verify key invariants are correct (read-only, no gas):

```bash
bash scripts/deploy/smoke-test.sh --network base_sepolia
```

Checks:
- `PLOTToken.MAX_SUPPLY` == 1,000,000,000 PLOT
- Treasury received 200M PLOT at deploy
- `EmissionController.currentRateBps` == 10000 (Year 0 = 100%)
- `Treasury.vetoExpiresAt` ≥ now + 729 days
- `Governor.name` == "GovernorPlot"
- All 3 critical role bindings are `true`
- All 13 contract addresses are non-zero

---

## Step 6: Start Services

```bash
bash scripts/deploy/phase4-services.sh --network base_sepolia
```

What happens:
1. Injects all deployed addresses into `.env` (atomic write with timestamped backup)
2. Checks for backend (`src/`), SNS (`services/sns/`), and indexer (`indexer/`) directories
3. Installs Python and Node.js dependencies if needed
4. Starts all PM2 services via `ecosystem.config.cjs`
5. Waits 5s and health-checks all three ports (8000, 3000, 42069)

If Qdrant is needed with persistent storage (not in-memory):
```bash
bash scripts/deploy/phase4-services.sh --network base_sepolia --start-qdrant
```

**Manual action required if:**
- Service directories are missing → script warns loudly but continues; create directories and re-run
- Qdrant Docker not installed → install Docker and re-run with `--start-qdrant`

---

## Full Testnet Sequence (One-liner Reference)

```bash
bash scripts/deploy/phase1-prereqs.sh && \
bash scripts/deploy/phase2-deploy-contracts.sh --network base_sepolia --broadcast && \
bash scripts/deploy/phase3-wire-roles.sh --network base_sepolia --broadcast && \
bash scripts/deploy/smoke-test.sh --network base_sepolia && \
bash scripts/deploy/phase4-services.sh --network base_sepolia
```

---

## Manual Forge Commands

For debugging or step-by-step inspection without the wrapper scripts, see
[05-manual-reference.md](05-manual-reference.md).
