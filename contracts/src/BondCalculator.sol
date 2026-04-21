// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title BondCalculator
 * @notice Pure bond calculation: domain base rate × complexity multiplier.
 *         All amounts in USDC units (6 decimals).
 */
contract BondCalculator is AccessControl {
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    // Domain IDs — must match ClaimRegistry.Domain enum
    uint8 public constant DOMAIN_GENERAL = 0;
    uint8 public constant DOMAIN_SCIENCE = 1;
    uint8 public constant DOMAIN_FINANCE = 2;
    uint8 public constant DOMAIN_MEDICAL = 3;
    uint8 public constant DOMAIN_REGULATORY = 4;
    uint8 public constant DOMAIN_NATIONAL_SECURITY = 5;

    // Complexity multipliers (basis points, 10000 = 1x)
    uint16 public constant COMPLEXITY_LOW = 10_000;    // 1x
    uint16 public constant COMPLEXITY_MEDIUM = 20_000; // 2x
    uint16 public constant COMPLEXITY_HIGH = 30_000;   // 3x
    uint16 public constant COMPLEXITY_VERY_HIGH = 50_000; // 5x

    // Base bonds in USDC (6 decimals)
    mapping(uint8 => uint256) public domainBaseBond;

    event DomainBaseBondUpdated(uint8 indexed domain, uint256 oldBond, uint256 newBond);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);

        // USD-denominated base bonds from implementation plan (USDC has 6 decimals)
        domainBaseBond[DOMAIN_GENERAL] = 100e6;           // $100
        domainBaseBond[DOMAIN_SCIENCE] = 250e6;           // $250
        domainBaseBond[DOMAIN_FINANCE] = 500e6;           // $500
        domainBaseBond[DOMAIN_MEDICAL] = 750e6;           // $750
        domainBaseBond[DOMAIN_REGULATORY] = 1_000e6;      // $1,000
        domainBaseBond[DOMAIN_NATIONAL_SECURITY] = 2_500e6; // $2,500
    }

    function calculateBond(uint8 domain, uint16 complexityBps) external view returns (uint256) {
        uint256 base = domainBaseBond[domain];
        require(base > 0, "BondCalculator: unknown domain");
        require(complexityBps >= COMPLEXITY_LOW, "BondCalculator: invalid complexity");
        return (base * complexityBps) / 10_000;
    }

    function setDomainBaseBond(uint8 domain, uint256 newBond) external onlyRole(GOVERNANCE_ROLE) {
        require(newBond > 0, "BondCalculator: zero bond");
        uint256 old = domainBaseBond[domain];
        // Max 25% change per governance vote (from implementation plan)
        if (old > 0) {
            require(
                newBond <= old * 125 / 100 && newBond >= old * 75 / 100,
                "BondCalculator: change exceeds 25% governance limit"
            );
        }
        domainBaseBond[domain] = newBond;
        emit DomainBaseBondUpdated(domain, old, newBond);
    }
}
