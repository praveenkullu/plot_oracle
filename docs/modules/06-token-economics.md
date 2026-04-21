# Module 6: Token Economics

**Contracts:** `EmissionController.sol`, `GovernorPlot.sol`, `Treasury.sol`

**Role in the system:** Manages the long-term health of the PLOT token and protocol governance.
EmissionController drips new PLOT to stakers on a decreasing schedule. GovernorPlot lets PLOT
holders vote on protocol changes. Treasury holds USDC fee revenue and can initiate PLOT buybacks.
Circuit breakers in EmissionController prevent death spirals if PLOT price crashes.

**Dependencies:** Module 1 (PLOTToken.sol)

---

## 1. EmissionController — `src/EmissionController.sol`

### What it does

Mints new PLOT tokens on a time-based schedule, decreasing each year to create scarcity over time.
An OPERATOR_ROLE keeper (or Chainlink Automation) calls `mintEmission(address to)` periodically
to flush accrued PLOT to the staking rewards pool.

### Emission Schedule

Each "year" is exactly `365 days` since deployment:

| Year | Rate | Annual PLOT |
|------|------|-------------|
| 0 (deploy → 365 days) | 100% (10,000 BPS) | 50,000,000 PLOT |
| 1 (365 → 730 days) | 80% (8,000 BPS) | 40,000,000 PLOT |
| 2 (730 → 1095 days) | 60% (6,000 BPS) | 30,000,000 PLOT |
| 3 (1095 → 1460 days) | 40% (4,000 BPS) | 20,000,000 PLOT |
| 4+ (forever after) | 20% floor (2,000 BPS) | 10,000,000 PLOT/year |

`MAX_ANNUAL_EMISSION = 50,000,000e18` — 5% of the 1B max supply per year at 100% rate.

### How emission accrues

Emission is not batched — it accrues every second. `pendingEmission()` returns how much has
accrued since the last mint:

```solidity
function pendingEmission() public view returns (uint256) {
    uint256 elapsed = block.timestamp - lastMintedAt;
    return (MAX_ANNUAL_EMISSION * currentRateBps() / BPS_DENOM) * elapsed / YEAR;
}
```

Important: the rate used is the **current** rate at the time of minting — it does not
time-weight across year boundaries. This incentivizes frequent minting during high-emission
periods (Year 0) to capture the full 100% rate before the year boundary.

### mintEmission()

```solidity
function mintEmission(address to) external onlyRole(OPERATOR_ROLE)
```

Reverts if:
- `emergencyMode == true`
- `emissionsPaused == true` AND `block.timestamp < pausedUntil`
- `pendingEmission() == 0` (nothing accrued)

On success:
- Updates `lastMintedAt = block.timestamp`
- Adds to `totalEmitted`
- Calls `plotToken.mint(to, amount)`

---

### Circuit Breakers

Circuit breakers protect against PLOT price crashes. An OPERATOR_ROLE keeper records price
snapshots; anyone can call `checkCircuitBreaker()` to compare the current price.

#### How snapshots work

```solidity
function recordSnapshot24h() external onlyRole(OPERATOR_ROLE)  // call once daily
function recordSnapshot7d()  external onlyRole(OPERATOR_ROLE)  // call once weekly
```

Each stores the Chainlink `latestRoundData()` price and timestamp.

#### 7-day check (more severe — emergency mode)

Triggered when `currentPrice * 100 < snapshot7dPrice * 40` (price dropped > 60%):
- Sets `emergencyMode = true`
- Emits `EmergencyModeActivated()`
- Blocks all minting until admin calls `deactivateEmergencyMode()`

This represents a catastrophic price collapse (e.g., PLOT went from $1 to below $0.40
over 7 days). The protocol enters manual governance mode.

#### 24-hour check (moderate — 48-hour pause)

Triggered when `currentPrice * 100 < snapshot24hPrice * 70` (price dropped > 30%):
- Sets `emissionsPaused = true`, `pausedUntil = block.timestamp + 48 hours`
- Emits `CircuitBreakerTriggered(pausedUntil)`
- Blocks minting for 48 hours, then auto-resumes

The 7-day check runs **first** (in `checkCircuitBreaker()`). If 7-day triggers, 24-hour is
skipped. This ensures we don't set a 48h pause when we should be in full emergency mode.

#### Why these specific thresholds?

- >30% in 24h is an extreme single-day move for any legitimate token (flash crash territory)
- >60% in 7 days would wipe out most submitter bonds' real value if not halted
- 48h pause gives governance time to assess and respond without requiring immediate action

---

## 2. GovernorPlot — `src/GovernorPlot.sol`

### What it does

On-chain governance: PLOT holders propose and vote on protocol changes. Uses OpenZeppelin's
modular Governor framework with one critical override — a **67% supermajority requirement**
instead of simple majority.

### Why 67% supermajority?

Simple majority (>50%) is vulnerable to governance attacks: an adversary acquiring 51% of
voting PLOT could pass malicious proposals. Requiring 67% means an attacker needs to control
2/3 of all participating votes — much harder to pull off without the community noticing.

All parameter changes (bond levels, confidence thresholds, emission rates) require 67%.

### Inheritance chain

```
GovernorPlot
├── Governor (base: propose, vote, execute state machine)
├── GovernorSettings (configurable: votingDelay, votingPeriod, proposalThreshold)
├── GovernorCountingSimple (for/against/abstain tallying)
├── GovernorVotes (PLOT-weighted voting via ERC20Votes checkpoints)
├── GovernorVotesQuorumFraction (1% of total supply needed to pass)
└── GovernorTimelockControl (queue/execute via TimelockController delay)
```

### Key parameters

| Parameter | Production Value | Notes |
|-----------|-----------------|-------|
| Voting delay | 2 days | Time after proposal before voting starts |
| Voting period | 14 days | Time for PLOT holders to vote |
| Proposal threshold | 10,000 PLOT | Minimum PLOT to submit a proposal |
| Quorum numerator | 4 (4%) | 4% of total supply must participate |
| Timelock delay | 2 days | Delay between passing and execution |
| Supermajority | 67% | Of participating votes must be in favor |

(Values above are production targets. Test deployment uses: delay=0, period=10 blocks, threshold=0,
quorum=1%, timelock=0 for speed.)

### The supermajority override

```solidity
function _voteSucceeded(uint256 proposalId)
    internal view override(Governor, GovernorCountingSimple) returns (bool)
{
    (uint256 againstVotes, uint256 forVotes,) = proposalVotes(proposalId);
    uint256 total = forVotes + againstVotes;
    if (total == 0) return false;
    return forVotes * SUPERMAJORITY_DENOMINATOR >= total * SUPERMAJORITY_NUMERATOR;
    //     forVotes * 100              >=         total * 67
    //     forVotes / total            >=         0.67 (67%)
}
```

Abstain votes don't count toward or against (not included in `total`).

### Proposal lifecycle

```
1. propose()       → ProposalState.Pending
2. (voting delay)  → ProposalState.Active
3. castVote()      → votes accumulate
4. (voting period) → ProposalState.Succeeded or Defeated
5. queue()         → ProposalState.Queued (via TimelockController)
6. (timelock delay)
7. execute()       → ProposalState.Executed
```

### TimelockController integration

GovernorPlot doesn't execute changes directly — it queues operations via `TimelockController`,
which enforces a mandatory delay. This gives users time to exit if they disagree with
a passed proposal.

Role wiring:
```solidity
timelock.grantRole(PROPOSER_ROLE,  address(governor));
timelock.grantRole(EXECUTOR_ROLE,  address(governor));
timelock.grantRole(CANCELLER_ROLE, address(governor));
```

### How to vote

1. Hold PLOT tokens
2. Delegate to yourself: `plotToken.delegate(msg.sender)` — required to activate voting weight
3. Wait for a proposal to enter Active state
4. Call `governor.castVote(proposalId, 1)` (1=For, 0=Against, 2=Abstain)

---

## 3. Treasury — `src/Treasury.sol`

### What it does

Holds the protocol's USDC fee revenue. The TimelockController (executor of passed governance
proposals) can withdraw USDC or initiate PLOT buybacks. The Foundation multisig can veto
proposals during the first 2 years of operation.

### Why USDC?

The treasury holds USDC — not PLOT — for stability. Governance decisions about spending
(grants, audits, buybacks) are denominated in stable value. USDC is Circle-minted natively
on Base (no bridge risk).

### Two-Year Foundation Veto

For the first 2 years post-deployment, the Foundation multisig holds `FOUNDATION_ROLE` and
can veto any governance proposal hash before it executes:

```solidity
function veto(bytes32 proposalHash) external onlyRole(FOUNDATION_ROLE)
    require(block.timestamp < vetoExpiresAt, "veto power expired")
    vetoed[proposalHash] = true
```

After `vetoExpiresAt = deployedAt + 730 days`, `veto()` always reverts. The Foundation loses
veto power automatically with no on-chain action required.

This is a "training wheels" mechanism: the Foundation can stop malicious governance in the
early days while the community is still small, but governance becomes fully decentralized after 2 years.

### Withdraw

```solidity
function withdraw(address to, uint256 amount, bytes32 proposalHash)
    external onlyRole(EXECUTOR_ROLE) nonReentrant
```

- Only `EXECUTOR_ROLE` (TimelockController) can withdraw
- Reverts if `vetoed[proposalHash] == true`
- The `proposalHash` ties each withdrawal to a specific governance proposal for auditability

### PLOT Buybacks

```solidity
function initiateBuyback(uint256 usdcAmount)
    external onlyRole(EXECUTOR_ROLE) nonReentrant
```

- Cap: `usdcAmount <= usdc.balanceOf(address(this)) × 10% / 100`
  - Maximum 10% of treasury USDC per buyback call
  - Prevents a single governance vote from liquidating the entire treasury
- Does **not** actually execute the swap — emits `BuybackInitiated(usdcAmount)` for an off-chain
  keeper to execute via a DEX
- The keeper watches for this event and performs the swap on-chain through a DEX aggregator

Why off-chain execution? DEX integration (slippage, routing) is complex and varies by market
conditions. Keeping it off-chain allows flexibility to use the best available route.

### ETH rejection

```solidity
receive() external payable {
    revert("Treasury: ETH not accepted");
}
```

The Treasury explicitly rejects ETH. All treasury funds are USDC only.

---

## How These Three Contracts Connect to Each Other

```
PLOT holders delegate → GovernorPlot vote
                              │
                         67% vote passes
                              │
                       TimelockController queues
                              │
                    (2-day delay for exit opportunity)
                              │
                       TimelockController executes
                              ├── Treasury.withdraw(to, amount, proposalHash)
                              ├── Treasury.initiateBuyback(usdcAmount)
                              ├── BondCalculator.setDomainBaseBond(domain, newBond)
                              ├── EmissionController.setPriceFeed(newFeed)
                              └── any other protocol parameter change
```

```
EmissionController (drips PLOT)
    │
    ├── recordSnapshot24h() / recordSnapshot7d()  [OPERATOR_ROLE keeper]
    │
    └── checkCircuitBreaker() [anyone]
          │
          ├── 7d drop >60% → emergencyMode=true
          │       └── only admin (Foundation → GovernorPlot) can deactivate
          │
          └── 24h drop >30% → emissionsPaused=true (48h)
                    └── auto-resumes after 48h
```

---

## Testing

Test files and counts:
- `test/EmissionController.t.sol` — 24 tests
- `test/GovernorPlot.t.sol` — 10 tests
- `test/Treasury.t.sol` — 17 tests

```bash
~/.config/.foundry/bin/forge test --match-contract "EmissionControllerTest|GovernorPlotTest|TreasuryTest" -v
```

Key scenarios by contract:

**EmissionController:**
- `test_CurrentRateBps_Year1/2/3/4/5Plus` — emission schedule correct
- `test_CircuitBreaker_30pctDrop_PausesEmissions` — 24h breaker triggers
- `test_CircuitBreaker_60pctDrop_EmergencyMode` — 7d breaker triggers
- `test_PauseExpires_MintingResumes` — auto-resume after 48h

**GovernorPlot:**
- `test_FullProposalLifecycle_ExecutesTarget` — end-to-end governance
- `test_Supermajority_Below67pct_Defeated` — 50/50 vote fails
- `test_Supermajority_67pct_Succeeds` — 100% for vote passes

**Treasury:**
- `test_Veto_AfterExpiry_Reverts` — veto expires correctly
- `test_InitiateBuyback_ExceedsCap_Reverts` — 10% cap enforced
- `test_Withdraw_VetoedProposal_Reverts` — vetoed proposals blocked
