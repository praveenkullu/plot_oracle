// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";

/**
 * @title GovernorPlot
 * @notice PLOT-weighted on-chain governance with a 67% supermajority requirement.
 *
 *         All proposals require 67% of participating votes to be in favor (not just a simple
 *         majority). This prevents governance capture for bond parameter changes and other
 *         high-stakes protocol settings. The 14-day voting period plus timelock delay gives
 *         the community adequate notice before changes take effect.
 *
 *         Anti-capture safeguards (enforced elsewhere):
 *           - Max 25% change per vote on bond parameters (enforced in BondCalculator)
 *           - Foundation multisig veto via Treasury during first 2 years
 */
contract GovernorPlot is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    uint256 public constant SUPERMAJORITY_NUMERATOR   = 67;
    uint256 public constant SUPERMAJORITY_DENOMINATOR = 100;

    constructor(
        IVotes             _token,
        TimelockController _timelock,
        uint48             _votingDelay,
        uint32             _votingPeriod,
        uint256            _proposalThreshold,
        uint256            _quorumNumerator
    )
        Governor("GovernorPlot")
        GovernorSettings(_votingDelay, _votingPeriod, _proposalThreshold)
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(_quorumNumerator)
        GovernorTimelockControl(_timelock)
    {}

    // ── Supermajority ──────────────────────────────────────────────────────────

    /**
     * @dev Override: require 67%+ of cast votes to be in favor (vs simple majority in base).
     */
    function _voteSucceeded(uint256 proposalId)
        internal
        view
        override(Governor, GovernorCountingSimple)
        returns (bool)
    {
        (uint256 againstVotes, uint256 forVotes,) = proposalVotes(proposalId);
        uint256 total = forVotes + againstVotes;
        if (total == 0) return false;
        return forVotes * SUPERMAJORITY_DENOMINATOR >= total * SUPERMAJORITY_NUMERATOR;
    }

    // ── Required overrides (resolve multiple-inheritance ambiguity) ───────────

    function votingDelay()
        public view override(Governor, GovernorSettings) returns (uint256)
    { return super.votingDelay(); }

    function votingPeriod()
        public view override(Governor, GovernorSettings) returns (uint256)
    { return super.votingPeriod(); }

    function proposalThreshold()
        public view override(Governor, GovernorSettings) returns (uint256)
    { return super.proposalThreshold(); }

    function quorum(uint256 timepoint)
        public view override(Governor, GovernorVotesQuorumFraction) returns (uint256)
    { return super.quorum(timepoint); }

    function state(uint256 proposalId)
        public view override(Governor, GovernorTimelockControl) returns (ProposalState)
    { return super.state(proposalId); }

    function proposalNeedsQueuing(uint256 proposalId)
        public view override(Governor, GovernorTimelockControl) returns (bool)
    { return super.proposalNeedsQueuing(proposalId); }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal view override(Governor, GovernorTimelockControl) returns (address)
    { return super._executor(); }
}
