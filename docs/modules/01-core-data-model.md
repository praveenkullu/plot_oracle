# Module 1: Core Data Model

**Contracts:** `PLOTToken.sol`, `BondCalculator.sol`, `BondEscrow.sol`, `ClaimRegistry.sol`

**Role in the system:** Foundation. Every other module imports or calls these four contracts.
No external dependencies — testable in complete isolation.

---

## 1. PLOTToken — `src/PLOTToken.sol`

### What it is

PLOT is the protocol's governance and staking token. It is a standard ERC-20 with three additions:
1. **ERC20Votes** — token holders can delegate their balance as voting power for GovernorPlot
2. **Mint authority** — only addresses with `MINTER_ROLE` (EmissionController) can issue new PLOT
3. **Slash authority** — only addresses with `SLASHER_ROLE` (BondEscrow, InternalVote) can burn tokens
   from a specific address as a penalty

### Key parameters

| Parameter | Value | Notes |
|-----------|-------|-------|
| `MAX_SUPPLY` | 1,000,000,000 PLOT (1B) | Hard cap, enforced on every mint |
| Initial mint | 200,000,000 PLOT (20%) | Minted to treasury on deployment |
| Decimals | 18 | Standard ERC-20 |
| Name / Symbol | "PLOT" / "PLOT" | |

### Important functions

```solidity
// Mint new PLOT — only MINTER_ROLE (EmissionController)
function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE)

// Slash (burn) tokens as penalty — only SLASHER_ROLE
function slash(address account, uint256 amount) external onlyRole(SLASHER_ROLE)
```

### Why ERC20Votes?

GovernorPlot needs to tally token-weighted votes at a specific block number (snapshot), not the
current balance. ERC20Votes adds checkpointing: every transfer records the new balance at the
current block so historical balances can be queried accurately. Token holders must self-delegate
(call `delegate(address(self))`) to activate their voting weight.

### Constructor

```solidity
constructor(address admin, address treasury)
```
- `admin` receives `DEFAULT_ADMIN_ROLE` and `MINTER_ROLE`
- `treasury` receives 200M PLOT immediately (20% initial allocation)

---

## 2. BondCalculator — `src/BondCalculator.sol`

### What it is

A pure calculation contract. Given a domain and complexity level, it returns the USDC amount a
submitter must bond. Nothing is stored here except the current domain base rates — all logic is
stateless math.

### Why USDC?

Bonds must be stable-value to be a reliable deterrent. A $100 bond should always mean approximately
$100 worth of economic risk, regardless of crypto volatility. PLOT would create perverse incentives
(bond becomes worthless if PLOT crashes).

### Domain base rates (in USDC, 6 decimals)

| Domain ID | Name | Base Bond | Why |
|-----------|------|-----------|-----|
| 0 | General | $100 | Low economic sensitivity |
| 1 | Science | $250 | Moderate complexity |
| 2 | Finance | $500 | Market-moving potential |
| 3 | Medical | $750 | Health/safety stakes |
| 4 | Regulatory | $1,000 | Legal consequences |
| 5 | National Security | $2,500 | Highest stakes |

### Complexity multipliers (basis points; 10,000 = 1×)

| Constant | BPS | Multiplier | Use Case |
|----------|-----|------------|----------|
| `COMPLEXITY_LOW` | 10,000 | 1× | Single verifiable fact |
| `COMPLEXITY_MEDIUM` | 20,000 | 2× | Multiple facts, cross-reference |
| `COMPLEXITY_HIGH` | 30,000 | 3× | Comparative, multi-source |
| `COMPLEXITY_VERY_HIGH` | 50,000 | 5× | Specialized, restricted sources |

### Bond formula

```
bond = domainBaseBond[domain] × complexityBps / 10_000
```

Example: Finance domain (`$500`) × high complexity (`3×`) = `$1,500` (1,500e6 USDC units)

### Governance constraint

The `setDomainBaseBond()` function (callable only by `GOVERNANCE_ROLE`) enforces a **25% maximum
change per vote** to prevent governance from abruptly repricing all claims:

```solidity
require(newBond <= old * 125 / 100 && newBond >= old * 75 / 100, "change exceeds 25% governance limit")
```

---

## 3. BondEscrow — `src/BondEscrow.sol`

### What it is

A USDC custody contract. When a submitter posts a claim, their USDC bond is locked here and cannot
be moved until the claim resolves. Two authorized contracts can trigger release or slash:
- `CLAIM_REGISTRY_ROLE` → `lockBond()` (called by ClaimRegistry on submission)
- `ORACLE_ROUTER_ROLE` → `releaseBond()` or `slashBond()` (called by OracleRouter on resolution)

### Bond outcomes

| Outcome | What happens |
|---------|-------------|
| Unchallenged or submitter wins | `releaseBond()` → 100% returned to submitter |
| Submitter loses dispute | `slashBond()` → 60% to challenger, 20% to voter pool, 20% to treasury |

### Important design: one bond per claim

The `lockedBond[claimId]` mapping allows exactly one active bond per claim ID. The
`lockBond()` function reverts if called twice for the same claimId:

```solidity
require(lockedBond[claimId] == 0, "BondEscrow: bond already locked");
```

### SafeERC20

All USDC transfers use OpenZeppelin's `SafeERC20` wrapper which checks for transfer failures
and reverts cleanly — essential because some ERC-20 tokens return `false` instead of reverting
on failure.

---

## 4. ClaimRegistry — `src/ClaimRegistry.sol`

### What it is

The core state machine of the protocol. Every claim that passes through Plot Protocol starts and
ends here. It stores minimal on-chain state (hashes, status, scores) and delegates actual content
storage to Arweave (off-chain).

### The `Claim` struct

```solidity
struct Claim {
    bytes32 claimId;             // keccak256(submitter + contentHash + timestamp + nonce)
    bytes32 contentHash;         // keccak256 of full text — Arweave lookup key
    address submitter;
    uint256 bond;                // USDC amount locked in BondEscrow
    Status  status;              // Current state (see below)
    Domain  selfDeclaredDomain;  // Submitter's best guess of topic domain
    Domain  voterAssignedDomain; // Corrected by voter consensus (if disputed)
    bool    domainFinalized;     // True after OracleRouter.finalizeDomain() called
    uint96  confidenceScore;     // 0-100, set at resolution
    uint256 submittedAt;
    bytes32 previousVersion;     // Linked list for versioned truth updates
    bytes32 nextVersion;
    bool    noveltyPassed;
}
```

### Status state machine

```
Submitted ──► Pending ──► Disputed ──► Verified
    │                                 │
    │            Pending ──────────── ┘ (unchallenged)
    │
    └──► Rejected  (novelty failed, or voter consensus: false)
    └──► Superseded  (a newer version of this claim was submitted)
```

Transitions are one-way — no state can go backward.

### Key functions and who calls them

| Function | Caller | What it does |
|----------|--------|-------------|
| `submitClaim()` | Submitter (any address) | Creates claim, locks bond, enforces daily cap |
| `recordNoveltyResult()` | NoveltyGate (NOVELTY_GATE_ROLE) | Moves to Pending or Rejected |
| `markDisputed()` | OracleRouter (ORACLE_ROUTER_ROLE) | Moves Pending → Disputed |
| `resolveVerified()` | OracleRouter | Moves Disputed → Verified with score |
| `resolveRejected()` | OracleRouter | Moves Disputed → Rejected |
| `resolveUnchallenged()` | OracleRouter | Moves Pending → Verified with score=100 |
| `finalizeDomain()` | OracleRouter | Sets voter-assigned domain |

### submitClaim() flow

```solidity
function submitClaim(
    bytes32 contentHash,       // keccak256 of full claim text
    Domain  selfDeclaredDomain,
    uint16  complexityBps,     // one of the COMPLEXITY_* constants from BondCalculator
    bytes32 supersedes         // bytes32(0) if new claim; prior claimId if updating
) external nonReentrant returns (bytes32 claimId)
```

1. Checks `contentHash` not already seen (exact-duplicate prevention)
2. Checks per-address daily cap (default 10/day, governance-adjustable)
3. Queries `BondCalculator.calculateBond()` to determine bond amount
4. Creates the `Claim` struct
5. Calls `BondEscrow.lockBond()` to pull USDC from submitter
6. If `supersedes != bytes32(0)`, marks the old claim as Superseded

### Content hash as Arweave pointer

The `contentHash` is the only link between the on-chain record and the full content on Arweave.
The off-chain Node.js service uploads the claim text to Arweave, gets back a transaction ID,
and the `contentHash` is used to look up the Arweave record. This means:
- On-chain: tiny (bytes32 hash + metadata)
- Off-chain: unlimited size for evidence, sources, vote rationales

### Versioned truth

Claims are linked in a doubly linked list via `previousVersion` / `nextVersion`. When a submitter
updates a claim (facts changed, new information), they call `submitClaim(... supersedes=oldId)`:
- Old claim becomes `Superseded`
- New claim's `previousVersion` points to old claim
- Old claim's `nextVersion` points to new claim

Queries for the latest version always follow `nextVersion` to the end of the chain.

### Anti-spam: daily cap

```solidity
uint256 today = block.timestamp / 1 days;
if (_lastSubmissionDay[msg.sender] != today) {
    _dailyCount[msg.sender] = 0;          // reset at midnight UTC
    _lastSubmissionDay[msg.sender] = today;
}
require(_dailyCount[msg.sender] < dailySubmissionCap, "daily cap reached");
```

Default cap: 10 submissions per address per day. Governance-adjustable via `setDailySubmissionCap()`.

---

## How These Four Contracts Connect

```
User calls ClaimRegistry.submitClaim()
    │
    ├── BondCalculator.calculateBond(domain, complexity)
    │       └── returns USDC amount required
    │
    └── BondEscrow.lockBond(claimId, msg.sender, amount)
            └── pulls USDC from submitter into escrow
```

Later, when resolved:
```
OracleRouter.executeResolution(claimId, verified, score, domain)
    │
    ├── ClaimRegistry.resolveVerified/Rejected(claimId, score)
    │
    ├── BondEscrow.releaseBond(claimId)   ← if submitter wins
    │       └── sends USDC back to submitter
    │
    └── BondEscrow.slashBond(claimId, challenger, voterPool)  ← if submitter loses
            └── splits USDC: 60% challenger / 20% voters / 20% treasury
```

---

## Testing

Test file: `test/ClaimRegistry.t.sol`, `test/BondCalculator.t.sol`, etc.

Run all tests:
```bash
~/.config/.foundry/bin/forge test --match-contract "ClaimRegistryTest|BondCalculatorTest|BondEscrowTest|PLOTTokenTest" -v
```

Key test scenarios to understand:
- `test_SubmitClaim_LocksBond` — verifies USDC is moved to escrow
- `test_DailyCap_Enforced` — submitter blocked after 10/day
- `test_DuplicateHash_Rejected` — second claim with same contentHash reverts
- `test_CalculateBond_Finance_High` — $500 × 3x = $1,500
