// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./ClaimRegistry.sol";

/**
 * @title ChallengeWindow
 * @notice Optimistic 2-hour challenge window for claims that pass novelty detection.
 *         After a claim enters Status.Pending, anyone can open a window.
 *         During the window any address can challenge by staking a counter-bond.
 *         If no challenge arrives before expiry, anyone may finalize the claim as Verified.
 *         On dispute the claim moves to Status.Disputed and OracleRouter drives resolution.
 *
 *         Requires ORACLE_ROUTER_ROLE in ClaimRegistry to call markDisputed() and resolveUnchallenged().
 *         Challenger bonds are held in this contract; OracleRouter releases or slashes them at resolution.
 */
contract ChallengeWindow is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ORACLE_ROUTER_ROLE = keccak256("ORACLE_ROUTER_ROLE");

    uint256 public constant MIN_WINDOW_DURATION = 1 hours;
    uint256 public constant MAX_WINDOW_DURATION = 30 days;

    // Challenger bond slash split when challenger loses (submitter's claim validated)
    uint256 public constant SUBMITTER_SHARE_BPS = 6000; // 60% → original submitter
    uint256 public constant VOTER_SHARE_BPS     = 2000; // 20% → voter pool
    uint256 public constant TREASURY_SHARE_BPS  = 2000; // 20% → treasury

    ClaimRegistry public immutable claimRegistry;
    IERC20 public immutable usdc;
    address public treasury;

    uint256 public windowDuration = 2 hours;

    struct Window {
        uint256 openedAt;
        uint256 expiresAt;
        address challenger;
        uint256 challengerBond;
        bool finalized;
    }

    mapping(bytes32 => Window) public windows;

    event WindowOpened(bytes32 indexed claimId, uint256 expiresAt);
    event ChallengeOpened(bytes32 indexed claimId, address indexed challenger, uint256 bond);
    event WindowExpired(bytes32 indexed claimId);
    event ChallengerBondReleased(bytes32 indexed claimId, address indexed challenger, uint256 amount);
    event ChallengerBondSlashed(bytes32 indexed claimId, address indexed challenger, uint256 amount);

    constructor(address admin, address _claimRegistry, address _usdc, address _treasury) {
        require(_treasury != address(0), "ChallengeWindow: zero treasury");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        claimRegistry = ClaimRegistry(_claimRegistry);
        usdc = IERC20(_usdc);
        treasury = _treasury;
    }

    /**
     * @notice Open a challenge window for a Pending claim. Permissionless.
     */
    function openWindow(bytes32 claimId) external {
        require(windows[claimId].openedAt == 0, "ChallengeWindow: window already open");
        ClaimRegistry.Claim memory claim = claimRegistry.getClaim(claimId);
        require(claim.status == ClaimRegistry.Status.Pending, "ChallengeWindow: claim not pending");

        uint256 expiresAt = block.timestamp + windowDuration;
        windows[claimId] = Window({
            openedAt: block.timestamp,
            expiresAt: expiresAt,
            challenger: address(0),
            challengerBond: 0,
            finalized: false
        });

        emit WindowOpened(claimId, expiresAt);
    }

    /**
     * @notice Challenge a claim within its open window. Any address may call.
     * @param claimId     Claim to dispute.
     * @param bondAmount  USDC (6-decimal) counter-bond the challenger stakes.
     */
    function challenge(bytes32 claimId, uint256 bondAmount) external nonReentrant {
        Window storage w = windows[claimId];
        require(w.openedAt != 0, "ChallengeWindow: no window open");
        require(block.timestamp < w.expiresAt, "ChallengeWindow: window expired");
        require(w.challenger == address(0), "ChallengeWindow: already challenged");
        require(!w.finalized, "ChallengeWindow: already finalized");
        require(bondAmount > 0, "ChallengeWindow: zero bond");

        w.challenger = msg.sender;
        w.challengerBond = bondAmount;

        emit ChallengeOpened(claimId, msg.sender, bondAmount);

        usdc.safeTransferFrom(msg.sender, address(this), bondAmount);
        claimRegistry.markDisputed(claimId);
    }

    /**
     * @notice Finalize an unchallenged claim after window expiry. Permissionless.
     *         Calls ClaimRegistry.resolveUnchallenged() → Status.Verified with score=100.
     */
    function finalizeUnchallenged(bytes32 claimId) external {
        Window storage w = windows[claimId];
        require(w.openedAt != 0, "ChallengeWindow: no window open");
        require(block.timestamp >= w.expiresAt, "ChallengeWindow: window not expired");
        require(w.challenger == address(0), "ChallengeWindow: has challenger");
        require(!w.finalized, "ChallengeWindow: already finalized");

        w.finalized = true;
        emit WindowExpired(claimId);

        claimRegistry.resolveUnchallenged(claimId, 100);
    }

    /**
     * @notice Return challenger's bond after a dispute resolves in challenger's favour.
     *         Called by OracleRouter when submitter's claim is rejected.
     */
    function releaseChallengerBond(bytes32 claimId) external onlyRole(ORACLE_ROUTER_ROLE) nonReentrant {
        Window storage w = windows[claimId];
        uint256 amount = w.challengerBond;
        require(amount > 0, "ChallengeWindow: no challenger bond");
        address recipient = w.challenger;
        w.challengerBond = 0;
        usdc.safeTransfer(recipient, amount);
        emit ChallengerBondReleased(claimId, recipient, amount);
    }

    /**
     * @notice Slash challenger's bond after a dispute resolves in submitter's favour.
     *         Split: 60% submitter, 20% voterPool, 20% treasury.
     *         Called by OracleRouter when submitter's claim is validated.
     * @param voterPool  Address receiving the voter share.
     */
    function slashChallengerBond(bytes32 claimId, address voterPool) external onlyRole(ORACLE_ROUTER_ROLE) nonReentrant {
        Window storage w = windows[claimId];
        uint256 amount = w.challengerBond;
        require(amount > 0, "ChallengeWindow: no challenger bond");
        address loser = w.challenger;
        address submitter = claimRegistry.getClaim(claimId).submitter;
        w.challengerBond = 0;

        uint256 submitterPayout = (amount * SUBMITTER_SHARE_BPS) / 10_000;
        uint256 voterPayout     = (amount * VOTER_SHARE_BPS) / 10_000;
        uint256 treasuryPayout  = amount - submitterPayout - voterPayout;

        usdc.safeTransfer(submitter, submitterPayout);
        usdc.safeTransfer(voterPool, voterPayout);
        usdc.safeTransfer(treasury, treasuryPayout);

        emit ChallengerBondSlashed(claimId, loser, amount);
    }

    // ── View helpers ────────────────────────────────────────────────────────

    function getWindow(bytes32 claimId) external view returns (Window memory) {
        return windows[claimId];
    }

    function isWindowOpen(bytes32 claimId) external view returns (bool) {
        Window storage w = windows[claimId];
        return w.openedAt != 0 && block.timestamp < w.expiresAt && !w.finalized;
    }

    // ── Governance ──────────────────────────────────────────────────────────

    function setWindowDuration(uint256 duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            duration >= MIN_WINDOW_DURATION && duration <= MAX_WINDOW_DURATION,
            "ChallengeWindow: duration out of range"
        );
        windowDuration = duration;
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTreasury != address(0), "ChallengeWindow: zero address");
        treasury = newTreasury;
    }
}
