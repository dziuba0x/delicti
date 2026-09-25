// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FtsoV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/FtsoV2Interface.sol";
import {ContractRegistry} from "@flarenetwork/flare-periphery-contracts/coston2/ContractRegistry.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MandateRegistry} from "./MandateRegistry.sol";
import {Vault} from "./Vault.sol";
import {SummaMeter} from "./SummaMeter.sol";

/// @title SummaLens: what an umbrella's bond is worth in dollars, now (SPEC amendment v1.1, S.7)
/// @notice The bond is posted in FLR, the chain that makes the sum provable, and read in dollars. FLR
///         moves (about −73 % in the year to 2026-09-24), so a counterparty that relies on an umbrella
///         asks this lens, at the moment it extends trust, whether the bond still covers what it
///         needs, and refuses otherwise. That is the market's margin call: when FLR falls, the agent
///         tops up with `post`, or it loses service. Nothing is liquidated, because the bond backs no
///         minted asset.
/// @dev    Holds nothing, decides nothing, and has no admin. The native asset's feed and its haircut
///         are fixed at construction. The haircut follows the FTSO risk tier Flare itself publishes
///         (FLR is tier 1, so 30 %). Not `view`: FtsoV2 reads are payable (free today).
contract SummaLens {
    MandateRegistry public immutable registry;
    SummaMeter public immutable meter;
    bytes21 public immutable nativeFeed; // FLR/USD
    uint16 public immutable haircutBps; // 3000 for FTSO risk tier 1
    FtsoV2Interface private immutable _ftsoOverride;

    struct Reading {
        uint256 bondWei; // native units still bonded under the umbrella
        uint256 nativeUsd6; // 1 native unit in µUSD, block-latency
        uint256 coverageUsd6; // bond × price × (1 − haircut)
        uint256 budgetUsd6;
        uint256 spentUsd6; // SummaMeter's tally (the brake's view, not a verdict)
        uint256 remainingUsd6; // budget − spent, floored at 0
        uint256 kBps; // coverage / budget, in basis points (10 000 = 1×)
    }

    error BadHaircut();

    constructor(MandateRegistry registry_, SummaMeter meter_, bytes21 nativeFeed_, uint16 haircutBps_, FtsoV2Interface ftsoOverride) {
        if (haircutBps_ >= 10_000) revert BadHaircut();
        registry = registry_;
        meter = meter_;
        nativeFeed = nativeFeed_;
        haircutBps = haircutBps_;
        _ftsoOverride = ftsoOverride;
    }

    function ftso() public view returns (FtsoV2Interface) {
        if (address(_ftsoOverride) != address(0)) return _ftsoOverride;
        return ContractRegistry.getFtsoV2();
    }

    /// @notice Everything a counterparty needs about an umbrella, in one call.
    function read(uint256 umbrellaId) public returns (Reading memory r) {
        MandateRegistry.Mandate memory u = registry.get(umbrellaId);
        r.bondWei = Vault(u.bond).bondOf(umbrellaId);
        (uint256 v, int8 d,) = ftso().getFeedById(nativeFeed);
        // µUSD per 1e18 wei: v × 10^6 / 10^d
        r.nativeUsd6 = d >= 6 ? v / 10 ** uint256(uint8(d) - 6) : v * 10 ** uint256(6 - int256(d));
        uint256 gross = Math.mulDiv(r.bondWei, r.nativeUsd6, 1e18);
        r.coverageUsd6 = (gross * (10_000 - haircutBps)) / 10_000;
        r.budgetUsd6 = u.budget;
        r.spentUsd6 = meter.spentUsd6(umbrellaId);
        r.remainingUsd6 = r.spentUsd6 >= r.budgetUsd6 ? 0 : r.budgetUsd6 - r.spentUsd6;
        r.kBps = r.budgetUsd6 == 0 ? 0 : (r.coverageUsd6 * 10_000) / r.budgetUsd6;
    }

    /// @notice Does the umbrella's bond, after the haircut, cover `kBps` of its budget right now?
    function covers(uint256 umbrellaId, uint256 kBps) external returns (bool) {
        return read(umbrellaId).kBps >= kBps && registry.isLive(umbrellaId);
    }

    /// @notice How much native currency to `post` so that `covers(umbrellaId, kBps)` holds at today's price.
    function topUpFor(uint256 umbrellaId, uint256 kBps) external returns (uint256 wei_) {
        Reading memory r = read(umbrellaId);
        uint256 needUsd6 = Math.mulDiv(r.budgetUsd6, kBps, 10_000, Math.Rounding.Ceil);
        if (r.coverageUsd6 >= needUsd6 || r.nativeUsd6 == 0) return 0;
        // invert `read` exactly, rounding up at each floor it takes, so posting this always suffices
        uint256 grossNeed = Math.mulDiv(needUsd6, 10_000, 10_000 - haircutBps, Math.Rounding.Ceil);
        uint256 bondNeed = Math.mulDiv(grossNeed, 1e18, r.nativeUsd6, Math.Rounding.Ceil);
        wei_ = bondNeed > r.bondWei ? bondNeed - r.bondWei : 0;
    }
}
