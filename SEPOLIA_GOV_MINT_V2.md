# GOV MINT v2 — Sepolia test package

**Status: LOCAL-TESTED, SIGNER-ATTESTED ELIGIBILITY PROTOTYPE. NOT PRODUCTION-READY.**

This package prepares a Sepolia rehearsal. It does not deploy contracts, send wallet transactions, merge the PR, move REAL, or change the existing DAO contract or deployed supply oracle. Review the exact branch before using its unsigned deployment data.

## Confirmed rules and test settings

| Rule | Sepolia candidate | Production direction |
| --- | --- | --- |
| Authorized corporate wallets | Exactly five; three approvals | Same |
| Eligible balance | Lowest balance across every Transfer in the lookback | Same rule |
| Holding lookback | 30 hours | 30 days |
| Public voting | 30 hours from third proposal approval | 30 days |
| Withdrawal delay | 30 hours of unpaused time after voting | 30 days |
| Release spacing | 90 actual hours between successful transfers | 90 days |
| Wallet quorum | max(5, ceil(2% of eligible wallets)) | ceil(2% of eligible wallets); no extra floor selected |
| Eligible wallet minimum | At least 1,000 REAL throughout the lookback | Same |
| Approval | At least 51% of counted weighted votes YES | Same |
| Concentration cap | Inherited 5% of fixed eligible voting power per address, for testing | Requires final review; not a unique-person limit |
| Release ceiling | 1M per proposal and 79M cumulative | Same |
| Five-year initial restriction | None | Removed by owner direction |
| Corporate-wallet replacement | Requester plus two other current approvals | Same |
| Replacement effects | All unfinished proposals/requests from old group invalidated | Same |
| Token custody | Tokens remain in holders' wallets | Same |

The Sepolia implementation refuses construction outside chain 11155111 or local test chain 31337. Its timing overrides are fixed in source and cannot be switched after deployment. Base public constants describe production-direction defaults; `timingConfiguration()` returns the actual deployment's values.

Five corporate wallets are **separate from** five public voter wallets. Corporate wallets cannot vote. Do not give test participants real mainnet assets or reuse publicly known development keys on a real network.

## What the scanner actually verifies

`scripts/gov-mint/build-electorate.mjs` scans all ERC-20 Transfer logs from a configured token deployment block through a fixed completed snapshot. The token must already have existed for the full 30-hour test lookback. It finds the block at/before the lookback boundary, reads opening balances there, replays every subsequent Transfer in block/transaction/log order and records each minimum. It reconciles reconstructed closing balances with `balanceOf` at the snapshot. It rejects missing blocks, duplicate/unordered logs, negative balances, wrong network/token/decimals and detected snapshot reorgs. Self transfers have no net balance effect. Credits and NFT face values are never added.

Wallets whose minimum is below 1,000 REAL are not voters and are not part of the quorum denominator. Current/former corporate signers, the DAO reserve, explicit exclusion addresses, the oracle's excluded wallets and all addresses with contract code at the snapshot are omitted under the current owner policy. Vaults/pools/vesting contracts are excluded by contract-code policy; any system allocation held by an ordinary wallet must also be explicitly listed. Burned REAL disappears from total supply and the burning holder's balance. Eligible voting supply is calculated separately from economic circulating supply; the deployed oracle is not rewritten.

The output contains canonical snapshot block/hash, anchor block/hash, time window, exclusions, eligible-address count, aggregate eligible whole-vote power, minimum balances, domain-separated Merkle root, per-wallet proofs and a hash of the reproducible manifest. The leaf binds chain, DAO, REAL token, snapshot block/hash, voter and raw voting power. Snapshot circulating supply is read from the oracle at that same block and attested with the electorate, rather than mixing a later supply read into the denominator. Individual weight is floor(minimum balance / 1,000 REAL), then the trial concentration cap applies. Vote order does not affect the cap.

## Important limitations — review before Sepolia use

1. **History is RPC-derived and signer-attested, not independently proven on-chain.** The contract verifies the Merkle inclusion proof and canonical recent block hash, but it does not verify every historical balance or completeness of the RPC log stream. Reconciliation cannot detect every malicious omission, such as a matching outbound and return pair. Three corporate signers could approve an incorrect or incomplete list, count or voting power. All three reviewers should independently regenerate and compare manifests using independent RPC sources. This is a rehearsal trust model, not the final solution to the earlier independent-verification goal. Do not fund this model with the real reserve.
2. **Snapshot is fixed before proposal creation, not mined by the third approval.** The three signers approve that exact snapshot/manifest. Public voting opens at the third approval and lasts the full configured period. The third approval must occur while the snapshot is still available through native `blockhash` (within 256 blocks); otherwise cancel and regenerate. An exact snapshot at vote opening plus independently verified continuous history needs a further proof/publication design before production. Transfers after the fixed snapshot never create additional votes for that proposal, but the on-chain code does not continuously rescan the lookback at each vote.
3. The oracle's exclusion checks are also queried at vote time; an oracle administrator could change them after the snapshot. A malicious/upgradeable oracle remains an external trust dependency. Arbitrary oracle changes cannot transfer the DAO's tokens directly, but can affect eligibility/availability.
4. Wallets are not unique people. A long-established collection of wallets can defeat an address cap. Excluding all contract wallets also excludes legitimate smart wallets, as previously discussed. Contract-code checks alone are not proof of humanity or ultimate ownership.
5. The 5% cap uses whole voting units and rounds down. If total eligible voting power is below 20 units, it can round every effective vote to zero. For Sepolia seed five ordinary voter wallets with 20,000 test REAL each, so the cap is exercised meaningfully. Final production cap/rounding policy requires review.
6. The minimum production participant count is now just the requested rounded-up 2%, so small electorates can pass quorum with one or two addresses. Sepolia has the separately requested five-address floor.
7. Pauses freeze voting and withdrawal-delay time. The effective deadline is `getEffectiveVotingEnd(id)`, not the original stored `votingEnd`. Overlapping proposal/system pauses count once; release spacing still uses actual wall-clock time. This implements the recommended freeze behavior. Explicit cancellation after voting opens is not added; corporate rotation invalidates all unfinished proposals, and a 3-of-5 pause can block them. Pending approvals do not yet have a separate expiry/revocation mechanism.

## Local validation commands

Use repository dependencies pinned to Solidity 0.8.28, OpenZeppelin 5.1.0, ethers 6.17.0 and Hardhat 3.17.0:

```bash
npm install
node test/run-gov-mint-v2.cjs
node test/run-gov-mint-v2.cjs test/gov-mint-sepolia.mjs
```

Run these sequentially; the runner reserves localhost port 18549. It creates and shuts down its own local chain. No external RPC or real wallet keys are used in these suites. Simulated time advancement tests the full durations without waiting hours.

## Sepolia preparation

1. Copy `config/gov-mint-sepolia.example.json` to a private working configuration. Fill in the deployer, a compatible 18-decimal **test** REAL address, test oracle address and exactly five distinct corporate test wallets. Do not commit credentials or keys. The RPC URL is provided through `SEPOLIA_RPC_URL`; the scripts never read a private key.
2. If new fixtures are needed, `GOV MINT Test Fixtures.sol` provides a Sepolia/local-only ERC-20 and simple owner-configured oracle. Its transfer-failure/oracle-failure switches exist to test safe failure. It is not the real token or deployed mainnet oracle. Deploy fixtures separately with a reviewed wallet, then populate their verified addresses.
3. Run `node scripts/gov-mint/prepare-sepolia.mjs CONFIG.json > deployment-plan.json`. This compiles exact pinned dependencies, checks chain 11155111, token/oracle code/interfaces and distinct signers, predicts the implementation/proxy addresses and generates two unsigned creation transactions. It sends nothing.
4. Review both transactions and pending deployer nonce. They assume two sequential ordinary CREATE deployments from the stated deployer. Changing the nonce changes the predicted addresses. Deploy implementation first; deploy the fixed ERC1967 proxy next with its encoded initializer atomically. Never deploy an empty/uninitialized proxy or use a proxy with an independent upgrade admin. Estimate current gas immediately before signing. Verify runtime bytecode/source on the explorer and read `timingConfiguration`, token, oracle and all five signers back.
5. Configure the test oracle to identify the new DAO reserve and all appropriate exclusions. Fund only with test REAL. Seed five public voter wallets with 20,000 test REAL each and ETH for gas; those wallets must differ from all five corporate signers. Add additional below-threshold, recently funded, moved/returned, corporate and system cases. Wait the full 30-hour lookback; Sepolia cannot use local time travel.
6. Fill `dao`, `tokenDeploymentBlock` and all explicit system/corporate/pool exclusions in the private configuration. Run `node scripts/gov-mint/build-electorate.mjs CONFIG.json > electorate.json`. Independently reproduce the manifest from a second RPC. Regenerate if the snapshot becomes stale or a reorg is detected.
7. One corporate signer calls `createProposal(recipient, amount, merkleRoot, proposalElectorate)` using the generated output. Two others inspect the exact amount/recipient/snapshot/root/manifest and call `approveProposal(id)` while the snapshot is recent. Their third total approval emits `VotingOpened`; public time starts then. Do not approve a hash without reproducing its manifest.
8. Each voter submits `castVote(id, support, power, proof)` from that same wallet using its generated proof. Check exclusions, under-threshold rejection, moved/returned token minima, invalid/foreign proofs, duplicate rejection, YES/NO results, fixed cap and quorum count. Exercise 3-of-5 pauses/unpauses and verify remaining time is preserved.
9. After voting and the 30-hour unpaused withdrawal delay, execute a passing proposal. Verify exact recipient amount, cumulative released total, replay rejection and the 90-hour actual-transfer cooldown on another passing proposal. Test a failed majority and an insufficient-participant proposal too.
10. Submit and approve a wallet replacement. Confirm the incoming wallet does not approve its own appointment, the removed wallet immediately loses permissions, prior corporate addresses cannot vote and every unfinished old-epoch proposal/request is unusable.

No live Sepolia deployment was performed by preparing this package. Before mainnet, resolve the independent historical-verification architecture, exact opening-snapshot semantics, exclusion-authority assumptions and final production concentration policy, then complete developer review and independent security review.
