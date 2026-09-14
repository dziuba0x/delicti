// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Stand-in for Flare's ProtocolsV2 (same address as FlareSystemsManager on Coston2).
///      A unit test has no Flare contracts to read the voting-round clock from, so Bond takes
///      an override for it — same reason it takes one for FdcVerification.
contract MockProtocolsV2 {
    uint64 public firstVotingRoundStartTs = 1_658_430_000; // Coston2's real value
    uint64 public votingEpochDurationSeconds = 90; // Coston2's real value

    /// @notice Place a voting round's start at an exact wall-clock time.
    /// @dev    Every commit–reveal test is really a statement about the distance between "when the
    ///         commitment was made" and "when the round that produced the proof began", so the
    ///         tests say that directly instead of computing round numbers backwards.
    function setRoundStart(uint64 round, uint64 ts) external {
        firstVotingRoundStartTs = ts - round * votingEpochDurationSeconds;
    }
}
