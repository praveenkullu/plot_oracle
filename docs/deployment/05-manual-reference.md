# Manual Deployment Reference

Raw forge/cast commands for when you need to debug, inspect, or deploy without the wrapper scripts.
For the standard deployment flow, use the automated scripts described in [README.md](README.md).

---

## Dry Run (Simulate)

```bash
cd contracts
~/.config/.foundry/bin/forge script script/Deploy.s.sol \
  --rpc-url base_sepolia \
  --sender $ADMIN_ADDRESS \
  -vvvv
```

## Deploy Contracts

```bash
~/.config/.foundry/bin/forge script script/Deploy.s.sol \
  --rpc-url base_sepolia \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY \
  -vvvv
```

Add `--slow` for mainnet (sends one tx at a time, waits for confirmation):
```bash
~/.config/.foundry/bin/forge script script/Deploy.s.sol \
  --rpc-url base_mainnet \
  --private-key $PRIVATE_KEY \
  --broadcast --verify --slow \
  --etherscan-api-key $BASESCAN_API_KEY \
  -vvvv
```

With Ledger hardware wallet (mainnet):
```bash
~/.config/.foundry/bin/forge script script/Deploy.s.sol \
  --rpc-url base_mainnet \
  --ledger \
  --broadcast --verify --slow \
  --etherscan-api-key $BASESCAN_API_KEY \
  -vvvv
```

## Set Testnet Bond Rates

Lower all domain base bonds to 1 USDC for e2e testing (testnet only).
The contract caps each `setDomainBaseBond` call at ±25%, so the script iterates
down in 25%-steps automatically (~130 transactions total).

```bash
cd contracts
set -a && source ../.env && set +a
forge script script/SetTestnetBonds.s.sol \
  --rpc-url "$BASE_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast -vv
```

Requires `GOVERNANCE_ROLE` on `BondCalculator` (held by the deployer wallet by default).
**Do not run on mainnet.**

---

## Wire Roles

```bash
~/.config/.foundry/bin/forge script script/WireRoles.s.sol \
  --rpc-url base_sepolia \
  --private-key $PRIVATE_KEY \
  --broadcast \
  -vvvv
```

## Manual Contract Verification

If `--verify` fails due to BaseScan rate limiting:

```bash
FORGE=~/.config/.foundry/bin/forge
CAST=~/.config/.foundry/bin/cast

$FORGE verify-contract $PLOT_TOKEN_ADDRESS src/PLOTToken.sol:PLOTToken \
  --chain base-sepolia \
  --etherscan-api-key $BASESCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(address,address)" $ADMIN_ADDRESS $TREASURY_WALLET)

# Repeat for each contract with appropriate constructor args
```

## Smoke Test Queries (Manual)

```bash
CAST=~/.config/.foundry/bin/cast

# PLOTToken max supply (expect: 1000000000000000000000000000)
$CAST call $PLOT_TOKEN_ADDRESS "MAX_SUPPLY()(uint256)" --rpc-url base_sepolia

# Treasury balance of 200M PLOT (expect: 200000000000000000000000000)
$CAST call $PLOT_TOKEN_ADDRESS "balanceOf(address)(uint256)" $TREASURY_WALLET --rpc-url base_sepolia

# Year 0 emission rate (expect: 10000)
$CAST call $EMISSION_CONTROLLER_ADDRESS "currentRateBps()(uint256)" --rpc-url base_sepolia

# Veto expiry (~730 days from deploy)
$CAST call $TREASURY_ADDRESS "vetoExpiresAt()(uint256)" --rpc-url base_sepolia

# Governor name (expect: "GovernorPlot")
$CAST call $GOVERNOR_ADDRESS "name()(string)" --rpc-url base_sepolia

# Check a role binding (e.g. MINTER_ROLE on PLOTToken → EmissionController)
MINTER_ROLE=$($CAST call $PLOT_TOKEN_ADDRESS "MINTER_ROLE()(bytes32)" --rpc-url base_sepolia)
$CAST call $PLOT_TOKEN_ADDRESS \
  "hasRole(bytes32,address)(bool)" $MINTER_ROLE $EMISSION_CONTROLLER_ADDRESS \
  --rpc-url base_sepolia
```

## Admin Handoff (Manual)

Grant `DEFAULT_ADMIN_ROLE` to Gnosis Safe and revoke from deployer:

```bash
CAST=~/.config/.foundry/bin/cast
DEFAULT_ADMIN_ROLE="0x0000000000000000000000000000000000000000000000000000000000000000"

# For each contract:
# 1. Grant to Gnosis Safe (deployer signs)
$CAST send $CONTRACT_ADDRESS \
  "grantRole(bytes32,address)" $DEFAULT_ADMIN_ROLE $GNOSIS_SAFE_ADDRESS \
  --private-key $PRIVATE_KEY \
  --rpc-url base_mainnet

# 2. Revoke from deployer (must be called by Gnosis Safe via multisig tx)
# Use app.safe.global to queue and sign this transaction as a multisig operation
```

Contracts requiring admin handoff (all 13):
`PLOT_TOKEN`, `BOND_CALCULATOR`, `BOND_ESCROW`, `CLAIM_REGISTRY`, `NOVELTY_GATE`,
`CHALLENGE_WINDOW`, `CONFIDENCE_SCORER`, `ORACLE_ROUTER`, `INTERNAL_VOTE`,
`EMISSION_CONTROLLER`, `TIMELOCK`, `GOVERNOR`, `TREASURY`

## Keeper Commands (Manual)

```bash
CAST=~/.config/.foundry/bin/cast

# 24h price snapshot
$CAST send $EMISSION_CONTROLLER_ADDRESS "recordSnapshot24h()" \
  --private-key $OPERATOR_PRIVATE_KEY --rpc-url base_mainnet

# 7d price snapshot
$CAST send $EMISSION_CONTROLLER_ADDRESS "recordSnapshot7d()" \
  --private-key $OPERATOR_PRIVATE_KEY --rpc-url base_mainnet

# Circuit breaker check (permissionless)
$CAST send $EMISSION_CONTROLLER_ADDRESS "checkCircuitBreaker()" \
  --private-key $OPERATOR_PRIVATE_KEY --rpc-url base_mainnet

# Finalize unchallenged claim
$CAST send $CHALLENGE_WINDOW_ADDRESS \
  "finalizeUnchallenged(uint256)" $CLAIM_ID \
  --private-key $OPERATOR_PRIVATE_KEY --rpc-url base_mainnet

# Release submitter bond
$CAST send $ORACLE_ROUTER_ADDRESS \
  "releaseSubmitterBond(uint256)" $CLAIM_ID \
  --private-key $OPERATOR_PRIVATE_KEY --rpc-url base_mainnet

# First emission mint
$CAST send $EMISSION_CONTROLLER_ADDRESS \
  "mintEmission(address)" $REWARDS_POOL_ADDRESS \
  --private-key $OPERATOR_PRIVATE_KEY --rpc-url base_mainnet
```
