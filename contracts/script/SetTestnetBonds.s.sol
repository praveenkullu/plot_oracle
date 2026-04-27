// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/BondCalculator.sol";

/// @dev Steps all domain base bonds down to 1 USDC (1e6) for testnet e2e testing.
///      Each call to setDomainBaseBond is capped at ±25% by the contract, so this
///      script iterates 75%-at-a-time until it can land exactly on 1e6.
///      Requires the broadcaster to hold GOVERNANCE_ROLE on BondCalculator.
///      DO NOT run on mainnet.
contract SetTestnetBonds is Script {
    address bondCalculator = vm.envAddress("BOND_CALCULATOR_ADDRESS");

    uint256 constant TARGET = 1e6; // 1 USDC

    function stepDown(BondCalculator bc, uint8 domain) internal {
        uint256 current = bc.domainBaseBond(domain);
        while (current > TARGET) {
            uint256 floor = current * 75 / 100; // max single-step decrease (25%)
            // If TARGET is within the allowed band, land on it directly; else step to floor
            uint256 next = (TARGET >= floor) ? TARGET : floor;
            bc.setDomainBaseBond(domain, next);
            current = next;
        }
    }

    function run() external {
        BondCalculator bc = BondCalculator(bondCalculator);

        vm.startBroadcast();

        stepDown(bc, 0); // General           (100 USDC → 1 USDC, ~13 steps)
        stepDown(bc, 1); // Science           (250 USDC → 1 USDC, ~19 steps)
        stepDown(bc, 2); // Finance           (500 USDC → 1 USDC, ~22 steps)
        stepDown(bc, 3); // Medical           (750 USDC → 1 USDC, ~24 steps)
        stepDown(bc, 4); // Regulatory        (1000 USDC → 1 USDC, ~25 steps)
        stepDown(bc, 5); // NationalSecurity  (2500 USDC → 1 USDC, ~29 steps)

        vm.stopBroadcast();

        console.log("All domain base bonds set to 1 USDC for testnet");
    }
}
