# Module 5: Confidence Scoring

**Contract:** `ConfidenceScorer.sol`

**Role in the system:** Translates a raw vote outcome into a nuanced confidence score that
accounts for the domain's inherent risk level. A Finance claim verified with 80% vote agreement
should carry less confidence than a General claim with 80% agreement — because Finance has higher
stakes and v1 lacks additional signal sources for high-stakes domains.

**Dependencies:** Module 1 (ClaimRegistry for Domain enum), Module 4 (InternalVote calls it)

---

## The Problem ConfidenceScorer Solves

After InternalVote resolves a dispute, it has:
- `weightFor` — votes supporting the claim
- `weightAgainst` — votes rejecting it
- `total = weightFor + weightAgainst`

A naive raw score: `rawScore = weightFor * 100 / total`

But this ignores domain context:
- A `rawScore` of 90 in a General domain is very reliable
- A `rawScore` of 90 in National Security, where errors have catastrophic consequences and v1
  lacks specialized validators, should be downgraded to reflect lower confidence

The `ConfidenceScorer` applies a **domain multiplier** to discount the raw score for
high-stakes domains.

---

## The Formula

```
adjustedScore = clamp(rawScore × domainMultiplierBps / BPS_DENOM, 0, 100)
```

Where:
- `rawScore` is 0–100 (from vote weights)
- `domainMultiplierBps` is 0–10000 (BPS; 10000 = no adjustment, 9000 = 10% discount)
- `BPS_DENOM = 10_000`
- `clamp` ensures the output never exceeds 100

---

## Default Domain Multipliers

| Domain | Multiplier BPS | Effective Discount | Rationale |
|--------|---------------|-------------------|-----------|
| General | 10,000 | 0% | Full confidence; low stakes |
| Science | 9,500 | 5% | Moderate complexity; needs expert voters |
| Finance | 9,000 | 10% | Market-moving potential |
| Medical | 8,500 | 15% | Health stakes; expert validators needed |
| Regulatory | 8,000 | 20% | Legal consequences; specialized knowledge required |
| National Security | 7,500 | 25% | Highest stakes; most conservative |

Example: Finance claim, 90% vote agreement:
- `rawScore = 90`
- `domainMultiplierBps = 9000`
- `adjustedScore = 90 × 9000 / 10000 = 81`

This can be raised toward 10,000 via governance as the system matures and more expert validators
join the Finance domain pool.

---

## computeScore()

```solidity
function computeScore(uint96 rawScore, ClaimRegistry.Domain domain)
    external view returns (uint96)
```

Called by `InternalVote.finalizeVote()` just before calling `OracleRouter.executeResolution()`.

The score is only computed when `verified = true`. When `verified = false` (claim rejected),
the score is always 0.

Safety fallback: if `domainMultiplierBps[domain] == 0` (unregistered domain), multiplier
defaults to `BPS_DENOM` (10,000 = no adjustment). This prevents a misconfiguration from
silently zeroing all scores.

---

## The Three Display Labels

The computed score maps to one of three labels that users see:

| Score Range | Label | Hex Color | Consumer Meaning |
|-------------|-------|-----------|-----------------|
| 70 – 100 | **Verified** | Green | Survived active adversarial scrutiny; high confidence |
| 30 – 69 | **Unchallenged** | Yellow | Passed the window with limited challenger coverage |
| 0 – 29 | **Unchecked** | Red | Minimal challenger coverage; low confidence |

Note: "Unchallenged" and "Unchecked" don't mean the claim was disputed — they describe how
much economic scrutiny the claim survived. A claim that passes a 2-hour window with no
challengers present scores 100 from `resolveUnchallenged()`, but its label may still
reflect limited scrutiny if the domain pool was thin.

---

## Governance Adjustability

Domain multipliers can be updated by admin via:

```solidity
function setDomainMultiplier(ClaimRegistry.Domain domain, uint256 multiplierBps)
    external onlyRole(DEFAULT_ADMIN_ROLE)
```

- Must be > 0
- No cap (can be set above 10,000 to boost scores — reserved for future use)
- In production, this should be controlled by GovernorPlot via timelock

---

## Connection to Other Modules

```
InternalVote.finalizeVote()
    │
    ├── rawScore = weightFor * 100 / totalWeight
    │
    └── ConfidenceScorer.computeScore(rawScore, claim.voterAssignedDomain)
              │
              └── adjustedScore returned to InternalVote
                        │
                        └── OracleRouter.executeResolution(claimId, verified, adjustedScore, domain)
                                  │
                                  └── ClaimRegistry.resolveVerified(claimId, adjustedScore)
                                           └── claim.confidenceScore = adjustedScore (stored permanently)
```

---

## Future Enhancements (v2)

The whitepaper describes a richer formula:

```
ConfidenceScore = w1*ChallengerExposure + w2*DomainPoolDepth
                + w3*CitationDiversity + w4*StakeRatio
                + w5*TimeInWindow
```

In v1, only the vote ratio is used as the primary signal, adjusted by domain multiplier.
Governance can update the formula as off-chain signal sources are integrated:
- `ChallengerExposure` — count of active challengers monitoring the domain pool (off-chain oracle)
- `CitationDiversity` — number of independent primary sources (parsed from Arweave claim data)
- `StakeRatio` — claim bond vs. average domain bond (already available on-chain)

---

## Testing

Test file: `test/ConfidenceScorer.t.sol` (16 tests)

```bash
~/.config/.foundry/bin/forge test --match-contract ConfidenceScorerTest -v
```

Key scenarios:
- `test_ComputeScore_General_NoAdjustment` — 1.0× multiplier, raw = adjusted
- `test_ComputeScore_Finance_Discounts` — 0.9× multiplier reduces score
- `test_ComputeScore_NeverExceeds100` — clamp check
- `test_SetDomainMultiplier_Admin` — governance update works
- `test_SetDomainMultiplier_ZeroReverts` — zero multiplier rejected
