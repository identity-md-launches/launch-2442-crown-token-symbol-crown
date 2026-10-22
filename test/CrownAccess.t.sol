// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CrownFixture} from "./helpers/CrownFixture.sol";
import {CrownHook} from "../src/CrownHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MineSalt} from "../script/MineSalt.s.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract CrownAccessTest is CrownFixture {
    function test_permissionsExactlyMatchDeploymentBits() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta);
        assertTrue(p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.flagsOf(address(hook)), 0x20cc);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.token(), address(token));
    }

    function test_allEnabledCallbacksRejectNonManager() public {
        vm.expectRevert(CrownHook.OnlyPoolManager.selector);
        hook.beforeInitialize(alice, key, Q96);
        vm.expectRevert(CrownHook.OnlyPoolManager.selector);
        hook.beforeSwap(alice, key, _params(true, -1 ether), "");
        vm.expectRevert(CrownHook.OnlyPoolManager.selector);
        hook.afterSwap(alice, key, _params(true, -1 ether), toBalanceDelta(-1 ether, 1 ether), "");
        vm.expectRevert(CrownHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(CrownHook.OnlySelf.selector);
        hook.quoteSwap(key, _params(true, -1 ether));
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok);
        assertEq(hook.totalFeesCollected(), 0);
    }

    function test_initializeAcceptsPolicyPoolAndReturnsSelector() public {
        vm.prank(address(manager));
        assertEq(hook.beforeInitialize(alice, key, Q96), IHooks.beforeInitialize.selector);
    }

    function test_initializeRejectsOtherPools() public {
        PoolKey memory bad = key;
        bad.currency1 = Currency.wrap(alice);
        _refusePool(bad);
        bad = key;
        bad.currency0 = Currency.wrap(bob);
        _refusePool(bad);
        bad = key;
        bad.fee = 3_000;
        _refusePool(bad);
        bad.fee = 0;
        _refusePool(bad);
        bad.fee = 0x800000;
        _refusePool(bad);
        bad = key;
        bad.tickSpacing = 1;
        _refusePool(bad);
        bad = key;
        bad.hooks = IHooks(alice);
        _refusePool(bad);
    }

    function test_swapCallbacksAlsoRejectWrongPool() public {
        PoolKey memory bad = key;
        bad.fee = 0;
        vm.prank(address(manager));
        vm.expectRevert(CrownHook.WrongPool.selector);
        hook.beforeSwap(alice, bad, _params(true, -1 ether), "");
        vm.prank(address(manager));
        vm.expectRevert(CrownHook.WrongPool.selector);
        hook.afterSwap(alice, bad, _params(true, -1 ether), toBalanceDelta(-1 ether, 1 ether), "");
    }

    function test_invalidAmountBoundsRejectedBeforeNegation() public {
        int256[4] memory invalid = [int256(0), type(int256).min, type(int256).max, -int256(type(int128).max) - 1];
        for (uint256 i; i < invalid.length; ++i) {
            vm.prank(address(manager));
            vm.expectRevert(CrownHook.InvalidSwapAmount.selector);
            hook.beforeSwap(alice, key, _params(true, invalid[i]), "");
        }
    }

    function test_noOwnerAdminSettersMintOrUpgradeFunctions() public {
        string[11] memory signatures = [
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "pause()",
            "unpause()",
            "upgradeTo(address)",
            "setFee(uint256)",
            "setToken(address)",
            "setPoolManager(address)",
            "withdraw(address,uint256)",
            "mint(address,uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(signatures[i], alice, 1 ether));
            assertFalse(ok, signatures[i]);
        }
    }

    function test_constructorsRejectZeroConfiguration() public {
        vm.expectRevert(CrownHook.InvalidAddress.selector);
        new CrownHook(IPoolManager(address(0)), address(token));
        vm.expectRevert(CrownHook.InvalidAddress.selector);
        new CrownHook(manager, address(0));
        vm.expectRevert(CrownHook.InvalidAddress.selector);
        new CrownHook(manager, address(manager));
    }

    function test_saltMinerDeploysReviewedBytecodeEvenBeforeDependenciesHaveCode() public {
        IPoolManager futureManager = IPoolManager(makeAddr("future manager"));
        address futureToken = makeAddr("future token");
        assertEq(address(futureManager).code.length, 0);
        assertEq(futureToken.code.length, 0);
        MineSalt miner = new MineSalt();
        (bytes32 salt, address expected) = miner.run(address(this), futureManager, futureToken, 0, 200_000);
        CrownHook deployed = new CrownHook{salt: salt}(futureManager, futureToken);
        assertEq(address(deployed), expected);
        assertTrue(HookFlags.matches(expected, HookFlags.CROWN));
    }

    function test_addressWithWrongPermissionBitsCannotDeploy() public {
        bytes memory code = abi.encodePacked(type(CrownHook).creationCode, abi.encode(manager, address(token)));
        bytes32 hash = keccak256(code);
        bytes32 salt;
        address predicted = vm.computeCreate2Address(salt, hash, address(this));
        if (HookFlags.matches(predicted, HookFlags.CROWN)) salt = bytes32(uint256(1));
        predicted = vm.computeCreate2Address(salt, hash, address(this));
        assertFalse(HookFlags.matches(predicted, HookFlags.CROWN));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new CrownHook{salt: salt}(manager, address(token));
    }

    function test_runtimeHasNoUpgradeOrDestructionOpcodes() public view {
        _checkRuntime(address(hook).code);
        _checkRuntime(address(token).code);
    }

    function _refusePool(PoolKey memory bad) internal {
        vm.prank(address(manager));
        vm.expectRevert(CrownHook.WrongPool.selector);
        hook.beforeInitialize(alice, bad, Q96);
    }

    function _checkRuntime(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }
}
