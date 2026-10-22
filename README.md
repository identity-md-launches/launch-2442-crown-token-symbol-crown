# Crown (CROWN)

Crown is a fixed-supply ERC-20 and an immutable Uniswap v4 hook for one native-ETH/CROWN pool. The largest **single** buy in each UTC day wins that day's entire hook-fee pot. Sells fund the pot but cannot win. No owner, administrator, setter, pause, upgrade, oracle, or external service controls the game.

## Build and test

Run from the repository root:

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, Cancun, optimizer 200 runs, and `bytecode_hash = "none"`. All Solidity dependencies, including test dependencies, are ordinary vendored files under `lib/`; compilation and tests need no network, environment variables, RPC, FFI, or filesystem permissions. The compiler and Foundry executable are supplied by the build environment. Dependency revisions, archive hashes, and licenses are recorded in [DEPENDENCIES.json](DEPENDENCIES.json) and [DEPENDENCIES.md](DEPENDENCIES.md).

The requested fuzz seed is pinned to `0x574600b9561d17518560f973639eaf89d30efe2587a83d0ad0bf3ba9dad5905f`. The suite includes 512 runs per parameterized fuzz test and 128 stateful invariant runs of 64 calls each. Tests deploy the real vendored Uniswap `PoolManager`, exercise ordinary router settlement, and compare the game to a separate ledger based on actual ETH balance changes.

## Contracts and deployment parameters

| Contract | Constructor | Purpose |
| --- | --- | --- |
| `Crown` | No arguments | ERC-20 named `Crown`, symbol `CROWN`, 18 decimals. Mints exactly `1_000_000_000 ether` (10^27 minor units) to its deployer once. No subsequent mint or transfer tax. |
| `CrownHook` | `(IPoolManager poolManager_, address token_)` | Both addresses are immutable. The launch supplies its PoolManager as `$poolManager` and the freshly deployed Crown as `$token`. Neither constructor queries external contracts. |

There is no owner parameter or fee-recipient parameter. The token's constructor mint is the only mint. The launch factory receives and distributes the initial supply according to the launch policy: 85% pool, 10% distributor, and 5% requester. The hook receives no allocation and has no ability to distribute or mint CROWN.

The pool key is fixed to native ETH as `currency0`, the constructor's CROWN as `currency1`, LP fee **12,500 pips (1.25%)**, tick spacing **60**, and this hook. Zero currency address means native ETH in v4; WETH is not this pair. Other tokens, fee tiers, tick spacings, and hooks are rejected. Only this pool participates in the game; ordinary transfers and other pools do not pay its hook fee.

Deployment target is Ethereum mainnet (chain ID 1). The actual PoolManager is supplied by the launch, never hardcoded. The deployer must verify it is the intended canonical manager on that chain and that `token_` is the deployed Crown. Contracts deliberately make no constructor code-existence or chain-ID calls, so deterministic deployment can be rehearsed on an empty chain.

### Address mining and initialization

The hook's low 14 address bits must equal **`0x20cc` (8396)**. Its constructor validates those bits against `getHookPermissions()`.

| Enabled permission | Reason |
| --- | --- |
| `beforeInitialize` | Restrict the hook to its exact pool key and require deployed callback code during initialization. |
| `beforeSwap` / `beforeSwapReturnDelta` | Charge a settled ETH fee when ETH is the specified currency. |
| `afterSwap` / `afterSwapReturnDelta` | Observe actual pool deltas, collect the fee, and update the pot/king; charge ETH when it is the unspecified currency. |

Every enabled callback and `unlockCallback` authenticates the immutable PoolManager. All other hook flags are false. Liquidity changes, fee collection through a zero liquidity change, and donations have no game tax or restriction.

Use [script/MineSalt.s.sol](script/MineSalt.s.sol)'s `run(factory, manager, token, start, count)` to search CREATE2 salts **after** the actual constructor addresses and factory address are known. This is a pure, offline computation; it never broadcasts. A search count of 200,000 normally suffices; if it returns `SaltNotFound`, continue with the next range. The factory must CREATE2-deploy the exact compiled creation bytecode concatenated with `abi.encode(manager, token)` using that salt. Compiler settings and constructor addresses affect the result. A test mines a salt and deploys the real bytecode at the predicted address.

The authorized launch process must deploy the token, deploy the hook, and initialize its pool atomically. Initialization is permissionless for the correct key once the hook exists, so atomic initialization prevents a third party choosing the opening price between deployment and initialization. The hook accepts the factory's initialization without assuming its address or granting it a role. The launch policy derives the opening sqrt price from its 10 ETH initial market capitalization and actual supply; the hook imposes no alternative initial price. Test fixtures use 1:1 solely for transparent accounting tests.

This repository contains no launch manifest, signed transaction, funded wallet, or broadcast script. The separate manifest/deployment stage supplies deployment addresses and factory allocations.

## Exact fee definition and rounding

The **hook fee is 2% of the actual gross ETH side**, rounded down to whole wei. It is additional to the pool's fixed LP fee. All hook fees enter that UTC day's pot; no portion is paid to a team, owner, liquidity provider, or caller of a maintenance function by the hook.

For a buy, let `G` be the trader's final ETH debit, `P` the ETH actually paid into the AMM including its LP fee, and `F` the hook fee:

```text
F = floor(G / 50)
P = G - F
biggestBuy candidate = P
```

For a sell, let `E` be the AMM's settled ETH output before the hook fee:

```text
F = floor(E / 50)
trader receives E - F
```

Thus a fully filled 1 ETH exact-input buy pays 0.02 ETH to the pot and 0.98 ETH into the pool. An exact-output sell requesting 1 ETH requests enough gross AMM output to deliver exactly 1 ETH after the hook fee. No CROWN is taken as a fee.

| Mode | AMM request and fee handling |
| --- | --- |
| Buy, exact input | Preview with net budget `G - floor(G/50)`. If fully filled, reserve `floor(G/50)`; if partially filled with pool payment `P`, use `floor(P/49)`. Return only that actual ETH fee before the real swap. |
| Buy, exact output | AMM produces the requested CROWN. From actual pool ETH input `P`, charge `floor(P/49)` ETH in `afterSwap`. |
| Sell, exact input | AMM consumes CROWN; charge `floor(E/50)` from actual ETH output in `afterSwap`. |
| Sell, exact output | Preview gross ETH output `N + floor(N/49)` for requested net output `N`. Charge `floor(E/50)` on actual previewed ETH output before the real swap. |

Gross-up has a possible one-wei ambiguity when integer rounding produces the same net value for two adjacent gross values. `floor(P/49)` selects the larger consistent gross value for exact-output buys and partial buys. Fully filled exact-input buys preserve their exact supplied budget. In every case `F = floor(G/50)` for buys and `F = floor(E/50)` for sells. Sub-50-wei gross sides may have zero fee. Any buy with positive settled ETH input can become king, even if token-output rounding leaves zero CROWN. A swap with no settled ETH input cannot become king.

All price limits are passed through unchanged. Unused inputs are not charged. Exact-output swaps can still partially fill at a price limit, as in v4; routers must enforce output minima or full-fill requirements. The router's final returned deltas include the hook fee, so its usual maximum-input/minimum-output checks apply. Failed settlement or slippage checks roll back the pool, pot, fee, and crown atomically.

### Why there is a reverting preview

v4's `afterSwap` return delta can adjust only the **unspecified** currency. Charging specified ETH solely there would tax CROWN in two of the four modes. Charging a percentage of the requested amount solely in `beforeSwap` would overcharge partial fills.

For the two ETH-specified modes, `beforeSwap` invokes an external self-call to `quoteSwap`, which calls the same PoolManager/pool at the adjusted amount and original price limit, then **always reverts** with the resulting delta. v4 skips the hook's own callbacks when the hook is the swap caller. The revert rolls back all simulated pool state, balances, protocol fees, and logs. Only the hook itself can enter this preview. It is not an executable fee-free swap entry point.

The real outer AMM swap then executes with the settled fee as its before-swap delta. `afterSwap` checks its actual ETH amount against the preview and clears the transient preview slots. The hook never cancels an entire swap to claim the user's input, never changes the LP fee, and never changes the price limit. This costs an additional simulation in the two ETH-specified modes, particularly when crossing many ticks. [SECURITY.md](SECURITY.md) records the delta and rounding review.

## UTC days, winners, claims, and rollover

`day = block.timestamp / 86400`. Each successful swap adds its fee to its execution day's pot. No daily keeper, settlement transaction, iteration over previous days, or off-chain service is necessary to start a new day.

- The king is the `tx.origin` of the largest single buy, ranked by `P`, excluding the hook fee. A strictly larger `P` replaces the king; ties retain the earlier buyer. Multiple smaller buys do not accumulate into a larger entry. Sells cannot replace a king.
- A buy in the last second of a UTC day can win the entire pot, including fees from earlier sells and buys. Transaction ordering and block timestamps determine the winner; this is not a random lottery or an MEV-resistant competition.
- For day `d`, claims are allowed from `(d + 1) * 86400` inclusive until `(d + 8) * 86400` exclusive. The seven-day deadline is measured from midnight ending the day, not from the winning buy.
- Only `msg.sender == king` may call `claim(d)`. Authorization never uses `tx.origin`. The whole pot is sent to the king with `call`, after zeroing the pot and marking the day finalized. Failed transfers revert all changes, including any attempted redemption, leaving the pot claimable during its window.
- At `(d + 8) * 86400`, claiming expires and anyone can call `rollover(d)`. It moves the entire unclaimed pot into the execution day's pot without moving ETH out of the hook or changing the current king. Repeated rollovers and claims of a finalized day revert.
- **Kingless-day interpretation:** a day with no positive ETH buys can roll immediately after its UTC day ends, since there is nobody to wait seven days for. A sell-only pot can roll through successive kingless days until a day has a winner. Empty ended days can also be finalized.

`tx.origin` is deliberately the identity rule even through routers or wallet apps. A transaction sent through an account-abstraction bundler or relayer crowns the outer transaction's origin, which may be the bundler/relayer EOA rather than the smart wallet. Buyers must understand which address is sending their transaction. Claim transactions must come directly from that crowned address (including its own delegated account code); a forwarding contract does not inherit its claim rights.

### Read API

| Function | Result |
| --- | --- |
| `currentDay()` | UTC day number. |
| `dayInfo(day)` | `(king, biggestBuy, pot, claimed)`; `biggestBuy` and `pot` are ETH wei. |
| `claimable(day)` | Whole pot during an ended day's active claim window with a king; otherwise zero. Independent of caller. |
| `pendingFees()` | Hook-owned native ETH credits awaiting redemption from PoolManager. |
| `totalFeesCollected()` / `totalPaid()` | Lifetime collected fees and successful ETH claim payouts. Rollovers do not increment either. |

`claimed` means **finalized**, whether by payout or rollover. In both cases `pot` becomes zero; historical king and biggest buy remain readable. `claimable` reports the entitlement, including backed pending credits that `claim` can redeem.

## ETH custody and operations after launch

When PoolManager already has enough native ETH, the hook takes the fee directly into its own balance during the swap. On a fresh token-only pool, the router has not yet settled its ETH input at callback time. Instead of reverting that valid trade, the hook mints an equal native-currency **ERC-6909 claim on PoolManager** to itself. This is an ETH-denominated credit, not CROWN, WETH, a separate vault, or a fee recipient. The fee belongs to the original swap day's pot immediately. The router must still settle every delta before the manager can lock.

Pending credits can be redeemed in three ways:

1. A later swap's `beforeSwap` redeems the available pending ETH automatically.
2. Anyone calls `redeemFees()` after settlement. It unlocks the manager if needed, burns the hook's credits, and takes ETH **only to the hook**. It returns the amount redeemed and pays no reward. It also works inside an already open manager unlock.
3. `claim(day)` redeems pending credits when its cash balance is insufficient to pay that pot.

The brief's immediate-ETH preference is therefore met whenever the manager is funded; the documented fresh-manager exception holds native ETH credits until settlement makes redemption possible. A launch integration can call `redeemFees()` immediately after its router unlock returns, in the same transaction, to materialize the fee as native ETH. No special router is required for trading or winning, and later claims perform this redemption automatically when necessary.

The hook's only ETH payout is `claim`. Rollover only changes accounting. Claim receivers that reject ETH block their own payout, not trading; their day can expire and roll over. Direct ETH donations are rejected except for PoolManager transfers. Forced ETH or unsolicited token/claim transfers are not added to pots, cannot increase prizes, and have no rescue/withdrawal path.

After launch there are **no settings to configure**. Winners are responsible for claiming within seven days. Anyone may finalize eligible rollovers and redeem pending fees; neither role is privileged or receives compensation. Frontends should show the UTC deadline, current largest net buy, applicable slippage limits, and transaction-origin identity. Deployment review, correct pool initialization/liquidity seeding, published source verification, and monitoring belong to the launch operator. An independent adversarial review and mainnet rehearsal remain release responsibilities; this local suite is not an external audit or a mainnet-fork result.
