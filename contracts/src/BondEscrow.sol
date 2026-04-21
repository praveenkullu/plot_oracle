// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BondEscrow
 * @notice Locks, releases, and slashes USDC bonds.
 *         Lock at claim submission; release or slash at resolution.
 *         Bond flow per spec:
 *           - Unchallenged: return bond + reward
 *           - Submitter wins: return bond + challenger's slashed bond
 *           - Submitter loses: 60% to challenger, 20% to voters, 20% to treasury
 */
contract BondEscrow is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant CLAIM_REGISTRY_ROLE = keccak256("CLAIM_REGISTRY_ROLE");
    bytes32 public constant ORACLE_ROUTER_ROLE = keccak256("ORACLE_ROUTER_ROLE");

    IERC20 public immutable usdc;
    address public treasury;

    // claimId -> locked bond amount
    mapping(bytes32 => uint256) public lockedBond;
    // claimId -> who locked it (submitter or challenger)
    mapping(bytes32 => address) public bondHolder;

    uint256 public constant CHALLENGER_SHARE_BPS = 6000;  // 60%
    uint256 public constant VOTER_SHARE_BPS = 2000;       // 20%
    uint256 public constant TREASURY_SHARE_BPS = 2000;    // 20%

    event BondLocked(bytes32 indexed claimId, address indexed holder, uint256 amount);
    event BondReleased(bytes32 indexed claimId, address indexed recipient, uint256 amount);
    event BondSlashed(bytes32 indexed claimId, address indexed loser, uint256 amount);

    constructor(address _usdc, address _treasury, address admin) {
        usdc = IERC20(_usdc);
        treasury = _treasury;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function lockBond(bytes32 claimId, address holder, uint256 amount)
        external
        onlyRole(CLAIM_REGISTRY_ROLE)
        nonReentrant
    {
        require(lockedBond[claimId] == 0, "BondEscrow: bond already locked");
        require(amount > 0, "BondEscrow: zero amount");
        usdc.safeTransferFrom(holder, address(this), amount);
        lockedBond[claimId] = amount;
        bondHolder[claimId] = holder;
        emit BondLocked(claimId, holder, amount);
    }

    // Called when claim passes unchallenged or submitter wins dispute
    function releaseBond(bytes32 claimId) external onlyRole(ORACLE_ROUTER_ROLE) nonReentrant {
        uint256 amount = lockedBond[claimId];
        require(amount > 0, "BondEscrow: no bond locked");
        address recipient = bondHolder[claimId];
        delete lockedBond[claimId];
        delete bondHolder[claimId];
        usdc.safeTransfer(recipient, amount);
        emit BondReleased(claimId, recipient, amount);
    }

    // Called when submitter loses: 60% challenger, 20% voters, 20% treasury
    function slashBond(bytes32 claimId, address challenger, address voterPool)
        external
        onlyRole(ORACLE_ROUTER_ROLE)
        nonReentrant
    {
        uint256 amount = lockedBond[claimId];
        require(amount > 0, "BondEscrow: no bond locked");
        address loser = bondHolder[claimId];
        delete lockedBond[claimId];
        delete bondHolder[claimId];

        uint256 challengerPayout = (amount * CHALLENGER_SHARE_BPS) / 10_000;
        uint256 voterPayout = (amount * VOTER_SHARE_BPS) / 10_000;
        uint256 treasuryPayout = amount - challengerPayout - voterPayout;

        usdc.safeTransfer(challenger, challengerPayout);
        usdc.safeTransfer(voterPool, voterPayout);
        usdc.safeTransfer(treasury, treasuryPayout);

        emit BondSlashed(claimId, loser, amount);
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTreasury != address(0), "BondEscrow: zero address");
        treasury = newTreasury;
    }
}
