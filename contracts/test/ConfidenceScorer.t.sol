// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/ConfidenceScorer.sol";
import "../src/ClaimRegistry.sol";

contract ConfidenceScorerTest is Test {
    ConfidenceScorer scorer;

    address admin = address(0xA0);

    function setUp() public {
        scorer = new ConfidenceScorer(admin);
    }

    // ── Default multipliers ───────────────────────────────────────────────────

    function test_DefaultMultipliers() public view {
        assertEq(scorer.domainMultiplierBps(uint8(ClaimRegistry.Domain.General)),         10_000);
        assertEq(scorer.domainMultiplierBps(uint8(ClaimRegistry.Domain.Science)),          9_500);
        assertEq(scorer.domainMultiplierBps(uint8(ClaimRegistry.Domain.Finance)),          9_000);
        assertEq(scorer.domainMultiplierBps(uint8(ClaimRegistry.Domain.Medical)),          8_500);
        assertEq(scorer.domainMultiplierBps(uint8(ClaimRegistry.Domain.Regulatory)),       8_000);
        assertEq(scorer.domainMultiplierBps(uint8(ClaimRegistry.Domain.NationalSecurity)), 7_500);
    }

    // ── computeScore ──────────────────────────────────────────────────────────

    function test_ComputeScore_General_Full() public view {
        // 100 * 10000 / 10000 = 100
        assertEq(scorer.computeScore(100, ClaimRegistry.Domain.General), 100);
    }

    function test_ComputeScore_General_Partial() public view {
        // 75 * 10000 / 10000 = 75
        assertEq(scorer.computeScore(75, ClaimRegistry.Domain.General), 75);
    }

    function test_ComputeScore_Science_Full() public view {
        // 100 * 9500 / 10000 = 95
        assertEq(scorer.computeScore(100, ClaimRegistry.Domain.Science), 95);
    }

    function test_ComputeScore_Finance_Full() public view {
        // 100 * 9000 / 10000 = 90
        assertEq(scorer.computeScore(100, ClaimRegistry.Domain.Finance), 90);
    }

    function test_ComputeScore_Medical_Full() public view {
        // 100 * 8500 / 10000 = 85
        assertEq(scorer.computeScore(100, ClaimRegistry.Domain.Medical), 85);
    }

    function test_ComputeScore_Regulatory_Full() public view {
        // 100 * 8000 / 10000 = 80
        assertEq(scorer.computeScore(100, ClaimRegistry.Domain.Regulatory), 80);
    }

    function test_ComputeScore_NationalSecurity_Full() public view {
        // 100 * 7500 / 10000 = 75
        assertEq(scorer.computeScore(100, ClaimRegistry.Domain.NationalSecurity), 75);
    }

    function test_ComputeScore_Zero_ReturnsZero() public view {
        assertEq(scorer.computeScore(0, ClaimRegistry.Domain.General), 0);
        assertEq(scorer.computeScore(0, ClaimRegistry.Domain.NationalSecurity), 0);
    }

    function test_ComputeScore_ClampsAtHundred() public {
        // Set multiplier > 1x and rawScore = 100: output must still be 100
        vm.prank(admin);
        scorer.setDomainMultiplier(ClaimRegistry.Domain.General, 15_000); // 1.5x
        assertEq(scorer.computeScore(100, ClaimRegistry.Domain.General), 100);
    }

    function test_ComputeScore_Finance_PartialVote() public view {
        // 80% vote ratio on Finance: 80 * 9000 / 10000 = 72
        assertEq(scorer.computeScore(80, ClaimRegistry.Domain.Finance), 72);
    }

    // ── setDomainMultiplier ───────────────────────────────────────────────────

    function test_SetDomainMultiplier_Admin() public {
        vm.prank(admin);
        scorer.setDomainMultiplier(ClaimRegistry.Domain.Science, 9_800);
        assertEq(scorer.domainMultiplierBps(uint8(ClaimRegistry.Domain.Science)), 9_800);
    }

    function test_SetDomainMultiplier_EmitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit ConfidenceScorer.DomainMultiplierSet(ClaimRegistry.Domain.Finance, 9_200);
        scorer.setDomainMultiplier(ClaimRegistry.Domain.Finance, 9_200);
    }

    function test_SetDomainMultiplier_Zero_Reverts() public {
        vm.prank(admin);
        vm.expectRevert("ConfidenceScorer: zero multiplier");
        scorer.setDomainMultiplier(ClaimRegistry.Domain.General, 0);
    }

    function test_SetDomainMultiplier_Unauthorized_Reverts() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        scorer.setDomainMultiplier(ClaimRegistry.Domain.General, 9_000);
    }

    function test_SetDomainMultiplier_AffectsComputeScore() public {
        vm.prank(admin);
        scorer.setDomainMultiplier(ClaimRegistry.Domain.Medical, 10_000); // upgrade Medical to 1x
        assertEq(scorer.computeScore(100, ClaimRegistry.Domain.Medical), 100);
    }
}
