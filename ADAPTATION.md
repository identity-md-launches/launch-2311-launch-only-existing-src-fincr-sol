# FINCR-only launch adaptation

The existing `src/FINCR.sol:FINCR` already supports the requested custom-token
launch without a contract change. Its exact source, constructor, voluntary burn,
compiler settings and dependencies are preserved. Only FINCR is selected for
launch; the application-contract list must be empty.

## Changes and reasons

| File | Change | Requirement |
| --- | --- | --- |
| `README.md` | Identifies FINCR as the sole launch contract, records the supply and allocations, preserves the paying founder's default trading-fee requester, and labels the mining documentation as a separate future deployment. | The previous entry-point documentation described a mining deployment and a mining reserve; this assignment launches only the token and sends the remainder directly to the founder. |
| `test/FINCRLaunch.t.sol` | Adds 13 offline token regressions, including three fuzz tests, for the exact bytecode pins, metadata, constructor validation, caller mint, allocation and claim transfers, pool transfer legs, burns, allowances, rejected privileged calls and forbidden opcodes. | Reproduce the imported finding and verify exact source preservation and custom-token launch behavior with the pinned toolchain. |
| `ADAPTATION.md` | Records the launch handoff, audit disposition and verification evidence. | Required adaptation record for the manifest and review steps. |

All existing Solidity source and tests, ABI files, dependency pins and build
configuration remain unchanged. No dependency was added. `SNAPSHOT.json` remains
the record of the original source snapshot, rather than a claim that the new
documentation and tests were part of that earlier snapshot.

## Handoff to the manifest step

These are the assignment's parameters; no `launch.json` is created by this adaptation.

| Field | Required value |
| --- | --- |
| Chain | Robinhood Chain, `4663` |
| Kind | `custom_token` |
| Token artifact | `src/FINCR.sol:FINCR` |
| `token.contract` | `FINCR` |
| `token.name` | `FINANCIER` |
| `token.symbol` | `FINCR` |
| `token.decimals` | `18` |
| `token.constructorArgs` | `["1000000000000000000000000000"]` |
| `token.totalSupply` | `"1000000000000000000000000000"` |
| `contracts` | `[]` |
| `pool.pairedCurrency` | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` (IMD, 18 decimals) |
| `pool.fee` | `12500` (1.25%) |
| `pool.tickSpacing` | `60` |
| `pool.initialPrice` | `"79228162514264337593543950336"` (provenance value; the deployer derives the opening price) |
| Custom hook | None |
| Trading-fee requester | Preserve the default authenticated paying founder wallet; no Operations or fee-router override |

Copy the assigned economics exactly:

```json
{"poolBps":5000,"initialMarketCapWei":"2500000000000000000000","remainderTo":"0xbcf19c0821a245383c127570615896abac9e424f"}
```

The market cap is 2,500 IMD for the entire supply. The single nonpayable
`uint256` constructor mints all 1,000,000,000 FINCR once to `msg.sender`, which
will be the official factory. It takes no owner, factory, pool-manager or launch
number arguments and needs no initializer or constructor-time external calls.

The factory transfers the mandatory 100,000,000 FINCR swarm share to its official
MerkleDistributor, allocates 500,000,000 FINCR to the pool, and sends the remaining
400,000,000 FINCR directly to the stated founder recipient. There is no swarm
wallet to configure. No project contract receives an allocation or reserve at
launch. Mining and gateway deployment and funding are independent later work;
none of the repository's mining, controller, receiver, reserve or fee-router
contracts belong in this manifest.

The authenticated paying wallet determines the default trading-fee requester.
The remainder recipient is recorded separately in economics; it is not used to
invent or override that authenticated identity.

## Exact preservation

The unchanged configuration builds with Solidity `0.8.30`, Cancun, optimizer
enabled with 200 runs, `viaIR=false` (the default), and `bytecode_hash="none"`.
The compiled FINCR artifact confirms these settings and has no library link
references. The existing dependency pins are OpenZeppelin Contracts `v5.4.0`
at `c64a1edb67b6e3f4a15cca8909c9482ad33a02b0` and forge-std `v1.9.7`
at `77041d2ce690e692d6e03cc812b57d1ddaa4d505`.

Verified pins:

- `src/FINCR.sol` SHA-256:
  `893149e5145b06a2c45b8d6f43a3a91bf1ff7312bca1cc60fd80259cd78cc0e1`.
- `keccak256(creationCode || abi.encode(uint256(1e27)))`:
  `0x511ed126a50c2e98030294c73314bb5b42beb62bbc2a87848e2bc44abddf7562`.
- `keccak256(address(token).code)` after construction with `1e27`:
  `0x946270e19519507b25f0e64ba542b050d325476e1a397aadf1f64ea23d16064c`.

`testPinnedCreationAndDeployedRuntime` checks both required keccak hashes against
the actual compiled creation code and the runtime deployed in the test.
`SNAPSHOT.json`'s `runtimeTemplateKeccak` is the artifact before the immutable
`initialSupply` is populated, so its different hash is expected.

## Imported audit finding

Finding `b4a313ce8de0f0c3da28d196338f0636bc5b840f004780bf8d5a2908e70cab64`
**reproduces and is informational, not a defect**. Both zero and `1e27 + 1`
revert with `"invalid supply"`; `1e27` succeeds and mints the full supply to
the constructor caller. Two constructor fuzz tests also cover invalid
nonmultiples and accepted positive multiples of 100.

The adaptation preserves that validation and fixes the launch argument in the
handoff and hash regression. Hardcoding a different constructor or restricting
its previously accepted inputs would violate the exact-preservation requirement.
No source fix is warranted, and no imported finding remains unreproduced.

Additional regressions confirm that both the constructor caller and a stranger
fail all 22 common mint/admin/freeze/seize selectors from the protected checks.
Transfers still work afterwards. A holder receiving `1e18` can voluntarily burn
`4e17`, leaving `6e17` and supply `1e27 - 4e17`; burning `6e17 + 1` reverts.
The constructor caller cannot transfer a holder's tokens without allowance.
The runtime opcode check skips PUSH data and rejects DELEGATECALL, CALLCODE
and SELFDESTRUCT.

## Verification

Run with the existing project configuration and the assignment's seed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x4606f75b98ee7a22efb4207e253a248f643a92e2b9bdc177b1522bd0c1af0d37 forge test
```

`forge build` passed with the existing configuration. The full `forge test`
passed **231 tests across 33 suites**, with zero failures or skipped tests,
using the seed above. The targeted
`forge test --match-contract FINCRLaunchTest -vv` also passed all 13 new tests,
including 512 runs for each fuzz test, with the same seed.

The new suite is entirely local and requires no RPC, secrets, environment reads
or extra dependencies. Its factory and transfer endpoints are test models;
pool transfer-leg checks do not claim to execute Uniswap v4 seed/swap settlement.
The supplied protected tests were read as the acceptance specification; their
official factory/PoolManager harness runs in the subsequent verification step.
No transactions were broadcast. Slither and Mythril were not run.
