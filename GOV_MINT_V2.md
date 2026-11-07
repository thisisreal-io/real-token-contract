# GOV MINT v2 — first development draft

Status: **DRAFT — incomplete voting eligibility; do not deploy or fund.**

This is a new contract file requested by Rick on November 7, 2026. It is derived from `DAO Minting Contract.sol` at commit `8fb104ec4d425171252f048cf48738fbff4e98fc` (original blob `44c7d4e3552c1c4f54982adc253d1456b6a519f6`). The original source is preserved byte for byte. V2 releases existing REAL; it does not mint tokens. This is a separate deployment design, **not** a storage-compatible upgrade to the original contract.

## Wallet replacement requested by Rick

1. One of the current five authorized wallets submits the slot and proposed replacement address. Submission records that wallet's approval once.
2. Two other distinct current authorized wallets approve the same immutable request. The incoming wallet cannot approve its own appointment unless already a current signer; an existing signer cannot be nominated, so in practice it cannot approve.
3. The third approval atomically replaces the old wallet. There are always five distinct nonzero authorized addresses. The outgoing wallet immediately loses its signer permissions. Its signature is not required: three of the other four wallets can recover a compromised slot.

This also supports ordinary departures. Recovery works while the system is paused. Approvals cannot be replayed, reused for a different request, or combined across wallet-group changes. Each replacement advances a signer epoch. **As a conservative draft behavior, every unexecuted release proposal and every outstanding replacement request from the previous epoch becomes unusable.** Public votes on those release proposals cannot execute; a fresh proposal and vote are required. Executed-proposal history remains intact. Confirm this reset behavior before production.

## Implemented in this draft

| Area | Change |
| --- | --- |
| Internal proposal approval | Creator plus two distinct current signers must approve before the fixed public voting start. Missed approval deadline fails closed. Proposal amount, recipient, root and dates cannot be edited. |
| Wallet recovery | Request plus two additional current approvals; atomic replacement, duplicate/zero/nominee rejection, old-wallet revocation, epoch isolation. |
| Release frequency | At least 90 days between **actual transfers**, checked at execution for every proposal. Multiple pending proposals cannot execute together. Timestamp never moves backward to an old voting deadline. |
| Release amounts | Existing 1M-per-proposal cap plus 79M cumulative release ceiling. |
| Administration | Removed unilateral signer and oracle setters and all UUPS upgrade entry points. `deployer` is provenance only and confers no authority. |
| Initialization | Exactly five distinct valid signers; token/oracle must contain code; one-time atomic proxy initialization required. Implementation initialization is disabled. |
| Votes | Reject nonexistent/stale proposals, current corporate signers, the vault, duplicate votes and zero-effective-power votes; require positive vote totals for execution. |
| Emergency approvals | Three-of-five actions bind the signer epoch; pre-rotation approvals cannot mix with the new group. |

The v2 draft uses a fixed ERC1967 proxy with **no contract-exposed upgrade path**. Deploying through an independently administrable proxy would undermine that property and is outside this design. A fixed implementation is a working design choice for review, not an instruction to deploy. A new version/migration would be necessary for future logic changes. The fixed oracle address may itself be an upgradeable proxy; its administrators remain a governance dependency.

## Remaining design and implementation work

**The contract is not finished and passing local tests is not production acceptance.**

1. **Voting eligibility is unresolved.** The original Merkle method remains. Three signers approve the root, but proofs still demonstrate membership in an approved tree, not historical token ownership, continuous holding, completeness, beneficial ownership or vesting exclusion. No claim of fully on-chain balance verification is made. Decide the balance-verification architecture before building the final vote path and proof-generation/distribution system. Existing REAL has no assumed historical balance checkpoint interface. Current-balance checks alone would not prevent token reuse between wallets. Do not mistake adding three signatures for solving this problem.
2. **Inherited numbers are test settings, not approved policy:** 15% quorum, 51% approval, 10 voter addresses, 5% cap per address, maximum 30-day voting period. Define production quorum/approval/minimum participants, minimum voting duration/notice, threshold rounding and whether the cap is wanted. Addresses do not prove unique people. No new arbitrary production thresholds are selected here.
3. **Snapshot consistency and exclusion authority:** circulating supply is still captured at proposal creation, with no recorded balance snapshot block for the Merkle tree. Corporate exclusions still consult the external oracle dynamically. Freeze/verify the required eligibility and supply context together and decide how external oracle upgrades and exclusion changes affect an ongoing vote. Removed signers must remain excluded if still organization-controlled; this requires a complete organization-wallet policy, not merely the current five-signer list.
4. **Pause clock and proposal lifecycle:** original pause controls block votes without extending deadlines. Define restart/extension/cancellation behavior; pending emergency approvals currently have no expiry/revocation beyond signer rotation. Decide proposal expiry, stale snapshots and cancellation/recovery safeguards.
5. **Initial reserve restriction:** earlier discussion mentioned a five-year initial no-release period, but the maintained reference does not establish its exact current authority or start date. This draft does not silently invent that timestamp.
6. **Deployment/custody:** no mainnet DAO deployment, reserve transfer, Safe modification or oracle configuration change is included. Verify actual chain state, funding, approved five-wallet identities, exclusion coverage and custody migration. The October 18 oracle record describes reserve custody in a Safe; supply reporting is not DAO release enforcement.
7. **Independent review and complete tests:** extend adversarial and invariant coverage once these decisions are settled; review failed/NO votes, cap and quorum boundaries, rotation/recovery policy, external token/oracle failures, long-lived snapshots and full reserve accounting. The current suite does not establish these as resolved.

## Local validation

Uses repository dependencies: Solidity 0.8.28, OpenZeppelin 5.1.0, ethers 6.17.0 and Hardhat 3.17.0. Run:

```bash
npm install
node test/run-gov-mint-v2.cjs
```

The runner starts an isolated localhost Hardhat chain, compiles v2 and test mocks, runs `test/gov-mint-v2.mjs`, and shuts down the child chain. It uses no live-chain RPC, real keys, Safe transaction or deployment. Nine integration groups cover initialization, absence of unilateral controls/upgrades, internal proposal approvals, proof/duplicate/exclusion checks, timelock and actual-transfer cooldown, replacement authority, stale signatures, recovery while paused, and invalid supply/zero effective voting power. **Mock voting trees intentionally do not prove real token holdings; this suite does not resolve the eligibility gap.**

## Sources for review

- DAO Governance / Governance & Token Release Structure: https://docs.google.com/document/d/1-iDf2Tfti7_X82m4hQAUPOAMA7SQ3kWyItr7C0XMRAw/edit
- Official active-development reference: https://drive.google.com/file/d/1E6fXcOJT2nV7SG_kjjg_djt0RmrVV2kg/view
- October 25 proposed initiation/replacement additions: https://drive.google.com/file/d/18-xAWr3h_v9qwUBEshtnEf36C8IYT4Wq/view
- October 18 Supply Oracle deployment reference: https://drive.google.com/file/d/14bcO8IcD94Vd9OrDRQjQTeQF5JLydPOT/view

No merge, deployment, live wallet action or developer message is part of this draft.
