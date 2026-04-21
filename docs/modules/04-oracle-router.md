# Module 4: Oracle Router & Dispute Resolution

**Contracts:** `OracleRouter.sol`, `InternalVote.sol`

**Role in the system:** Adjudicates disputed claims. When a challenger disputes a claim,
InternalVote opens a weighted-quorum vote among VOTER_ROLE holders. Once quorum is reached,
OracleRouter executes the outcome: updating claim status, releasing/slashing bonds, and
recording the voter-assigned domain.

**Dependencies:** Module 1 (ClaimRegistry, BondEscrow), Module 3 (ChallengeWindow),
Module 5 (ConfidenceScorer)

---

## Two-Contract Design

These two contracts have separate concerns:

| Contract | Concern |
|----------|---------|
| `InternalVote` | Runs the vote: open → cast → finalize. Enforces quorum and voter roles. |
| `OracleRouter` | Executes the outcome: updates ClaimRegistry, releases/slashes bonds, finalizes domain. |

InternalVote holds `INTERNAL_VOTE_ROLE` on OracleRouter, meaning only the vote contract can
trigger resolution. OracleRouter holds `ORACLE_ROUTER_ROLE` on ClaimRegistry, BondEscrow, and
ChallengeWindow.

---

## InternalVote — `src/InternalVote.sol`

### The `VoteState` struct

```solidity
struct VoteState {
    uint256 weightFor;      // total voting weight in favor (claim is valid)
    uint256 weightAgainst;  // total voting weight against (claim is invalid)
    uint256 openedAt;       // 0 if vote not yet opened
    bool    finalized;      // true after finalizeVote() called
}
```

### Voter weights

Each voter has a weight stored in `mapping(address => uint256) public voterWeight`. Default weight
is 1 if not explicitly set. Admin can set higher weights for more reputable or stake-weighted voters.

In v1, weight is set manually by admin. In v2, this will be replaced by PLOT stake amount
(integration with domain pools).

### openVote()

```solidity
function openVote(bytes32 claimId) external
```

- Permissionless — any address may open a vote
- Requires claim status is `Disputed` (set by ChallengeWindow.challenge())
- Records `openedAt` timestamp; emits `VoteOpened`

### castVote()

```solidity
function castVote(bytes32 claimId, bool support) external onlyRole(VOTER_ROLE)
```

- `support = true` → submitter wins (claim is accurate)
- `support = false` → challenger wins (claim is inaccurate)
- Each voter can only vote once per claim
- Accumulates weighted votes in `weightFor` or `weightAgainst`

### finalizeVote()

```solidity
function finalizeVote(bytes32 claimId) external
```

- Permissionless — any address can trigger once quorum is reached
- Requires `weightFor + weightAgainst >= quorumWeight`
- Tie (equal weights) resolves as **rejected** (challenger wins)
- Computes:
  - `verified = weightFor > weightAgainst`
  - `rawScore = weightFor * 100 / totalWeight` (0-100)
  - Calls `ConfidenceScorer.computeScore(rawScore, domain)` for domain adjustment
- Calls `OracleRouter.executeResolution(claimId, verified, score, domain)`

### Quorum

Default `quorumWeight` set at deployment. Admin can change it via `setQuorumWeight()`.

If quorum is never reached (too few voters), the vote remains open indefinitely. In v2, a
timeout mechanism will auto-reject claims where no resolution is possible.

---

## OracleRouter — `src/OracleRouter.sol`

### executeResolution()

This is the single function that ties everything together when a dispute is settled:

```solidity
function executeResolution(
    bytes32 claimId,
    bool verified,                  // true = submitter wins
    uint96 score,                   // 0-100 confidence score
    ClaimRegistry.Domain voterAssignedDomain
) external onlyRole(INTERNAL_VOTE_ROLE) nonReentrant
```

**Path A: Submitter wins (verified = true)**
1. `claimRegistry.resolveVerified(claimId, score)` → Status: Verified
2. `bondEscrow.releaseBond(claimId)` → submitter gets USDC back
3. `challengeWindow.slashChallengerBond(claimId, voterPool)` → challenger loses bond
   - 60% goes to submitter, 20% to voter pool, 20% to treasury

**Path B: Challenger wins (verified = false)**
1. `claimRegistry.resolveRejected(claimId)` → Status: Rejected
2. `bondEscrow.slashBond(claimId, challenger, voterPool)` → submitter loses bond
   - 60% goes to challenger, 20% to voter pool, 20% to treasury
3. `challengeWindow.releaseChallengerBond(claimId)` → challenger gets USDC back

**Domain finalization:**
After either path, if the domain hasn't been finalized yet:
```solidity
if (!c.domainFinalized) {
    claimRegistry.finalizeDomain(claimId, voterAssignedDomain);
}
```
The voter-assigned domain is now permanently recorded on the claim.

### releaseSubmitterBond()

```solidity
function releaseSubmitterBond(bytes32 claimId) external nonReentrant
```

Called by a keeper after an unchallenged claim is verified. When there's no challenger,
`BondEscrow.releaseBond()` isn't called by `executeResolution()` (that path only applies to
disputed claims). This separate function handles the unchallenged case:

- Requires claim is Verified
- Requires no challenger (window.challenger == address(0))
- Calls `bondEscrow.releaseBond(claimId)` → submitter gets USDC back

---

## Voter Domain Tagging

A key feature of dispute resolution is that **voters correct the domain** if the submitter
declared the wrong one. This matters because domain determines the bond level and routing.

When `castVote()` is called, the voter is implicitly agreeing with the current `voterAssignedDomain`
on the claim (which starts as the submitter's `selfDeclaredDomain`). In v2, voters will explicitly
submit a domain tag alongside their vote.

For v1:
- Voters vote on accuracy only (support/against)
- Domain correction is done by admin calling `ClaimRegistry.finalizeDomain()` separately if needed
- The `voterAssignedDomain` passed to `executeResolution()` is taken from the claim's current
  `voterAssignedDomain` field (which equals `selfDeclaredDomain` unless manually corrected)

---

## Full Dispute Flow Example

```
1. Submitter posts claim: "Apple stock will hit $300 by end of year"
   → Domain: Finance, Complexity: Medium → Bond: $1,000
   → Status: Submitted

2. SNS: similarity 0.65 → novel
   → NoveltyGate.submitNoveltyResult(passed=true)
   → Status: Pending

3. Keeper: ChallengeWindow.openWindow(claimId)
   → 2-hour window starts

4. Challenger: ChallengeWindow.challenge(claimId, 500e6)
   → $500 challenger bond locked
   → Status: Disputed

5. Keeper: InternalVote.openVote(claimId)
   → VoteState created

6. Voter A: InternalVote.castVote(claimId, false)  ← against (thinks claim is wrong)
   → weightAgainst += 1

7. Voter B: InternalVote.castVote(claimId, false)
   → weightAgainst += 1

8. Voter C: InternalVote.castVote(claimId, false)
   → weightAgainst += 1   (quorum = 3 reached)

9. Anyone: InternalVote.finalizeVote(claimId)
   → verified = false (weightFor=0, weightAgainst=3)
   → OracleRouter.executeResolution(claimId, false, 0, Finance)

10. OracleRouter.executeResolution():
    → ClaimRegistry.resolveRejected(claimId)   → Status: Rejected
    → BondEscrow.slashBond(claimId, challenger, voterPool)
       → challenger gets 60% of $1,000 = $600
       → voterPool gets $200
       → treasury gets $200
    → ChallengeWindow.releaseChallengerBond(claimId)
       → challenger gets their $500 bond back
    → ClaimRegistry.finalizeDomain(claimId, Finance)
```

Net result: Submitter loses $1,000. Challenger nets $600 + $500 = $1,100 (profit $100).
Voters share $200. Treasury gets $200.

---

## Role Wiring Required at Deployment

After deploying these contracts, the following roles must be granted:

```solidity
// OracleRouter needs to call ClaimRegistry, BondEscrow, and ChallengeWindow
claimRegistry.grantRole(ORACLE_ROUTER_ROLE, address(oracleRouter));
bondEscrow.grantRole(ORACLE_ROUTER_ROLE, address(oracleRouter));
challengeWindow.grantRole(ORACLE_ROUTER_ROLE, address(oracleRouter));

// InternalVote needs to call OracleRouter
oracleRouter.grantRole(INTERNAL_VOTE_ROLE, address(internalVote));
```

---

## Phase 2: UMA Integration (Stubbed in v1)

In v1, all disputes go through InternalVote. In Phase 2 (post-launch), OracleRouter will be
extended with UMA OptimisticOracleV3 integration for escalated disputes:

```
Layer 1: InternalVote (PLOT stakers, ~90% of disputes)
  └── if appealed by losing party (2× bond) →
Layer 2: UMA OOv3 (DVM arbitration, ~8%)
  └── if UMA unavailable →
Layer 3: Emergency queue (holds claim in Disputed state until resolved)
```

The UMA interface is designed but stubbed — `routeDispute()` in OracleRouter currently only
calls `startInternalVote()`. The UMA path will be added in a future upgrade via governance.

---

## Testing

Test files: `test/OracleRouter.t.sol` (20 tests), `test/InternalVote.t.sol` (included in OracleRouter tests)

```bash
~/.config/.foundry/bin/forge test --match-contract OracleRouterTest -v
```

Key scenarios:
- `test_ExecuteResolution_Verified` — submitter wins, bond returned
- `test_ExecuteResolution_Rejected` — challenger wins, bond slashed
- `test_FinalizeVote_TieResolvesRejected` — tie breaks against submitter
- `test_ReleaseSubmitterBond_Unchallenged` — unchallenged claim bond returned
