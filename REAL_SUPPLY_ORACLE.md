# REAL Supply Oracle

`REALSupplyOracle.sol` is the production-named supply oracle. Fresh deployments use a **fresh implementation and fresh ERC1967Proxy**, atomically initialized in the proxy constructor. This revision also supports the specific REALSupplyOracle upgrade described below; it does not support upgrading the older SupplyOracleV2 or CirculatingSupplyOracle variants.

## Zero-address LP reporting upgrade

The previous deployment treated `lpBurnAddress == address(0)` as unset. This revision appends one private boolean after the existing storage fields. Every previous slot, offset and type is checked against the exact baseline source from commit `fe9e8b76f54579f4a23006cd18c011eefd0037c2`, retained in `test/fixtures/REALSupplyOracle.before-zero-lp.sol`.

- `setLpBurnAddress(address(0))` explicitly enables counting LP tokens held at the all-zero address.
- `isLpBurnAddressConfigured()` distinguishes this from unset; old nonzero settings keep working without migration.
- `clearLpBurnAddress()` disables reporting and resets the address to zero.
- Existing zero/unset configurations stay unset after a bare upgrade. Use `upgradeToAndCall(newImplementation, abi.encodeCall(setLpBurnAddress, (address(0))))` to upgrade and enable zero-address tracking atomically, signed by the existing owner. Do not call `initialize` again.
- Configured zero-address reporting includes Uniswap V2's initial 1,000 LP base units, plus LP tokens explicitly transferred there. It reports inaccessible LP claims, not destroyed underlying REAL, and never subtracts them from REAL circulation.

For the existing Sepolia proxy `0x93a83641128057ca5d713edcfe9f935a7e55f9e5`, run `RPC_URL=... node scripts/prepare-lp-zero-upgrade.mjs <proxy>` to check the baseline code and storage layout and prepare unsigned implementation data. After the owner deploys the new implementation, supply its address as the second argument to verify its runtime and prepare/estimate the unsigned owner upgrade call. The script never loads keys or sends transactions. Confirm the connected network and owner before signing.

The same proxy address and all existing supply settings remain in place. The LP pair must still be configured separately on the intended chain; a mainnet pair cannot be used on Sepolia. For a fresh deployment, a zero initializer address remains unset until the owner explicitly selects it with `setLpBurnAddress(address(0))`.

## Accounting

Circulating REAL = live ERC-20 total supply minus registered vesting locks, DAO reserve and undistributed rewards reserve. User-staked REAL, including an unstaking waiting period, remains circulating. Vote exclusions and LP reporting do not change circulation.

The rewards reserve uses either the live balance of one dedicated wallet or one aggregate accounting adapter. These modes are mutually exclusive. Both zero disables rewards accounting. `setRewardsReserve(wallet, source)` is owner-only; changing addresses does not move tokens. Moving an entire reserve to a replacement requires coordinating the token transfers and address update so snapshots during the transition are understood.

The initial 900,000 REAL reserve is not hardcoded: the oracle reads its remaining balance. Rewards transferred to user-owned circulating balances increase circulation. Direct mode assumes everything held by that dedicated wallet is undistributed reserve. A future reward contract containing both earned claimable rewards and undistributed reserves should use the aggregate adapter to report only the latter.

`IRewardsReserveSupply` requires `realToken()` and `getUndistributedRewards()`. It is a **trusted accounting source**, not proof of balances: its implementation must exclude DAO funds, registered vesting locks and user stake. Several validator reward contracts can be represented by one reviewed aggregate adapter; the oracle does not loop through an unlimited list.

Known address overlaps are rejected, including direct DAO/rewards equality, factory addresses and vesting membership exposed by REAL factories' `isDeployedVesting(address)` registry. Legacy factory adapters without that optional registry cannot provide the membership check. No address check can prove an aggregate adapter reports disjoint assets; review that adapter before registering it.

The optional `IStakingSupplyMetrics` exposes `realToken()` and `getStakingMetrics()`, returning staked base units, distinct staker count and validator count. The oracle's corresponding getter adds `configured`; unset returns `(false, 0, 0, 0)`. Definitions of stakers and validators belong to the future adapter. A validator registration count is not evidence of online machines. This integration does not imply custody by validator operators and never subtracts user stake from circulation.

A failing rewards source or vesting factory makes affected supply reads revert. The owner can replace/disable the rewards source; factory registration is append-only and a broken registered factory may require an upgrade. Staking-source failure affects its metrics getter, not supply calculations.

## Administration

The initial owner is explicit in the initializer. Ownership handoff requires acceptance; renouncing is disabled. The owner can change settings and authorize UUPS upgrades. Public reads require an RPC connection only, never a backend private key.

## Reviewed deployment inputs

Files in `deploy/` separate the two networks. All token values use 18 decimals.

| Setting | Sepolia | Ethereum mainnet |
| --- | --- | --- |
| Chain ID | 11155111 | 1 |
| Owner | `0xbF44702EdC6A288691212C1503B07a9F860Fdbef` | `0x4106E21F155383DfB947b44e2A846405Cd7837A6` |
| Token | `0xe6654E7dbD7CAF7b5a2eD068a3c945fD208000Fa` | `0x325Aa344761c19F7ab6dc45A95f01d6907A30DCA` |
| Issuance baseline | 21,000,000 | 100,000,000 |
| First factory | `0xd964e11dA64dB950EC7e97ED5363e78F2BdC345a` | `0x63b19d49d7C3FE0EC8749c4AaA6D4116bE18ad74` |
| DAO reserve | Unset | `0x2Ef8340e0eeacA70D738090bA36Bb57d4Aa09a3f` |
| Rewards reserve | Owner's test wallet above | `0x6B5dbA8ba898f5D313A7ae379d31a3B133D77525` |

LP configuration, aggregate rewards adapter and staking metrics initially remain unset. The Sepolia test reserve is a personal test wallet: its entire tREAL balance is excluded for testing. This is not the mainnet reserve wallet.

Mainnet allocation labels were cross-checked with the project-provided [Corporate Wallet List](https://real-development.medium.com/real-corporate-wallet-list-517c31f60052). Factory/NFT deployments and ownership handoff are listed in [BBDc-Public Deploy Notes](https://github.com/mr-rickrix/BBDc-Public/blob/3d32634233c185b502d5c73e700952d4a3e2e019/Deploy%20Notes). Mainnet mint events total 100 million REAL; the deployed token's `mintedSupply()` counter is not a reliable historical issuance baseline. The repository's newer token source differs from the token deployed at that address.

At the checked mainnet snapshot the DAO held 79 million, rewards Safe held 900,000 and the factory reported zero locks: circulation was 20.1 million REAL. These are snapshots, not constants. Published future vesting schedules alone do not create on-chain locks; the oracle subtracts actual registered factory accounting.

## Build and local tests

Use Node.js 22 or newer, `npm install`, then `npm run test:real-supply`. This compiles the production source using solc 0.8.28, optimizer 200, Cancun, and OpenZeppelin 5.1.0, and runs a localhost-only test chain. The test asserts chain ID 31337 before creating local transactions.

Coverage includes atomic initialization with a reserve; disabled reinitialization; unauthorized configuration/upgrades; two-step ownership handoff; burn math; DAO/Safe treatment; reward payouts and source replacement; wrong-token sources; invalid accounting; known overlap rejection in either configuration order; factory aggregation; LP metrics; and user staking remaining circulating. This is not an independent security audit.

## Prepare, deploy and verify

1. Review and merge a specific commit; use that same source for the final Sepolia rehearsal and mainnet. Compile `REALSupplyOracle.sol` with Solidity 0.8.28, optimizer 200, Cancun, OZ 5.1.0. Record the commit and compiler settings.
2. Set `RPC_URL` to a Sepolia RPC and run `node scripts/prepare-real-supply-oracle.mjs deploy/real-supply-oracle.sepolia.json`. This is read-only: it validates the chain/token/factory, compiles, estimates implementation gas and writes artifacts, initializer and unsigned data under ignored `artifacts/real-supply-oracle/`. It never loads a key or broadcasts.
3. Using your wallet or Remix, review and sign the fresh implementation deployment. It has no constructor arguments. Re-estimate gas and confirm the network in the signing wallet.
4. Rerun the preparation script with the config, an output directory and the deployed implementation address as its third argument. It verifies exact runtime bytecode, including UUPS address immutables, then prepares and estimates the fresh proxy deployment against current chain state. Preserve any earlier deployment-plan artifact separately if desired.
5. Review and sign deployment of ERC1967Proxy with `(implementation, initializer)`. Always pass initialization bytes in the constructor; do not deploy an empty proxy for later initialization.
6. Verify source on Etherscan using generated `standard-input.json`; verify proxy linkage. Confirm code, creation receipt, `Initialized`, owner, token, baseline, factory list and reserve configuration. Read ERC1967 implementation slot `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`.
7. At one fixed block, reconcile `total - vesting - DAO - rewards = circulating`; compare token/factory reads directly. At a prior Sepolia snapshot, total 20,999,979 minus locks 530 minus test reserve 8,996 equaled 20,990,453 tREAL. Recheck current values.
8. On Sepolia, exercise reward payouts, reserve replacement and owner/initializer protections. Check unset staking metrics and confirm user stake never affects circulation. Keep the old deployments intact.
9. After the rehearsal and review pass, repeat preparation with a mainnet RPC and `deploy/real-supply-oracle.mainnet.json`. Recheck balances, addresses and no-future-mint assumptions before signing. Mainnet deployment and backend registration are not performed by this PR or its CI.
