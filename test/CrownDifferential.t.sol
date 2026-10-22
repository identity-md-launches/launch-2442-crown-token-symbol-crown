// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CrownFixture} from "./helpers/CrownFixture.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev The oracle is an equally seeded, unhooked pool in the real v4 PoolManager.
/// It detects a preview leaking price changes, LP fees, or token deltas into the real swap.
contract CrownDifferentialTest is CrownFixture {
    using StateLibrary for IPoolManager;

    PoolKey private referenceKey;

    function setUp() public override {
        super.setUp();
        referenceKey = PoolKey(key.currency0, key.currency1, key.fee, key.tickSpacing, IHooks(address(0)));
        manager.initialize(referenceKey, Q96);
        router.modify(referenceKey, ModifyLiquidityParams(-60_000, 60_000, 10_000 ether, bytes32(0)));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_allModesMatchUnhookedPool(uint96 amountSeed, uint8 mode) public {
        uint256 amount = bound(uint256(amountSeed), 1, 50 ether);
        _compare(amount, mode % 4, 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_priceLimitedTradesMatchUnhookedPool(uint96 amountSeed, uint16 tickSeed, uint8 mode) public {
        uint256 amount = bound(uint256(amountSeed), 1 ether, 100 ether);
        int24 distance = int24(int256(bound(uint256(tickSeed), 1, 60)));
        bool buy = mode % 4 < 2;
        _compare(amount, mode % 4, TickMath.getSqrtPriceAtTick(buy ? -distance : distance));
    }

    function test_roundingEdgesInEveryMode() public {
        uint256[12] memory amounts = [uint256(1), 2, 48, 49, 50, 51, 97, 98, 99, 100, 101, 102];
        for (uint8 mode; mode < 4; ++mode) {
            for (uint256 i; i < amounts.length; ++i) {
                _compare(amounts[i], mode, 0);
            }
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_alternatingModesDoNotAccumulatePreviewFees(uint96[8] memory amounts, uint16 modes) public {
        for (uint256 i; i < amounts.length; ++i) {
            _compare(bound(uint256(amounts[i]), 1, 5 ether), uint8((modes >> (2 * i)) & 3), 0);
        }
        // LPs must also be able to collect exactly the same fees and unwind both positions.
        BalanceDelta hooked = router.modify(key, ModifyLiquidityParams(-60_000, 60_000, 0, bytes32(0)));
        BalanceDelta plain = router.modify(referenceKey, ModifyLiquidityParams(-60_000, 60_000, 0, bytes32(0)));
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(plain), "preview accrued extra LP fees");
        hooked = router.modify(key, ModifyLiquidityParams(-60_000, 60_000, -10_000 ether, bytes32(0)));
        plain = router.modify(referenceKey, ModifyLiquidityParams(-60_000, 60_000, -10_000 ether, bytes32(0)));
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(plain), "preview changed LP principal");
        _assertSettled();
    }

    function _compare(uint256 amount, uint8 mode, uint160 limit) private {
        bool buy = mode < 2;
        bool exactInput = mode % 2 == 0;
        SwapParams memory params = _params(buy, exactInput ? -int256(amount) : int256(amount));
        if (limit != 0) params.sqrtPriceLimitX96 = limit;

        // Specify the equivalent AMM trade without a hook. The reference pool supplies all
        // price, rounding, token-output, partial-fill, and LP-fee calculations independently.
        SwapParams memory plainParams = SwapParams(params.zeroForOne, params.amountSpecified, params.sqrtPriceLimitX96);
        if (buy && exactInput) plainParams.amountSpecified = -int256(amount - amount / 50);
        if (!buy && !exactInput) plainParams.amountSpecified = int256(amount + amount / 49);
        uint256 budget = exactInput ? amount : 1_000 ether;
        vm.prank(bob, bob);
        BalanceDelta plain = router.swap{value: buy ? budget : 0}(referenceKey, plainParams, budget, 0, "");

        uint256 beforeETH = alice.balance;
        uint256 beforeTokens = token.balanceOf(alice);
        uint256 beforePot = _pot(START_DAY);
        (BalanceDelta actual, BalanceDelta raw) = _tradeLimit(alice, params);

        assertEq(BalanceDelta.unwrap(raw), BalanceDelta.unwrap(plain), "AMM execution differs from reference");
        assertEq(actual.amount1(), plain.amount1(), "hook changed CROWN side");
        uint256 fee = uint256(int256(plain.amount0()) - int256(actual.amount0()));
        if (buy) {
            uint256 paid = beforeETH - alice.balance;
            assertEq(paid, uint256(-int256(plain.amount0())) + fee, "ETH debit not conserved");
            assertEq(fee, paid / 50, "buy fee must be 2% of settled gross debit");
            assertEq(token.balanceOf(alice) - beforeTokens, uint256(int256(plain.amount1())));
        } else {
            uint256 gross = uint256(int256(plain.amount0()));
            assertEq(alice.balance - beforeETH + fee, gross, "ETH output not conserved");
            assertEq(fee, gross / 50, "sell fee must be 2% of settled gross output");
            assertEq(beforeTokens - token.balanceOf(alice), uint256(-int256(plain.amount1())));
        }
        assertEq(_pot(START_DAY), beforePot + fee, "fee not credited exactly once");
        _assertSamePoolState();
    }

    function _assertSamePoolState() private view {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint160 refPrice, int24 refTick, uint24 refProtocolFee, uint24 refLpFee) =
            manager.getSlot0(referenceKey.toId());
        assertEq(price, refPrice, "preview changed price");
        assertEq(tick, refTick, "preview changed tick");
        assertEq(protocolFee, refProtocolFee);
        assertEq(lpFee, refLpFee);
        assertEq(manager.getLiquidity(key.toId()), manager.getLiquidity(referenceKey.toId()));
        (uint256 fee0, uint256 fee1) = manager.getFeeGrowthGlobals(key.toId());
        (uint256 refFee0, uint256 refFee1) = manager.getFeeGrowthGlobals(referenceKey.toId());
        assertEq(fee0, refFee0, "preview accrued ETH LP fees");
        assertEq(fee1, refFee1, "preview accrued CROWN LP fees");
    }
}
