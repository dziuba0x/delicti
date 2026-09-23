// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vault} from "../../src/Vault.sol";
import {MandateRegistry} from "../../src/MandateRegistry.sol";
import {AgentRefs} from "../../src/AgentRefs.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";

/// A judge that names whoever asks — the Vault's constructor is the one asking.
contract SelfNamingJudge {
    function vault() external view returns (address) {
        return msg.sender;
    }
}

/// Exposes the Vault's arithmetic to a symbolic executor.
contract VaultHarness is Vault {
    constructor(address[] memory js)
        Vault(MandateRegistry(address(0)), AgentRefs(address(0)), ProtocolsV2Interface(address(0)), 0, js)
    {}

    function penalty(uint256 base, uint256 budget, uint256 severity) external pure returns (uint256) {
        return _penalty(base, budget, severity);
    }

    /// The accrual half of `_distribute` and `settle`, on storage the harness sets directly.
    function distributeAndSettleOne(uint256 id, uint256 total, uint256 principalDeposits, uint256 dep, uint256 rest)
        external
        returns (uint256 toPrincipal, uint256 toOthers, uint256 credited)
    {
        totalDeposits[id] = total;
        principalSide[id] = principalDeposits;
        uint256 before = owed[address(1)];
        _distribute(id, address(1), rest);
        toPrincipal = owed[address(1)] - before;
        toOthers = unsettled[id];
        // one outside depositor holding `dep` of the non-principal deposits
        credited = (dep * remainderPerUnit[id]) / 1e36;
    }
}

/// Halmos: `halmos --match-contract VaultMathCheck`. Bounded symbolic proofs, not samples.
contract VaultMathCheck {
    VaultHarness h;

    function setUp() public {
        address[] memory js = new address[](1);
        js[0] = address(new SelfNamingJudge());
        h = new VaultHarness(js);
    }

    /// A verdict never takes more than the bond it is measured on, and never less than the floor.
    function check_penaltyIsBounded(uint64 base, uint64 budget, uint64 severity) public view {
        uint256 p = h.penalty(base, budget, severity);
        assert(p <= base);
        if (budget != 0 && severity != 0) assert(p >= (uint256(base) * 1000) / 10_000);
    }

    /// More proven severity never costs less.
    function check_penaltyIsMonotone(uint64 base, uint64 budget, uint64 s1, uint64 s2) public view {
        if (s1 > s2) (s1, s2) = (s2, s1);
        assert(h.penalty(base, budget, s1) <= h.penalty(base, budget, s2));
    }

    /// The surety rule loses and creates nothing: every wei of a verdict's remainder is either
    /// credited to the principal now or accrued for the other depositors, and no single outside
    /// depositor can ever be credited more than was accrued for all of them.
    function check_distributionConservesValue(uint64 total, uint64 principalDeposits, uint64 dep, uint64 rest) public {
        if (total == 0 || principalDeposits > total) return;
        uint256 others = uint256(total) - principalDeposits;
        if (dep > others) return;
        (uint256 toPrincipal, uint256 toOthers, uint256 credited) =
            h.distributeAndSettleOne(1, total, principalDeposits, dep, rest);
        assert(toPrincipal + toOthers == rest);
        assert(credited <= toOthers);
        if (others == 0) assert(toOthers == 0);
    }
}
