// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PLOTToken
 * @notice PLOT governance + staking token. Fixed max supply with decreasing emissions.
 *         Slashing authority granted to BondEscrow and InternalVote (future module).
 */
contract PLOTToken is ERC20, ERC20Permit, ERC20Votes, AccessControl, ReentrancyGuard {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant EMISSION_CONTROLLER_ROLE = keccak256("EMISSION_CONTROLLER_ROLE");

    uint256 public constant MAX_SUPPLY = 1_000_000_000e18; // 1 billion PLOT

    uint256 public totalSlashed;

    event Slashed(address indexed account, uint256 amount, address indexed slasher);

    constructor(address admin, address treasury) ERC20("PLOT", "PLOT") ERC20Permit("PLOT") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        // Mint initial treasury allocation (20% of max supply)
        _mint(treasury, MAX_SUPPLY / 5);
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(totalSupply() + amount <= MAX_SUPPLY, "PLOTToken: max supply exceeded");
        _mint(to, amount);
    }

    function slash(address account, uint256 amount) external onlyRole(SLASHER_ROLE) nonReentrant {
        _burn(account, amount);
        totalSlashed += amount;
        emit Slashed(account, amount, msg.sender);
    }

    // ERC20Votes overrides
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
