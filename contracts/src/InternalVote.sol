// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./ClaimRegistry.sol";
import "./OracleRouter.sol";
import "./ConfidenceScorer.sol";

/**
 * @title InternalVote
 * @notice Weighted-quorum voting for disputed Plot Protocol claims.
 *         VOTER_ROLE holders cast votes; admin sets per-voter weights (default 1).
 *         Once total vote weight reaches quorumWeight, anyone may call finalizeVote().
 *         Outcome (verified/rejected) is forwarded to OracleRouter.executeResolution().
 *
 *         Score = weightFor * 100 / totalWeight (0-100), meaningful when verified=true.
 *         Domain defaults to the claim's voterAssignedDomain (set to selfDeclaredDomain at
 *         submission); governance may update it separately via ClaimRegistry.finalizeDomain.
 */
contract InternalVote is AccessControl {
    bytes32 public constant VOTER_ROLE = keccak256("VOTER_ROLE");

    ClaimRegistry    public immutable claimRegistry;
    OracleRouter     public immutable oracleRouter;
    ConfidenceScorer public immutable confidenceScorer;

    uint256 public quorumWeight;

    mapping(address => uint256) public voterWeight;

    struct VoteState {
        uint256 weightFor;
        uint256 weightAgainst;
        uint256 openedAt;   // 0 if not yet opened
        bool    finalized;
    }

    mapping(bytes32 => VoteState)                        public voteStates;
    mapping(bytes32 => mapping(address => bool))         public hasVoted;

    event VoteOpened(bytes32 indexed claimId);
    event VoteCast(bytes32 indexed claimId, address indexed voter, bool support, uint256 weight);
    event VoteFinalized(bytes32 indexed claimId, bool verified, uint256 weightFor, uint256 weightAgainst);

    constructor(
        address admin,
        address _claimRegistry,
        address _oracleRouter,
        address _confidenceScorer,
        uint256 _quorumWeight
    ) {
        require(_quorumWeight > 0, "InternalVote: zero quorum");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        claimRegistry    = ClaimRegistry(_claimRegistry);
        oracleRouter     = OracleRouter(_oracleRouter);
        confidenceScorer = ConfidenceScorer(_confidenceScorer);
        quorumWeight     = _quorumWeight;
    }

    /**
     * @notice Open a vote for a Disputed claim. Permissionless.
     */
    function openVote(bytes32 claimId) external {
        ClaimRegistry.Claim memory c = claimRegistry.getClaim(claimId);
        require(c.status == ClaimRegistry.Status.Disputed, "InternalVote: claim not disputed");
        VoteState storage v = voteStates[claimId];
        require(v.openedAt == 0, "InternalVote: vote already opened");
        v.openedAt = block.timestamp;
        emit VoteOpened(claimId);
    }

    /**
     * @notice Cast a vote on an open dispute. VOTER_ROLE only.
     * @param support true = claim is valid (submitter wins), false = claim is invalid (challenger wins).
     */
    function castVote(bytes32 claimId, bool support) external onlyRole(VOTER_ROLE) {
        VoteState storage v = voteStates[claimId];
        require(v.openedAt != 0,                       "InternalVote: vote not opened");
        require(!v.finalized,                          "InternalVote: vote finalized");
        require(!hasVoted[claimId][msg.sender],        "InternalVote: already voted");

        uint256 weight = _getWeight(msg.sender);
        hasVoted[claimId][msg.sender] = true;

        if (support) {
            v.weightFor += weight;
        } else {
            v.weightAgainst += weight;
        }

        emit VoteCast(claimId, msg.sender, support, weight);
    }

    /**
     * @notice Finalize vote once total weight >= quorumWeight. Permissionless.
     *         Calls OracleRouter.executeResolution() with the computed outcome.
     *         Tie (weightFor == weightAgainst) resolves as rejected.
     */
    function finalizeVote(bytes32 claimId) external {
        VoteState storage v = voteStates[claimId];
        require(v.openedAt != 0,   "InternalVote: vote not opened");
        require(!v.finalized,      "InternalVote: already finalized");

        uint256 total = v.weightFor + v.weightAgainst;
        require(total >= quorumWeight, "InternalVote: quorum not reached");

        v.finalized = true;

        bool   verified = v.weightFor > v.weightAgainst;
        uint96 rawScore = verified ? uint96((v.weightFor * 100) / total) : 0;

        ClaimRegistry.Claim memory c = claimRegistry.getClaim(claimId);
        uint96 score = verified
            ? confidenceScorer.computeScore(rawScore, c.voterAssignedDomain)
            : 0;

        emit VoteFinalized(claimId, verified, v.weightFor, v.weightAgainst);

        oracleRouter.executeResolution(claimId, verified, score, c.voterAssignedDomain);
    }

    // ── Governance ──────────────────────────────────────────────────────────

    function setVoterWeight(address voter, uint256 weight) external onlyRole(DEFAULT_ADMIN_ROLE) {
        voterWeight[voter] = weight;
    }

    function setQuorumWeight(uint256 weight) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(weight > 0, "InternalVote: zero quorum");
        quorumWeight = weight;
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    function _getWeight(address voter) internal view returns (uint256) {
        uint256 w = voterWeight[voter];
        return w > 0 ? w : 1;
    }
}
