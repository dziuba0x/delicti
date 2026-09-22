// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Kinds — the challenge kinds and how their severities combine
/// @notice A kind names a challenge in the commit–reveal preimage (SPEC §6.7) and decides how a
///         verdict's severity accumulates (SPEC §8.1). Kinds are unique across every judge of a
///         Vault, which is what lets one commitment gate serve all of them.
library Kinds {
    uint8 internal constant FALSE_PAYMENT = 1; // §6.1
    uint8 internal constant BUDGET_NATIVE = 2; // §6.2
    uint8 internal constant BUDGET_ERC20 = 3; // §6.3
    uint8 internal constant UNANCHORED_DEED = 4; // §6.4
    uint8 internal constant UNDER_REPORTED = 5; // §6.5
    uint8 internal constant BUDGET_PAYMENT = 6; // §6.8
    uint8 internal constant XRP_OUTFLOW = 7; // §6.10

    /// @notice The `assetKey` by which an XRPL mandate promises a budget of GROSS XRP OUTFLOW, fees
    ///         included (SPEC §6.10), rather than of XRP delivered by `Payment`s (§6.8, `assetKey = 0`).
    ///         High bits set, so no EVM path can mistake it for a token address (`Deeds.erc20Of`).
    bytes32 internal constant XRP_OUTFLOW_KEY = bytes32("XRP/outflow");

    /// @dev Additive kinds sum: each verdict is about a different receipt or transaction. Every
    ///      other kind is nested and keeps a high-water mark.
    function additive(uint8 kind) internal pure returns (bool) {
        return kind == FALSE_PAYMENT || kind == UNANCHORED_DEED;
    }

    /// @dev Every budget kind shares one bucket: a mandate has one unit on one source, so at most one
    ///      of them measures it, and they measure the same thing — how far past the budget it went.
    function bucket(uint8 kind) internal pure returns (uint8) {
        return (kind == BUDGET_ERC20 || kind == BUDGET_PAYMENT || kind == XRP_OUTFLOW) ? BUDGET_NATIVE : kind;
    }
}
