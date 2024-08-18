// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SrPool} from "./SrPool.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {LiquidityMath} from "v4-core/libraries/LiquidityMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapMath} from "v4-core/libraries/SwapMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";
import {ProtocolFeeLibrary} from "v4-core/libraries/ProtocolFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Slot0} from "v4-core/types/Slot0.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {CurrencyDelta} from "v4-core/libraries/CurrencyDelta.sol";
import {NoDelegateCall} from "v4-core/NoDelegateCall.sol";
import {CurrencyReserves} from "v4-core/libraries/CurrencyReserves.sol";

contract SrAmmV2 is NoDelegateCall {
    using PoolIdLibrary for PoolKey;
    using SrPool for *;
    using SafeCast for *;
    using CurrencyDelta for Currency;
    using CurrencyReserves for Currency;
    using LPFeeLibrary for uint24;

    mapping(PoolId id => SrPool.SrPoolState) internal _srPools;
    mapping(PoolId id => uint256 lastBlock) internal _lastBlock;

    event Swap(
        PoolId indexed id,
        address sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );

    function _initializePool(PoolKey memory key, uint160 sqrtPriceX96)
        internal
        noDelegateCall
        returns (int24 bidTick, int24 offerTick)
    {
        PoolId id = key.toId();
        /// @notice gets and validates the initial LP fee for a pool. Dynamic fee pools have an initial fee of 0.
        /// @dev if a dynamic fee pool wants a non-0 initial fee, it should call `updateDynamicLPFee` in the afterInitialize hook
        /// @param self The fee to get the initial LP from
        /// @return initialFee 0 if the fee is dynamic, otherwise the fee (if valid)
        uint24 lpFee = key.fee.getInitialLPFee();
        uint24 protocolFee = 0;
        (bidTick, offerTick) = _srPools[id].initialize(sqrtPriceX96, protocolFee, lpFee);
    }

    function srAmmSwap(PoolKey calldata key, IPoolManager.SwapParams memory params)
        internal
        returns (BalanceDelta swapDelta)
    {
        resetSlot(key);
        (BalanceDelta result,, uint24 swapFee, SrPool.SrSwapState memory srSwapState) = _srPools[key.toId()].swap(
            SrPool.SwapParams({
                tickSpacing: key.tickSpacing,
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                lpFeeOverride: 0
            })
        );

        emit Swap(
            key.toId(),
            msg.sender,
            result.amount0(),
            result.amount1(),
            srSwapState.sqrtPriceX96,
            srSwapState.liquidity,
            srSwapState.tick,
            swapFee
        );

        return result;
    }

    function srAmmAddLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta liquidityDelta)
    {
        (BalanceDelta result,) = _srPools[key.toId()].modifyLiquidity(
            SrPool.ModifyLiquidityParams({
                owner: msg.sender,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: params.liquidityDelta.toInt128(),
                tickSpacing: key.tickSpacing,
                salt: params.salt
            })
        );

        return result;
    }

    function resetSlot(PoolKey calldata key) internal returns (bool) {
        if (_lastBlock[key.toId()] == block.number) {
            return false;
        }

        _srPools[key.toId()].initializeAtNewSlot();
        _lastBlock[key.toId()] = block.number;

        return true;
    }
}
