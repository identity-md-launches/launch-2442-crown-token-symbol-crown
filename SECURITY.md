# Crown security and accounting review

This records the local implementation review against the supplied Ethereum and v4 security references. It is not an independent audit. No privileged key, oracle, configurable recipient, or proxy exists.

## Fee algebra and partial fills

Let `r = 2/100`, `G` be gross buy input, and `P` be the core swap's positive ETH input. The implementation's fee identity is `F = floor(G/50)` and `G = P + F`. Given `P`, choosing `F = floor(P/49)` satisfies this identity: write `P = 49q + s`, `0 <= s < 49`, then `G = 50q + s` and `floor(G/50) = q`.

For exact-input buys the initial preview budget is `B = G - floor(G/50)`. If it is fully used, the initial fee is exactly correct. If the price limit prevents full use (`P < B`), then `floor(P/49) <= floor(G/50)`; reducing the reservation leaves at least the original preview budget available. The actual swap therefore reaches the same price bound and spends the same `P`. Its fee is based solely on that settled `P`. `afterSwap` checks the actual amount against the quote and the fee identity against the final gross input.

For exact-output sells requesting net `N`, the preview requests `M = N + floor(N/49)`, which obeys `M - floor(M/50) = N`. If fully filled, the actual request `N + fee` equals `M`. If partially filled at `E < M`, `N + floor(E/50) >= E`, so the real swap still reaches the same price bound with the same settled ETH. The amount comparison rejects any unexpected disagreement.

For exact-output buys and exact-input sells, ETH is the unspecified currency. Its final core delta is already known in `afterSwap`, so a preview is unnecessary. The callback returns a positive ETH fee delta; the token delta is unmodified.

All requested values are bounded to signed int128 before negation or gross-up. Fee arithmetic is far below uint256 overflow for those bounds. Fees are checked when cast to int128. ETH deltas are widened to int256 before absolute-value conversion, avoiding the signed int128 minimum negation trap. Huge exact-output requests that cannot be represented by v4's core deltas revert atomically rather than truncate.

## PoolManager settlement

The real core swap creates a trader delta `D`. Its hook delta `H` is exactly `(F, 0)` in the native-ETH/CROWN currency order. v4 returns `D - H` to the router and credits `H` to the hook. The hook's `take` or native-claim `mint` creates its equal negative ETH delta, leaving its net transient balance zero. The router settles its own final returned delta. Every integration test checks no hook/token debt remains and that PoolManager is locked with zero nonzero deltas.

No-op protection: `beforeSwap` returns only a positive fee in the specified currency and zero in the unspecified currency. On buys this is strictly below a positive requested amount; on sells it adds to the required gross output. It never claims that the hook executed the full trade. The fee-free inner swap exists only inside `quoteSwap`, which authenticates self-calls and unconditionally reverts. It cannot retain pool state or value. The real price limit and fixed LP fee are preserved.

The before/after communication uses two dedicated transient slots. Both are cleared after a specified-ETH swap; an outer revert also rolls back transient writes. Tests mix all four modes inside one unlock and follow with another specified-ETH swap. Simulated swaps call no untrusted external recipient or token; the fixed PoolManager skips self-hook callbacks and does internal accounting only.

`redeemFees` burns only the hook's recorded native claims and takes ETH to itself. It checks whether PoolManager is already unlocked before opening an unlock. `unlockCallback` requires the configured manager. No caller-supplied recipient or amount influences redemption. Redemption never changes the day pot, original day attribution, or total fees.

## Game and payout invariants

Under ordinary transfers:

```text
sum(unfinalized day pots) = totalFeesCollected - totalPaid
hook native ETH + pending native claims = totalFeesCollected - totalPaid
totalPaid <= totalFeesCollected
```

Forced ETH only makes the custody balance larger; it does not change the recorded entitlement. Unsolicited ERC-6909 claims are likewise not counted as collected fees. Rollover conserves aggregate pot value and finalizes its source day before crediting the current day. It cannot roll the current/future day. Date comparisons use day differences after testing `day < currentDay`, avoiding caller-controlled deadline multiplication/overflow.

Claim authenticates `msg.sender`, checks the UTC window, marks finalized, zeroes the pot, and increments totalPaid before calling the king. OpenZeppelin's `ReentrancyGuard` also covers claim, rollover, and public redemption. Failed native transfers revert the entire operation. The recorded king and buy size survive payout and rollover as history. A reentrant receiver cannot claim twice, roll that pot, or recursively redeem; tests exercise all three calls.

Pool callbacks call only the immutable manager and the reverting quote self-call. The hook's ETH receiver authenticates the manager and makes no further calls. Fee and crown state changes and their events precede the fee transfer. The claim transfer forwards gas using `call`, with its success result checked. No swap pays ETH to its winner, so an unreceivable winner cannot halt swaps.

## Scope and assumptions

- The constructor PoolManager must be the legitimate v4 implementation. Its authenticated callbacks and accounting are trusted. No manager address is embedded in the source.
- Only the fixed native ETH / ordinary Crown ERC-20 key is accepted. Fee-on-transfer, rebasing, callback tokens, WETH pairing, and dynamic LP fees are outside this contract's supported pool.
- `tx.origin` is used exclusively for the explicitly requested winner identity, never authorization. Router-provided `sender` or `hookData` cannot forge a different king. A bundler may be the actual origin.
- No withdrawal, administrative role, ownership transfer, mint-after-construction, external library link, delegatecall, selfdestruct, or upgrade path exists. Runtime opcode checks mirror the supplied floor's reachable-code scan.
- There are no production loops over users, entries, elapsed days, or pending claims. Salt mining is an off-chain deployment computation; invariant test loops are test-only.
- Winners, arbitrageurs, flash-funded traders, and validators can compete on size and ordering. Recycling liquidity and last-block buying are game-economic risks; the contract neither uses randomness nor claims to prevent such behavior. Liquidity providers retain their normal removal rights.
- Atomic deployment and initialization are required to prevent a third party choosing the opening price after deployment. The initialization callback rejects foreign keys and prevents predeployment initialization with missing hook code.

## Validation and remaining release work

The delivered suite includes real-manager fee/rounding/partial-fill tests in all four directions, empty native reserves with ERC-6909 redemption, sequential swaps inside one unlock, quote and callback access failures, exact CREATE2 permissions, token supply/transfer failures, UTC boundary and tie cases, expired/repeated/unauthorized claims, sell-only rollovers, recipient failure/reentrancy, forced ETH, and a stateful independent accounting model. Tests do not read or set environment variables. The provided fuzz seed is pinned in Foundry configuration.

`forge build`, `forge test`, and formatting are the required local checks. Foundry's built-in lint reports conservative casts and reentrancy warnings around the standard guard and authenticated manager calls; the bounds and CEI/guard protections are described above. Slither and Mythril were not available and were not run. A mainnet fork test, formal verification, explorer verification, and independent adversarial audit were not performed here. Those remain launch/release responsibilities. This repository does not broadcast transactions.
