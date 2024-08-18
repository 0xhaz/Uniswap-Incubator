// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
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
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {CurrencyDelta} from "v4-core/libraries/CurrencyDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {SrAmmV2} from "./SrAmmV2.sol";
import {console} from "forge-std/console.sol";

contract SrAmmHookV2 is BaseHook, SrAmmV2 {
    using PoolIdLibrary for PoolKey;
    using CurrencyDelta for Currency;
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        bytes hookData;
        bool settleUsingBurn;
        bool takeClaims;
    }

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // initialize srPool
            beforeAddLiquidity: true,
            afterAddLiquidity: false, // maintain artificial liquidity
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // custom swap accounting
            afterSwap: false, // settle reduced diffs
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // custom swap
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------
    uint256 lastBlockNumber;
    mapping(uint256 => int24) slotOfferTickMap;
    mapping(uint256 => uint160) slotOfferSqrtMap;

    function checkSlotChanged() public view returns (bool) {
        if (block.number != lastBlockNumber) {
            return true;
        } else {
            return false;
        }
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata hookData)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        BalanceDelta delta = srAmmSwap(key, params);
        console.log("SrAmmHook: swap delta ");
        console.logInt(delta.amount0());
        console.logInt(delta.amount1());

        bool exactInput = params.amountSpecified < 0;
        (Currency specified, Currency unspecified) =
            (params.zeroForOne == exactInput) ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        uint256 specifiedAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        int128 unspecifiedAmount;

        if (params.zeroForOne) {
            unspecifiedAmount = exactInput ? delta.amount1() : -delta.amount0();
        } else {
            unspecifiedAmount = exactInput ? delta.amount0() : -delta.amount1();
        }

        BeforeSwapDelta returnDelta;

        if (exactInput) {
            // in exact-input swaps, the specified token is a debt that gets paid down by the swapper
            // the unspecified token is credited to the PoolManager, that is claimed by the swapper
            specified.take(poolManager, address(this), specifiedAmount, true);
            unspecified.settle(poolManager, address(this), uint128(unspecifiedAmount), true);
            returnDelta = toBeforeSwapDelta(specifiedAmount.toInt128(), -unspecifiedAmount);
        } else {
            // exactOutput
            // in exact-output swaps, the unspecified token is a debt that gets paid down by the swapper
            // the specified token is credited to the PoolManager, that is claimed by the swapper
            unspecified.take(poolManager, address(this), uint128(unspecifiedAmount), true);
            specified.settle(poolManager, address(this), specifiedAmount, true);
        }

        return (this.beforeSwap.selector, returnDelta, 0);
    }

    function settleOutputTokenPostSwap(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        address sender
    ) internal {
        console.log("Settling tokens");
        console.logInt(delta.amount0());
        console.logInt(delta.amount1());

        if (delta.amount0() > 0) {
            console.log("taking amount0");
            poolManager.take(key.currency0, sender, uint128(delta.amount0()));
        }
        if (delta.amount1() > 0) {
            console.log("taking amount1");
            poolManager.take(key.currency1, sender, uint128(delta.amount1()));
        }

        console.log("Settled tokens");
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        revert();
        return BaseHook.beforeAddLiquidity.selector;
    }

    function afterSwap(
        address sender,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, int128) {
        // console.log("After Swap delta");
        // console.logInt(delta.amount0());
        // console.logInt(delta.amount1());
        // console.logInt(unspecifiedDelta);

        //int128 diffSettledDelta = delta.amount0() + unspecifiedDelta;

        //console.logInt(diffSettledDelta);
        return (BaseHook.afterSwap.selector, 0);
    }
}
