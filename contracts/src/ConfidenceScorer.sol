// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./ClaimRegistry.sol";

/**
 * @title ConfidenceScorer
 * @notice Refines a raw vote-ratio score (0-100) using a per-domain multiplier.
 *
 *         v1 formula: adjustedScore = clamp(rawScore * domainMultiplierBps / BPS_DENOM, 0, 100)
 *
 *         High-stakes domains start with lower multipliers, reflecting that v1 lacks the
 *         additional off-chain signals (challenger exposure, citation diversity, etc.) that
 *         those domains require for full confidence. Governance can raise multipliers as
 *         additional signal sources are integrated.
 *
 *         Called by InternalVote.finalizeVote() before forwarding the score to OracleRouter.
 */
contract ConfidenceScorer is AccessControl {
    uint256 public constant BPS_DENOM = 10_000;

    // Default domain multipliers (BPS) — all ≤ 10000 (≤ 1x) for v1
    uint256 public constant DEFAULT_GENERAL_BPS           = 10_000; // 1.00x
    uint256 public constant DEFAULT_SCIENCE_BPS           =  9_500; // 0.95x
    uint256 public constant DEFAULT_FINANCE_BPS           =  9_000; // 0.90x
    uint256 public constant DEFAULT_MEDICAL_BPS           =  8_500; // 0.85x
    uint256 public constant DEFAULT_REGULATORY_BPS        =  8_000; // 0.80x
    uint256 public constant DEFAULT_NATIONAL_SECURITY_BPS =  7_500; // 0.75x

    mapping(uint8 => uint256) public domainMultiplierBps;

    event DomainMultiplierSet(ClaimRegistry.Domain indexed domain, uint256 multiplierBps);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        domainMultiplierBps[uint8(ClaimRegistry.Domain.General)]          = DEFAULT_GENERAL_BPS;
        domainMultiplierBps[uint8(ClaimRegistry.Domain.Science)]          = DEFAULT_SCIENCE_BPS;
        domainMultiplierBps[uint8(ClaimRegistry.Domain.Finance)]          = DEFAULT_FINANCE_BPS;
        domainMultiplierBps[uint8(ClaimRegistry.Domain.Medical)]          = DEFAULT_MEDICAL_BPS;
        domainMultiplierBps[uint8(ClaimRegistry.Domain.Regulatory)]       = DEFAULT_REGULATORY_BPS;
        domainMultiplierBps[uint8(ClaimRegistry.Domain.NationalSecurity)]  = DEFAULT_NATIONAL_SECURITY_BPS;
    }

    /**
     * @notice Compute a domain-adjusted confidence score.
     * @param rawScore  Base vote-ratio score (0-100): weightFor * 100 / totalWeight.
     * @param domain    Voter-assigned domain for the claim.
     * @return score    Domain-adjusted score in [0, 100].
     */
    function computeScore(uint96 rawScore, ClaimRegistry.Domain domain)
        external
        view
        returns (uint96)
    {
        uint256 multiplier = domainMultiplierBps[uint8(domain)];
        if (multiplier == 0) multiplier = BPS_DENOM; // safety fallback for unregistered domain
        uint256 adjusted = (uint256(rawScore) * multiplier) / BPS_DENOM;
        return uint96(adjusted > 100 ? 100 : adjusted);
    }

    /**
     * @notice Set per-domain multiplier. Admin only.
     * @param multiplierBps New multiplier in BPS. Must be > 0.
     */
    function setDomainMultiplier(ClaimRegistry.Domain domain, uint256 multiplierBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(multiplierBps > 0, "ConfidenceScorer: zero multiplier");
        domainMultiplierBps[uint8(domain)] = multiplierBps;
        emit DomainMultiplierSet(domain, multiplierBps);
    }
}
