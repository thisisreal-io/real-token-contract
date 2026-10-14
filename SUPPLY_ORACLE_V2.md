# Supply oracle v2: developer review and deployment inputs

This branch preserves `CirculatingSupplyOracle.sol` (V1) unchanged, adds `SupplyOracleV2.sol` as a separate contract, and adds its isolated Cancun test harness. V1 remains available for reference; deploying V2 does not alter V1. The proposed contract is a new UUPS implementation for a **new, atomically initialized ERC1967Proxy**. Its storage layout and initializer differ from the previously deployed Sepolia oracle. Do not upgrade the old Sepolia proxy to this implementation.

## Supply rules

| Value | Definition |
| --- | --- |
| `getMaxSupply()` | 100 million REAL, expressed with 18 decimals. |
| `getTotalSupply()` | Live `REAL.totalSupply()`. |
| `getBurnedSupply()` | Cumulative minted amount provided at initialization minus live `totalSupply()`. This assumes the REAL token cannot mint again. Sending REAL to a dead address does **not** reduce ERC-20 total supply. |
| `getVestingLockedBalance()` | Sum of the registered factories' live `totalLocked()` counters. |
| `getDaoWalletBalance()` | Live REAL balance of the configured DAO vault; zero when the address is unset. |
| `getCirculatingSupply()` | Live total supply minus registered vesting locks minus the DAO vault. Safe and corporate wallet balances remain circulating even when voting is excluded. Invalid accounting reverts visibly. |
| `getEthLpBurned()` / `getUsdcLpBurned()` | V2-style LP token balances at the selected LP burn address. These metrics do **not** subtract REAL from circulating supply. |

The DAO continues to call `getCirculatingSupply()` and `isVotingExcluded(address)` using the same signatures. A DAO vault is automatically voting excluded while configured. The legacy `deployer()` getter now returns `owner()`; administration uses `owner()`, `transferOwnership()` and `acceptOwnership()`.

## Deployment inputs and checks

1. Independently confirm the REAL token address on the intended chain. For mainnet the project-supplied address is `0x325Aa344761c19F7ab6dc45A95f01d6907A30DCA`. Confirm its 18 decimals, its current total supply and that minting is permanently unavailable.
2. Deploy `SupplyOracleV2` implementation using Solidity 0.8.28, optimizer enabled with 200 runs, Cancun EVM, OpenZeppelin Contracts and Contracts Upgradeable **5.1.0**. The implementation constructor disables direct initialization.
3. Encode `initialize(initialOwner, tokenAddress, totalIssuedEver, firstFactory, initialDaoWallet, initialLpBurnAddress, initialVoteExcludedWallets)` and pass the bytes **in the ERC1967Proxy constructor transaction**. `initialOwner` should be the chosen admin Safe. Mainnet `totalIssuedEver` is 100 million REAL in base units if independently verified; testnet needs its own historical cumulative minted amount including any destroyed tokens. Set unknown future addresses to zero and configure them later.
4. Check the proxy owner, token, baseline, DAO address, factory list, vote exclusions and the circulating calculation on chain before relying on the figures. Configure ETH and USDC V2-style LP pairs only after verifying the REAL/quote tokens and the intended LP burn address. The quote-token parameter must be the actual WETH or USDC token for that pool.
5. Deploy a **fresh Sepolia proxy** and verify the build and behavior there before mainnet. The old Sepolia proxy's layout is incompatible. Have a separate security reviewer verify the full implementation, deployment transaction and eventual chain state.

The owner can change the DAO address, LP burn address, LP pair pointers and voting exclusions, append verified same-token vesting factories, and perform UUPS upgrades. Ownership transfer is two-step; the recipient must accept. Renouncing is disabled because it would permanently freeze needed configuration. The factory list has a 32-factory cap and cannot remove a factory: registering one is a long-lived trust decision. A broken factory can cause supply reads to revert; an upgrade is then needed. Changing a tracked LP pair or burn address changes which LP tokens the getters count, and does not preserve history of previous addresses. Only Uniswap V2-style LP ERC-20 pairs are supported. Staking accounting and monthly future unlock charts are outside this oracle.

## Tests

Run `npm install` and `npm test` with Node.js 22 or newer. The tests compile the exact local Solidity source with solc 0.8.28 and OZ 5.1.0, launch a Cancun Hardhat chain, and test initialization, admin handoff, upgrade access, REAL burn math, DAO and Safe treatment, factory aggregation and rejection, invalid accounting, LP pair validation and reporting, and compatibility getters. These are local behavioral tests, not a production security audit or confirmation of deployed bytecode.
