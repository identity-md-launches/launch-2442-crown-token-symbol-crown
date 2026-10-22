// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Crown} from "../../src/Crown.sol";
import {CrownHook} from "../../src/CrownHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {PoolRouter} from "./PoolRouter.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

abstract contract CrownFixture is Test {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

    uint160 internal constant Q96 = 79228162514264337593543950336;
    uint256 internal constant START_DAY = 20_000;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    Crown internal token;
    CrownHook internal hook;
    IPoolManager internal manager;
    PoolRouter internal router;
    PoolKey internal key;
    address internal alice;
    address internal bob;
    address internal carol;

    function setUp() public virtual {
        vm.warp(START_DAY * 1 days + 1 hours);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        token = new Crown();
        _newPool(false);
        _fund(alice);
        _fund(bob);
        _fund(carol);
    }

    function _newPool(bool tokensOnly) internal {
        manager = IPoolManager(address(new PoolManager(address(this))));
        bytes memory code = abi.encodePacked(type(CrownHook).creationCode, abi.encode(manager, address(token)));
        bytes32 hash = keccak256(code);
        address at;
        for (uint256 salt; salt < 200_000; ++salt) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), hash))))
            );
            if (!HookFlags.matches(predicted, HookFlags.CROWN)) continue;
            assembly ("memory-safe") { at := create2(0, add(code, 32), mload(code), salt) }
            break;
        }
        require(at != address(0), "CREATE2 hook deployment failed");
        hook = CrownHook(payable(at));
        router = new PoolRouter(manager);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12_500, 60, IHooks(at));
        manager.initialize(key, Q96);
        token.transfer(address(router), 1_000_000 ether);
        if (tokensOnly) {
            // Above this range the position is entirely currency1, CROWN; manager holds no ETH.
            router.modify(key, ModifyLiquidityParams(-600, 0, 10_000 ether, bytes32(0)));
        } else {
            vm.deal(address(router), 1_000_000 ether);
            router.modify(key, ModifyLiquidityParams(-60_000, 60_000, 10_000 ether, bytes32(0)));
        }
    }

    function _fund(address trader) internal {
        vm.deal(trader, 100_000 ether);
        token.transfer(trader, 100_000 ether);
        vm.prank(trader);
        token.approve(address(router), type(uint256).max);
    }

    function _params(bool buy, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _trade(address trader, bool buy, int256 amount) internal returns (BalanceDelta delta, BalanceDelta raw) {
        return _tradeLimit(trader, _params(buy, amount));
    }

    function _tradeLimit(address trader, SwapParams memory params)
        internal
        returns (BalanceDelta delta, BalanceDelta raw)
    {
        uint256 maxInput = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : 1_000 ether;
        vm.recordLogs();
        vm.prank(trader, trader);
        delta = router.swap{value: params.zeroForOne ? maxInput : 0}(key, params, maxInput, 0, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 swaps;
        for (uint256 i; i < logs.length; ++i) {
            // recordLogs also observes reverted subcalls. The real swap's sender is the
            // router; the reverted preview's sender is the hook. Only read the real trade.
            if (
                logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC
                    && logs[i].topics[2] == bytes32(uint256(uint160(address(router))))
            ) {
                (int128 a0, int128 a1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                raw = toBalanceDelta(a0, a1);
                ++swaps;
            }
        }
        assertEq(swaps, 1, "the quote must leave no events or executed swap behind");
        _assertSettled();
    }

    function _buy(address trader, uint256 grossETH) internal returns (uint256 poolETH) {
        (, BalanceDelta raw) = _trade(trader, true, -int256(grossETH));
        return uint256(-int256(raw.amount0()));
    }

    function _pot(uint256 day) internal view returns (uint256 pot) {
        (,, pot,) = hook.dayInfo(day);
    }

    function _assertSettled() internal view {
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0, "hook ETH debt");
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0, "hook token debt");
        assertEq(manager.getNonzeroDeltaCount(), 0, "manager debt remains");
        assertFalse(manager.isUnlocked(), "manager left unlocked");
        assertEq(token.balanceOf(address(hook)), 0, "hook collected CROWN");
        assertEq(manager.balanceOf(address(hook), 0), hook.pendingFees());
        assertEq(address(hook).balance + hook.pendingFees() + hook.totalPaid(), hook.totalFeesCollected());
    }
}
