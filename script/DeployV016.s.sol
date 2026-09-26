// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AnchorLog} from "../src/AnchorLog.sol";
import {SpendMeter} from "../src/SpendMeter.sol";
import {AgentRefs} from "../src/AgentRefs.sol";
import {BondLens} from "../src/BondLens.sol";
import {Vault} from "../src/Vault.sol";
import {JudgeEvm} from "../src/JudgeEvm.sol";
import {JudgeXrpl} from "../src/JudgeXrpl.sol";
import {JudgeSumma} from "../src/JudgeSumma.sol";
import {SummaMeter} from "../src/SummaMeter.sol";
import {MandateFacilitator} from "../src/MandateFacilitator.sol";
import {SummaLens} from "../src/SummaLens.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {FtsoV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/FtsoV2Interface.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";

/// @notice v0.16 (watch pool v2, the seal) and amendment v1.2 (Conatus), over the live core, in one
///         broadcast. Nothing live changes: every mandate bonded in an earlier Vault keeps it (§8.2).
///         The core (registry, anchor log, spend meter) and AgentRefs are reused, so every mandate,
///         umbrella and exclusivity statement stays where it is.
///
///   1. The consequence layer: JudgeEvm and JudgeXrpl, each told the address the Vault is about to
///      get, then that Vault (+ BondLens). No setter exists at any point.
///   2. SUMMA: JudgeSumma, then VaultSumma (the same Vault bytecode, judges = [JudgeSumma]). The price
///      map is the v0.15 map, row for row (read back from the live JudgeSumma on 2026-09-27):
///      testXRP / XRP/outflow → XRP/USD, and testFLR / MockUSDT0 → USDT/USD.
///   3. Conatus: SummaMeter v1.2 (the tripwire), MandateFacilitator v1.2 (refused attempts on record)
///      and SummaLens, each naming JudgeSumma or the meter immutably.
///
/// The addresses are written to deployments/<network>-v0.16.json.
///
///   set -a; . ./.env; set +a      # PRIVATE_KEY, REG, LOG, METER, REFS, USDT0
///   forge script script/DeployV016.s.sol --rpc-url coston2 --broadcast --slow
contract DeployV016 is Script {
    bytes21 constant XRP_USD = bytes21(0x015852502f55534400000000000000000000000000);
    bytes21 constant USDT_USD = bytes21(0x01555344542f555344000000000000000000000000);
    bytes21 constant FLR_USD = bytes21(0x01464c522f55534400000000000000000000000000);

    struct Out {
        Vault vault;
        JudgeEvm judgeEvm;
        JudgeXrpl judgeXrpl;
        BondLens bondLens;
        JudgeSumma summa;
        Vault vaultSumma;
        SummaMeter meter;
        MandateFacilitator facilitator;
        SummaLens lens;
    }

    function run() external returns (Out memory o) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        MandateRegistry reg = MandateRegistry(vm.envAddress("REG"));
        AnchorLog anchorLog = AnchorLog(vm.envAddress("LOG"));
        SpendMeter spend = SpendMeter(vm.envAddress("METER"));
        AgentRefs refs = AgentRefs(vm.envAddress("REFS"));
        address usdt0 = vm.envAddress("USDT0"); // on Coston2: MockUSDT0 (EIP-3009, public mint)
        require(
            address(anchorLog.registry()) == address(reg) && address(spend.registry()) == address(reg)
                && address(refs.registry()) == address(reg),
            "core mismatch"
        );

        // Production timers, as v0.13–v0.15 run them.
        uint64 responseWindow = uint64(vm.envOr("RESPONSE_WINDOW", uint256(24 hours)));
        uint64 anchorGrace = uint64(vm.envOr("ANCHOR_GRACE", uint256(1 hours)));
        uint64 commitLead = uint64(vm.envOr("COMMIT_LEAD", uint256(10 minutes)));
        uint64 meterGrace = uint64(vm.envOr("METER_GRACE", uint256(5 minutes)));
        uint16 haircutBps = uint16(vm.envOr("LENS_HAIRCUT_BPS", uint256(3000)));
        bool testnet = vm.envOr("TESTNET", true);

        JudgeSumma.PriceRow[] memory map = new JudgeSumma.PriceRow[](2);
        map[0] = JudgeSumma.PriceRow(testnet ? bytes32("testXRP") : bytes32("XRP"), bytes32("XRP/outflow"), XRP_USD, 6);
        map[1] = JudgeSumma.PriceRow(
            testnet ? bytes32("testFLR") : bytes32("FLR"), bytes32(uint256(uint160(usdt0))), USDT_USD, 6
        );

        vm.startBroadcast(pk);

        // 1. The consequence layer.
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);
        o.judgeEvm = new JudgeEvm(
            Vault(predicted),
            reg,
            anchorLog,
            IFdcVerification(address(0)),
            spend,
            anchorGrace,
            responseWindow,
            meterGrace
        );
        o.judgeXrpl = new JudgeXrpl(Vault(predicted), reg, anchorLog, IFdcVerification(address(0)), refs);
        address[] memory judges = new address[](2);
        judges[0] = address(o.judgeEvm);
        judges[1] = address(o.judgeXrpl);
        o.vault = new Vault(reg, refs, ProtocolsV2Interface(address(0)), commitLead, judges);
        require(address(o.vault) == predicted, "vault address prediction");
        o.bondLens = new BondLens();

        // 2. SUMMA.
        address predictedSumma = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        o.summa = new JudgeSumma(
            Vault(predictedSumma), reg, refs, IFdcVerification(address(0)), FtsoV2Interface(address(0)), map
        );
        address[] memory summaJudges = new address[](1);
        summaJudges[0] = address(o.summa);
        o.vaultSumma = new Vault(reg, refs, ProtocolsV2Interface(address(0)), commitLead, summaJudges);
        require(address(o.vaultSumma) == predictedSumma, "VaultSumma address prediction");

        // 3. Conatus.
        o.meter = new SummaMeter(reg, o.summa, FtsoV2Interface(address(0)));
        o.facilitator = new MandateFacilitator(reg, o.summa, o.meter, testnet ? bytes32("testFLR") : bytes32("FLR"));
        o.lens = new SummaLens(reg, o.meter, FLR_USD, haircutBps, FtsoV2Interface(address(0)));

        vm.stopBroadcast();

        string memory k = "v0.16";
        vm.serializeString(k, "version", "v0.16 + amendment v1.2");
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "registry", address(reg));
        vm.serializeAddress(k, "anchorLog", address(anchorLog));
        vm.serializeAddress(k, "spendMeter", address(spend));
        vm.serializeAddress(k, "agentRefs", address(refs));
        vm.serializeAddress(k, "vault", address(o.vault));
        vm.serializeAddress(k, "judgeEvm", address(o.judgeEvm));
        vm.serializeAddress(k, "judgeXrpl", address(o.judgeXrpl));
        vm.serializeAddress(k, "bondLens", address(o.bondLens));
        vm.serializeAddress(k, "judgeSumma", address(o.summa));
        vm.serializeAddress(k, "vaultSumma", address(o.vaultSumma));
        vm.serializeAddress(k, "summaMeter", address(o.meter));
        vm.serializeAddress(k, "mandateFacilitator", address(o.facilitator));
        vm.serializeAddress(k, "summaLens", address(o.lens));
        vm.serializeAddress(k, "usdt0", usdt0);
        vm.serializeUint(k, "responseWindow", o.judgeEvm.responseWindow());
        vm.serializeUint(k, "anchorGrace", o.judgeEvm.anchorGrace());
        vm.serializeUint(k, "meterGrace", o.judgeEvm.meterGrace());
        vm.serializeUint(k, "commitLead", o.vault.commitLead());
        string memory json = vm.serializeUint(k, "lensHaircutBps", haircutBps);
        string memory net =
            block.chainid == 114 ? "coston2" : block.chainid == 14 ? "flare" : vm.toString(block.chainid);
        vm.createDir(string.concat(vm.projectRoot(), "/deployments"), true);
        vm.writeJson(json, string.concat(vm.projectRoot(), "/deployments/", net, "-v0.16.json"));

        console.log("Vault:              ", address(o.vault));
        console.log("JudgeEvm:           ", address(o.judgeEvm));
        console.log("JudgeXrpl:          ", address(o.judgeXrpl));
        console.log("BondLens:           ", address(o.bondLens));
        console.log("JudgeSumma:         ", address(o.summa));
        console.log("VaultSumma:         ", address(o.vaultSumma));
        console.log("SummaMeter:         ", address(o.meter));
        console.log("MandateFacilitator: ", address(o.facilitator));
        console.log("SummaLens:          ", address(o.lens));
        console.log("commitLead:         ", o.vault.commitLead());
    }
}
