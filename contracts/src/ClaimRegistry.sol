// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./BondEscrow.sol";
import "./BondCalculator.sol";

/**
 * @title ClaimRegistry
 * @notice Core state machine for Plot Protocol claims.
 *         Hybrid on-chain/off-chain: state on Base L2, full content on Arweave.
 *         Status flow: Submitted -> Pending -> Disputed -> Verified | Rejected | Superseded
 */
contract ClaimRegistry is AccessControl, ReentrancyGuard {
    bytes32 public constant ORACLE_ROUTER_ROLE = keccak256("ORACLE_ROUTER_ROLE");
    bytes32 public constant NOVELTY_GATE_ROLE = keccak256("NOVELTY_GATE_ROLE");

    // Domain must match BondCalculator domain constants
    enum Domain {
        General,
        Science,
        Finance,
        Medical,
        Regulatory,
        NationalSecurity
    }

    enum Status {
        Submitted,
        Pending,
        Disputed,
        Verified,
        Rejected,
        Superseded
    }

    struct Claim {
        bytes32 claimId;
        bytes32 contentHash;        // keccak256 of full content; points to Arweave record
        address submitter;
        uint256 bond;
        Status status;
        Domain selfDeclaredDomain;  // submitter's best guess
        Domain voterAssignedDomain; // set by OracleRouter after vote consensus
        bool domainFinalized;
        uint96 confidenceScore;     // 0-100 after resolution
        uint256 submittedAt;
        bytes32 previousVersion;    // linked list for versioned truth
        bytes32 nextVersion;
        bool noveltyPassed;
    }

    BondEscrow public immutable bondEscrow;
    BondCalculator public immutable bondCalculator;

    mapping(bytes32 => Claim) public claims;
    // Content hash -> claimId for exact-duplicate detection (Layer 1 novelty)
    mapping(bytes32 => bytes32) public contentHashToClaim;

    // Per-address daily submission cap (10/day, governance-adjustable)
    uint256 public dailySubmissionCap = 10;
    mapping(address => uint256) private _dailyCount;
    mapping(address => uint256) private _lastSubmissionDay;

    uint256 private _claimNonce;

    event ClaimSubmitted(
        bytes32 indexed claimId,
        address indexed submitter,
        bytes32 contentHash,
        Domain selfDeclaredDomain,
        uint256 bond
    );
    event StatusChanged(bytes32 indexed claimId, Status oldStatus, Status newStatus);
    event DomainFinalized(bytes32 indexed claimId, Domain voterAssignedDomain);
    event NoveltyResult(bytes32 indexed claimId, bool passed);
    event ConfidenceScoreSet(bytes32 indexed claimId, uint96 score);
    event ClaimSuperseded(bytes32 indexed oldClaimId, bytes32 indexed newClaimId);

    constructor(address admin, address _bondEscrow, address _bondCalculator) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        bondEscrow = BondEscrow(_bondEscrow);
        bondCalculator = BondCalculator(_bondCalculator);
    }

    function submitClaim(
        bytes32 contentHash,
        Domain selfDeclaredDomain,
        uint16 complexityBps,
        bytes32 supersedes    // pass bytes32(0) if new claim (not a version update)
    ) external nonReentrant returns (bytes32 claimId) {
        require(contentHash != bytes32(0), "ClaimRegistry: empty content hash");
        require(contentHashToClaim[contentHash] == bytes32(0), "ClaimRegistry: duplicate content");

        // Daily cap check
        uint256 today = block.timestamp / 1 days;
        if (_lastSubmissionDay[msg.sender] != today) {
            _dailyCount[msg.sender] = 0;
            _lastSubmissionDay[msg.sender] = today;
        }
        require(_dailyCount[msg.sender] < dailySubmissionCap, "ClaimRegistry: daily cap reached");
        _dailyCount[msg.sender]++;

        uint256 bond = bondCalculator.calculateBond(uint8(selfDeclaredDomain), complexityBps);

        claimId = keccak256(abi.encodePacked(msg.sender, contentHash, block.timestamp, _claimNonce++));

        claims[claimId] = Claim({
            claimId: claimId,
            contentHash: contentHash,
            submitter: msg.sender,
            bond: bond,
            status: Status.Submitted,
            selfDeclaredDomain: selfDeclaredDomain,
            voterAssignedDomain: selfDeclaredDomain, // default until finalized
            domainFinalized: false,
            confidenceScore: 0,
            submittedAt: block.timestamp,
            previousVersion: supersedes,
            nextVersion: bytes32(0),
            noveltyPassed: false
        });

        contentHashToClaim[contentHash] = claimId;

        // Lock submitter's bond in escrow
        bondEscrow.lockBond(claimId, msg.sender, bond);

        // Mark superseded claim if this is a version update
        if (supersedes != bytes32(0)) {
            require(claims[supersedes].claimId == supersedes, "ClaimRegistry: unknown superseded claim");
            claims[supersedes].nextVersion = claimId;
            _updateStatus(supersedes, Status.Superseded);
            emit ClaimSuperseded(supersedes, claimId);
        }

        emit ClaimSubmitted(claimId, msg.sender, contentHash, selfDeclaredDomain, bond);
    }

    // Called by NoveltyGate after SNS attestation check
    function recordNoveltyResult(bytes32 claimId, bool passed)
        external
        onlyRole(NOVELTY_GATE_ROLE)
    {
        Claim storage c = claims[claimId];
        require(c.claimId == claimId, "ClaimRegistry: unknown claim");
        require(c.status == Status.Submitted, "ClaimRegistry: wrong status");

        c.noveltyPassed = passed;
        emit NoveltyResult(claimId, passed);

        if (passed) {
            _updateStatus(claimId, Status.Pending);
        } else {
            _updateStatus(claimId, Status.Rejected);
        }
    }

    // Called by ChallengeWindow when a dispute is opened
    function markDisputed(bytes32 claimId) external onlyRole(ORACLE_ROUTER_ROLE) {
        Claim storage c = claims[claimId];
        require(c.claimId == claimId, "ClaimRegistry: unknown claim");
        require(c.status == Status.Pending, "ClaimRegistry: not pending");
        _updateStatus(claimId, Status.Disputed);
    }

    // Called by OracleRouter after vote resolves
    function resolveVerified(bytes32 claimId, uint96 score) external onlyRole(ORACLE_ROUTER_ROLE) {
        _resolveWithScore(claimId, Status.Verified, score);
    }

    function resolveRejected(bytes32 claimId) external onlyRole(ORACLE_ROUTER_ROLE) {
        _resolveWithScore(claimId, Status.Rejected, 0);
    }

    // Unchallenged window expiry — OracleRouter calls this to finalize
    function resolveUnchallenged(bytes32 claimId, uint96 score) external onlyRole(ORACLE_ROUTER_ROLE) {
        Claim storage c = claims[claimId];
        require(c.claimId == claimId, "ClaimRegistry: unknown claim");
        require(c.status == Status.Pending, "ClaimRegistry: not pending");
        _resolveWithScore(claimId, Status.Verified, score);
    }

    // Voter-assigned domain set after dispute resolution
    function finalizeDomain(bytes32 claimId, Domain voterAssignedDomain)
        external
        onlyRole(ORACLE_ROUTER_ROLE)
    {
        Claim storage c = claims[claimId];
        require(c.claimId == claimId, "ClaimRegistry: unknown claim");
        require(!c.domainFinalized, "ClaimRegistry: domain already finalized");
        c.voterAssignedDomain = voterAssignedDomain;
        c.domainFinalized = true;
        emit DomainFinalized(claimId, voterAssignedDomain);
    }

    function setDailySubmissionCap(uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(cap > 0, "ClaimRegistry: zero cap");
        dailySubmissionCap = cap;
    }

    function getClaim(bytes32 claimId) external view returns (Claim memory) {
        return claims[claimId];
    }

    function _resolveWithScore(bytes32 claimId, Status newStatus, uint96 score) internal {
        Claim storage c = claims[claimId];
        require(c.claimId == claimId, "ClaimRegistry: unknown claim");
        c.confidenceScore = score;
        emit ConfidenceScoreSet(claimId, score);
        _updateStatus(claimId, newStatus);
    }

    function _updateStatus(bytes32 claimId, Status newStatus) internal {
        Status old = claims[claimId].status;
        claims[claimId].status = newStatus;
        emit StatusChanged(claimId, old, newStatus);
    }
}
