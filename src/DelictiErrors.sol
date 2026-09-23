// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title DelictiErrors — every refusal the consequence layer can give, declared once
/// @notice Until v0.11 all of these lived on `Bond`. Splitting it into a `Vault` and its judges
///         (SPEC §8.2) moved each check into whichever contract makes it, and a caller — a
///         watcher's script, a test — should not have to know which one that is: an error's
///         selector is its signature, so declaring them in one interface that all of them inherit
///         keeps every selector identical to v0.10's and costs no bytecode.
interface DelictiErrors {
    error NothingToSlash();
    error NotAgentTx();
    error TxNotSuccessful();
    error UnorderedTxs();
    error WithinBudget();
    error LengthMismatch();
    error LeafNotAnchored();
    error LeafConsumed();
    error WrongReceiptKind();
    error FdcProofInvalid();
    error ProofDoesNotMatchClaim();
    error ClaimOutsideProvenRange();
    error MandateStillLive();
    error TransferFailed();
    error CoolingWindow();
    error NothingOwed();
    error BondSlashed();
    error BadStake();
    error NotExclusive();
    error DeedWithinGrace();
    error AlreadyAccused();
    error AccusationClosed();
    error ResponseWindowOpen();
    error AnchoredInTime();
    error AnchoredTooLate();
    error WrongDeed();
    error NoMeter();
    error NotMetered();
    error TallyAgrees();
    error NoCommitment();
    error CommittedTooLate();
    error CommitmentStale();
    error ClockDrift();
    error WrongSource();
    error WrongAsset();
    error NotThisBond();
    error NotAcknowledged();
    error AccusationOpen();
    error NoAgentRef();
    error AgentRefNotProven();
    error DuplicateLeaf();
    error NothingNew();
    error NoDeposit();
    // v0.11
    error NotJudge();
    error JudgeOfAnotherVault();
    error NoJudges();
    error NoAccusationOpen();
    error NotExclusiveOnXrpl();
    // v0.12
    error NoBeneficiary();
    error BeneficiaryFixed();
}
