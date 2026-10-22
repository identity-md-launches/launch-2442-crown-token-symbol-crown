// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @notice A daily largest-buy contest for one native-ETH/CROWN Uniswap v4 pool.
/// @dev No privileged accounts. tx.origin identifies buys only; claims authenticate msg.sender.
contract CrownHook is IUnlockCallback, ReentrancyGuard {
    using SafeCast for uint256;
    using TransientStateLibrary for IPoolManager;

    uint256 public constant FEE_BPS = 200;
    uint256 public constant BPS = 10_000;
    uint256 public constant DAY = 1 days;
    uint256 public constant CLAIM_DAYS = 7;
    uint24 public constant POOL_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;

    // address(0) is v4's native ETH currency, never an owner/recipient placeholder.
    Currency private constant ETH = Currency.wrap(address(0));
    bytes32 private constant QUOTED_ETH_SLOT = keccak256("crown.quoted.eth");
    bytes32 private constant SPECIFIED_FEE_SLOT = keccak256("crown.specified.fee");

    IPoolManager public immutable poolManager;
    address public immutable token;

    struct DayInfo {
        address king;
        uint256 biggestBuy;
        uint256 pot;
        bool claimed;
    }

    mapping(uint256 day => DayInfo) public dayInfo;
    /// @notice ETH represented by this hook's native-currency ERC-6909 claims on PoolManager.
    uint256 public pendingFees;
    uint256 public totalFeesCollected;
    uint256 public totalPaid;

    error OnlyPoolManager();
    error OnlySelf();
    error InvalidAddress();
    error WrongPool();
    error InvalidSwapAmount();
    error QuoteResult(int256 delta);
    error UnexpectedQuote();
    error SettlementMismatch();
    error DayNotEnded();
    error AlreadyFinalized();
    error NotKing();
    error ClaimExpired();
    error RolloverTooEarly();
    error ETHTransferFailed();

    event FeeCollected(uint256 indexed day, bool indexed buy, uint256 poolETH, uint256 fee);
    event KingCrowned(uint256 indexed day, address indexed king, uint256 biggestBuy);
    event Claimed(uint256 indexed day, address indexed king, uint256 amount);
    event RolledOver(uint256 indexed fromDay, uint256 indexed toDay, uint256 amount);
    event FeesRedeemed(uint256 amount);

    constructor(IPoolManager poolManager_, address token_) {
        if (address(poolManager_) == address(0) || token_ == address(0) || token_ == address(poolManager_)) {
            revert InvalidAddress();
        }
        poolManager = poolManager_;
        token = token_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        _checkPool(key);
        return IHooks.beforeInitialize.selector;
    }

    /// @dev ETH is specified for exact-input buys and exact-output sells. v4 can change that
    /// currency only in beforeSwap. Preview with a reverting self-call to price partial fills;
    /// the real AMM trade still runs normally, with only its settled fee returned as a delta.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        // All eventual v4 deltas are int128. Bound before negation or gross-up arithmetic.
        if (
            params.amountSpecified == 0 || params.amountSpecified > type(int128).max
                || params.amountSpecified < -int256(type(int128).max)
        ) revert InvalidSwapAmount();

        _redeemAvailable();
        uint256 fee = 0;
        if (_ethIsSpecified(params)) {
            SwapParams memory preview = params;
            uint256 requested = uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified);
            uint256 poolETH;
            if (params.zeroForOne) {
                uint256 reserved = requested * FEE_BPS / BPS;
                uint256 netBudget = requested - reserved;
                preview.amountSpecified = -int256(netBudget);
                poolETH = _quoteETH(key, preview);
                // At full fill preserve the input's rounding. At a limit, reconstruct the
                // actual gross charge from the ETH that traded, never the unused budget.
                fee = poolETH == netBudget ? reserved : poolETH * FEE_BPS / (BPS - FEE_BPS);
            } else {
                preview.amountSpecified = int256(requested + requested * FEE_BPS / (BPS - FEE_BPS));
                poolETH = _quoteETH(key, preview);
                fee = poolETH * FEE_BPS / BPS;
            }
            _store(QUOTED_ETH_SLOT, poolETH);
            _store(SPECIFIED_FEE_SLOT, fee);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        _checkPool(key);
        int256 ethDelta = int256(delta.amount0());
        if (params.zeroForOne ? ethDelta > 0 : ethDelta < 0) revert SettlementMismatch();
        uint256 poolETH = uint256(ethDelta < 0 ? -ethDelta : ethDelta);
        bool specified = _ethIsSpecified(params);
        uint256 fee;
        if (specified) {
            if (poolETH != _load(QUOTED_ETH_SLOT)) revert SettlementMismatch();
            fee = _load(SPECIFIED_FEE_SLOT);
            _store(QUOTED_ETH_SLOT, 0);
            _store(SPECIFIED_FEE_SLOT, 0);
        } else {
            fee = params.zeroForOne ? poolETH * FEE_BPS / (BPS - FEE_BPS) : poolETH * FEE_BPS / BPS;
        }
        // Invariant for every buy: fee = floor(actual gross ETH debit * 2%).
        if (params.zeroForOne && fee != (poolETH + fee) * FEE_BPS / BPS) revert SettlementMismatch();

        uint256 day = currentDay();
        DayInfo storage info = dayInfo[day];
        if (fee != 0) {
            info.pot += fee;
            totalFeesCollected += fee;
        }
        if (params.zeroForOne && poolETH > info.biggestBuy) {
            info.king = tx.origin;
            info.biggestBuy = poolETH;
            emit KingCrowned(day, tx.origin, poolETH);
        }
        emit FeeCollected(day, params.zeroForOne, poolETH, fee);
        if (fee != 0) {
            // A fresh, token-only pool has no ETH until the router settles its input.
            // Minting the same native-currency credit avoids depending on prefunding.
            if (address(poolManager).balance >= fee) {
                poolManager.take(ETH, address(this), fee);
            } else {
                pendingFees += fee;
                poolManager.mint(address(this), 0, fee);
            }
        }
        return (IHooks.afterSwap.selector, specified ? int128(0) : fee.toInt128());
    }

    /// @dev Quote-only entry point. A caller cannot use it to execute a fee-free swap:
    /// only this contract can enter, and ALL paths revert, undoing pool state and deltas.
    function quoteSwap(PoolKey calldata key, SwapParams calldata params) external {
        if (msg.sender != address(this)) revert OnlySelf();
        BalanceDelta delta = poolManager.swap(key, params, "");
        revert QuoteResult(BalanceDelta.unwrap(delta));
    }

    function currentDay() public view returns (uint256) {
        return block.timestamp / DAY;
    }

    /// @notice Returns the king's entitlement, independent of the caller, during the claim window.
    function claimable(uint256 day) public view returns (uint256) {
        uint256 today = currentDay();
        if (day >= today || today - day > CLAIM_DAYS) return 0;
        DayInfo storage info = dayInfo[day];
        return info.claimed || info.king == address(0) ? 0 : info.pot;
    }

    function claim(uint256 day) external nonReentrant {
        uint256 today = currentDay();
        if (day >= today) revert DayNotEnded();
        DayInfo storage info = dayInfo[day];
        if (info.claimed) revert AlreadyFinalized();
        if (msg.sender != info.king) revert NotKing();
        if (today - day > CLAIM_DAYS) revert ClaimExpired();

        uint256 amount = info.pot;
        info.claimed = true;
        info.pot = 0;
        totalPaid += amount;
        emit Claimed(day, msg.sender, amount);
        if (address(this).balance < amount) _redeem();
        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) revert ETHTransferFailed();
    }

    /// @notice A kingless day rolls immediately after midnight; a king gets seven full days.
    /// @dev `claimed` means finalized, including rollover. Historical king/size remain readable.
    function rollover(uint256 day) external nonReentrant {
        uint256 today = currentDay();
        if (day >= today) revert DayNotEnded();
        DayInfo storage info = dayInfo[day];
        if (info.claimed) revert AlreadyFinalized();
        if (info.king != address(0) && today - day <= CLAIM_DAYS) revert RolloverTooEarly();
        uint256 amount = info.pot;
        info.pot = 0;
        info.claimed = true;
        dayInfo[today].pot += amount;
        emit RolledOver(day, today, amount);
    }

    /// @notice Anyone can redeem pending ETH credits into the hook. No caller receives a share.
    function redeemFees() external nonReentrant returns (uint256 redeemed) {
        uint256 before = pendingFees;
        _redeem();
        return before - pendingFees;
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        _redeemAvailable();
        return "";
    }

    receive() external payable onlyPoolManager {}

    function _redeem() private {
        if (pendingFees == 0) return;
        if (poolManager.isUnlocked()) _redeemAvailable();
        else poolManager.unlock("");
    }

    function _redeemAvailable() private {
        uint256 amount = pendingFees;
        if (amount > address(poolManager).balance) amount = address(poolManager).balance;
        if (amount == 0) return;
        pendingFees -= amount;
        emit FeesRedeemed(amount);
        poolManager.burn(address(this), 0, amount);
        poolManager.take(ETH, address(this), amount);
    }

    function _quoteETH(PoolKey calldata key, SwapParams memory params) private returns (uint256) {
        (bool success, bytes memory result) = address(this).call(abi.encodeCall(this.quoteSwap, (key, params)));
        if (success) revert UnexpectedQuote();
        if (result.length != 36 || bytes4(result) != QuoteResult.selector) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
        int256 packed;
        assembly ("memory-safe") {
            packed := mload(add(result, 36))
        }
        int256 amount = int256(BalanceDelta.wrap(packed).amount0());
        return uint256(amount < 0 ? -amount : amount);
    }

    function _checkPool(PoolKey calldata key) private view {
        if (
            !key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != token || key.fee != POOL_FEE
                || key.tickSpacing != TICK_SPACING || address(key.hooks) != address(this)
        ) {
            revert WrongPool();
        }
    }

    function _ethIsSpecified(SwapParams calldata params) private pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    function _store(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _load(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }
}
