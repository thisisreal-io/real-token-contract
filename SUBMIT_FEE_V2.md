# Submit Fee V2: company-profile category

The current server and frontend submission maps accept Property0, Forum1 and Poll2. The existing `submit fee.sol` enum has those same three values. The DEV MCP catalog exposes a Submit Fee ABI, but ABI enums do not enumerate their allowed values. No claim is made here that deployed bytecode was independently matched to source.

`SubmitFeeV2.sol` appends Company3 and preserves0–2. The submit signature and Submitted event layout remain compatible. Every successful explicit submit call burns exactly1 REAL (10^18 token units). This contract is a separate deployable version; it does not upgrade or modify any deployed contract or the original source file.

## Scope and rules

- Property/company create-or-claim payments may use an on-chain token burn OR an off-chain Credit debit, never both for one application.
- The contract does not handle Credits, hold membership balances, verify applicants, approve profiles, activate classrooms, or assign profile management. Owner eligibility remains a separate backend check using combined eligible holdings.
- Forum/Poll category values are retained for compatibility. Their presence does not introduce a platform charge. Current ordinary discussion/poll participation remains free at1 REAL membership; do not wire this function into those ordinary actions. DAO governance is separate.
- A combined create-and-claim request uses one paid application and one unique backend ID, not two submit calls. A rejected resubmission uses a new application/ID after explicit user fee confirmation. Retried confirmation must reuse its accepted payment, never ask for another burn.
- The fee burns REAL; native gas is separate. Transaction must send no native ETH value. Approval is for the new contract address when deployed. Vesting NFTs cannot be burned as a submission fee.
- Function arguments and events are public. Never place applicant names, verification messages, contact emails, documents, private answers or raw answer hashes in the on-chain title/backend ID. The future adapter must use a reviewed non-sensitive public reference.

## Review and deployment handoff

1. Miura reviews the source and tests. The repo already pins OpenZeppelin5.1.0; V2 uses that exact version for reproducibility, unlike the original file's5.2.0 import. Review the compiler settings and real burnable18-decimal token address.
2. Deploy only after the separately approved deployment process, first on the intended test network. This PR provides no deployment script, addresses, signing keys or automatic deployment job.
3. Verify bytecode/source, token binding, fee constant and Company3 behavior. Check burn and Submitted events in a test transaction, allowance, native-value rejection, replay handling and failed-transaction retry.
4. Add a dedicated reviewed V2 contract configuration for the new profile-payment adapter. Do NOT silently replace the legacy Submit Fee row/address: outstanding legacy intents must still confirm against their original chain/contract.
5. Backend implementation still needs pinned chain/contract/token/fee context per intent; source of truth for schema-valid application/title/wallet; globally reserved backend IDs; authorized wallet verification; confirmed successful receipts/events from the expected emitter; global transaction/intent replay protection; post-fee combined-balance eligibility and stale/unknown transaction reconciliation. A Company label in an ABI is not enough to enable payments.
6. Add Company3 to the NEW profile frontend payment adapter only after backend support. The current frontend/backend maps are intentionally unchanged by this PR. Mainnet selection must not reuse the current frontend's hard-coded Sepolia configuration.

The new version has its own usedBackendIds mapping. Old and new deployments do not share replay state; backend intent/receipt linkage must enforce reuse protection across both. Preserve paid-but-unconfirmed recovery rather than offering Credit spending while a token burn may still succeed.

## Tests

Run `npm install`, then `npm run test:submit-fee-v2`. A disposable Hardhat node binds127.0.0.1 only; tests refuse a non-loopback RPC. No real chain, user wallet, server data or backend record is touched. The workflow only installs, compiles and tests; it cannot deploy remotely.

Tests compile using solc0.8.28, optimizer200, Shanghai EVM target with pinned OpenZeppelin5.1.0, and exercise the bytecode on a local chain. Checks cover category codes0–3, exact token/supply reduction and event contents, constructor validation, duplicate/zero IDs, empty title, invalid enum, allowance/balance failures, reverted burn rollback with safe retry, and reentrancy rejection. These are functional checks, not a production security audit.
