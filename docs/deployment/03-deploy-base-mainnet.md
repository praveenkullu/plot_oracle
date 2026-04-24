# Deploy to Base Mainnet

**Warning:** Mainnet deployments involve real funds. There is no undo for a deployed contract.
Complete the full testnet deployment on Base Sepolia first.

---

## Automated Mainnet Deployment

`phase5-mainnet.sh` wraps phases 2–4 with a 7-point pre-flight safety gate and requires
an interactive confirmation before sending any transactions.

```bash
# With PRIVATE_KEY in .env
bash scripts/deploy/phase5-mainnet.sh --confirm-mainnet

# With hardware wallet (Ledger) — recommended for mainnet
bash scripts/deploy/phase5-mainnet.sh --confirm-mainnet --ledger
```

The script exits immediately without `--confirm-mainnet`. This prevents accidental mainnet runs.

---

## Pre-Flight Checklist (Automated)

`phase5-mainnet.sh` automatically checks all of the following. Any failure blocks deployment.

| Check | Pass Condition |
|-------|---------------|
| 1. Test suite | `forge test --fuzz-runs 10000` passes |
| 2. No compiler warnings | `forge build` output contains no "warning" |
| 3. Testnet artifact | `deployments/base_sepolia.json` exists with `rolesWired: true` |
| 4. Admin is multisig | `cast code ADMIN_ADDRESS` returns non-empty bytecode |
| 5. Foundation is multisig | `cast code FOUNDATION_ADDRESS` returns non-empty bytecode |
| 6. Chainlink feed responds | `latestRoundData()` returns a valid round |
| 7. Deployer balance | Deployer wallet holds > 0.05 ETH on Base Mainnet |

### Manual Pre-Deployment Checklist

Before running the script, also verify:

- [ ] Admin address is a Gnosis Safe (not an EOA) — set up at [safe.global](https://safe.global)
- [ ] Foundation address is a separate Gnosis Safe (3-of-5 recommended)
- [ ] `CHAINLINK_PLOT_USD_FEED` is set (use ETH/USD placeholder `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` until PLOT feed is live)
- [ ] SNS oracle wallet private key stored in AWS Secrets Manager or HashiCorp Vault
- [ ] Operator wallet funded with ETH for daily gas costs
- [ ] Base Sepolia smoke tests pass (run `bash scripts/deploy/smoke-test.sh --network base_sepolia`)
- [ ] External audit completed (recommended)

---

## Mainnet Governor Parameters

Set these in `.env` before running `phase5-mainnet.sh`. The script exports defaults if unset.

| Variable | Default (testnet) | Mainnet Recommended |
|----------|-------------------|---------------------|
| `GOVERNOR_VOTING_DELAY` | 86400 | 172800 (~2 days) |
| `GOVERNOR_VOTING_PERIOD` | 604800 | 1209600 (~14 days) |
| `GOVERNOR_PROP_THRESHOLD` | 10000 | 10000 PLOT |
| `GOVERNOR_QUORUM_NUM` | 4 | 4% |
| `TIMELOCK_DELAY` | 172800 | 172800 (2 days in seconds) |
| `INTERNAL_VOTE_QUORUM` | 3 | 3 (raise via governance later) |
| `USDC_ADDRESS` | Base Sepolia USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

---

## What `phase5-mainnet.sh` Does

1. Runs 7 automated pre-flight checks (fails hard on any failure)
2. Prints all governor parameters for review
3. Prompts: type exactly `DEPLOY MAINNET` to proceed (cannot be automated)
4. Runs `phase2-deploy-contracts.sh --network base_mainnet --broadcast`
5. Runs `phase3-wire-roles.sh --network base_mainnet --broadcast`
6. Runs `smoke-test.sh --network base_mainnet`
7. Runs `phase4-services.sh --network base_mainnet`
8. Prints 5-point post-deploy manual action checklist

---

## Post-Deployment Manual Actions (CRITICAL)

After the script completes, the following **must** be done manually:

### 1. Admin Handoff (Do This Immediately)

The deployer EOA currently holds `DEFAULT_ADMIN_ROLE` on all 13 contracts.
Transfer it to the Gnosis Safe:

```bash
# Set GNOSIS_SAFE_ADDRESS in .env first, then:
bash scripts/deploy/phase3-wire-roles.sh \
  --network base_mainnet --broadcast --admin-handoff
```

Then have the Gnosis Safe sign `revokeRole` transactions for the deployer
on all 13 contracts via [app.safe.global](https://app.safe.global).

### 2. Register Chainlink Automation Upkeeps

At [automation.chain.link](https://automation.chain.link), register:

| Upkeep | Target | Trigger | LINK Budget |
|--------|--------|---------|-------------|
| Price Snapshots | EmissionController | Daily (24h) + Weekly (7d) | ~10 LINK |
| Circuit Breaker | EmissionController | Hourly | ~50 LINK |

Until Chainlink Automation is registered, run keepers manually:
```bash
# Daily (cron: 0 0 * * *)
bash scripts/keepers/record-snapshots.sh --network base_mainnet --interval 24h

# Weekly (cron: 0 0 * * 0)
bash scripts/keepers/record-snapshots.sh --network base_mainnet --interval 7d

# Every 5 min (cron: */5 * * * *)
bash scripts/keepers/finalize-claims.sh --network base_mainnet
```

### 3. Register PLOT/USD Chainlink Feed

After the PLOT token has sufficient liquidity:
1. Register the feed at [data.chain.link](https://data.chain.link)
2. Submit a governance proposal to call `EmissionController.setPriceFeed(<new_address>)`

### 4. Fund Operator Wallet

Fund `OPERATOR_WALLET` with ETH for daily keeper gas costs.

### 5. Set Up Production Qdrant

```bash
docker run -d --name qdrant \
  -p 6333:6333 -p 6334:6334 \
  -v qdrant_storage:/qdrant/storage \
  qdrant/qdrant
```

Update `.env`:
```env
QDRANT_IN_MEMORY=false
QDRANT_HOST=localhost
QDRANT_PORT=6333
```

Then restart services: `~/.local/bin/pm2 restart all --update-env`

---

## Emergency Procedures

### If a contract is compromised

1. Admin multisig: call `revokeRole()` on the affected contract
2. EmissionController: call `deactivateEmergencyMode()` via admin multisig
3. Treasury: Foundation multisig vetoes the suspicious proposal hash before execution
4. GovernorPlot: TimelockController `cancel()` aborts queued operations

### If Chainlink price feed gives bad data

1. Admin multisig calls `EmissionController.setPriceFeed(newFeedAddress)`
2. Non-emergency: submit governance proposal (2-day timelock)
3. Emergency: admin can update directly via `DEFAULT_ADMIN_ROLE`

### If EmissionController triggers false emergency mode

1. Admin multisig calls `EmissionController.deactivateEmergencyMode()`
2. Investigate: stale snapshot or bad price feed
3. Governance vote to adjust circuit breaker parameters if needed
