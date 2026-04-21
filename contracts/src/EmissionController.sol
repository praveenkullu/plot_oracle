// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "./PLOTToken.sol";

/**
 * @title EmissionController
 * @notice Manages decreasing PLOT token emissions with Chainlink-oracle circuit breakers.
 *
 *         Emission schedule (years since deployment):
 *           Year 0: 100%  →  Year 1: 80%  →  Year 2: 60%  →  Year 3: 40%  →  Year 4+: 20% (floor)
 *         Accrues linearly; OPERATOR_ROLE flushes via mintEmission().
 *
 *         Circuit breakers (checked by anyone via checkCircuitBreaker()):
 *           - PLOT/USD down >30% in 24h  → pause emissions 48h
 *           - PLOT/USD down >60% in 7d   → emergency mode (manual deactivation by admin)
 *         Operators record price snapshots via recordSnapshot24h() / recordSnapshot7d().
 */
contract EmissionController is AccessControl {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    PLOTToken             public immutable plotToken;
    AggregatorV3Interface public            priceFeed;
    uint256               public immutable deployedAt;

    uint256 public constant MAX_ANNUAL_EMISSION = 50_000_000e18; // 5% of 1B max supply
    uint256 public constant EMISSION_FLOOR_BPS  = 2_000;         // 20%
    uint256 public constant BPS_DENOM           = 10_000;
    uint256 public constant YEAR                = 365 days;

    uint256 public lastMintedAt;
    uint256 public totalEmitted;

    bool    public emissionsPaused;
    uint256 public pausedUntil;
    bool    public emergencyMode;

    int256  public snapshot24hPrice;
    uint256 public snapshot24hAt;
    int256  public snapshot7dPrice;
    uint256 public snapshot7dAt;

    event EmissionMinted(address indexed to, uint256 amount);
    event CircuitBreakerTriggered(uint256 pausedUntil);
    event EmergencyModeActivated();
    event EmergencyModeDeactivated();
    event PriceFeedUpdated(address indexed newFeed);

    constructor(address admin, address _plotToken, address _priceFeed) {
        require(_plotToken != address(0), "EmissionController: zero plotToken");
        require(_priceFeed != address(0), "EmissionController: zero priceFeed");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE,      admin);
        plotToken    = PLOTToken(_plotToken);
        priceFeed    = AggregatorV3Interface(_priceFeed);
        deployedAt   = block.timestamp;
        lastMintedAt = block.timestamp;
    }

    // ── Views ──────────────────────────────────────────────────────────────────

    /**
     * @notice Emission rate in BPS for the current year since deployment.
     */
    function currentRateBps() public view returns (uint256) {
        uint256 year = (block.timestamp - deployedAt) / YEAR;
        if (year == 0) return 10_000;
        if (year == 1) return  8_000;
        if (year == 2) return  6_000;
        if (year == 3) return  4_000;
        return EMISSION_FLOOR_BPS;
    }

    /**
     * @notice PLOT accrued since last mint, at the current rate.
     */
    function pendingEmission() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastMintedAt;
        return (MAX_ANNUAL_EMISSION * currentRateBps() / BPS_DENOM) * elapsed / YEAR;
    }

    // ── Minting ────────────────────────────────────────────────────────────────

    /**
     * @notice Flush accrued PLOT to `to`. OPERATOR_ROLE only.
     *         Reverts if in emergency mode or within a 48h circuit-breaker pause window.
     */
    function mintEmission(address to) external onlyRole(OPERATOR_ROLE) {
        require(!emergencyMode, "EmissionController: emergency mode active");
        if (emissionsPaused) {
            require(block.timestamp >= pausedUntil, "EmissionController: emissions paused");
            emissionsPaused = false;
        }

        uint256 amount = pendingEmission();
        require(amount > 0, "EmissionController: nothing to mint");

        lastMintedAt  = block.timestamp;
        totalEmitted += amount;

        plotToken.mint(to, amount);
        emit EmissionMinted(to, amount);
    }

    // ── Price snapshots ────────────────────────────────────────────────────────

    /**
     * @notice Save current oracle price as the 24-hour reference snapshot.
     *         Should be called once daily by automation (e.g. Chainlink Automation).
     */
    function recordSnapshot24h() external onlyRole(OPERATOR_ROLE) {
        (, int256 price,,,) = priceFeed.latestRoundData();
        snapshot24hPrice = price;
        snapshot24hAt    = block.timestamp;
    }

    /**
     * @notice Save current oracle price as the 7-day reference snapshot.
     *         Should be called once weekly by automation.
     */
    function recordSnapshot7d() external onlyRole(OPERATOR_ROLE) {
        (, int256 price,,,) = priceFeed.latestRoundData();
        snapshot7dPrice = price;
        snapshot7dAt    = block.timestamp;
    }

    // ── Circuit breaker ────────────────────────────────────────────────────────

    /**
     * @notice Compare current oracle price to stored snapshots and trigger circuit breakers.
     *         Permissionless — anyone can call.
     *
     *         7-day check (higher severity): if price fell >60% from snapshot → emergency mode.
     *         24-hour check: if price fell >30% from snapshot → pause emissions 48h.
     */
    function checkCircuitBreaker() external {
        (, int256 currentPrice,,,) = priceFeed.latestRoundData();
        require(currentPrice > 0, "EmissionController: invalid price");

        // 7-day check first (more severe)
        if (snapshot7dAt > 0 && snapshot7dPrice > 0 && !emergencyMode) {
            // drop >60%: currentPrice < snapshot7dPrice * 40 / 100
            if (currentPrice * 100 < snapshot7dPrice * 40) {
                emergencyMode = true;
                emit EmergencyModeActivated();
                return;
            }
        }

        // 24-hour check
        if (snapshot24hAt > 0 && snapshot24hPrice > 0) {
            // drop >30%: currentPrice < snapshot24hPrice * 70 / 100
            if (currentPrice * 100 < snapshot24hPrice * 70) {
                if (!emissionsPaused || block.timestamp >= pausedUntil) {
                    pausedUntil     = block.timestamp + 48 hours;
                    emissionsPaused = true;
                    emit CircuitBreakerTriggered(pausedUntil);
                }
            }
        }
    }

    // ── Admin ──────────────────────────────────────────────────────────────────

    function deactivateEmergencyMode() external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyMode = false;
        emit EmergencyModeDeactivated();
    }

    function setPriceFeed(address newFeed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFeed != address(0), "EmissionController: zero address");
        priceFeed = AggregatorV3Interface(newFeed);
        emit PriceFeedUpdated(newFeed);
    }
}
