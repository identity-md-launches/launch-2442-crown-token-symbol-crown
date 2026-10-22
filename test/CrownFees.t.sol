// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CrownFixture} from "./helpers/CrownFixture.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {CrownHook} from "../src/CrownHook.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";

contract RedeemWithinUnlock is IUnlockCallback {
    IPoolManager private immutable manager;
    CrownHook private immutable hook;

    constructor(IPoolManager manager_, CrownHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function redeem() external returns (uint256) {
        return abi.decode(manager.unlock(""), (uint256));
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        return abi.encode(hook.redeemFees());
    }
}

contract CrownFeesTest is CrownFixture {
    using StateLibrary for IPoolManager;

    function test_buyExactInput() public {
        (BalanceDelta delta, BalanceDelta raw) = _trade(alice, true, -1 ether);
        assertEq(delta.amount0(), -1 ether);
        assertEq(raw.amount0(), -0.98 ether);
        _assertFee(delta, raw, true, 0);
        (address king, uint256 biggest,,) = hook.dayInfo(START_DAY);
        assertEq(king, alice);
        assertEq(biggest, 0.98 ether);
    }

    function test_buyExactOutput() public {
        (BalanceDelta delta, BalanceDelta raw) = _trade(alice, true, 1 ether);
        assertEq(delta.amount1(), 1 ether);
        _assertFee(delta, raw, true, 0);
    }

    function test_sellExactInput() public {
        (BalanceDelta delta, BalanceDelta raw) = _trade(alice, false, -1 ether);
        assertEq(delta.amount1(), -1 ether);
        _assertFee(delta, raw, false, 0);
    }

    function test_sellExactOutput() public {
        (BalanceDelta delta, BalanceDelta raw) = _trade(alice, false, 1 ether);
        assertEq(delta.amount0(), 1 ether, "receive exactly the requested ETH AFTER tax");
        _assertFee(delta, raw, false, 0);
    }

    function test_partialBuyExactInputChargesSettledAmount() public {
        (BalanceDelta delta, BalanceDelta raw) =
            _tradeLimit(alice, SwapParams(true, -100 ether, TickMath.getSqrtPriceAtTick(-60)));
        assertLt(uint256(-int256(delta.amount0())), 100 ether);
        _assertFee(delta, raw, true, 0);
        (, uint256 biggest,,) = hook.dayInfo(START_DAY);
        assertEq(biggest, uint256(-int256(raw.amount0())));
    }

    function test_partialBuyExactOutput() public {
        (BalanceDelta delta, BalanceDelta raw) =
            _tradeLimit(alice, SwapParams(true, 100 ether, TickMath.getSqrtPriceAtTick(-60)));
        assertLt(uint256(int256(delta.amount1())), 100 ether);
        _assertFee(delta, raw, true, 0);
    }

    function test_partialSellExactInput() public {
        (BalanceDelta delta, BalanceDelta raw) =
            _tradeLimit(alice, SwapParams(false, -100 ether, TickMath.getSqrtPriceAtTick(60)));
        assertLt(uint256(-int256(delta.amount1())), 100 ether);
        _assertFee(delta, raw, false, 0);
    }

    function test_partialSellExactOutputChargesSettledAmount() public {
        (BalanceDelta delta, BalanceDelta raw) =
            _tradeLimit(alice, SwapParams(false, 100 ether, TickMath.getSqrtPriceAtTick(60)));
        assertLt(uint256(int256(delta.amount0())), 100 ether);
        _assertFee(delta, raw, false, 0);
    }

    function test_freshTokenOnlyManagerBuyExactInput() public {
        _freshBuy(false);
    }

    function test_freshTokenOnlyManagerBuyExactOutput() public {
        _freshBuy(true);
    }

    function test_nextSwapAutomaticallyRedeemsPendingFees() public {
        _newPool(true);
        _buy(alice, 1 ether);
        uint256 pending = hook.pendingFees();
        assertGt(pending, 0);
        _buy(bob, 1 ether);
        assertEq(hook.pendingFees(), 0);
        assertEq(address(hook).balance, 2 * pending);
    }

    function test_freshManagerSellExactInputAfterFirstBuy() public {
        _freshSell(false);
    }

    function test_freshManagerSellExactOutputAfterFirstBuy() public {
        _freshSell(true);
    }

    function test_allFourModesInOneUnlockClearTransientState() public {
        SwapParams[] memory params = new SwapParams[](4);
        params[0] = _params(true, -1 ether);
        params[1] = _params(true, 0.5 ether);
        params[2] = _params(false, 0.5 ether);
        params[3] = _params(false, -1 ether);
        vm.prank(alice, alice);
        BalanceDelta[] memory deltas = router.batch(key, params);
        assertEq(deltas[0].amount0(), -1 ether);
        assertEq(deltas[1].amount1(), 0.5 ether);
        assertEq(deltas[2].amount0(), 0.5 ether);
        assertEq(deltas[3].amount1(), -1 ether);
        _assertSettled();
        // A further specified-ETH swap in this same transaction must get a fresh preview.
        uint256 beforePot = _pot(START_DAY);
        (BalanceDelta delta, BalanceDelta raw) = _trade(bob, true, -2 ether);
        _assertFee(delta, raw, true, beforePot);
    }

    function test_dayClaimAutomaticallyRedeemsPendingFees() public {
        _newPool(true);
        _buy(alice, 1 ether);
        assertGt(hook.pendingFees(), 0);
        vm.warp((START_DAY + 1) * 1 days);
        uint256 balance = alice.balance;
        vm.prank(alice);
        hook.claim(START_DAY);
        assertEq(alice.balance - balance, 0.02 ether);
        assertEq(hook.pendingFees(), 0);
        _assertSettled();
    }

    function test_publicRedemptionWorksInsideExistingUnlockAndKeepsOriginalDay() public {
        _newPool(true);
        _buy(alice, 1 ether);
        vm.warp((START_DAY + 1) * 1 days);
        RedeemWithinUnlock redeemer = new RedeemWithinUnlock(manager, hook);
        assertEq(redeemer.redeem(), 0.02 ether);
        assertEq(_pot(START_DAY), 0.02 ether);
        assertEq(_pot(START_DAY + 1), 0);
        assertEq(hook.totalFeesCollected(), 0.02 ether);
        assertEq(hook.pendingFees(), 0);
        _assertSettled();
    }

    function test_oneWeiBuyCountsItsActualPoolPaymentWithoutChargingRoundedFee() public {
        (BalanceDelta delta, BalanceDelta raw) = _trade(alice, true, -1);
        assertEq(delta.amount0(), -1);
        assertEq(raw.amount0(), -1);
        assertEq(delta.amount1(), 0);
        (address king, uint256 biggest, uint256 pot,) = hook.dayInfo(START_DAY);
        assertEq(king, alice);
        assertEq(biggest, 1);
        assertEq(pot, 0);
    }

    function test_zeroLiquidityDoesNotCreateFeeOrKing() public {
        // Remove the only position, so all four swaps have no liquidity to trade against.
        router.modify(key, ModifyLiquidityParams(-60_000, 60_000, -10_000 ether, bytes32(0)));
        (BalanceDelta delta,) = _trade(alice, true, -1 ether);
        assertEq(BalanceDelta.unwrap(delta), 0);
        (address king, uint256 biggest, uint256 pot,) = hook.dayInfo(START_DAY);
        assertEq(king, address(0));
        assertEq(biggest, 0);
        assertEq(pot, 0);
    }

    function test_badPriceLimitRevertsWithoutFeeOrCrown() public {
        vm.prank(alice, alice);
        vm.expectRevert();
        router.swap{value: 1 ether}(key, SwapParams(true, -1 ether, Q96 + 1), 1 ether, 0, "");
        assertEq(_pot(START_DAY), 0);
        assertEq(hook.totalFeesCollected(), 0);
    }

    function test_routerSlippageFailureRollsBackAllGameAndPoolState() public {
        vm.prank(alice, alice);
        vm.expectRevert(PoolRouter.OutputTooSmall.selector);
        router.swap{value: 1 ether}(key, _params(true, -1 ether), 1 ether, 10 ether, "");
        assertEq(_pot(START_DAY), 0);
        (address king,,,) = hook.dayInfo(START_DAY);
        assertEq(king, address(0));
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, Q96);
        _assertSettled();
    }

    function test_liquidityFeeCollectIsUntaxedAndUnrestricted() public {
        _buy(alice, 1 ether);
        uint256 pot = _pot(START_DAY);
        BalanceDelta collected = router.modify(key, ModifyLiquidityParams(-60_000, 60_000, 0, bytes32(0)));
        assertGt(collected.amount0(), 0);
        assertGe(collected.amount1(), 0);
        assertEq(_pot(START_DAY), pot);
        router.modify(key, ModifyLiquidityParams(-60_000, 60_000, -10_000 ether, bytes32(0)));
        assertEq(_pot(START_DAY), pot);
    }

    function testFuzz_fourDirectionsRespectFeeAndBudget(uint96 amount, bool buy, bool exactInput) public {
        uint256 size = bound(uint256(amount), 100, 20 ether);
        int256 specified = exactInput ? -int256(size) : int256(size);
        (BalanceDelta delta, BalanceDelta raw) = _trade(alice, buy, specified);
        _assertFee(delta, raw, buy, 0);
        if (exactInput) assertEq(buy ? -int256(delta.amount0()) : -int256(delta.amount1()), int256(size));
        else assertEq(buy ? int256(delta.amount1()) : int256(delta.amount0()), int256(size));
    }

    function testFuzz_partialFillsRespectFee(uint96 amount, uint16 ticks, bool buy, bool exactInput) public {
        uint256 size = bound(uint256(amount), 1 ether, 100 ether);
        int24 limitTick = int24(int256(bound(uint256(ticks), 1, 60)));
        if (buy) limitTick = -limitTick;
        int256 specified = exactInput ? -int256(size) : int256(size);
        (BalanceDelta delta, BalanceDelta raw) =
            _tradeLimit(alice, SwapParams(buy, specified, TickMath.getSqrtPriceAtTick(limitTick)));
        _assertFee(delta, raw, buy, 0);
        if (exactInput) assertLe(buy ? -int256(delta.amount0()) : -int256(delta.amount1()), int256(size));
        else assertLe(buy ? int256(delta.amount1()) : int256(delta.amount0()), int256(size));
    }

    function testFuzz_buyRoundingAtSmallWeiAmounts(uint16 amount) public {
        uint256 size = bound(uint256(amount), 1, 1_000);
        (BalanceDelta delta, BalanceDelta raw) = _trade(alice, true, -int256(size));
        _assertFee(delta, raw, true, 0);
        assertEq(-int256(delta.amount0()), int256(size));
    }

    function testFuzz_sellExactOutputAtSmallWeiAmounts(uint16 amount) public {
        uint256 size = bound(uint256(amount), 1, 1_000);
        (BalanceDelta delta, BalanceDelta raw) = _trade(alice, false, int256(size));
        _assertFee(delta, raw, false, 0);
        assertEq(int256(delta.amount0()), int256(size));
    }

    function _assertFee(BalanceDelta delta, BalanceDelta raw, bool buy, uint256 beforePot) internal view {
        uint256 fee = uint256(int256(raw.amount0()) - int256(delta.amount0()));
        assertEq(delta.amount1(), raw.amount1(), "CROWN never taxed");
        assertEq(fee, buy ? uint256(-int256(delta.amount0())) / 50 : uint256(int256(raw.amount0())) / 50);
        assertEq(_pot(START_DAY) - beforePot, fee);
        assertEq(address(hook).balance + hook.pendingFees(), hook.totalFeesCollected());
        if (!buy && beforePot == 0) {
            (address king, uint256 biggest,,) = hook.dayInfo(START_DAY);
            assertEq(king, address(0));
            assertEq(biggest, 0);
        }
    }

    function _freshSell(bool exactOutput) internal {
        _newPool(true);
        _fund(bob);
        _buy(alice, 1 ether);
        assertGt(hook.pendingFees(), 0);
        uint256 beforePot = _pot(START_DAY);
        (BalanceDelta delta, BalanceDelta raw) =
            _trade(bob, false, exactOutput ? int256(0.1 ether) : -int256(0.1 ether));
        _assertFee(delta, raw, false, beforePot);
        if (exactOutput) assertEq(delta.amount0(), 0.1 ether);
        else assertEq(delta.amount1(), -0.1 ether);
        assertEq(hook.pendingFees(), 0);
        (address king,,,) = hook.dayInfo(START_DAY);
        assertEq(king, alice);
        _assertSettled();
    }

    function _freshBuy(bool exactOutput) internal {
        _newPool(true);
        assertEq(address(manager).balance, 0);
        (BalanceDelta delta, BalanceDelta raw) = _trade(alice, true, exactOutput ? int256(1 ether) : -int256(1 ether));
        _assertFee(delta, raw, true, 0);
        assertGt(hook.pendingFees(), 0);
        assertEq(address(hook).balance, 0);
        uint256 pending = hook.pendingFees();
        uint256 balance = carol.balance;
        vm.prank(carol);
        assertEq(hook.redeemFees(), pending);
        assertEq(carol.balance, balance, "redemption has no reward");
        assertEq(address(hook).balance, pending);
        assertEq(hook.pendingFees(), 0);
        assertEq(hook.redeemFees(), 0);
        _assertSettled();
    }
}
