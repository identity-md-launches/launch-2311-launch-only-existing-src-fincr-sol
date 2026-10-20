# FINCR token tests

The existing `FINCRLaunch.t.sol` checks the exact creation code with the authorized
constructor argument, deployed runtime hash, metadata, factory-caller mint,
50%/10%/40% transfer allocations, and absence of privileged token operations.
It remains unchanged.

`FINCRBehavior.t.sol` adds constructor and event checks, zero/one/full-supply/maximum
input boundaries, self-transfers, approval replacement and revocation, finite and
infinite allowances, repeated spending, and voluntary burns. Rejected transfers
and burns must preserve balances and supply; failed delegated transfers must also
preserve allowances. Its six fuzz properties each run 1,000 cases.

`FINCRInvariant.t.sol` targets only the eight actions in `helpers/FINCRHandler.sol`.
The handler deploys the original FINCR and transfers its supply to local actors
in the launch allocation proportions. It never edits token storage or mints more
tokens. Four properties are checked throughout 256 sequences of 128 calls:

- All balances sum to live supply; live supply plus voluntary burns equals 1e27.
- Each holder's balance matches independently tracked receipts, spending and burns.
- Each allowance matches approvals and successful delegated spending, including
  unchanged allowances after rejected calls.
- Metadata, initial supply and the pinned runtime hash remain unchanged.

After each sequence, every remaining balance must still be voluntarily burnable.
A deterministic handler exercise also checks that positive direct transfers,
positive delegated transfers, burns and expected failures are reachable.

Run the full suite with the assignment's seed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x4606f75b98ee7a22efb4207e253a248f643a92e2b9bdc177b1522bd0c1af0d37 forge test
```

All new tests work offline with the existing dependencies. Their labeled actors
are test identities, not deployment settings. They exercise FINCR's transfer
behavior, not an official factory or Uniswap pool deployment. Manifest selection,
IMD pairing, the 2,500 IMD opening valuation and the authenticated fee requester
remain launch-stage checks; this suite supplies no substitute addresses or manifest.
