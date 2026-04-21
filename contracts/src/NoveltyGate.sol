// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./ClaimRegistry.sol";

/**
 * @title NoveltyGate
 * @notice On-chain bridge that accepts SNS oracle results and forwards them to ClaimRegistry.
 *         The off-chain Semantic Novelty Service (SNS) computes embeddings + cosine similarity,
 *         then an authorized oracle address calls submitNoveltyResult() with the finding.
 *
 *         Similarity thresholds (in basis points, 10000 = 1.0):
 *           >= 9500 → auto-reject (near-certain paraphrase)
 *           9000-9499 → flagged (higher bond tier, treated as reject in v1)
 *           < 9000 → novel (passes to challenge window)
 */
contract NoveltyGate is AccessControl {
    bytes32 public constant SNS_ORACLE_ROLE = keccak256("SNS_ORACLE_ROLE");

    ClaimRegistry public immutable claimRegistry;

    // Threshold above which a claim is considered a duplicate (inclusive)
    uint16 public noveltyRejectThresholdBps = 9000; // 0.90 cosine similarity

    struct NoveltyRecord {
        uint16 similarityBps;      // 0-10000 (cosine similarity * 10000)
        bytes32 justificationHash; // keccak256 of justification JSON stored on Arweave
        bytes32 nearestClaimId;    // most similar existing claim (bytes32(0) if none)
        bool processed;
    }

    mapping(bytes32 => NoveltyRecord) public noveltyRecords;

    event NoveltyResultSubmitted(
        bytes32 indexed claimId,
        bool passed,
        uint16 similarityBps,
        bytes32 nearestClaimId,
        bytes32 justificationHash
    );

    event ThresholdUpdated(uint16 oldThresholdBps, uint16 newThresholdBps);

    constructor(address admin, address _claimRegistry) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        claimRegistry = ClaimRegistry(_claimRegistry);
    }

    /**
     * @notice Called by the off-chain SNS oracle after computing semantic similarity.
     * @param claimId         The claim being evaluated.
     * @param similarityBps   Cosine similarity * 10000 (0-10000).
     * @param nearestClaimId  Most similar existing claim ID, or bytes32(0) if none found.
     * @param justificationHash keccak256 of the JSON justification stored on Arweave.
     */
    function submitNoveltyResult(
        bytes32 claimId,
        uint16 similarityBps,
        bytes32 nearestClaimId,
        bytes32 justificationHash
    ) external onlyRole(SNS_ORACLE_ROLE) {
        require(!noveltyRecords[claimId].processed, "NoveltyGate: already processed");
        require(similarityBps <= 10000, "NoveltyGate: invalid similarity bps");

        bool passed = similarityBps < noveltyRejectThresholdBps;

        noveltyRecords[claimId] = NoveltyRecord({
            similarityBps: similarityBps,
            justificationHash: justificationHash,
            nearestClaimId: nearestClaimId,
            processed: true
        });

        emit NoveltyResultSubmitted(claimId, passed, similarityBps, nearestClaimId, justificationHash);

        claimRegistry.recordNoveltyResult(claimId, passed);
    }

    /**
     * @notice Governance-adjustable reject threshold. Must be between 5000 (0.50) and 9900 (0.99).
     */
    function setRejectThreshold(uint16 thresholdBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(thresholdBps >= 5000 && thresholdBps <= 9900, "NoveltyGate: threshold out of range");
        emit ThresholdUpdated(noveltyRejectThresholdBps, thresholdBps);
        noveltyRejectThresholdBps = thresholdBps;
    }

    function getNoveltyRecord(bytes32 claimId) external view returns (NoveltyRecord memory) {
        return noveltyRecords[claimId];
    }
}
