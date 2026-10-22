// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @dev Test-only flash accounting: borrow manager ETH, swap while its cash is zero,
/// then repay the loan and settle the swap together. This reaches deferred fee collection
/// on every swap mode without mocking the manager, its balance, or hook callbacks.
contract FlashAccountingRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, uint256 maxInput)
        external
        payable
        returns (BalanceDelta delta)
    {
        if (params.zeroForOne) {
            require(msg.value == maxInput, "ETH input budget");
        } else {
            require(msg.value == 0, "sell does not send ETH");
            require(IERC20(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), maxInput));
        }
        delta = abi.decode(manager.unlock(abi.encode(key, params)), (BalanceDelta));
        uint256 spent = uint256(-int256(params.zeroForOne ? delta.amount0() : delta.amount1()));
        uint256 received = uint256(int256(params.zeroForOne ? delta.amount1() : delta.amount0()));
        require(spent <= maxInput, "input exceeded");
        _pay(params.zeroForOne ? key.currency1 : key.currency0, msg.sender, received);
        _pay(params.zeroForOne ? key.currency0 : key.currency1, msg.sender, maxInput - spent);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (PoolKey memory key, SwapParams memory params) = abi.decode(data, (PoolKey, SwapParams));
        require(key.currency0.isAddressZero(), "native pair only");
        manager.take(key.currency0, address(this), address(manager).balance);
        require(address(manager).balance == 0, "flash loan must remove available ETH");
        BalanceDelta delta = manager.swap(key, params, "");
        _settle(key.currency0);
        _settle(key.currency1);
        require(manager.currencyDelta(address(this), key.currency0) == 0, "unpaid ETH loan or swap");
        require(manager.currencyDelta(address(this), key.currency1) == 0, "unpaid CROWN swap");
        return abi.encode(delta);
    }

    function _settle(Currency currency) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) {
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: uint256(-delta)}();
            } else {
                require(IERC20(Currency.unwrap(currency)).transfer(address(manager), uint256(-delta)));
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(delta));
        }
    }

    function _pay(Currency currency, address recipient, uint256 amount) private {
        if (amount == 0) return;
        if (currency.isAddressZero()) {
            (bool ok,) = payable(recipient).call{value: amount}("");
            require(ok, "ETH payment failed");
        } else {
            require(IERC20(Currency.unwrap(currency)).transfer(recipient, amount));
        }
    }

    receive() external payable {}
}
