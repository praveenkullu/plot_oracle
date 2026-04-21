// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/EmissionController.sol";
import "../src/PLOTToken.sol";

contract MockPriceFeed {
    int256 public answer;
    function setAnswer(int256 _answer) external { answer = _answer; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
    function description() external pure returns (string memory) { return "PLOT/USD"; }
    function version() external pure returns (uint256) { return 1; }
    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

contract EmissionControllerTest is Test {
    EmissionController ec;
    PLOTToken          plot;
    MockPriceFeed      feed;

    address admin    = address(0xA0);
    address treasury = address(0xA1);
    address operator = address(0xA2);
    address receiver = address(0xA3);

    function setUp() public {
        feed = new MockPriceFeed();
        feed.setAnswer(100e8); // $100

        plot = new PLOTToken(admin, treasury);

        ec = new EmissionController(admin, address(plot), address(feed));

        vm.startPrank(admin);
        plot.grantRole(plot.MINTER_ROLE(), address(ec));
        ec.grantRole(ec.OPERATOR_ROLE(), operator);
        vm.stopPrank();
    }

    // ── currentRateBps ────────────────────────────────────────────────────────

    function test_CurrentRateBps_Year1() public view {
        assertEq(ec.currentRateBps(), 10_000);
    }

    function test_CurrentRateBps_Year2() public {
        vm.warp(ec.deployedAt() + 365 days + 1);
        assertEq(ec.currentRateBps(), 8_000);
    }

    function test_CurrentRateBps_Year3() public {
        vm.warp(ec.deployedAt() + 730 days + 1);
        assertEq(ec.currentRateBps(), 6_000);
    }

    function test_CurrentRateBps_Year4() public {
        vm.warp(ec.deployedAt() + 1095 days + 1);
        assertEq(ec.currentRateBps(), 4_000);
    }

    function test_CurrentRateBps_Year5Plus_Floor() public {
        vm.warp(ec.deployedAt() + 1460 days + 1);
        assertEq(ec.currentRateBps(), 2_000);
    }

    // ── pendingEmission ───────────────────────────────────────────────────────

    function test_PendingEmission_AccruedAfterHalfYear() public {
        // 182 days into Year 0 (100% rate)
        uint256 elapsed = 182 days;
        vm.warp(ec.deployedAt() + elapsed);
        uint256 expected = 50_000_000e18 * elapsed / (365 days);
        assertEq(ec.pendingEmission(), expected);
    }

    function test_PendingEmission_ZeroAtDeployment() public view {
        assertEq(ec.pendingEmission(), 0);
    }

    // ── mintEmission ──────────────────────────────────────────────────────────

    function test_MintEmission_Basic() public {
        // At exactly deployedAt + 365 days → year index 1 → rate 80%
        // pending = 50M * 80% * 365days/365days = 40M
        vm.warp(ec.deployedAt() + 365 days);
        vm.prank(operator);
        ec.mintEmission(receiver);
        assertEq(plot.balanceOf(receiver), 40_000_000e18);
        assertEq(ec.totalEmitted(), 40_000_000e18);
    }

    function test_MintEmission_UpdatesLastMintedAt() public {
        vm.warp(ec.deployedAt() + 100 days);
        vm.prank(operator);
        ec.mintEmission(receiver);
        assertEq(ec.lastMintedAt(), block.timestamp);
    }

    function test_MintEmission_Unauthorized_Reverts() public {
        vm.warp(ec.deployedAt() + 1 days);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        ec.mintEmission(receiver);
    }

    function test_MintEmission_NothingToMint_Reverts() public {
        // Same block → elapsed = 0 → amount = 0
        vm.expectRevert("EmissionController: nothing to mint");
        vm.prank(operator);
        ec.mintEmission(receiver);
    }

    function test_MintEmission_TwiceAccumulates() public {
        vm.warp(ec.deployedAt() + 100 days);
        vm.prank(operator);
        ec.mintEmission(receiver);
        uint256 first = plot.balanceOf(receiver);

        vm.warp(block.timestamp + 100 days);
        vm.prank(operator);
        ec.mintEmission(receiver);
        uint256 second = plot.balanceOf(receiver) - first;

        assertEq(first, second); // same 100-day window at same rate
    }

    // ── Circuit breaker: 24h ──────────────────────────────────────────────────

    function test_CircuitBreaker_30pctDrop_PausesEmissions() public {
        vm.prank(operator);
        ec.recordSnapshot24h(); // snapshot at $100

        feed.setAnswer(69e8); // $69 → 31% drop
        ec.checkCircuitBreaker();

        assertTrue(ec.emissionsPaused());
        assertEq(ec.pausedUntil(), block.timestamp + 48 hours);
    }

    function test_CircuitBreaker_30pctDrop_EmitsEvent() public {
        vm.prank(operator);
        ec.recordSnapshot24h();

        feed.setAnswer(60e8);
        vm.expectEmit(false, false, false, true);
        emit EmissionController.CircuitBreakerTriggered(block.timestamp + 48 hours);
        ec.checkCircuitBreaker();
    }

    function test_CircuitBreaker_Exactly30pct_DoesNotTrigger() public {
        vm.prank(operator);
        ec.recordSnapshot24h(); // $100

        feed.setAnswer(70e8); // exactly 30% drop → not > 30% → no trigger
        ec.checkCircuitBreaker();

        assertFalse(ec.emissionsPaused());
    }

    // ── Circuit breaker: 7d ───────────────────────────────────────────────────

    function test_CircuitBreaker_60pctDrop_EmergencyMode() public {
        vm.prank(operator);
        ec.recordSnapshot7d(); // snapshot at $100

        feed.setAnswer(39e8); // $39 → 61% drop
        ec.checkCircuitBreaker();

        assertTrue(ec.emergencyMode());
    }

    function test_CircuitBreaker_7d_TakesPriorityOver24h() public {
        vm.prank(operator);
        ec.recordSnapshot24h(); // $100

        vm.prank(operator);
        ec.recordSnapshot7d();  // $100

        feed.setAnswer(39e8); // triggers both checks; 7d check runs first
        ec.checkCircuitBreaker();

        // Should be emergency mode (7d), not just paused (24h)
        assertTrue(ec.emergencyMode());
        assertFalse(ec.emissionsPaused());
    }

    // ── Paused state blocks minting ───────────────────────────────────────────

    function test_EmissionsPaused_BlocksMinting() public {
        vm.prank(operator);
        ec.recordSnapshot24h();
        feed.setAnswer(60e8);
        ec.checkCircuitBreaker();

        vm.warp(block.timestamp + 1 hours); // still within 48h pause
        vm.warp(ec.deployedAt() + 1 days);  // ensure some emission accrued
        vm.prank(operator);
        vm.expectRevert("EmissionController: emissions paused");
        ec.mintEmission(receiver);
    }

    function test_EmergencyMode_BlocksMinting() public {
        vm.prank(operator);
        ec.recordSnapshot7d();
        feed.setAnswer(39e8);
        ec.checkCircuitBreaker();

        vm.warp(ec.deployedAt() + 1 days);
        vm.prank(operator);
        vm.expectRevert("EmissionController: emergency mode active");
        ec.mintEmission(receiver);
    }

    function test_PauseExpires_MintingResumes() public {
        vm.prank(operator);
        ec.recordSnapshot24h();
        feed.setAnswer(60e8);
        ec.checkCircuitBreaker();

        // Warp past 48h pause
        vm.warp(block.timestamp + 49 hours);
        vm.prank(operator);
        ec.mintEmission(receiver); // should not revert

        assertFalse(ec.emissionsPaused());
        assertGt(plot.balanceOf(receiver), 0);
    }

    // ── Admin governance ──────────────────────────────────────────────────────

    function test_DeactivateEmergencyMode_Admin() public {
        vm.prank(operator);
        ec.recordSnapshot7d();
        feed.setAnswer(39e8);
        ec.checkCircuitBreaker();
        assertTrue(ec.emergencyMode());

        vm.prank(admin);
        ec.deactivateEmergencyMode();
        assertFalse(ec.emergencyMode());
    }

    function test_DeactivateEmergencyMode_Unauthorized_Reverts() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        ec.deactivateEmergencyMode();
    }

    function test_SetPriceFeed_Admin() public {
        address newFeed = address(new MockPriceFeed());
        vm.prank(admin);
        ec.setPriceFeed(newFeed);
        assertEq(address(ec.priceFeed()), newFeed);
    }

    function test_SetPriceFeed_ZeroAddress_Reverts() public {
        vm.prank(admin);
        vm.expectRevert("EmissionController: zero address");
        ec.setPriceFeed(address(0));
    }
}
