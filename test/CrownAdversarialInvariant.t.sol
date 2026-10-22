// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameHandler, CrownInvariantTest} from "./CrownInvariant.t.sol";
import {CrownFixture} from "./helpers/CrownFixture.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {FlashAccountingRouter} from "./helpers/FlashAccountingRouter.sol";
import {CrownRejectingRecipient} from "./helpers/PayoutReceivers.sol";
import {Crown} from "../src/Crown.sol";
import {CrownHook} from "../src/CrownHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Adds adversarial transitions to the existing independent wallet/manager ledger.
/// Invalid claims/rollovers are executed and checked, rather than discarded by preconditions.
contract AdversarialGameHandler is GameHandler {
    FlashAccountingRouter public immutable flashRouter;
    CrownRejectingRecipient private immutable rejector;
    uint256 public flashSwaps;
    uint256 public rejectedClaims;
    uint256 public rejectedRollovers;
    uint256 public failedPayouts;
    uint256 public redemptions;

    constructor(
        CrownHook hook_,
        Crown token_,
        IPoolManager manager_,
        PoolRouter router_,
        PoolKey memory key_,
        FlashAccountingRouter flashRouter_
    ) GameHandler(hook_, token_, manager_, router_, key_) {
        flashRouter = flashRouter_;
        rejector = new CrownRejectingRecipient();
        for (uint256 i; i < 3; ++i) {
            vm.prank(actors[i]);
            token.approve(address(flashRouter_), type(uint256).max);
        }
    }

    function flashTrade(uint96 amountSeed, uint8 actorSeed, bool buy, bool exactInput) external {
        address actor = actors[uint256(actorSeed) % 3];
        uint256 amount = bound(uint256(amountSeed), 1, 1 ether);
        uint256 maxInput = exactInput ? amount : 5 ether;
        SwapParams memory params = SwapParams(
            buy,
            exactInput ? -int256(amount) : int256(amount),
            buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        uint256 walletBefore = actor.balance;
        uint256 managerBefore = _poolETH();
        vm.prank(actor, actor);
        flashRouter.swap{value: buy ? maxInput : 0}(key, params, maxInput);
        _recordTrade(actor, buy, walletBefore, managerBefore);
        assertEq(address(flashRouter).balance, 0, "flash router retained ETH");
        assertEq(token.balanceOf(address(flashRouter)), 0, "flash router retained CROWN");
        ++flashSwaps;
    }

    function attemptClaim(uint32 daySeed, uint8 actorSeed, bool asKing, bool rejectETH) external {
        uint256 today = block.timestamp / 1 days;
        uint256 day = _chooseDay(daySeed);
        ExpectedDay storage info = expected[day];
        address actor = asKing && info.king != address(0) ? info.king : actors[uint256(actorSeed) % 3];
        bytes4 error;
        if (day >= today) error = CrownHook.DayNotEnded.selector;
        else if (info.finalized) error = CrownHook.AlreadyFinalized.selector;
        else if (actor != info.king) error = CrownHook.NotKing.selector;
        else if (today - day > 7) error = CrownHook.ClaimExpired.selector;
        else if (rejectETH) error = CrownHook.ETHTransferFailed.selector;

        bytes32 beforeState = _fingerprint(day, actor);
        uint256 balanceBefore = actor.balance;
        // Like a delegated EOA that rejects native ETH. Install code only for the
        // otherwise-valid payout case, and restore it before the next handler action.
        bool rejecting = error == CrownHook.ETHTransferFailed.selector;
        if (rejecting) vm.etch(actor, address(rejector).code);
        vm.prank(actor, actor);
        (bool ok, bytes memory result) = address(hook).call(abi.encodeCall(hook.claim, (day)));
        if (rejecting) vm.etch(actor, "");
        assertEq(ok, error == bytes4(0), "claim success disagrees with independent state machine");
        if (error != bytes4(0)) {
            assertEq(result, abi.encodeWithSelector(error), "unexpected claim failure");
            assertEq(_fingerprint(day, actor), beforeState, "rejected claim changed value or entitlement");
            ++rejectedClaims;
            if (rejecting) ++failedPayouts;
        } else {
            assertEq(actor.balance - balanceBefore, info.pot, "wrong recipient or payout");
            paid += info.pot;
            info.pot = 0;
            info.finalized = true;
            ++claims;
        }
    }

    function attemptRollover(uint32 daySeed, uint8 actorSeed) external {
        uint256 today = block.timestamp / 1 days;
        uint256 day = _chooseDay(daySeed);
        address actor = actors[uint256(actorSeed) % 3];
        ExpectedDay storage info = expected[day];
        bytes4 error;
        if (day >= today) error = CrownHook.DayNotEnded.selector;
        else if (info.finalized) error = CrownHook.AlreadyFinalized.selector;
        else if (info.king != address(0) && today - day <= 7) error = CrownHook.RolloverTooEarly.selector;

        bytes32 beforeState = _fingerprint(day, actor);
        bytes32 backingBefore = _backing(actor);
        vm.prank(actor, actor);
        (bool ok, bytes memory result) = address(hook).call(abi.encodeCall(hook.rollover, (day)));
        assertEq(ok, error == bytes4(0), "rollover success disagrees with independent state machine");
        assertEq(_backing(actor), backingBefore, "rollover moved ETH or credited a fee twice");
        if (error != bytes4(0)) {
            assertEq(result, abi.encodeWithSelector(error), "unexpected rollover failure");
            assertEq(_fingerprint(day, actor), beforeState, "rejected rollover changed entitlements");
            ++rejectedRollovers;
        } else {
            expected[today].pot += info.pot;
            info.pot = 0;
            info.finalized = true;
            ++rollovers;
        }
    }

    function redeem(uint8 actorSeed) external {
        address actor = actors[uint256(actorSeed) % 3];
        uint256 actorBefore = actor.balance;
        uint256 creditsBefore = manager.balanceOf(address(hook), 0);
        uint256 hookBefore = address(hook).balance;
        uint256 managerBefore = address(manager).balance;
        vm.prank(actor, actor);
        uint256 redeemed = hook.redeemFees();
        assertEq(actor.balance, actorBefore, "redeemer received game funds");
        assertEq(creditsBefore - manager.balanceOf(address(hook), 0), redeemed, "wrong burned credit amount");
        assertEq(address(hook).balance - hookBefore, redeemed, "redeemed ETH did not reach hook");
        assertEq(managerBefore - address(manager).balance, redeemed);
        assertEq(hook.totalFeesCollected(), collected, "redemption counted fees twice");
        assertEq(hook.totalPaid(), paid, "redemption counted as a king payout");
        if (redeemed != 0) ++redemptions;
    }

    function _chooseDay(uint32 seed) private view returns (uint256) {
        // Include the current and next day to exercise premature operations as well.
        return firstDay + uint256(seed) % (block.timestamp / 1 days - firstDay + 2);
    }

    function _fingerprint(uint256 day, address actor) private view returns (bytes32) {
        return keccak256(abi.encode(_dayHash(day), _dayHash(block.timestamp / 1 days), _backing(actor)));
    }

    function _dayHash(uint256 day) private view returns (bytes32) {
        (address king, uint256 biggest, uint256 pot, bool claimed) = hook.dayInfo(day);
        return keccak256(abi.encode(king, biggest, pot, claimed, hook.claimable(day)));
    }

    function _backing(address actor) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                actor.balance,
                address(hook).balance,
                address(manager).balance,
                manager.balanceOf(address(hook), 0),
                hook.pendingFees(),
                hook.totalFeesCollected(),
                hook.totalPaid()
            )
        );
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract CrownAdversarialInvariantTest is CrownInvariantTest {
    AdversarialGameHandler private adversary;
    FlashAccountingRouter private flashRouter;

    function setUp() public override {
        CrownFixture.setUp();
        flashRouter = new FlashAccountingRouter(manager);
        adversary = new AdversarialGameHandler(hook, token, manager, router, key, flashRouter);
        handler = adversary;
        for (uint256 i; i < 3; ++i) {
            token.transfer(handler.actors(i), 100_000 ether);
        }
        // Start with a nonzero liability held as manager credits; ordinary trade, claim,
        // redemption, failure, and rollover actions can all encounter that state.
        adversary.flashTrade(uint96(1 ether), 0, true, true);
        assertGt(hook.pendingFees(), 0);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = GameHandler.trade.selector;
        selectors[1] = GameHandler.advance.selector;
        selectors[2] = AdversarialGameHandler.flashTrade.selector;
        selectors[3] = AdversarialGameHandler.attemptClaim.selector;
        selectors[4] = AdversarialGameHandler.attemptRollover.selector;
        selectors[5] = AdversarialGameHandler.redeem.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_fixedSupplyAndAllTokenBalancesAreConserved() public view {
        uint256 held = token.balanceOf(address(this)) + token.balanceOf(address(manager))
            + token.balanceOf(address(router)) + token.balanceOf(address(hook)) + token.balanceOf(alice)
            + token.balanceOf(bob) + token.balanceOf(carol) + token.balanceOf(address(flashRouter))
            + token.balanceOf(address(handler));
        for (uint256 i; i < 3; ++i) {
            held += token.balanceOf(handler.actors(i));
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether, "supply changed during game");
        assertEq(held, token.totalSupply(), "CROWN escaped tracked participants");
        assertEq(address(flashRouter).balance, 0, "router kept prize funds");
        assertEq(token.balanceOf(address(flashRouter)), 0);
    }

    /// @dev Turn every surviving liability into a real payout after every random sequence.
    /// A backed pot is insufficient if the actual redemption/claim path cannot withdraw it.
    function afterInvariant() public {
        uint256 lastDay = block.timestamp / 1 days;
        vm.warp((lastDay + 8) * 1 days);
        for (uint256 day = START_DAY; day <= lastDay; ++day) {
            handler.rollover(uint32(day - START_DAY));
        }
        uint256 payoutDay = block.timestamp / 1 days;
        handler.trade(uint96(1 ether), 1, true, true);
        vm.warp((payoutDay + 1) * 1 days);
        handler.claim(uint32(payoutDay - START_DAY));
        assertEq(handler.paid(), handler.collected(), "some collected fees could never be paid");
        assertEq(address(hook).balance, 0);
        assertEq(hook.pendingFees(), 0);
        invariant_accountedETHIsBackedAndNeverOverpaid();
        invariant_everyDayMatchesIndependentLedger();
        invariant_fixedSupplyAndAllTokenBalancesAreConserved();
    }

    function test_handlerExercisesDeferredFeesFailuresAndSuccessfulFinalization() public {
        adversary.attemptClaim(0, 0, true, false); // Current day.
        adversary.attemptRollover(0, 1); // Current day.
        adversary.redeem(2);
        adversary.flashTrade(uint96(0.5 ether), 2, true, true);
        vm.warp((START_DAY + 1) * 1 days);
        adversary.attemptRollover(0, 1); // King's window has not expired.
        adversary.attemptClaim(0, 1, false, false); // Wrong caller.
        adversary.attemptClaim(0, 0, true, true); // ETH call fails, including credit redemption.
        adversary.attemptClaim(0, 0, true, false);
        adversary.attemptClaim(0, 0, true, false); // Cannot claim twice.
        adversary.attemptRollover(0, 1); // Cannot roll a paid pot.
        handler.trade(uint96(0.1 ether), 1, false, true); // Sell-only day.
        vm.warp((START_DAY + 2) * 1 days);
        adversary.attemptRollover(1, 2);
        handler.trade(uint96(1 ether), 2, true, true);
        vm.warp((START_DAY + 10) * 1 days);
        adversary.attemptClaim(2, 2, true, false); // Expired.
        adversary.attemptRollover(2, 0);
        assertEq(adversary.failedPayouts(), 1);
        assertEq(adversary.rejectedClaims(), 5);
        assertEq(adversary.rejectedRollovers(), 3);
        assertEq(adversary.claims(), 1);
        assertEq(adversary.rollovers(), 2);
        assertEq(adversary.redemptions(), 1);
        invariant_accountedETHIsBackedAndNeverOverpaid();
        invariant_everyDayMatchesIndependentLedger();
        invariant_fixedSupplyAndAllTokenBalancesAreConserved();
    }
}
