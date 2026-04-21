# Deploy to Base Mainnet

**Warning:** Mainnet deployments involve real funds. Follow this checklist precisely.
There is no undo for a deployed contract.

---

## Pre-Deployment Checklist

### Code quality
- [ ] All 138 tests pass: `~/.config/.foundry/bin/forge test`
- [ ] No compiler warnings: `~/.config/.foundry/bin/forge build`
- [ ] Fuzz testing run: `~/.config/.foundry/bin/forge test --fuzz-runs 10000`
- [ ] External audit completed (recommended before mainnet)

### Configuration
- [ ] Admin address is a Gnosis Safe multisig (not an EOA)
- [ ] Foundation address is a separate Gnosis Safe multisig (3-of-5 recommended)
- [ ] Treasury wallet is the same address receiving the 200M PLOT initial allocation
- [ ] SNS oracle wallet private key is in a hardware security module or secrets manager
- [ ] Operator wallet (keeper) is funded with ETH for gas
- [ ] `CHAINLINK_PLOT_USD_FEED` set to the real PLOT/USD feed address on Base Mainnet
  - PLOT/USD Chainlink feed must be registered after PLOT token deploys; use a placeholder
    ETH/USD feed (`0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` on Base) until PLOT feed is live

### Testnet verification
- [ ] Full testnet deployment completed on Base Sepolia
- [ ] All smoke tests pass on Sepolia
- [ ] Off-chain services running against Sepolia for at least 1 week

---

## Mainnet-Specific Parameters

Use production parameters (not the fast test values used in tests/Sepolia):

| Parameter | Value | Notes |
|-----------|-------|-------|
| Voting delay | 172,800 blocks (~2 days at 1s/block) | Time after proposal before voting |
| Voting period | 1,209,600 blocks (~14 days) | Time to vote |
| Proposal threshold | 10,000e18 PLOT | Minimum PLOT to create proposal |
| Quorum numerator | 4 | 4% of total supply |
| Timelock delay | 172,800 seconds (2 days) | Delay between passing and execution |
| InternalVote quorum | 3 (initial) | Raise via governance after launch |

---

## Deploy Command

```bash
cd contracts

# Dry run first (no --broadcast)
~/.config/.foundry/bin/forge script script/Deploy.s.sol \
  --rpc-url base_mainnet \
  --sender $ADMIN_ADDRESS \
  -vvvv

# Deploy for real
~/.config/.foundry/bin/forge script script/Deploy.s.sol \
  --rpc-url base_mainnet \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY \
  --slow \
  -vvvv
```

`--slow` sends one transaction at a time, waiting for confirmation. Slower but safer for
a multi-step deployment.

---

## Role Wiring

```bash
~/.config/.foundry/bin/forge script script/WireRoles.s.sol \
  --rpc-url base_mainnet \
  --private-key $PRIVATE_KEY \
  --broadcast \
  -vvvv
```

---

## Post-Deployment: Transfer Admin to Multisig

The deployer (EOA) should renounce `DEFAULT_ADMIN_ROLE` after granting it to the Gnosis Safe.
This ensures no single private key can administer the protocol:

```bash
CAST=~/.config/.foundry/bin/cast

# For each contract: grant DEFAULT_ADMIN_ROLE to multisig, then revoke from deployer
$CAST send $CLAIM_REGISTRY_ADDRESS \
  "grantRole(bytes32,address)" \
  $(cast keccak "DEFAULT_ADMIN_ROLE" | head -c 66) \
  $GNOSIS_SAFE_ADDRESS \
  --private-key $PRIVATE_KEY \
  --rpc-url base_mainnet

# Repeat for all contracts, then revoke deployer
$CAST send $CLAIM_REGISTRY_ADDRESS \
  "revokeRole(bytes32,address)" \
  $(cast keccak "DEFAULT_ADMIN_ROLE" | head -c 66) \
  $DEPLOYER_ADDRESS \
  --private-key $GNOSIS_SAFE_PRIVATE_KEY \
  --rpc-url base_mainnet
```

---

## Post-Deployment: Verify Addresses

After deployment, record all addresses in a permanent reference file:

```bash
# Check final state
CAST=~/.config/.foundry/bin/cast

# PLOTToken
echo "PLOTToken address: $PLOT_TOKEN_ADDRESS"
$CAST call $PLOT_TOKEN_ADDRESS "totalSupply()(uint256)" --rpc-url base_mainnet
# Expected: 200000000000000000000000000 (200M with 18 decimals)

# Treasury
$CAST call $TREASURY_ADDRESS "vetoExpiresAt()(uint256)" --rpc-url base_mainnet
# Expected: deployment_timestamp + 63072000 (730 days in seconds)

# EmissionController
$CAST call $EMISSION_CONTROLLER_ADDRESS "currentRateBps()(uint256)" --rpc-url base_mainnet
# Expected: 10000 (Year 0, 100%)

# Governor
$CAST call $GOVERNOR_ADDRESS "name()(string)" --rpc-url base_mainnet
# Expected: "GovernorPlot"
```

---

## Emergency Contacts and Procedures

### If a contract is compromised

1. Admin multisig: call `revokeRole()` on affected contract to remove compromised role
2. EmissionController: admin calls `deactivateEmergencyMode()` or stops keeper bot
3. Treasury: Foundation multisig vetoes any suspicious proposal hashes before execution
4. GovernorPlot: TimelockController has a `cancel()` function to abort queued operations

### If the Chainlink price feed gives bad data

1. Admin calls `EmissionController.setPriceFeed(newFeedAddress)` with a corrected feed
2. Proposals to change the feed go through governance (2 days timelock)
3. In emergency, admin (multisig) can update directly via DEFAULT_ADMIN_ROLE

### If EmissionController triggers false emergency mode

1. Admin multisig calls `EmissionController.deactivateEmergencyMode()`
2. Investigate root cause (stale snapshot, bad price feed)
3. Governance vote to adjust circuit breaker parameters if needed
