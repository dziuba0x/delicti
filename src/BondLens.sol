// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vault} from "./Vault.sol";
import {Kinds} from "./Kinds.sol";
import {MandateRegistry} from "./MandateRegistry.sol";

/// @title BondLens — read-only arithmetic over a Vault's public state
/// @notice Holds nothing, is trusted with nothing, and can be redeployed or replaced by anyone at any
///         time: every number it returns is derived from public getters. It exists because "what would this case take?" is a
///         question a watcher asks BEFORE paying 20 FLR per attestation, and a risk market asks
///         when it prices loss-given-breach.
contract BondLens {
    /// @notice What a verdict of this kind and severity would take from this mandate right now.
    ///         Mirrors `Vault._accumulate` + `Vault._penalty`; `test/Proportional.t.sol` pins the
    ///         two against each other.
    function penaltyFor(Vault bond, uint256 mandateId, uint8 kind, uint256 severity)
        external
        view
        returns (uint256 increment, uint256 target)
    {
        bool additive = Kinds.additive(kind);
        uint8 bucket = Kinds.bucket(kind);
        uint256 prev = bond.severityIn(mandateId, bucket);
        uint256 add = additive ? severity : (severity > prev ? severity - prev : 0);
        uint256 total = bond.severityOf(mandateId);
        unchecked {
            total = total + add < total ? type(uint256).max : total + add;
        }
        uint256 base = bond.slashed(mandateId) ? bond.slashBase(mandateId) : bond.bondOf(mandateId);
        uint256 budget = bond.registry().get(mandateId).budget;
        if (budget == 0 || total >= budget) {
            target = base;
        } else {
            target = (base * total) / budget;
            uint256 floor = (base * bond.MIN_SLASH_BPS()) / 10_000;
            if (target < floor) target = floor;
        }
        uint256 done = bond.slashedAmount(mandateId);
        increment = target > done ? target - done : 0;
        uint256 left = bond.bondOf(mandateId);
        if (increment > left) increment = left;
    }

    /// @notice The collateralisation ratio a counterparty should read before trusting a mandate:
    ///         bond per unit of budget, in basis points of 1:1. Units differ (bond is native, budget
    ///         is the mandate's asset), so this is a number to compare across mandates in the SAME
    ///         asset, not a solvency statement.
    function coverBps(Vault bond, uint256 mandateId) external view returns (uint256) {
        uint256 budget = bond.registry().get(mandateId).budget;
        if (budget == 0) return type(uint256).max;
        return (bond.bondOf(mandateId) * 10_000) / budget;
    }
}
