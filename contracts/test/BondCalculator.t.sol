// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/BondCalculator.sol";

contract BondCalculatorTest is Test {
    BondCalculator calc;
    address admin = makeAddr("admin");

    function setUp() public {
        calc = new BondCalculator(admin);
    }

    function test_GeneralLowComplexity() public view {
        // DOMAIN_GENERAL=0, COMPLEXITY_LOW=10_000
        assertEq(calc.calculateBond(0, 10_000), 100e6);
    }

    function test_FinanceMediumComplexity() public view {
        // DOMAIN_FINANCE=2, COMPLEXITY_MEDIUM=20_000
        assertEq(calc.calculateBond(2, 20_000), 1000e6); // $500 * 2x
    }

    function test_NationalSecurityVeryHigh() public view {
        // DOMAIN_NATIONAL_SECURITY=5, COMPLEXITY_VERY_HIGH=50_000
        assertEq(calc.calculateBond(5, 50_000), 12_500e6); // $2500 * 5x
    }

    function test_GovernanceUpdateWithinLimit() public {
        vm.prank(admin);
        calc.setDomainBaseBond(0, 120e6); // DOMAIN_GENERAL, 20% increase
        assertEq(calc.domainBaseBond(0), 120e6);
    }

    function test_GovernanceUpdateExceedsLimitReverts() public {
        vm.prank(admin);
        vm.expectRevert("BondCalculator: change exceeds 25% governance limit");
        calc.setDomainBaseBond(0, 200e6); // DOMAIN_GENERAL, 100% increase
    }

    function test_UnknownDomainReverts() public {
        vm.expectRevert("BondCalculator: unknown domain");
        calc.calculateBond(99, 10_000);
    }
}
