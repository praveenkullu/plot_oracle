# Module 3: Challenge Window

**Contract:** `ChallengeWindow.sol`

**Role in the system:** Optimistic verification layer. After a claim passes novelty detection
(Status: Pending), it enters a 2-hour window. Anyone who believes the claim is false can
stake a counter-bond to challenge it. If no one challenges, the claim is automatically
verified. If challenged, it escalates to dispute resolution (Module 4).

**Dependencies:** Module 1 (ClaimRegistry for status updates, USDC via SafeERC20)

---

## The Optimistic Design

"Optimistic" means: **assume the claim is true and only investigate if someone objects.**

This is the same design used by Optimistic Rollups and UMA's Optimistic Oracle. The key insight
is that most claims are either obviously correct (no one wastes money challenging them) or
obviously incorrect (challengers earn rewards). Only genuinely ambiguous cases need full dispute
resolution.

Benefits vs. reviewing every claim:
- No voter overhead for clear-cut cases (90%+ of claims in practice)
- Challengers are incentivized to find false claims (they earn 60% of the slashed bond)
- Submitters are incentivized to only submit accurate claims (they risk losing their bond)

---

## State Diagram

```
Claim Status: Pending
       │
       ▼
ChallengeWindow.openWindow()   ← permissionless, anyone can open
  creates Window{openedAt, expiresAt, challenger=0, finalized=false}
       │
       │──── 2 hours pass, no challenge ────────────────►
       │                                                  │
       │                                     finalizeUnchallenged()
       │                                    (permissionless call)
       │                                       calls ClaimRegistry
       │                                    .resolveUnchallenged(score=100)
       │                                          │
       │                                    Status: Verified ✓
       │
       │──── challenger calls challenge() ──────────────►
                  challenger bond locked in ChallengeWindow
                  ClaimRegistry.markDisputed() called
                       │
                  Status: Disputed
                       │
                  → InternalVote opens (Module 4)
                       │
           ┌───────────┴───────────┐
      Submitter wins          Challenger wins
           │                        │
   releaseBond (BondEscrow)   slashBond (BondEscrow)
   slashChallengerBond        releaseChallengerBond
   (ChallengeWindow)          (ChallengeWindow)
```

---

## ChallengeWindow.sol — Key Details

### The `Window` struct

```solidity
struct Window {
    uint256 openedAt;       // block.timestamp when openWindow() was called
    uint256 expiresAt;      // openedAt + windowDuration (default 2 hours)
    address challenger;     // address(0) if unchallenged
    uint256 challengerBond; // USDC amount staked by challenger (0 if unchallenged)
    bool    finalized;      // prevents double-finalization
}
```

One window per claimId, stored in `mapping(bytes32 => Window) public windows`.

### openWindow()

```solidity
function openWindow(bytes32 claimId) external
```

- Permissionless — anyone can call (typically the submitter or a keeper)
- Requires `claimRegistry.getClaim(claimId).status == Status.Pending`
- Can only be called once per claim (reverts if `windows[claimId].openedAt != 0`)
- Sets `expiresAt = block.timestamp + windowDuration`

### challenge()

```solidity
function challenge(bytes32 claimId, uint256 bondAmount) external nonReentrant
```

- Can be called by any address while `block.timestamp < expiresAt`
- Only one challenger per claim (first come, first served)
- Pulls `bondAmount` USDC from challenger via `safeTransferFrom`
- Calls `claimRegistry.markDisputed(claimId)` — status moves to Disputed

There is no minimum for `bondAmount` in the contract code, but economically, a challenger should
post at least as much as the submitter to have credible skin in the game.

### finalizeUnchallenged()

```solidity
function finalizeUnchallenged(bytes32 claimId) external
```

- Permissionless — any address may trigger (typically a keeper)
- Requires: window exists, has expired, no challenger, not already finalized
- Calls `claimRegistry.resolveUnchallenged(claimId, 100)` — score 100 (full confidence)
- Marks `w.finalized = true` to prevent double-finalization

### releaseChallengerBond() and slashChallengerBond()

These are called by OracleRouter (Module 4) after vote resolution:

```solidity
// Challenger wins (submitter's claim rejected)
function releaseChallengerBond(bytes32 claimId) external onlyRole(ORACLE_ROUTER_ROLE)
    → transfers challengerBond back to challenger

// Challenger loses (submitter's claim verified)
function slashChallengerBond(bytes32 claimId, address voterPool) external onlyRole(ORACLE_ROUTER_ROLE)
    → splits challengerBond: 60% to submitter, 20% to voterPool, 20% to treasury
```

### Window duration

Default: `2 hours`. Range: 1 hour to 30 days. Governance-adjustable via `setWindowDuration()`.

Future tiers (not in v1):
- Flash: 15 minutes, 5× bond — for breaking news
- Deep: 24 hours, 0.5× bond — for scientific/historical claims

---

## Bond Economics

### When does a challenger post a bond?

A challenger stakes their own USDC to signal they are serious. If they're wrong (claim is
actually accurate), they lose their bond. This prevents frivolous challenges that would clog
the dispute resolution system.

### Why 60/20/20 split when submitter wins?

| Recipient | Share | Rationale |
|-----------|-------|-----------|
| Submitter | 60% | Compensation for the hassle of defending a true claim |
| Voter pool | 20% | Reward voters for correctly evaluating the claim |
| Treasury | 20% | Protocol sustainability fund |

The symmetric principle applies when the submitter loses:
- Submitter's bond goes: 60% challenger, 20% voter pool, 20% treasury
- Challenger is rewarded, voters are rewarded, protocol is funded

---

## Interaction with Other Modules

### Before challenge window

1. `ClaimRegistry.submitClaim()` → Status: Submitted (Module 1)
2. `NoveltyGate.submitNoveltyResult()` → Status: Pending (Module 2)
3. `ChallengeWindow.openWindow()` → Window created

### After challenge window

If unchallenged:
- `ChallengeWindow.finalizeUnchallenged()` → Status: Verified
- Keeper calls `OracleRouter.releaseSubmitterBond()` → USDC returned to submitter

If challenged:
- `InternalVote.openVote()` → Dispute voting begins (Module 4)
- `InternalVote.finalizeVote()` → `OracleRouter.executeResolution()` → bond settlement

---

## Testing

Test file: `test/ChallengeWindow.t.sol` (21 tests)

Key scenarios:
```bash
~/.config/.foundry/bin/forge test --match-contract ChallengeWindowTest -v
```

Important test cases:
- `test_OpenWindow_PendingClaim` — window opens successfully
- `test_Challenge_TransfersBond` — USDC moves from challenger to contract
- `test_FinalizeUnchallenged_VerifiesClaim` — expired window finalizes correctly
- `test_Challenge_AfterExpiry_Reverts` — can't challenge after 2 hours
- `test_SlashChallengerBond_CorrectSplit` — 60/20/20 distribution verified
