# GOV MINT v2 — current development reference

**Status: Sepolia rehearsal candidate using signer-attested eligibility. Not production-ready. No live deployment has been performed.**

The original `DAO Minting Contract.sol` is preserved. The separate v2 branch began from commit `8fb104ec4d425171252f048cf48738fbff4e98fc`; the original file blob is `44c7d4e3552c1c4f54982adc253d1456b6a519f6`. V2 is a new fixed-implementation deployment design, not a storage-compatible upgrade to V1. It releases existing REAL; it does not mint more tokens.

## Owner-confirmed rules

- Exactly five authorized corporate wallets; three distinct current approvals for release-proposal initiation and for corporate-wallet replacement.
- A replacement request records the requester's approval; two other current wallets approve. No outgoing-wallet signature is required. The nominee cannot approve its own appointment. The third approval swaps one address atomically and revokes the old address immediately.
- Replacement invalidates every unfinished proposal/request and emergency approval from the old signer group. Already executed transfers remain historical facts.
- Public voting begins on the third internal proposal approval and runs 30 days in production direction; Sepolia runs 30 hours.
- Tokens stay in members' wallets. Voting power is based on the **lowest balance throughout the prior holding period**, one vote per 1,000 REAL. Production lookback is 30 days; Sepolia uses 30 hours. Top-ups do not instantly add weight and moved/returned tokens cannot regain lost minimum balance within the same lookback.
- Only qualifying wallet addresses count in quorum. Below-1,000 wallets and credit-only accounts do not count. Corporate/system/DAO/pool/vesting balances are excluded; current policy also excludes contract wallets.
- Quorum is **2% of eligible wallet addresses, rounded up**, replacing the old 15% token-weight quorum. Sepolia has a five-participating-wallet floor; production has no extra floor selected.
- At least 51% of counted weighted votes must be YES.
- Maximum 1M REAL per proposal, 30-day withdrawal delay and 90-day spacing between actual transfers. Sepolia uses 30-hour withdrawal delay and 90-hour spacing. Cumulative releases are capped at 79M REAL.
- No initial five-year reserve restriction.

## Implemented protections

The contract has no unilateral deployer setter or upgrade entry point. Initialization rejects duplicate/zero corporate signers and non-contract token/oracle addresses. Recovery works while paused. Signer epochs and pause-state revisions isolate old approvals. Past corporate signer addresses remain excluded from public voting. Domain-separated proofs bind the chain, DAO, token and fixed snapshot. Duplicate votes, zero effective weight and excess aggregate vote weight are rejected. Quorum is counted by participating eligible addresses, while 51% approval is measured by counted weighted votes.

System and proposal pauses freeze the remaining voting time, including overlap without double counting. The withdrawal-delay timer freezes too; actual transfer spacing continues to use wall-clock time. `getEffectiveVotingEnd` is the operative deadline. Pauses do not silently reject proposals. Corporate rotation invalidates them explicitly through the signer epoch. This implements the recommended freeze behavior from the design discussion.

The inherited 5% per-address cap is retained for the Sepolia trial. It is calculated against fixed aggregate eligible voting power, never the running vote tally, so voting order has no effect. It does not prove unique people or defeat established multi-wallet ownership. Whole-unit rounding can produce zero caps in very small electorates; the test guide specifies sufficient seed balances. Final production concentration/rounding policy remains subject to review.

## Sepolia files and instructions

See **[SEPOLIA_GOV_MINT_V2.md](SEPOLIA_GOV_MINT_V2.md)** for the exact test/deployment steps, configuration, limitations and trust model.

- `GOV MINT v2.sol`: general v2 draft, production-direction day timings and 2% wallet quorum.
- `GOV MINT Sepolia v2.sol`: separate fixed test overrides, restricted to Sepolia/local construction.
- `GOV MINT Test Fixtures.sol`: isolated test token/oracle, never the real deployed contracts.
- `scripts/gov-mint/build-electorate.mjs`: full-transfer-history minimum-balance reconstruction, exclusions, snapshot manifest and proofs.
- `scripts/gov-mint/prepare-sepolia.mjs`: read-only preflight and unsigned implementation/proxy deployment transactions.
- `scripts/gov-mint/compile.mjs`: pinned compiler/dependency validation and bytecode-size check.
- `config/gov-mint-sepolia.example.json`: address/configuration template without credentials.
- `test/gov-mint-v2.mjs`: existing protection regressions updated for the new electorate interface.
- `test/gov-mint-sepolia.mjs`: complete local rehearsal with scanner, unsigned deployment, pauses, YES/NO votes and release/recovery paths.

## What remains unresolved before production

**Eligibility history is computed off-chain and attested by three corporate signers.** Merkle inclusion does not cryptographically establish complete transfer history. A malicious RPC can omit some matched transfers undetected by closing-balance reconciliation, and three signers can approve false electorate metadata. This is not the fully independent on-chain holding-history verification previously identified as the final security goal. It is a clearly limited Sepolia rehearsal model. Do not put the real reserve under this model.

The snapshot is a completed canonical block preceding proposal creation, checked during each approval within native blockhash availability; it is not a snapshot mined exactly when the third approval opens voting. The eligible manifest, holder count and aggregate eligible power are frozen together at that snapshot. Rework the exact-opening snapshot/publication and historical-proof architecture before production. The external oracle supplies the snapshot's economic circulating figure and exclusions; eligible supply is computed separately, and dynamic oracle exclusion checks at voting time remain an administrative trust dependency. The mainnet supply oracle is untouched.

Other production work includes complete corporate/pool exclusion coverage, final concentration policy, pending-approval expiry/revocation, developer/security review, live chain verification and reserve-custody migration. No test result is an independent security audit.

## Validation

Run the two suites sequentially, on an isolated localhost Hardhat chain:

```bash
npm install
node test/run-gov-mint-v2.cjs
node test/run-gov-mint-v2.cjs test/gov-mint-sepolia.mjs
```

No private keys or live-chain transactions are used by the local suites. See the Sepolia guide for actual deployment preparation; none has been broadcast by this work.

## Historical sources

- Original governance specification: https://docs.google.com/document/d/1-iDf2Tfti7_X82m4hQAUPOAMA7SQ3kWyItr7C0XMRAw/edit
- Official active-development reference: https://drive.google.com/file/d/1E6fXcOJT2nV7SG_kjjg_djt0RmrVV2kg/view
- October 25 additions: https://drive.google.com/file/d/18-xAWr3h_v9qwUBEshtnEf36C8IYT4Wq/view
- Supply Oracle mainnet record: https://drive.google.com/file/d/14bcO8IcD94Vd9OrDRQjQTeQF5JLydPOT/view

The rules confirmed in this conversation and summarized above supersede the corresponding older open questions and inherited test values. Governance reserve releases remain distinct from ordinary community polls, vesting and public supply reporting.
