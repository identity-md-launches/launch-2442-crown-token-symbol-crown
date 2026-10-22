// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CrownHook} from "../../src/CrownHook.sol";
import {PoolRouter} from "./PoolRouter.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract CrownRejectingRecipient {
    receive() external payable {
        revert("king rejects ETH");
    }
}

/// @dev Runtime is installed on a crowned EOA to model delegated account receive code.
/// A claim's ETH call must allow useful work and preserve accounting during a nested buy.
contract CrownReinvestingRecipient {
    CrownHook public immutable hook;
    PoolRouter public immutable router;
    address private immutable token;
    uint256 private immutable rewardDay;
    bool public observedFinalization;
    uint256 public reinvested;

    constructor(CrownHook hook_, PoolRouter router_, address token_, uint256 day_) {
        hook = hook_;
        router = router_;
        token = token_;
        rewardDay = day_;
    }

    receive() external payable {
        require(msg.sender == address(hook), "only reward");
        (,, uint256 pot, bool finalized) = hook.dayInfo(rewardDay);
        observedFinalization = finalized && pot == 0 && hook.claimable(rewardDay) == 0;
        reinvested = msg.value / 2;
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(token), 12_500, 60, IHooks(address(hook)));
        router.swap{value: reinvested}(
            key, SwapParams(true, -int256(reinvested), TickMath.MIN_SQRT_PRICE + 1), reinvested, 0, ""
        );
    }
}
