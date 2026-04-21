// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Treasury
 * @notice Plot Protocol treasury. Holds USDC fee revenue and manages buybacks.
 *
 *         Role model:
 *           EXECUTOR_ROLE  — assigned to TimelockController; can withdraw and initiate buybacks.
 *           FOUNDATION_ROLE — holds veto power on any proposal hash for the first 2 years.
 *
 *         Buyback mechanics:
 *           initiateBuyback() is capped at 10% of current USDC balance per call.
 *           Actual DEX swap execution is off-chain — a keeper watches BuybackInitiated events.
 *
 *         After vetoExpiresAt (2 years post-deploy), FOUNDATION_ROLE's veto() calls revert,
 *         fully decentralizing the treasury to PLOT governance.
 */
contract Treasury is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant EXECUTOR_ROLE   = keccak256("EXECUTOR_ROLE");
    bytes32 public constant FOUNDATION_ROLE = keccak256("FOUNDATION_ROLE");

    IERC20  public immutable usdc;
    uint256 public immutable vetoExpiresAt;

    uint256 public constant BUYBACK_CAP_BPS = 1_000; // 10%
    uint256 public constant BPS_DENOM       = 10_000;

    mapping(bytes32 => bool) public vetoed;

    event Deposit(address indexed from, uint256 amount);
    event Withdrawal(address indexed to, uint256 amount, bytes32 indexed proposalHash);
    event BuybackInitiated(uint256 usdcAmount);
    event ProposalVetoed(bytes32 indexed proposalHash);

    constructor(address admin, address foundation, address _usdc) {
        require(_usdc       != address(0), "Treasury: zero usdc");
        require(foundation  != address(0), "Treasury: zero foundation");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FOUNDATION_ROLE,    foundation);
        usdc          = IERC20(_usdc);
        vetoExpiresAt = block.timestamp + 730 days;
    }

    receive() external payable {
        revert("Treasury: ETH not accepted");
    }

    // ── Deposits ───────────────────────────────────────────────────────────────

    /**
     * @notice Transfer USDC from caller into the treasury. Caller must approve first.
     */
    function deposit(uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, amount);
    }

    // ── Withdrawals ────────────────────────────────────────────────────────────

    /**
     * @notice Withdraw USDC to `to`. EXECUTOR_ROLE only.
     * @param proposalHash Governance proposal hash this withdrawal corresponds to.
     *                     Reverts if the proposal was vetoed by the foundation.
     */
    function withdraw(address to, uint256 amount, bytes32 proposalHash)
        external
        onlyRole(EXECUTOR_ROLE)
        nonReentrant
    {
        require(to != address(0),      "Treasury: zero recipient");
        require(!vetoed[proposalHash], "Treasury: proposal vetoed");
        usdc.safeTransfer(to, amount);
        emit Withdrawal(to, amount, proposalHash);
    }

    // ── Buyback ────────────────────────────────────────────────────────────────

    /**
     * @notice Signal a PLOT buyback of `usdcAmount`. EXECUTOR_ROLE only.
     *         Capped at 10% of current USDC balance. Off-chain keeper executes the swap.
     */
    function initiateBuyback(uint256 usdcAmount)
        external
        onlyRole(EXECUTOR_ROLE)
        nonReentrant
    {
        require(usdcAmount > 0, "Treasury: zero amount");
        uint256 balance = usdc.balanceOf(address(this));
        uint256 cap     = balance * BUYBACK_CAP_BPS / BPS_DENOM;
        require(usdcAmount <= cap, "Treasury: exceeds buyback cap");
        emit BuybackInitiated(usdcAmount);
    }

    // ── Foundation veto ────────────────────────────────────────────────────────

    /**
     * @notice Veto a governance proposal, preventing its execution via withdraw().
     *         FOUNDATION_ROLE only; reverts after the 2-year training-wheels period.
     */
    function veto(bytes32 proposalHash) external onlyRole(FOUNDATION_ROLE) {
        require(block.timestamp < vetoExpiresAt, "Treasury: veto power expired");
        vetoed[proposalHash] = true;
        emit ProposalVetoed(proposalHash);
    }
}
