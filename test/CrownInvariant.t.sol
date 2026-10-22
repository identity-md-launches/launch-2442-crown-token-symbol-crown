// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CrownFixture} from "./helpers/CrownFixture.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {Crown} from "../src/Crown.sol";
import {CrownHook} from "../src/CrownHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Independent ledger derived from actual wallet/manager ETH changes, not hook events/state.
contract GameHandler is Test {
    struct ExpectedDay {
        address king;
        uint256 biggest;
        uint256 pot;
        bool finalized;
    }

    CrownHook public immutable hook;
    Crown public immutable token;
    IPoolManager public immutable manager;
    PoolRouter public immutable router;
    uint256 public immutable firstDay;
    PoolKey private key;
    address[3] public actors;
    mapping(uint256 => ExpectedDay) public expected;
    uint256 public collected;
    uint256 public paid;
    uint256 public swaps;
    uint256 public claims;
    uint256 public rollovers;

    constructor(CrownHook hook_, Crown token_, IPoolManager manager_, PoolRouter router_, PoolKey memory key_) {
        hook = hook_;
        token = token_;
        manager = manager_;
        router = router_;
        key = key_;
        firstDay = block.timestamp / 1 days;
        for (uint256 i; i < 3; ++i) {
            actors[i] = address(uint160(uint256(keccak256(abi.encode("invariant trader", i)))));
            vm.deal(actors[i], 100_000 ether);
            vm.prank(actors[i]);
            token.approve(address(router), type(uint256).max);
        }
    }

    function trade(uint96 amountSeed, uint8 actorSeed, bool buy, bool exactInput) external {
        address actor = actors[uint256(actorSeed) % 3];
        uint256 amount = bound(uint256(amountSeed), 1e8, 1 ether);
        uint256 maxInput = exactInput ? amount : 5 ether;
        SwapParams memory params = SwapParams(
            buy,
            exactInput ? -int256(amount) : int256(amount),
            buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        uint256 walletBefore = actor.balance;
        uint256 managerBefore = address(manager).balance;
        vm.prank(actor, actor);
        router.swap{value: buy ? maxInput : 0}(key, params, maxInput, 0, "");
        uint256 base = buy ? address(manager).balance - managerBefore : managerBefore - address(manager).balance;
        uint256 fee;
        if (buy) {
            uint256 gross = walletBefore - actor.balance;
            fee = gross / 50;
            assertEq(base + fee, gross);
        } else {
            fee = base / 50;
            assertEq(actor.balance - walletBefore + fee, base);
        }
        ExpectedDay storage info = expected[block.timestamp / 1 days];
        info.pot += fee;
        collected += fee;
        if (buy && base > info.biggest) {
            info.king = actor;
            info.biggest = base;
        }
        ++swaps;
    }

    function advance(uint32 secondsSeed) external {
        vm.warp(block.timestamp + bound(uint256(secondsSeed), 1, 3 days));
    }

    function claim(uint32 daySeed) external {
        uint256 today = block.timestamp / 1 days;
        uint256 day = firstDay + uint256(daySeed) % (today - firstDay + 1);
        ExpectedDay storage info = expected[day];
        if (day >= today || info.king == address(0) || info.finalized || today - day > 7) return;
        uint256 before = info.king.balance;
        vm.prank(info.king);
        hook.claim(day);
        assertEq(info.king.balance - before, info.pot);
        paid += info.pot;
        info.pot = 0;
        info.finalized = true;
        ++claims;
    }

    function rollover(uint32 daySeed) external {
        uint256 today = block.timestamp / 1 days;
        uint256 day = firstDay + uint256(daySeed) % (today - firstDay + 1);
        ExpectedDay storage info = expected[day];
        if (day >= today || info.finalized || (info.king != address(0) && today - day <= 7)) return;
        hook.rollover(day);
        expected[today].pot += info.pot;
        info.pot = 0;
        info.finalized = true;
        ++rollovers;
    }
}

contract CrownInvariantTest is CrownFixture {
    GameHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new GameHandler(hook, token, manager, router, key);
        for (uint256 i; i < 3; ++i) {
            token.transfer(handler.actors(i), 100_000 ether);
        }
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = GameHandler.trade.selector;
        selectors[1] = GameHandler.advance.selector;
        selectors[2] = GameHandler.claim.selector;
        selectors[3] = GameHandler.rollover.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_accountedETHIsBackedAndNeverOverpaid() public view {
        assertEq(hook.totalFeesCollected(), handler.collected());
        assertEq(hook.totalPaid(), handler.paid());
        assertLe(handler.paid(), handler.collected());
        assertEq(address(hook).balance + hook.pendingFees(), handler.collected() - handler.paid());
        _assertSettled();
    }

    function invariant_everyDayMatchesIndependentLedger() public view {
        uint256 outstanding;
        uint256 today = block.timestamp / 1 days;
        for (uint256 day = START_DAY; day <= today; ++day) {
            (address king, uint256 biggest, uint256 pot, bool finalized) = hook.dayInfo(day);
            (address wantKing, uint256 wantBiggest, uint256 wantPot, bool wantFinalized) = handler.expected(day);
            assertEq(king, wantKing);
            assertEq(biggest, wantBiggest);
            assertEq(pot, wantPot);
            assertEq(finalized, wantFinalized);
            outstanding += pot;
            uint256 entitlement = day < today && today - day <= 7 && king != address(0) && !finalized ? pot : 0;
            assertEq(hook.claimable(day), entitlement);
        }
        assertEq(outstanding + handler.paid(), handler.collected());
    }
}
