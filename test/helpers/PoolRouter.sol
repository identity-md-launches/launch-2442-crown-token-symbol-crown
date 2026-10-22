// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @dev Test-only router: prefunds from its own caller, settles its own funds, refunds the rest.
/// It needs no CROWN-specific callback data, identity encoding, fee payment, or redemption.
contract PoolRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    error OnlyManager();
    error InputExceeded();
    error OutputTooSmall();
    error TransferFailed();

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, uint256 maxInput, uint256 minOutput, bytes memory data)
        external
        payable
        returns (BalanceDelta delta)
    {
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        Currency output = params.zeroForOne ? key.currency1 : key.currency0;
        if (input.isAddressZero()) {
            require(msg.value == maxInput, "fund ETH input");
        } else {
            require(msg.value == 0, "unexpected ETH");
            require(IERC20(Currency.unwrap(input)).transferFrom(msg.sender, address(this), maxInput));
        }
        delta = abi.decode(manager.unlock(abi.encode(uint8(0), key, params, data)), (BalanceDelta));
        int128 paidDelta = params.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = params.zeroForOne ? delta.amount1() : delta.amount0();
        uint256 paid = uint256(-int256(paidDelta));
        uint256 received = uint256(int256(outDelta));
        if (paid > maxInput) revert InputExceeded();
        if (received < minOutput) revert OutputTooSmall();
        _pay(output, msg.sender, received);
        _pay(input, msg.sender, maxInput - paid);
    }

    /// @dev Seed/modify using this router's test-funded balances. Position belongs to the router.
    function modify(PoolKey memory key, ModifyLiquidityParams memory params) external returns (BalanceDelta delta) {
        delta = abi.decode(manager.unlock(abi.encode(uint8(1), key, params)), (BalanceDelta));
    }

    /// @dev Execute several swaps in one unlock using this test router's prefunded balances.
    function batch(PoolKey memory key, SwapParams[] memory params) external returns (BalanceDelta[] memory deltas) {
        return abi.decode(manager.unlock(abi.encode(uint8(2), key, params)), (BalanceDelta[]));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyManager();
        uint8 action = abi.decode(data, (uint8));
        if (action == 2) return _batch(data);
        PoolKey memory key;
        BalanceDelta delta;
        if (action == 0) {
            SwapParams memory params;
            bytes memory hookData;
            (, key, params, hookData) = abi.decode(data, (uint8, PoolKey, SwapParams, bytes));
            delta = manager.swap(key, params, hookData);
        } else {
            ModifyLiquidityParams memory params;
            (, key, params) = abi.decode(data, (uint8, PoolKey, ModifyLiquidityParams));
            (delta,) = manager.modifyLiquidity(key, params, "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        require(manager.currencyDelta(address(this), key.currency0) == 0, "unsettled ETH");
        require(manager.currencyDelta(address(this), key.currency1) == 0, "unsettled token");
        return abi.encode(delta);
    }

    function _batch(bytes calldata data) private returns (bytes memory) {
        (, PoolKey memory key, SwapParams[] memory params) = abi.decode(data, (uint8, PoolKey, SwapParams[]));
        BalanceDelta[] memory deltas = new BalanceDelta[](params.length);
        BalanceDelta total;
        for (uint256 i; i < params.length; ++i) {
            deltas[i] = manager.swap(key, params[i], "");
            total = total + deltas[i];
        }
        _settle(key.currency0, total.amount0());
        _settle(key.currency1, total.amount1());
        return abi.encode(deltas);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: amount}();
            } else {
                require(IERC20(Currency.unwrap(currency)).transfer(address(manager), amount));
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(int256(delta)));
        }
    }

    function _pay(Currency currency, address to, uint256 amount) private {
        if (amount == 0) return;
        if (currency.isAddressZero()) {
            (bool success,) = payable(to).call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            require(IERC20(Currency.unwrap(currency)).transfer(to, amount));
        }
    }

    receive() external payable {}
}
