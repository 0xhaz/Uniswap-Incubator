// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

/**
 * @title JustInTimeHook
 * @notice When LP providers add liquidity to Uniswap they generally do so within a certain tick range. This liquidity is either "active" or "inactive"
 * If a liquidity position is across a tick range that includes the current tick value (i.e the liquidity covers the current price), that is "active".
 * Any liquidity position above or below that which doesn't include the current tick is inactive liquidity.
 * When swappers conduct swaps they tap into the active liquidity positions to facilitate their swaps. They take the token they're purchasing from the active liquidity
 * and settle the token they're selling there.
 * LP Rebalancing
 * As swaps happen, the price of the pool is also shifting. Positions that were active could become inactive if the price shifts enough, and previously inactive positions can become active.
 * This means that LPs who consistently want to be paid out LP fees need to periodically rebalance their liquidity (i.e update their tick range) to ensure their liqudity is considered active
 * Uniswap doesn't automatically rebalance positions for LPs, since some LPs may not want to provide that liquidity outside their predetermined range. This has spawned a whole nich area of protocols
 * which integrate with AMMs like Uniswap and perform automatic rebalancing for LPs based on defined criteria.
 * JIT Liquidity
 * This is a strategy that enables JIT liquidity on large trades with the aim of the LP attempting to make profit
 * The LP:
 * 1. Observes a large trade coming in
 * 2. Adds sizeable liquidity to the pool right before the swap concentrated in a single tick that the swap will be in range (i.e liquidity will be active)
 * 3. Lets the swap execute and receives a large portion of the LP fee since the swap will mostly (if not entirely) be facilitated by the LP's liquidity
 * 4. Removes the liquidity and fees accrued immediately
 * Economic of JIT Liquidity
 * For an LP to add JIT Liquidity, their expected profit must be positive. The LP's profit here comes from the difference between LP Fee earned and the cost of hedging their transaction
 * Assuming the LP decides to concentrate their liquidity in the tick the swap is taking place in:
 * The revenue they earn:
 * Revenue = Liquidity Supplied to Swap * AMM LP Fee Rate
 * Cost = (Liquidity Supplied to Swap * Fee Rate of other exchange)
 *        + Slippage on other exchange
 *        + Gase Fees for adding and removing JIT Liquidity on AMM
 * Example of Profitable Trade
 * 1. Assume an ETH/USDC pool with a 5bps fee tier (i.e 0.05% fees)
 * 2. Assume an alternative liquidity venue, e.g a CEX exists with ETH/USDC pool with 0.01% fees that has extremely deep liquidty available
 * 3. Assume spot price (price at current tick) is 1 ETH = 1000 USDC (for easier calculations)
 * 4. Assume spot price at CEX is also 1 ETH = 1000 USDC
 * Say a whale wants to sell 5000 ETH into the AMM pool. To execute the swap with no slippage, 5M USDC is required in liquidity at the current tick
 * LP adds 5M USDC to the pool right before the swap. Assume, without loss of generality and for simplicity, the whale's swap will 100% go through the LP's liquidity
 * Whale is charged 0.05% fees in the input token, i.e 2.5 ETH. The remaining 4977.5 ETH get swapped for 4.9975M USDC
 * The LP position now consist of 2500 USDC and 5000 ETH
 * Assuming now the LP also conducts a hedging trade at the CEX selling 5000 ETH at a 1bps fee with very deep liquidity available to them and they are able to get 4.9995M USDC for it after fees
 * Final LP balance = 5,002,000 USDC
 * Therefore, the LP made 2,000 USDC in profit in this trade
 */
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

/**
 * @notice Mechanism Design
 * We want the liquidity to be added just in time through beforeSwap and then removed afterSwap, so the hook must:
 * 1. Own the liquidity the LP plans to use for this strategy, allowing the hook to provision the liqudity automatically
 * 2. Have some logic to differentiate between a regular swap and a "large" swap, since this strategy is only profitable for large swaps
 * 3. If possible, have the ability to hedge the transactions
 */
contract JustInTimeHook is IUnlockCallback, BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for uint128;
    using StateLibrary for IPoolManager;

    /// @notice Thrown when trying to interact with a non-initialized pool
    error JIT__PoolNotInitialized();
    error JIT__TickSpacingNotDefault();
    error JIT__MinimumLiquidityNotMet();
    error JIT__SenderIsNotHook();
    error JIT__Expired();
    error JIT__TooMuchSlippage();

    uint128 private movingAverageGasPrice;
    uint104 private movingAverageGasPriceCount;

    /// @dev Min tick for full range with tick spacing of 60
    int24 private constant MIN_TICK = TickMath.MIN_TICK;
    /// @dev Max tick for full range with tick spacing of 60
    int24 private constant MAX_TICK = TickMath.MAX_TICK;

    int256 private constant MAX_INT = type(int256).max;
    uint16 private constant MINIMUM_LIQUIDITY = 1000;

    uint16 private constant LARGE_SWAP_THRESHOLD = 100; // 1%
    uint16 private constant MAX_BP = 10000; // 100%
    uint24 private constant BASE_FEES = 5000; // 0.5%

    struct PoolInfo {
        bool hasAccruedFees;
        bool JIT;
        address liquidityToken;
    }

    mapping(PoolId => PoolInfo) public poolInfo;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
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

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) public override returns (bytes4) {
        if (sender != address(this)) revert JIT__SenderIsNotHook();

        return this.beforeAddLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        public
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = getFee();
        poolManager.updateDynamicLPFee(key, fee);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta delta, bytes calldata)
        public
        override
        returns (bytes4, int128)
    {
        return (this.afterSwap.selector, 0);
    }

    //////////////////////// Helper Function ////////////////////////

    /**
     * @notice Adds liquidity to the pool just before a swap
     * @param key The pool key
     * @param params The liquidity parameters
     * @param hookData Arbitrary data for usage in the hook
     */
    function addJITLiquidity(
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external payable {}

    /**
     * @notice Regular swaps are swaps that are not large enough to warrant JIT liquidity
     * @param key The pool key
     * @return The swap fee
     */
    function _handleRegularSwap(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        uint160 sqrtPriceX96,
        uint128 liquidity
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        // Logic for regular swaps
        poolInfo[key.toId()].hasAccruedFees = true;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @notice Large swaps are swaps that are large enough to warrant JIT liquidity
     */
    function _handleLargeSwap(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        uint160 sqrtPriceX96,
        uint128 liquidity
    ) private returns (bytes4, BeforeSwapDelta, uint24) {
        // Logic for handling large swaps, including JIT-related actions
        BalanceDelta delta;
        bytes memory ZERO_BYTES = "";

        (delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -(liquidity.toInt256()),
                salt: 0
            }),
            ZERO_BYTES
        );

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // Update our moving average gas price
    function updateMovingAverage() internal {
        uint128 gasPrice = uint128(tx.gasprice);

        movingAverageGasPrice =
            ((movingAverageGasPrice * movingAverageGasPriceCount) + gasPrice) / (movingAverageGasPriceCount + 1);

        movingAverageGasPriceCount++;
    }

    function getFee() internal view returns (uint24) {
        uint128 gasPrice = uint128(tx.gasprice);

        /// @dev if gasPrice > movingAverageGasPrice * 1.
        if (gasPrice > (movingAverageGasPrice * 11) / 10) {
            return BASE_FEES / 2;
        }

        /// @dev if gasPrice < movingAverageGasPrice * 0.
        if (gasPrice < (movingAverageGasPrice * 9) / 10) {
            return BASE_FEES * 2;
        }

        return BASE_FEES;
    }

    /**
     * @notice Check liquidity for large swap or regular swap
     */
    function _rebalance(PoolKey memory key, int24 tickLower, int24 tickUpper) internal {
        PoolId poolId = key.toId();
        bytes memory ZERO_BYTES = "";

        /**
         * @notice Modifies the liquidity of a position in the pool
         * @dev This function can be used to increase or decrease the liquidity of a position in the pool
         * @param key The pool to modify liquidity in
         * @param params The parameters for modifying the liquidity
         * @param hookData The data to pass through to the add/removeLiquidity hooks
         * @return callerDelta The balance delta of the caller of modifyLiquidity. This is the total of both principal and fee deltas
         * @return feeDelta The balance delta of the fees generated in the liquidity range. Returned for informational purposes only
         */
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -(poolManager.getLiquidity(poolId).toInt256()),
                salt: 0
            }),
            ZERO_BYTES
        );

        /**
         * @notice Computes the sqrt price from the given amounts of token0 and token1
         * @param delta The delta of token0 and token1
         * @return sqrtPriceX96 The sqrt price from the given amounts of token0 and token1
         * @return liquidity The liquidity of the pool after the swap
         */
        uint160 newSqrtPriceX96 = (
            FixedPointMathLib.sqrt(
                FullMath.mulDiv(uint128(delta.amount1()), FixedPoint96.Q96, uint128(delta.amount0()))
            ) * FixedPointMathLib.sqrt(FixedPoint96.Q96)
        ).toUint160();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        /**
         * @notice Swaps token0 for token1 or token1 for token0 in the pool
         * @param key The pool to swap in
         * @param params The parameters for the swap
         * @param hookData The data to pass through to the swap hooks
         * @return amount0 The amount of token0 swapped
         */
        poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: newSqrtPriceX96 < sqrtPriceX96,
                amountSpecified: -MAX_INT - 1, // equivalent to type(int256).min
                sqrtPriceLimitX96: newSqrtPriceX96
            }),
            ZERO_BYTES
        );

        /**
         * @notice Computes the maximum amount of liquidity received for a given amount of token0, token1, the current
         * pool prices and the prices at the tick boundaries
         * @param sqrtPriceX96 A sqrt price representing the current pool prices
         * @param sqrtPriceAX96 A sqrt price representing the first tick boundary
         * @param sqrtPriceBX96 A sqrt price representing the second tick boundary
         * @param amount0 The amount of token0 being sent in
         * @param amount1 The amount of token1 being sent in
         * @return liquidity The maximum amount of liquidity received
         */
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            newSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(MIN_TICK),
            TickMath.getSqrtPriceAtTick(MAX_TICK),
            uint256(uint128(delta.amount0())),
            uint256(uint128(delta.amount1()))
        );

        (BalanceDelta balanceDeltaAfter,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: liquidity.toInt256(),
                salt: 0
            }),
            ZERO_BYTES
        );

        // Donate any "dust" from the sqrtRatio change as fees
        uint128 donateAmount0 = uint128(delta.amount0() + balanceDeltaAfter.amount0());
        uint128 donateAmount1 = uint128(delta.amount1() + balanceDeltaAfter.amount1());

        /**
         * @notice Donate the given currency amounts to the pool with the given pool key
         * @param key The key of the pool to donate to
         * @param amount0 The amount of currency0 to donate
         * @param amount1 The amount of currency1 to donate
         * @param hookData Arbitrary data for usage in the hook
         * @return BalanceDelta The delta of the caller after the donation
         */
        poolManager.donate(key, donateAmount0, donateAmount1, ZERO_BYTES);
    }

    function _nearestUsableTick(int24 tick_, uint24 tickSpacing) internal pure returns (int24 result) {
        result = int24(_divRound(int128(tick_), int128(int24(tickSpacing)))) * int24(tickSpacing);

        if (result < MIN_TICK) {
            result += int24(tickSpacing);
        } else if (result > MAX_TICK) {
            result -= int24(tickSpacing);
        }
    }

    function _divRound(int128 x, int128 y) internal pure returns (int128 result) {
        int128 quot = _div(x, y);
        result = quot >> 64;

        // Check if remainder is greater than 0.5
        if (quot % 2 ** 64 >= 0x8000000000000000) {
            result += 1;
        }
    }

    int128 private constant MIN_64x64 = -0x80000000000000000000000000000000; // -1
    int128 private constant MAX_64x64 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF; // 1

    function _div(int128 x, int128 y) internal pure returns (int128) {
        unchecked {
            require(y != 0); // Division by zero
            int256 result = (int256(x) << 64) / y;
            require(result >= MIN_64x64 && result <= MAX_64x64); // Overflow
            return int128(result);
        }
    }
}
