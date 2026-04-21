// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./ClaimRegistry.sol";
import "./BondEscrow.sol";
import "./ChallengeWindow.sol";

/**
 * @title OracleRouter
 * @notice Executes dispute resolution outcomes for Plot Protocol.
 *         Requires ORACLE_ROUTER_ROLE in ClaimRegistry, BondEscrow, and ChallengeWindow.
 *         Only InternalVote (INTERNAL_VOTE_ROLE) may call executeResolution().
 *
 *         Resolution paths:
 *           Verified (submitter wins): resolveVerified → releaseBond → slashChallengerBond
 *           Rejected (challenger wins): resolveRejected → slashBond → releaseChallengerBond
 *
 *         Unchallenged path: ChallengeWindow.finalizeUnchallenged sets Verified directly;
 *           keeper then calls releaseSubmitterBond() to return the escrow bond.
 */
contract OracleRouter is AccessControl, ReentrancyGuard {
    bytes32 public constant INTERNAL_VOTE_ROLE = keccak256("INTERNAL_VOTE_ROLE");

    ClaimRegistry  public immutable claimRegistry;
    BondEscrow     public immutable bondEscrow;
    ChallengeWindow public immutable challengeWindow;

    address public voterPool;

    event DisputeResolved(bytes32 indexed claimId, bool verified, uint96 score);
    event SubmitterBondReleased(bytes32 indexed claimId);

    constructor(
        address admin,
        address _claimRegistry,
        address _bondEscrow,
        address _challengeWindow,
        address _voterPool
    ) {
        require(_voterPool != address(0), "OracleRouter: zero voterPool");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        claimRegistry   = ClaimRegistry(_claimRegistry);
        bondEscrow      = BondEscrow(_bondEscrow);
        challengeWindow = ChallengeWindow(_challengeWindow);
        voterPool       = _voterPool;
    }

    /**
     * @notice Execute resolution after InternalVote reaches quorum.
     * @param claimId             Disputed claim to resolve.
     * @param verified            true = submitter wins; false = challenger wins.
     * @param score               Confidence score (0-100); meaningful only when verified.
     * @param voterAssignedDomain Domain consensus from voters; stored on the claim.
     */
    function executeResolution(
        bytes32 claimId,
        bool verified,
        uint96 score,
        ClaimRegistry.Domain voterAssignedDomain
    ) external onlyRole(INTERNAL_VOTE_ROLE) nonReentrant {
        ChallengeWindow.Window memory w = challengeWindow.getWindow(claimId);
        address challenger      = w.challenger;
        bool hasChallengerBond  = w.challengerBond > 0;

        if (verified) {
            claimRegistry.resolveVerified(claimId, score);
            bondEscrow.releaseBond(claimId);
            if (hasChallengerBond) {
                challengeWindow.slashChallengerBond(claimId, voterPool);
            }
        } else {
            claimRegistry.resolveRejected(claimId);
            bondEscrow.slashBond(claimId, challenger, voterPool);
            if (hasChallengerBond) {
                challengeWindow.releaseChallengerBond(claimId);
            }
        }

        ClaimRegistry.Claim memory c = claimRegistry.getClaim(claimId);
        if (!c.domainFinalized) {
            claimRegistry.finalizeDomain(claimId, voterAssignedDomain);
        }

        emit DisputeResolved(claimId, verified, score);
    }

    /**
     * @notice Release submitter bond after unchallenged window finalization.
     *         Permissionless — anyone may call once the claim is Verified with no challenger.
     */
    function releaseSubmitterBond(bytes32 claimId) external nonReentrant {
        ClaimRegistry.Claim memory c = claimRegistry.getClaim(claimId);
        require(c.status == ClaimRegistry.Status.Verified, "OracleRouter: claim not verified");
        ChallengeWindow.Window memory w = challengeWindow.getWindow(claimId);
        require(w.challenger == address(0), "OracleRouter: disputed claim");
        bondEscrow.releaseBond(claimId);
        emit SubmitterBondReleased(claimId);
    }

    // ── Governance ──────────────────────────────────────────────────────────

    function setVoterPool(address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(pool != address(0), "OracleRouter: zero address");
        voterPool = pool;
    }
}
