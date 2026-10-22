// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CrownFixture} from "./helpers/CrownFixture.sol";
import {FlashAccountingRouter} from "./helpers/FlashAccountingRouter.sol";
import {CrownRejectingRecipient, CrownReinvestingRecipient} from "./helpers/PayoutReceivers.sol";
import {CrownHook} from "../src/CrownHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @dev Attempts real swaps without paying the manager. Taking its ETH first forces
/// the hook to mint fee credits, whose rollback must also be atomic with settlement.
contract CrownUnsettledSwap is IUnlockCallback {
    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function attempt(PoolKey memory key, SwapParams memory params) external {
        manager.unlock(abi.encode(key, params));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, SwapParams memory params) = abi.decode(data, (PoolKey, SwapParams));
        manager.take(key.currency0, address(this), address(manager).balance);
        manager.swap(key, params, "");
        return "";
    }

    receive() external payable {}
}

contract CrownAdversarialTest is CrownFixture {
    using StateLibrary for IPoolManager;

    FlashAccountingRouter private flashRouter;

    function setUp() public override {
        super.setUp();
        flashRouter = new FlashAccountingRouter(manager);
        vm.prank(alice);
        token.approve(address(flashRouter), type(uint256).max);
        vm.prank(bob);
        token.approve(address(flashRouter), type(uint256).max);
        vm.prank(carol);
        token.approve(address(flashRouter), type(uint256).max);
    }

    function test_largerGrossBuyCanTieAfterFeeRounding() public {
        assertEq(_buy(alice, 49), 49);
        assertEq(_buy(bob, 50), 49);
        (address king, uint256 biggest, uint256 pot,) = hook.dayInfo(START_DAY);
        assertEq(king, alice, "a larger gross debit must not break a net tie");
        assertEq(biggest, 49);
        assertEq(pot, 1);
        assertEq(_buy(carol, 51), 50);
        (king, biggest, pot,) = hook.dayInfo(START_DAY);
        assertEq(king, carol, "one more settled wei must win");
        assertEq(biggest, 50);
        assertEq(pot, 2);
    }

    function test_largeUnfilledBudgetCannotTakeCrown() public {
        uint256 first = _buy(alice, 1 ether);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        uint256 beforeETH = bob.balance;
        (BalanceDelta delta, BalanceDelta raw) = _tradeLimit(bob, SwapParams(true, -100 ether, price - 1));
        uint256 actualPoolInput = uint256(-int256(raw.amount0()));
        assertLt(actualPoolInput, first);
        assertEq(beforeETH - bob.balance, uint256(-int256(delta.amount0())), "unused budget not refunded");
        (address king, uint256 biggest,,) = hook.dayInfo(START_DAY);
        assertEq(king, alice);
        assertEq(biggest, first);
    }

    function test_allFourEmptyPoolSwapsLeaveNoPotOrKing() public {
        router.modify(key, ModifyLiquidityParams(-60_000, 60_000, -10_000 ether, bytes32(0)));
        for (uint8 mode; mode < 4; ++mode) {
            uint256 snapshot = vm.snapshotState();
            (BalanceDelta delta,) = _trade(alice, mode < 2, mode % 2 == 0 ? -int256(1 ether) : int256(1 ether));
            assertEq(BalanceDelta.unwrap(delta), 0, "empty pool must not consume the budget");
            (address king, uint256 biggest, uint256 pot, bool finalized) = hook.dayInfo(START_DAY);
            assertEq(king, address(0));
            assertEq(biggest, 0);
            assertEq(pot, 0);
            assertFalse(finalized);
            assertEq(hook.totalFeesCollected(), 0);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_unpaidSwapsCannotCreateCrownPotOrFeeCreditsInAnyMode() public {
        CrownUnsettledSwap unpaid = new CrownUnsettledSwap(manager);
        uint256 managerBefore = address(manager).balance;
        uint256 tokensBefore = token.balanceOf(address(manager));
        for (uint8 mode; mode < 4; ++mode) {
            SwapParams memory params = _params(mode < 2, mode % 2 == 0 ? -int256(1 ether) : int256(1 ether));
            vm.prank(bob, bob);
            vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
            unpaid.attempt(key, params);
            (address king, uint256 biggest, uint256 pot, bool finalized) = hook.dayInfo(START_DAY);
            assertEq(king, address(0), "unpaid buyer stole the crown");
            assertEq(biggest, 0);
            assertEq(pot, 0);
            assertFalse(finalized);
            assertEq(hook.pendingFees(), 0, "unpaid fee credits survived");
            assertEq(hook.totalFeesCollected(), 0);
            assertEq(address(manager).balance, managerBefore);
            assertEq(token.balanceOf(address(manager)), tokensBefore);
            assertEq(address(unpaid).balance, 0, "unpaid flash loan survived");
            (uint160 price,,,) = manager.getSlot0(key.toId());
            assertEq(price, Q96, "unpaid swap changed price");
            _assertSettled();
        }
        _buy(alice, 1 ether);
        (address paidKing,, uint256 paidPot,) = hook.dayInfo(START_DAY);
        assertEq(paidKing, alice);
        assertEq(paidPot, 0.02 ether, "failed operations poisoned subsequent accounting");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_allModesWithTemporarilyEmptyManager(uint96 sizeSeed, uint8 mode) public {
        uint256 size = bound(uint256(sizeSeed), 1, 10 ether);
        bool buy = mode % 4 < 2;
        bool exactInput = mode % 2 == 0;
        uint256 budget = exactInput ? size : 100 ether;
        uint256 beforeETH = alice.balance;
        uint256 managerBefore = address(manager).balance;
        uint256 beforeTokens = token.balanceOf(alice);
        BalanceDelta delta = _flash(alice, buy, exactInput ? -int256(size) : int256(size), budget);
        uint256 fee = hook.pendingFees();
        if (buy) {
            uint256 spent = beforeETH - alice.balance;
            assertEq(fee, spent / 50);
            assertEq(address(manager).balance - managerBefore, spent, "flash loan not repaid");
            assertEq(token.balanceOf(alice) - beforeTokens, uint256(int256(delta.amount1())));
            (address king, uint256 biggest,,) = hook.dayInfo(START_DAY);
            assertEq(king, alice);
            assertEq(biggest, spent - fee);
        } else {
            uint256 received = alice.balance - beforeETH;
            assertEq(fee, (received + fee) / 50);
            assertEq(managerBefore - address(manager).balance, received, "flash loan not repaid");
            assertEq(beforeTokens - token.balanceOf(alice), uint256(-int256(delta.amount1())));
            (address king, uint256 biggest,,) = hook.dayInfo(START_DAY);
            assertEq(king, address(0));
            assertEq(biggest, 0);
        }
        if (exactInput) assertEq(buy ? -int256(delta.amount0()) : -int256(delta.amount1()), int256(size));
        else assertEq(buy ? int256(delta.amount1()) : int256(delta.amount0()), int256(size));
        assertEq(address(hook).balance, 0);
        assertEq(_pot(START_DAY), fee);
        assertEq(address(flashRouter).balance, 0);
        assertEq(token.balanceOf(address(flashRouter)), 0);
        _assertSettled();
        assertEq(hook.redeemFees(), fee);
        assertEq(address(hook).balance, fee);
        assertEq(hook.pendingFees(), 0);
        _assertSettled();
    }

    function test_pendingFeesFromSeveralDaysRolloverAndPayExactlyOnce() public {
        _flash(alice, true, -1 ether, 1 ether);
        vm.warp((START_DAY + 1) * 1 days);
        _flash(bob, true, -2 ether, 2 ether);
        vm.warp((START_DAY + 8) * 1 days);
        _flash(carol, true, -3 ether, 3 ether);
        assertEq(hook.pendingFees(), 0.12 ether);
        assertEq(address(hook).balance, 0);
        hook.rollover(START_DAY);
        assertEq(hook.pendingFees(), 0.12 ether, "rollover must not spend credits");
        assertEq(_pot(START_DAY + 8), 0.08 ether);
        uint256 beforeETH = bob.balance;
        vm.prank(bob);
        hook.claim(START_DAY + 1);
        assertEq(bob.balance - beforeETH, 0.04 ether);
        assertEq(address(hook).balance, 0.08 ether);
        assertEq(hook.pendingFees(), 0);
        vm.warp((START_DAY + 9) * 1 days);
        beforeETH = carol.balance;
        vm.prank(carol);
        hook.claim(START_DAY + 8);
        assertEq(carol.balance - beforeETH, 0.08 ether);
        assertEq(hook.totalPaid(), 0.12 ether);
        assertEq(hook.totalPaid(), hook.totalFeesCollected());
        _assertSettled();
    }

    function test_rejectedClaimCanExpireAndRolloverWithoutLosingItsCredits() public {
        _flash(alice, true, -1 ether, 1 ether);
        vm.warp((START_DAY + 1) * 1 days);
        CrownRejectingRecipient rejector = new CrownRejectingRecipient();
        vm.etch(alice, address(rejector).code);
        vm.prank(alice);
        vm.expectRevert(CrownHook.ETHTransferFailed.selector);
        hook.claim(START_DAY);
        assertEq(hook.pendingFees(), 0.02 ether);
        assertEq(hook.totalPaid(), 0);
        assertEq(hook.claimable(START_DAY), 0.02 ether);
        vm.warp((START_DAY + 8) * 1 days);
        hook.rollover(START_DAY);
        _flash(bob, true, -1 ether, 1 ether);
        assertEq(hook.pendingFees(), 0.04 ether);
        vm.warp((START_DAY + 9) * 1 days);
        uint256 beforeETH = bob.balance;
        vm.prank(bob);
        hook.claim(START_DAY + 8);
        assertEq(bob.balance - beforeETH, 0.04 ether);
        vm.prank(alice);
        vm.expectRevert(CrownHook.AlreadyFinalized.selector);
        hook.claim(START_DAY);
        _assertSettled();
    }

    function test_claimCallbackCanBuyWithoutReopeningPreviousDay() public {
        _buy(alice, 1 ether);
        CrownReinvestingRecipient receiver = new CrownReinvestingRecipient(hook, router, address(token), START_DAY);
        vm.etch(alice, address(receiver).code);
        vm.warp((START_DAY + 1) * 1 days);
        uint256 beforeETH = alice.balance;
        uint256 beforeTokens = token.balanceOf(alice);
        vm.prank(alice, alice);
        hook.claim(START_DAY);
        assertTrue(CrownReinvestingRecipient(payable(alice)).observedFinalization());
        assertEq(CrownReinvestingRecipient(payable(alice)).reinvested(), 0.01 ether);
        assertEq(alice.balance - beforeETH, 0.01 ether);
        assertGt(token.balanceOf(alice), beforeTokens);
        assertEq(hook.claimable(START_DAY), 0);
        assertEq(_pot(START_DAY), 0);
        (address king, uint256 biggest, uint256 pot, bool finalized) = hook.dayInfo(START_DAY + 1);
        assertEq(king, alice);
        assertEq(biggest, 0.0098 ether);
        assertEq(pot, 0.0002 ether);
        assertFalse(finalized);
        assertEq(hook.totalPaid(), 0.02 ether);
        assertEq(hook.totalFeesCollected(), 0.0202 ether);
        _assertSettled();
    }

    function _flash(address actor, bool buy, int256 amount, uint256 budget) private returns (BalanceDelta delta) {
        vm.prank(actor, actor);
        return flashRouter.swap{value: buy ? budget : 0}(key, _params(buy, amount), budget);
    }
}
