# Plot Protocol — Implementation Plan

**Source:** whitepaper_v02.md (pages 1-25)
**Date:** 2026-04-09
**Updated:** 2026-04-09 (tech stack added)
**Status:** Confirmed

---

## Design Decisions

1. **Reputation system removed** — bonds serve as the quality/spam filter from day 1. No cold-start problem. Accuracy stats can be tracked as a passive view function later.
2. **Scope validation gate removed** — voters determine domain scope during dispute resolution. Self-declared domain by submitter is used for routing; voters confirm or correct it. Final voter-consensus domain tag stored permanently on Arweave.
3. **Pipeline simplified** from 3 gates to 2: Novelty Detection → Truth Verification.
4. **Dual-asset model (Option A) chosen** — USDC for payments/bonds, PLOT for governance/staking/access.
5. **Single verification tier (Standard)** for v1 — Flash and Deep tiers added later via governance.
6. **3 confidence labels** (Verified/Unchallenged/Unchecked) instead of 5.
7. **UMA integration stubbed** for v1 — internal vote first, UMA as phase 2.
8. **Base (by Coinbase) chosen as L2** — native USDC (Circle mint), low gas (~$0.001-0.01), EAS native, Coinbase onramp, UMA OOv3 deployed.
9. **USDC on Base** as the stablecoin — native Circle-minted USDC (`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`), no bridge risk for bonds.

---

## Tech Stack Overview

### Why Base over Arbitrum/Optimism

| Factor | Base | Arbitrum | Optimism |
|--------|------|----------|----------|
| **Native USDC** | Yes (Circle mint) | Yes (bridged + native) | Bridged only |
| **Gas costs** | ~$0.001-0.01 | ~$0.01-0.05 | ~$0.01-0.05 |
| **Coinbase onramp** | Direct fiat->USDC | Requires bridge | Requires bridge |
| **EAS support** | Native | Available | Available |
| **Developer tooling** | OnchainKit, Paymaster | Mature | Mature |
| **UMA OOv3** | Deployed | Deployed | Deployed |

Native USDC is critical — bonds are the core economic mechanism and bridge risk is unacceptable. Coinbase Smart Wallet provides gasless onboarding via paymaster sponsorship. EAS is native on Base for voter credential attestations.

### Global / Shared Stack

| Layer | Technology | Rationale |
|-------|-----------|-----------|
| L2 Chain | Base (Chain ID 8453) | Native USDC, low gas, Coinbase ecosystem |
| Stablecoin | USDC (native on Base) | Circle-minted, no bridge risk |
| Smart Contracts | Solidity 0.8.x + Foundry | Industry standard, best testing/fuzzing |
| Contract Framework | OpenZeppelin 5.x | Audited ERC-20, AccessControl, ReentrancyGuard |
| Off-chain Storage | Arweave (via Irys/Bundlr) | Permanent storage per whitepaper |
| Backend API | Node.js/TypeScript + Express | Event indexing, SNS service, CVS service |
| Indexer | Ponder or Envio | Base-native event indexing (replaces subgraph) |
| Testing | Foundry (on-chain) + Vitest (off-chain) | Fast, parallel, fork-testing |
| Deployment | Foundry scripts | Deterministic deploys with verification |

### Contract Architecture on Base

```
Base L2 (Chain ID 8453)
├── PLOTToken.sol                 (ERC-20 + slashing)
├── ClaimRegistry.sol             (core state machine)
├── BondEscrow.sol                (USDC lock/release/slash)
├── NoveltyGate.sol               (content hash + SNS attestation check)
├── ChallengeWindow.sol           (optimistic challenge timer)
├── OracleRouter.sol              (dispute routing)
├── InternalVote.sol              (commit-reveal + domain tagging)
├── ConfidenceScorer.sol          (weighted formula)
├── EmissionController.sol        (token emissions + circuit breakers)
├── GovernorPlot.sol              (OZ Governor + Timelock)
└── Treasury.sol                  (Gnosis Safe + auto-rebalance)

External integrations:
├── USDC (0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) — native on Base
├── Chainlink VRF v2.5 — jury randomness
├── Chainlink Price Feeds — PLOT/USD for circuit breakers
├── EAS (0x4200000000000000000000000000000000000021) — native on Base
├── Irys/Bundlr — Arweave uploads
└── UMA OOv3 (Phase 5) — external escalation
```

---

## Module Overview (6 Modules)

```
Module 1: Core Data Model            <-- Foundation
    |
    |-- Module 2: Novelty Detection       <-- needs M1
    |-- Module 3: Truth Verification      <-- needs M1
    |       |
    |       +-- Module 4: Oracle Router    <-- needs M1, M3
    |               |    (voters tag domain here)
    |               +-- Module 5: Confidence Scoring <-- needs M1, M4
    |
    +-- Module 6: Bond & Token Economics  <-- needs M1
```

**Parallel paths** (after M1):
- Path A: M2 -> M3 -> M4 -> M5 (verification pipeline)
- Path B: M6 (token economics)

---

## Module 1: Core Data Model & Claim Registry

**Prerequisites:** None — this is the foundation.

### Tech Stack

| Component | Technology | Notes |
|-----------|-----------|-------|
| ClaimRegistry.sol | Solidity + Foundry | Core state machine, structs, status enum |
| Arweave uploader | Irys SDK (TypeScript) | Bundle claim content + metadata for permanent storage |
| Content hashing | keccak256 (on-chain) | Content hash as Arweave pointer |
| Access control | OpenZeppelin AccessControl | Roles: SUBMITTER_ROLE, ORACLE_ROUTER_ROLE, ADMIN_ROLE |
| Daily cap tracking | Solidity `mapping(address => DailyCount)` | Per-address spam control |
| Events/Indexing | Ponder indexer | Index ClaimSubmitted, StatusChanged, DomainFinalized |

### What it does
- Solidity structs for Claims: ID, content hash, submitter, bond amount, status, self-declared domain (submitter's best guess), voter-assigned domain (consensus from resolution, null until voted), confidence score, timestamps, version pointers
- `ClaimRegistry` contract: submit (with self-declared domain), update status, update domain tag, read claims
- Hybrid on-chain/off-chain: state on L2, full content on Arweave
- Status enum: `Submitted -> Pending -> Disputed -> Verified -> Rejected -> Superseded`
- Versioned truth via linked list
- Per-address daily submission cap (simple spam control, e.g., 10/day, governance-adjustable)

### Key interfaces
```solidity
function submitClaim(
    bytes calldata claimData,
    bytes32 contentHash,
    uint8 selfDeclaredDomain,  // submitter's best guess
    uint256 bond
) external returns (bytes32 claimId);

function finalizeDomain(
    bytes32 claimId,
    uint8 voterAssignedDomain  // set by vote consensus
) external;  // only callable by OracleRouter
```

### On-Chain (L2 Smart Contracts)
- Claim ID and content hash (pointer to Arweave)
- Submitter address and bond amount
- Verification status (submitted / pending / disputed / verified / rejected / superseded)
- Confidence score
- Self-declared domain and voter-assigned domain
- Novelty check result
- Timestamp and version pointers (previous/next)

### Off-Chain (Arweave)
- Full claim text and structured metadata
- Supporting evidence and source citations
- Dispute arguments and vote rationales
- Media attachments
- Complete verification history
- Voter-assigned domain tag (consensus scope)

### Testable independently
Yes — pure state machine, no external dependencies.

---

## Module 2: Gate 1 — Novelty Detection

**Prerequisites:** Module 1

### Tech Stack

| Component | Technology | Notes |
|-----------|-----------|-------|
| Layer 1: Content hashing | Solidity (on-chain) | keccak256 duplicate detection in ClaimRegistry |
| Layer 2: SNS service | Python + FastAPI | Sentence transformer embeddings, off-chain |
| Embedding model | all-MiniLM-L6-v2 (384-dim) | Fast, good semantic similarity, runs on CPU |
| Vector DB | Qdrant (self-hosted) | Cosine similarity search per domain cluster |
| SNS attestation | EAS on Base | Signed attestation of novelty result committed on-chain |
| Layer 3: Justification validation | TypeScript rules engine | Reject empty/trivial novelty justifications |
| Topic-cluster cooldowns | Redis + BullMQ | Rate-limit submissions within semantic neighborhoods |
| NoveltyGate.sol | Solidity | Verifies SNS attestation before allowing claim to proceed |

### What it does
- **Layer 1 (on-chain):** Content hashing for exact/near-exact duplicate detection. Hash full content. Two claims with identical content hashes are flagged as duplicates regardless of wording.
- **Layer 2 (off-chain):** Semantic Novelty Service (SNS). Sentence transformer embeddings, vector DB, cosine similarity against existing verified claims in same domain.

| Similarity | Classification | Action |
|------------|---------------|--------|
| 0.95+ | Near-certain paraphrase | Auto-reject |
| 0.90-0.95 | Likely paraphrase | Flagged; higher bond required to proceed |
| 0.80-0.90 | Related but potentially novel | Normal processing |
| Below 0.80 | Clearly novel | Passes novelty gate |

- **Layer 3:** Novelty justification — structured field:
```json
{
    "nearest_existing_claim": "claim_id_12345",
    "similarity_score": 0.78,
    "novel_elements": [
        "Adds effective date (March 1) not in existing claim",
        "Specifies SWIFT disconnection for 7 of 14 banks",
        "Identifies Country X as the target"
    ]
}
```
- SNS output committed on-chain as signed attestation
- Topic-cluster cooldowns to prevent Sybil flooding of semantic neighborhoods
- Empty or trivially weak novelty justifications auto-rejected

### Testable independently
Yes — Layer 1 is pure hashing logic. Layer 2 is an independent off-chain service with its own test suite. Layer 3 is input validation.

---

## Module 3: Gate 2 — Truth Verification (Optimistic Challenge)

**Prerequisites:** Module 1

### Tech Stack

| Component | Technology | Notes |
|-----------|-----------|-------|
| ChallengeWindow.sol | Solidity + Foundry | Time-based state machine with bond escrow |
| USDC bond escrow | BondEscrow.sol (IERC20 transfers) | Lock submitter + challenger bonds in contract |
| Timer management | `block.timestamp` | Window expiry checks on-chain |
| Challenge events | Solidity events + Ponder | Index ChallengeOpened, Disputed, WindowExpired |
| Off-chain notifications | Node.js WebSocket server | Alert challengers of new claims in their domain |

### What it does
- Claims passing novelty enter a challenge window
- v1: Standard tier only (2 hours, 1x bond)
- Any participant can dispute by staking counter-bond + evidence
- If unchallenged -> accepted, bond returned + verification reward
- If challenged -> escalates to Oracle Router (Module 4)
- Submitter's self-declared domain used for routing to voter pools

### Provisional status labels

| Stage | Label | Consumer Sees |
|-------|-------|---------------|
| Submitted, no challenges | "Submitted -- Pending Verification" | Claim text, sources, bond amount |
| Challenge window active | "Unchallenged -- [X min remaining]" | Above + countdown + active challenger count |
| Disputed | "Disputed -- Resolution Pending" | Above + challenger's counter-evidence |
| Verified | "Verified" + confidence score | Full verified claim with provenance |

### Future tiers (not in v1)

| Tier | Window | Bond | Use Case |
|------|--------|------|----------|
| Flash | 15 min | 5x standard | Breaking news |
| Standard | 2 hours | 1x standard | Daily news (v1) |
| Deep | 24 hours | 0.5x standard | Scientific/historical |

### Testable independently
Yes — time-based state machine. Mock the clock, test transitions.

---

## Module 4: Oracle Router & Dispute Resolution

**Prerequisites:** Module 1, Module 3

### Tech Stack

| Component | Technology | Notes |
|-----------|-----------|-------|
| OracleRouter.sol | Solidity | Routes disputes to internal vote, UMA, or emergency queue |
| InternalVote.sol | Solidity | Commit-reveal voting with domain tagging |
| VRF for jury selection | Chainlink VRF v2.5 (on Base) | Verifiable random jury selection (15-31 voters) |
| Commit-reveal scheme | Solidity keccak256 commitments | Voter commits hash(vote + domain + salt), reveals later |
| Domain pool registry | Solidity `mapping(uint8 => DomainPool)` | Stakers self-select into domain pools |
| UMA integration (Phase 5) | UMA OptimisticOracleV3 (on Base) | Stubbed interface in v1, wired in Phase 5 |
| Voter credentials | EAS attestations (optional) | Domain expertise proofs for vote weighting |

### What it does
- `OracleRouter` contract routes disputes to appropriate resolution backend

```solidity
contract OracleRouter {
    enum Backend { INTERNAL, UMA, FALLBACK, EMERGENCY_QUEUE }

    function routeDispute(bytes32 claimId, bytes evidence) external {
        // Layer 1: Try internal PLOT-staker resolution first
        if (internalQuorumReachable(claimId)) {
            startInternalVote(claimId, evidence);
        }
        // Layer 2: Escalate to UMA if internal fails or is appealed
        else if (umaHealthy()) {
            escalateToUMA(claimId, evidence);
        }
        // Layer 3: Fallback if UMA unavailable
        else if (fallbackAvailable()) {
            escalateToFallback(claimId, evidence);
        }
        // Emergency: queue until resolution available
        else {
            queueDispute(claimId, evidence);
        }
    }
}
```

### Layer 1 — Internal PLOT-Staker Vote (~90% of disputes)
- PLOT stakers self-select into domain pools
- Claims routed to pool matching submitter's self-declared domain
- Random jury selection (15-31 voters), weighted by stake
- Commit-reveal voting
- **Voters submit:** resolution vote (accurate/inaccurate) + **domain tag** (confirm or correct the submitter's declared domain)
- Simple majority + supermajority (>66%) + quorum (5% of pool)
- Domain consensus: if >50% of voters tag a different domain than declared, the voter-assigned domain overrides
- Winning voters earn fees; losing voters slashed 1-5%
- Escalation: losing party posts 2x bond to escalate to Layer 2

### Layer 2 — UMA Optimistic Oracle + DVM (~8%) — Stubbed for v1

Integration flow (for when UMA is integrated):
```
1. Plot's Oracle Router calls OptimisticOracleV3.assertTruth(
       claim: "Claim XYZ is [accurate/inaccurate]",
       asserter: Plot dispute contract address,
       callbackRecipient: Plot Oracle Router contract,
       currency: USDC,
       bond: [scaled to dispute],
       liveness: [per tier],
       identifier: ASSERT_TRUTH
   )
2. If no one disputes within UMA's liveness period -> assertion settles
3. If disputed within UMA -> escalates to UMA's DVM
   - $UMA holders vote (NOT PLOT holders)
   - Commit phase: 24 hours / Reveal phase: 24 hours
   - Majority wins; voters rewarded with UMA inflation
4. UMA calls back to Plot's Oracle Router with resolution
```

### Token roles (clearly separated)

| Function | Token Used | Rationale |
|----------|-----------|-----------|
| Claim submission bonds | PLOT or USDC | Skin-in-the-game for submitters |
| Internal dispute bonds | PLOT | Challenge requires PLOT stake |
| Internal dispute voting | PLOT | First-line resolution by domain experts |
| UMA escalation bond | USDC | UMA's OO supports whitelisted ERC-20s |
| UMA DVM voting | $UMA | UMA's native mechanism |
| Governance | PLOT | Protocol parameter changes |
| Bounties | PLOT or USDC | Flexibility for demand-side users |

### Layer 3 — Emergency Queue (~2%)
- Heartbeat monitor on UMA contract responsiveness
- Disputes enter "pending resolution" queue
- Challenge windows extend indefinitely until oracle service restored
- Claims labeled "disputed -- pending resolution" and do not enter verified archive

### What gets stored permanently (Arweave) after resolution
- Full claim text + structured metadata
- Voter-assigned domain tag (the consensus scope)
- Resolution outcome + vote rationales
- Evidence from both sides
- Confidence score
- Source citations

### Testable independently
Yes — mock vote mechanism, verify domain tagging logic. Each layer testable in isolation.

### Note on unchallenged claims
If a claim passes the challenge window unchallenged, its self-declared domain stands as the final tag. Only disputed claims get voter-corrected domain tags.

---

## Module 5: Confidence Scoring

**Prerequisites:** Module 1, Module 4 (dispute outcomes)

### Tech Stack

| Component | Technology | Notes |
|-----------|-----------|-------|
| ConfidenceScorer.sol | Solidity pure/view functions | On-chain weighted formula computation |
| Weight parameters | Solidity governance-adjustable storage | Changeable via GovernorPlot |
| ChallengerExposure oracle | Off-chain service -> on-chain update | Count active challengers per domain pool |
| Label assignment | Solidity enum (Green/Yellow/Red) | Based on score thresholds |
| Cross-domain bounty trigger | Solidity + Chainlink Automation | Auto-post bounty when score < 30 |

### What it does
- Confidence score (0-100) from observable on-chain signals:
```
ConfidenceScore = w1*ChallengerExposure + w2*DomainPoolDepth
                + w3*CitationDiversity + w4*StakeRatio
                + w5*TimeInWindow
```

Where:
- **ChallengerExposure** = number of active challengers online and monitoring the domain pool during the challenge window
- **DomainPoolDepth** = total value staked by challengers in the relevant domain pool
- **CitationDiversity** = number of independent primary sources cited (1 source = low confidence; 4+ = high)
- **StakeRatio** = ratio of the claim's bond to the average bond in that domain
- **TimeInWindow** = percentage of the challenge window that elapsed

Weight calibration set by governance, adjustable per domain.

### 3 display labels

| Score | Label | Visual | Meaning |
|-------|-------|--------|---------|
| 70-100 | **Verified** | Green | Survived active adversarial scrutiny |
| 30-69 | **Unchallenged** | Yellow | Passed window but limited scrutiny |
| 0-29 | **Unchecked** | Red | Minimal or no challenger coverage |

### Minimum challenger requirements
For domains with real-world consequences (finance, regulatory, medical), the protocol requires a minimum number of active challengers before claims can achieve "Verified" (Green) status.

### Cross-domain verification bounties
When a claim scores below 30, the protocol automatically posts a verification bounty from the maintenance endowment. Rewards challengers who dispute or endorse via confirmation bond.

### Testable independently
Yes — pure math on mock inputs.

---

## Module 6: Bond Mechanics & Token Economics

**Prerequisites:** Module 1, ERC-20 token contract

### Tech Stack

| Component | Technology | Notes |
|-----------|-----------|-------|
| PLOTToken.sol | Solidity ERC-20 + OpenZeppelin | Fixed max supply, slashing authority, AccessControl |
| BondCalculator.sol | Solidity pure functions | Domain base rate lookup, complexity multiplier |
| BondEscrow.sol | Solidity | Lock/release/slash USDC bonds via IERC20 |
| RevenueDistributor.sol | Solidity | USDC fees -> PLOT staker revenue pool (pro-rata) |
| EmissionController.sol | Solidity | Decreasing emission curve with governance adjustment |
| Circuit breakers | Solidity + Chainlink Price Feed | PLOT/USD oracle for death spiral triggers |
| GovernorPlot.sol | OpenZeppelin Governor + TimelockController | PLOT-weighted voting, 14-day delay |
| Treasury | Gnosis Safe multisig | Foundation veto during first 2 years (training wheels) |

### PLOT Token
- ERC-20 with slashing authority
- Fixed maximum supply
- Decreasing emission curve

### USD-Denominated Bonds
Since scope is self-declared and may be corrected by voters:
- **Submitter picks domain -> bond set by that domain's base rate**
- If voters re-classify to a higher-bond domain: no additional penalty (honest mistake)
- If voters re-classify to a lower-bond domain: difference refunded
- Incentivizes accurate self-declaration without punishing mistakes

### Base bond schedule (USD-equivalent)

| Domain | Base Bond | Rationale |
|--------|-----------|-----------|
| General | $100 | Low economic sensitivity |
| Science | $250 | Moderate verification complexity |
| Finance | $500 | High market impact potential |
| Regulatory / Compliance | $1,000 | Direct commercial and legal consequences |
| National Security | $2,500 | Highest stakes |

These are governance-adjustable starting points.

### Adaptive bond sizing (v1: simplified)
- Base bond x domain rate only
- Dispute-rate adjustment and impact-based scaling deferred to v2

### Dual-Asset Model (Option A)
- USDC for all payments, bonds, and bounties
- PLOT required to operate on the network (license, not payment)
- PLOT stakers earn share of protocol revenue (USDC fees -> revenue distribution)
- PLOT-exclusive governance

### How each participant earns

| Participant | Earns From | Risk |
|-------------|-----------|------|
| Agent operators | Verification rewards for claims passing all gates; challenger bond when they dispute false claims | Bond loss if claims fail gates or lose disputes |
| Voters / validators | Fees for correct votes in internal dispute resolution | Stake slashing for incorrect votes |
| Node operators | Fees from serving API queries | Infrastructure costs |
| Challengers | Slashed bonds from false claims they catch | Bond loss if their challenges fail |

### Bond flow
- Lock at submission -> unchallenged = return + reward
- Challenged + submitter wins = return + challenger's slashed bond
- Challenged + submitter loses = 60% to challenger, 20% to voters, 20% to treasury

### Emission schedule
```
Year 1: 100% of planned emissions (bootstrap)
Year 2: max(80%, 100% - (organic_revenue / target_revenue * 50%))
Year 3: max(60%, same formula applied)
...
Hard floor: emissions never go below 20% of Year 1 rate
```

### Death spiral prevention
Circuit breaker triggers (via price oracle):
```
If PLOT price drops > 30% in 24 hours:
    - Pause new PLOT emissions for 48 hours
    - Increase minimum bond sizes by 50% (in USD terms)
    - Reduce maximum claim submission rate per agent by 50%
    - Trigger emergency governance vote on parameter adjustment

If PLOT price drops > 60% in 7 days:
    - Emergency pause on non-essential protocol operations
    - Treasury begins PLOT buyback from stablecoin reserves (capped at 10%)
    - All emissions redirected to stablecoin revenue pool
    - Governance enters emergency mode (shorter voting, higher quorum)
```

### Anti-governance-capture safeguards
- Supermajority vote (67%+) for bond parameter changes
- 14-day delay between proposal and implementation
- Maximum change rate: bonds cannot change by more than 25% per governance vote
- Foundation multisig veto during first 2 years (training wheels)

### Spam control (replaces reputation system)
- Flat per-address submission cap (10/day, governance-adjustable)
- Bond as primary economic spam filter ($100+ at risk per claim)

### Testable independently
Yes — token is standard ERC-20 + slashing. Bond calculator is pure functions. Circuit breakers are condition checks.

---

## Build Order

| Phase | Modules | Key Tech | What's testable |
|-------|---------|----------|-----------------|
| **1** | M1 + M6 | Foundry, OZ, USDC on Base, Irys SDK | Submit claims, lock USDC bonds, PLOT token, Arweave storage |
| **2** | M2 + M3 (parallel) | Python/FastAPI, Qdrant, EAS, Solidity timers | Novelty filtering + challenge windows |
| **3** | M4 (internal vote only) | Chainlink VRF, commit-reveal | Full dispute flow with voter domain tagging |
| **4** | M5 | Solidity pure functions, Chainlink Automation | Confidence scores on resolved claims |
| **5** | M4-L2 (UMA integration) | UMA OOv3 SDK | External escalation path |

### Development Environment Setup

```
# Contracts
forge init plot-protocol && cd plot-protocol
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0
forge install smartcontractkit/chainlink@v2.19.0

# Base Sepolia testnet for development
# Chain ID: 84532
# RPC: https://sepolia.base.org
# Block Explorer: https://sepolia.basescan.org

# Off-chain services
# SNS + CVS: Python 3.11+ with FastAPI, sentence-transformers
# Indexer: Ponder (ponder.sh) configured for Base
# Arweave: Irys SDK (@irys/sdk)
```

### Base Mainnet Addresses (for integration)

| Contract | Address | Notes |
|----------|---------|-------|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | Native Circle-minted |
| EAS | `0x4200000000000000000000000000000000000021` | OP Stack native |
| Schema Registry | `0x4200000000000000000000000000000000000020` | For EAS schemas |
| Chainlink VRF Coordinator | Verify at docs.chain.link | VRF v2.5 on Base |
| Chainlink ETH/USD Feed | Verify at docs.chain.link | For gas cost estimation |
| UMA OOv3 | Verify at docs.uma.xyz | For Phase 5 integration |

---

## Hallucination Defense (Cross-cutting, not a separate module)

Built into the claim submission and verification flow.

### Tech Stack

| Component | Technology | Notes |
|-----------|-----------|-------|
| URL fetcher + archiver | Node.js + Playwright | Fetch + snapshot cited URLs (handles JS-rendered pages) |
| Semantic comparison | Python (same FastAPI as SNS) | Claim-vs-source similarity scoring |
| Source Grounding Score | Python -> EAS attestation on Base | 0.0-1.0 score committed on-chain |
| Complexity classifier | TypeScript rules engine | Keyword matching, entity count, domain rarity |
| Archive storage | Arweave (via Irys) | Permanent source snapshots alongside claims |

### Citation Verification Service (CVS)
- Every claim must include >=1 source URL
- Off-chain service fetches + archives cited URL (snapshot)
- Computes semantic similarity between claim and source
- Assigns Source Grounding Score (0.0-1.0)
- Score <0.5 -> flagged, cannot pass challenge window without confirmation bond

### Claim Complexity Scoring
- Rule-based classifier adjusting bond requirements:

| Complexity | Example | Bond Multiplier |
|------------|---------|-----------------|
| Low | Single verifiable fact | 1x |
| Medium | Multiple facts, cross-reference required | 2x |
| High | Comparative, multi-source, niche | 3x |
| Very High | Specialized, restricted-access sources | 5x |

### Deferred to v2
- Multi-model cross-checking (multiple LLM families)
- Automated challenge bots (source checker, cross-reference, consistency)
- Source reputation registry

---

## Data Lifecycle — Versioned Truth

- Permanent storage creates tension with changing reality
- Old records are never modified or deleted, but new records can supersede them
- Original marked "superseded" (not wrong, just no longer current)
- Full version history preserved permanently

### Update triggers
- **Automated monitoring:** Agent operators run persistent watchers
- **User-initiated requests:** Bounties asking whether a claim is still accurate
- **Decay challenges:** Any participant can stake to challenge currency of an existing claim. If outdated and corrected version submitted, challenger earns reward from maintenance endowment

### Default query behavior
Returns most current version. Full version history available for compliance, legal discovery, and research.

---

## Evaluation Summary

### What these design decisions gain
- **2 fewer modules** (8 -> 6), ~30% less surface area
- **No ML/NLP dependency** for scope classification
- **No cold-start problem** — bonds work from day 1
- **Simpler bond calculation** — flat per-domain, no reputation multiplier
- **More decentralized** scope determination — human consensus
- **Cleaner pipeline:** submit -> novelty check -> challenge window -> vote (with scope tagging) -> store

### Risks to monitor
- **Spam without reputation gating:** $100+ bond per claim is probably sufficient deterrent. Monitor at launch.
- **No economic reward for track record:** High-quality agents get no bond discount. Acceptable for v1.
- **Voter burden:** Voters now determine scope AND accuracy. Mitigated by scope being a single dropdown.
- **Unchallenged claims have imprecise domain routing:** Self-declared domain may be wrong. Low impact — it's metadata, not truth.

### Base L2-specific risks

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Base sequencer centralization | Liveness (not safety) — if sequencer goes down, no new tx | All OP Stack L2s share this; doesn't affect protocol logic. L1 force-inclusion as fallback |
| Base fee spikes during congestion | Higher gas costs for vote commits/reveals | Gas costs still 10-100x cheaper than L1; bond amounts dwarf gas |
| Chainlink VRF availability on Base | Jury selection blocked if VRF down | Fallback to commit-reveal with blockhash (less random but functional) |
| USDC regulatory risk | Circle could freeze protocol USDC | Treasury diversification; monitor regulatory landscape |
| Base ecosystem maturity | Fewer battle-tested DeFi integrations | UMA, Chainlink, EAS all already deployed; core dependencies covered |

### Future additions (post-v1, via governance)
- Reputation system (passive accuracy tracking -> bond discounts)
- Flash and Deep verification tiers
- Multi-model cross-checking for hallucination defense
- Automated challenge bot infrastructure
- Source reputation registry
- Anti-consensus-bias mechanisms (rationale hashing, diversity checks)
- Entity-relation triple hashing for novelty detection
