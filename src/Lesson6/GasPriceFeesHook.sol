// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

/**
 * @title GasPriceHook
 * @notice Dynanmic Fees are an interesting concept because it allows pools to adjust their
 * competitiveness with other pools for the same token pair by adjusting how much swap fees is being charged.
 * @notice Hooks can be designed in different ways, to favour LPs or to favour swappers
 * @notice This hook will be adjusting the fees charged depending on what the average gas price has been onchain
 * @notice Mechanism Design:
 * 1. Hook will keep track of the moving average gas price over time onchain.
 * 2. When gas price is roughly equal to the average, we will charge a certain amount of fees.
 * 3. If gas price is over 10% higher than the average, we will charge a lower fees.
 * 4. If gas price is over 10% lower than the average, we will charge a higher fees.
 * @notice PoolManage contains a mapping of all pools, which contains the pool's Pool.State struct. Within the
 * Pool.State struct, there is Slot0 - accessible via the getSlot0() function on the PoolManager if you're using StateLibrary.
 * @notice One of the values that is part of Slot0 is the lpFee. The fees charged on each swap are represented by this lpFee property
 * @notice Normally, pools defined a lpFee during initialization that cannot change. A dynamic fee hook, basically,
 * has the capability to just update this property whenever it wants.
 */
contract GasPriceFeesHook is BaseHook {
    using LPFeeLibrary for uint24;

    // Keeping track of the moving average gas price
    uint128 public movingAverageGasPrice;
    // How many times has the moving average been updated?
    // Needed as the denominator to update it the next time based on the moving average formula
    uint104 public movingAverageGasPriceCount;

    // The default base fees we will charge
    uint24 public constant BASE_FEES = 5000; // 0.5%

    error MustUseDynamicFee();

    // Initialize BaseHook parent contract in the constructor
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        updateMovingAverage();
    }

    // Required override function for BaseHook to let the PoolManager know which hooks are implemented
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        // `.isDynamicFee()` function comes from using the `LPFeeLibrary` for the `uint24` type
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    /**
     * @notice Before a swap happens we need to:
     * 1. Get the current gas price
     * 2. Compare current gas price with our moving average
     * 3. Calculate how much fees should be charged on this pool depending on if current gas price is higher or lower
     * 4. Update the swap fees in the pool manager
     *
     */
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        onlyByPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = getFee();
        poolManager.updateDynamicLPFee(key, fee);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        updateMovingAverage();
        return (this.afterSwap.selector, 0);
    }

    //////////////////////// Helper Functions ////////////////////////
    // Update our moving average gas price
    function updateMovingAverage() internal {
        uint128 gasPrice = uint128(tx.gasprice);

        // New Average = ((Old Average * # of Txns Tracked) + Current Gas Price) / (# of Txns Tracked + 1)
        movingAverageGasPrice =
            ((movingAverageGasPrice * movingAverageGasPriceCount) + gasPrice) / (movingAverageGasPriceCount + 1);

        // Increment the count
        movingAverageGasPriceCount++;
    }

    function getFee() internal view returns (uint24) {
        uint128 gasPrice = uint128(tx.gasprice);

        // if gasPrice > movingAverageGasPrice * 1.1, then half the fees
        if (gasPrice > (movingAverageGasPrice * 11) / 10) {
            return BASE_FEES / 2;
        }

        // if gasPrice < movingAverageGasPrice * 0.9, then double the fees
        if (gasPrice < (movingAverageGasPrice * 9) / 10) {
            return BASE_FEES * 2;
        }

        return BASE_FEES;
    }
}
