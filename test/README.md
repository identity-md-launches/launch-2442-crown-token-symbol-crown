# CROWN test coverage

All tests run offline against the vendored, real Uniswap v4 `PoolManager` and the
production `Crown`/`CrownHook`. The existing fixtures mine a valid CREATE2 hook
address. There is no RPC, fork, FFI, environment mutation, or newly installed dependency.

The original token, access, fee, game, and invariant tests are retained. This
addition concentrates on independent execution checks and adversarial sequences:

| Requirement / risk | Coverage |
| --- | --- |
| Crown / CROWN metadata and immutable supply | `Crown.t.sol`; aggregate supply conservation during random game actions in `CrownAdversarialInvariant.t.sol` |
| Buy/sell, exact input/output, settled ETH fee | Existing `CrownFees.t.sol`; `CrownDifferential.t.sol` compares all four modes to an identically seeded pool without a hook |
| Preview rollback, correct LP fees, price limits | Differential comparisons of deltas, price, tick, liquidity, fee growth, LP fee collection, and full position removal; mixed sequences and partial fills |
| Strictly larger single buy, tie, last-second king | Existing `CrownGame.t.sol`; added 49/50 wei gross-input tie and 51 wei successor, plus a large unfilled budget that cannot dethrone the king |
| Claim authorization, expiry, double claim, failed ETH call | Existing game tests; the adversarial handler executes invalid operations and checks exact errors and unchanged state |
| Rollover after seven days, sell-only day | Existing midnight/deadline tests; random rollover attempts and multi-day pots backed by unredeemed manager credits |
| Atomic failed settlement | All four unpaid swap modes revert in the real manager, restoring pool price, fee credits, pot, crown, and balances |
| Useful work during ETH payout | A delegated-account receiver buys with part of its reward; the old day is already finalized and the new fee belongs only to the new day |
| Deferred ETH fees | `FlashAccountingRouter` temporarily borrows all manager ETH within an unlock, swaps, and repays/settles before returning; tests exercise credit collection for all four modes without mocking balances |
| No overpayment or stranded liabilities | Independent accounting after each random action, and an `afterInvariant` sequence that rolls all remaining pots forward and actually pays them out |

## Independent accounting

The existing `GameHandler` now measures pool ETH as manager cash minus its native
currency credits owed to the hook. This makes its wallet-balance oracle valid for
both immediate fees and pending credits, including redemption during a later swap.
Expected pots and winners come from those measured flows, rather than hook events
or the hook's fee counters. The same ledger is reused by the new adversarial handler.

The additional campaign runs **256 sequences of 80 calls**, with three actors,
ordinary/flash swaps in all four modes, time advances, claims, rollovers, and public
redemption. Expected rejections are caught and asserted; an unexpected revert or
success fails the test. It checks:

- Collected fees equal payouts plus outstanding day pots.
- Outstanding fees are backed by hook ETH plus recorded native manager credits.
- Winners, net buy sizes, finalization flags, and `claimable` match the independent ledger.
- Redemptions pay no caller reward and cannot count the same fee twice.
- Failed payouts preserve entitlements, ETH, and credits.
- The full fixed CROWN supply remains with the tracked participants.
- Every surviving pot can ultimately be rolled forward and paid through a real claim.

A deterministic handler test also executes each failure/success branch, so the
campaign does not rely solely on random selection to reach failed payouts and
successful finalization. The new parameterized tests each request 1,000 runs with
inline Foundry settings; no configuration file is changed.

## Running

```sh
forge build
FOUNDRY_FUZZ_SEED=0x574600b9561d17518560f973639eaf89d30efe2587a83d0ad0bf3ba9dad5905f forge test
```

For a workspace allowing generated files only under `test/`, append
`--out test/scratch/out --cache-path test/scratch/cache` to either command.
Nothing under `test/scratch/` is required by the delivered tests.

The fee expectations use settled gross ETH: a buy pays the pot `floor(debit / 50)`
and ranks on the remaining pool payment; a sell contributes
`floor(pool ETH output / 50)`. A king's claim window is
`[(day + 1) * 86400, (day + 8) * 86400)`. Kingless days can roll after midnight.
The accounting campaigns generate no unsolicited donations; the existing forced-ETH
test separately checks that surplus ETH cannot inflate a prize.

These are local integration tests, not a mainnet-fork run. Live deployment,
factory/router wiring, and mainnet state have not been exercised here.
