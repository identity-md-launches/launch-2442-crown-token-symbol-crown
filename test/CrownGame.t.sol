// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CrownFixture} from "./helpers/CrownFixture.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {CrownHook} from "../src/CrownHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract WalletRelay {
    function buy(PoolRouter router, PoolKey memory key, SwapParams memory params) external payable {
        router.swap{value: msg.value}(key, params, msg.value, 0, abi.encode(address(this)));
    }

    function forwardClaim(CrownHook hook, uint256 day) external {
        hook.claim(day);
    }
}

contract RejectETH {
    receive() external payable {
        revert("rejected");
    }
}

/// @dev Models a code-bearing king (e.g. an EIP-7702 account) and adversarial payout callback.
contract ReenteringKing {
    CrownHook public immutable hook;
    uint256 public immutable day;
    bool public attempted;
    bool public reentered;

    constructor(CrownHook hook_, uint256 day_) {
        hook = hook_;
        day = day_;
    }

    function collect() external {
        hook.claim(day);
    }

    receive() external payable {
        attempted = true;
        (bool a,) = address(hook).call(abi.encodeCall(hook.claim, (day)));
        (bool b,) = address(hook).call(abi.encodeCall(hook.rollover, (day)));
        (bool c,) = address(hook).call(abi.encodeCall(hook.redeemFees, ()));
        reentered = a || b || c;
    }
}

contract CrownGameTest is CrownFixture {
    function test_strictlyLargerBuyWinsAndTieKeepsEarlierKing() public {
        uint256 first = _buy(alice, 1 ether);
        _buy(bob, 0.5 ether);
        _assertKing(START_DAY, alice, first);
        _buy(bob, 1 ether);
        _assertKing(START_DAY, alice, first);
        uint256 larger = _buy(carol, 1 ether + 100);
        _assertKing(START_DAY, carol, larger);
        assertGt(larger, first);
    }

    function test_buySizesAreNotAccumulatedPerBuyer() public {
        uint256 first = _buy(alice, 2 ether);
        _buy(bob, 1.5 ether);
        _buy(bob, 1.5 ether);
        _assertKing(START_DAY, alice, first);
    }

    function test_sellAddsPotWithoutChangingKing() public {
        uint256 first = _buy(alice, 1 ether);
        uint256 pot = _pot(START_DAY);
        _trade(bob, false, -10 ether);
        assertGt(_pot(START_DAY), pot);
        _assertKing(START_DAY, alice, first);
    }

    function test_kingCrownedInLastSecondReceivesWholeDayPot() public {
        _trade(alice, false, -5 ether);
        uint256 earlyPot = _pot(START_DAY);
        vm.warp((START_DAY + 1) * 1 days - 1);
        _buy(bob, 1 ether);
        assertEq(_pot(START_DAY), earlyPot + 0.02 ether);
        assertEq(hook.claimable(START_DAY), 0);
        vm.warp((START_DAY + 1) * 1 days);
        uint256 before = bob.balance;
        vm.prank(bob);
        hook.claim(START_DAY);
        assertEq(bob.balance - before, earlyPot + 0.02 ether);
    }

    function test_midnightStartsIndependentDay() public {
        vm.warp((START_DAY + 1) * 1 days - 1);
        uint256 oldSize = _buy(alice, 3 ether);
        vm.warp((START_DAY + 1) * 1 days);
        uint256 newSize = _buy(bob, 0.5 ether);
        assertEq(hook.currentDay(), START_DAY + 1);
        _assertKing(START_DAY, alice, oldSize);
        _assertKing(START_DAY + 1, bob, newSize);
        assertEq(_pot(START_DAY), 0.06 ether);
        assertEq(_pot(START_DAY + 1), 0.01 ether);
    }

    function test_routerAndWalletUseOriginAndIgnoreHookData() public {
        WalletRelay wallet = new WalletRelay();
        vm.prank(bob, bob);
        wallet.buy{value: 1 ether}(router, key, _params(true, -1 ether));
        _assertKing(START_DAY, bob, 0.98 ether);
        assertGt(token.balanceOf(address(wallet)), 0);
        vm.warp((START_DAY + 1) * 1 days);
        vm.prank(bob, bob);
        vm.expectRevert(CrownHook.NotKing.selector);
        wallet.forwardClaim(hook, START_DAY);
        vm.prank(bob);
        hook.claim(START_DAY);
    }

    function test_claimAndDoubleClaim() public {
        uint256 size = _buy(alice, 1 ether);
        _trade(bob, false, -1 ether);
        uint256 pot = _pot(START_DAY);
        vm.prank(alice);
        vm.expectRevert(CrownHook.DayNotEnded.selector);
        hook.claim(START_DAY);
        vm.warp((START_DAY + 1) * 1 days);
        assertEq(hook.claimable(START_DAY), pot);
        vm.prank(bob);
        vm.expectRevert(CrownHook.NotKing.selector);
        hook.claim(START_DAY);
        uint256 balance = alice.balance;
        vm.prank(alice);
        hook.claim(START_DAY);
        assertEq(alice.balance - balance, pot);
        assertEq(hook.claimable(START_DAY), 0);
        assertEq(_pot(START_DAY), 0);
        (address king, uint256 biggest,, bool claimed) = hook.dayInfo(START_DAY);
        assertEq(king, alice);
        assertEq(biggest, size);
        assertTrue(claimed);
        vm.prank(alice);
        vm.expectRevert(CrownHook.AlreadyFinalized.selector);
        hook.claim(START_DAY);
        vm.expectRevert(CrownHook.AlreadyFinalized.selector);
        hook.rollover(START_DAY);
        _assertSettled();
    }

    function test_claimAllowedUntilLastSecondOfSevenDayWindow() public {
        _buy(alice, 1 ether);
        vm.warp((START_DAY + 8) * 1 days - 1);
        assertEq(hook.claimable(START_DAY), 0.02 ether);
        vm.expectRevert(CrownHook.RolloverTooEarly.selector);
        hook.rollover(START_DAY);
        vm.prank(alice);
        hook.claim(START_DAY);
    }

    function test_rolloverAtSevenDaysAfterEndMovesWholePotExactlyOnce() public {
        _buy(alice, 1 ether);
        vm.warp((START_DAY + 8) * 1 days);
        assertEq(hook.claimable(START_DAY), 0);
        vm.prank(alice);
        vm.expectRevert(CrownHook.ClaimExpired.selector);
        hook.claim(START_DAY);
        uint256 newSize = _buy(bob, 2 ether);
        uint256 held = address(hook).balance;
        vm.prank(carol);
        hook.rollover(START_DAY);
        assertEq(address(hook).balance, held);
        assertEq(_pot(START_DAY), 0);
        assertEq(_pot(START_DAY + 8), 0.06 ether);
        _assertKing(START_DAY + 8, bob, newSize);
        (,,, bool finalized) = hook.dayInfo(START_DAY);
        assertTrue(finalized);
        vm.expectRevert(CrownHook.AlreadyFinalized.selector);
        hook.rollover(START_DAY);
        vm.warp((START_DAY + 9) * 1 days);
        uint256 before = bob.balance;
        vm.prank(bob);
        hook.claim(START_DAY + 8);
        assertEq(bob.balance - before, 0.06 ether);
        _assertSettled();
    }

    function test_sellOnlyDayRollsAfterMidnightWithoutSevenDayDelay() public {
        _trade(alice, false, -1 ether);
        uint256 pot = _pot(START_DAY);
        assertGt(pot, 0);
        _assertKing(START_DAY, address(0), 0);
        assertEq(hook.claimable(START_DAY), 0);
        vm.expectRevert(CrownHook.DayNotEnded.selector);
        hook.rollover(START_DAY);
        vm.warp((START_DAY + 1) * 1 days);
        assertEq(hook.claimable(START_DAY), 0);
        hook.rollover(START_DAY);
        assertEq(_pot(START_DAY + 1), pot);
        _assertKing(START_DAY + 1, address(0), 0);
        vm.warp((START_DAY + 2) * 1 days);
        hook.rollover(START_DAY + 1);
        assertEq(_pot(START_DAY + 2), pot);
        _buy(bob, 1 ether);
        vm.warp((START_DAY + 3) * 1 days);
        uint256 before = bob.balance;
        vm.prank(bob);
        hook.claim(START_DAY + 2);
        assertEq(bob.balance - before, pot + 0.02 ether);
        _assertSettled();
    }

    function test_rolloverBeforeKingDeadlineRefused() public {
        _buy(alice, 1 ether);
        vm.warp((START_DAY + 1) * 1 days);
        vm.expectRevert(CrownHook.RolloverTooEarly.selector);
        hook.rollover(START_DAY);
    }

    function test_failedTransferLeavesClaimAvailableForRetry() public {
        _buy(alice, 1 ether);
        vm.warp((START_DAY + 1) * 1 days);
        RejectETH receiver = new RejectETH();
        // A delegated EOA can have receive code. Keep the same crowned address.
        vm.etch(alice, address(receiver).code);
        vm.prank(alice);
        vm.expectRevert(CrownHook.ETHTransferFailed.selector);
        hook.claim(START_DAY);
        assertEq(hook.claimable(START_DAY), 0.02 ether);
        (,,, bool claimed) = hook.dayInfo(START_DAY);
        assertFalse(claimed);
        assertEq(hook.totalPaid(), 0);
        assertEq(address(hook).balance, 0.02 ether);
        vm.etch(alice, "");
        vm.prank(alice);
        hook.claim(START_DAY);
        assertEq(hook.totalPaid(), 0.02 ether);
    }

    function test_rejectedClaimAlsoRollsBackRedemption() public {
        _newPool(true);
        _buy(alice, 1 ether);
        vm.warp((START_DAY + 1) * 1 days);
        RejectETH receiver = new RejectETH();
        vm.etch(alice, address(receiver).code);
        vm.prank(alice);
        vm.expectRevert(CrownHook.ETHTransferFailed.selector);
        hook.claim(START_DAY);
        assertEq(hook.pendingFees(), 0.02 ether);
        assertEq(address(hook).balance, 0);
        assertEq(hook.claimable(START_DAY), 0.02 ether);
        _assertSettled();
    }

    function test_claimCannotReenterClaimRolloverOrRedemption() public {
        ReenteringKing receiver = new ReenteringKing(hook, START_DAY);
        _fund(address(receiver));
        _buy(address(receiver), 1 ether);
        vm.warp((START_DAY + 1) * 1 days);
        uint256 before = address(receiver).balance;
        receiver.collect();
        assertTrue(receiver.attempted());
        assertFalse(receiver.reentered());
        assertEq(address(receiver).balance - before, 0.02 ether);
        assertEq(hook.totalPaid(), 0.02 ether);
        _assertSettled();
    }

    function test_emptyAndFutureDaysHaveNoEntitlement() public {
        assertEq(hook.claimable(0), 0);
        assertEq(hook.claimable(START_DAY), 0);
        assertEq(hook.claimable(type(uint256).max), 0);
        vm.expectRevert(CrownHook.DayNotEnded.selector);
        hook.claim(type(uint256).max);
        vm.expectRevert(CrownHook.DayNotEnded.selector);
        hook.rollover(type(uint256).max);
        vm.expectRevert(CrownHook.NotKing.selector);
        hook.claim(START_DAY - 1);
        hook.rollover(START_DAY - 1);
        assertEq(_pot(START_DAY), 0);
    }

    function test_forcedETHCannotInflatePotOrPayout() public {
        _buy(alice, 1 ether);
        // Force an unaccounted balance without any SELFDESTRUCT helper in delivered bytecode.
        vm.deal(address(hook), address(hook).balance + 1 ether);
        assertEq(_pot(START_DAY), 0.02 ether);
        vm.warp((START_DAY + 1) * 1 days);
        uint256 before = alice.balance;
        vm.prank(alice);
        hook.claim(START_DAY);
        assertEq(alice.balance - before, 0.02 ether);
        assertEq(address(hook).balance, 1 ether);
    }

    function testFuzz_multipleDaysNeverPayMoreThanCollected(uint96 a, uint96 b, uint96 c) public {
        uint256 x = bound(uint256(a), 1_000, 10 ether);
        uint256 y = bound(uint256(b), 1_000, 10 ether);
        uint256 z = bound(uint256(c), 1_000, 10 ether);
        _buy(alice, x);
        vm.warp((START_DAY + 1) * 1 days);
        _buy(bob, y);
        vm.prank(alice);
        hook.claim(START_DAY);
        vm.warp((START_DAY + 9) * 1 days);
        hook.rollover(START_DAY + 1);
        _buy(carol, z);
        assertEq(_pot(START_DAY + 9), y / 50 + z / 50);
        vm.warp((START_DAY + 10) * 1 days);
        vm.prank(carol);
        hook.claim(START_DAY + 9);
        assertEq(hook.totalFeesCollected(), x / 50 + y / 50 + z / 50);
        assertEq(hook.totalPaid(), hook.totalFeesCollected());
        assertEq(address(hook).balance, 0);
        _assertSettled();
    }

    function _assertKing(uint256 day, address expected, uint256 expectedSize) internal view {
        (address king, uint256 size,,) = hook.dayInfo(day);
        assertEq(king, expected);
        assertEq(size, expectedSize);
    }
}
