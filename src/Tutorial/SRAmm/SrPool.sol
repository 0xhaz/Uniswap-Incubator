// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {TickBitmap} from "v4-core/libraries/TickBitmap.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {SwapMath} from "v4-core/libraries/SwapMath.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Slot0} from "v4-core/types/Slot0.sol";
import {ProtocolFeeLibrary} from "v4-core/libraries/ProtocolFeeLibrary.sol";
import {LiquidityMath} from "v4-core/libraries/LiquidityMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {console} from "forge-std/console.sol";

library SrPool {
    using SafeCast for *;
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using SrPool for SrPoolState;
    using ProtocolFeeLibrary for uint24;
    using LPFeeLibrary for uint24;
    using CustomRevert for bytes4;

    /// @notice Info stored for each initialized individual tick
    struct TickInfo {
        // The total position liquidity that references this tick
        uint128 liquidityGross;
        // amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left)
        int128 liquidityNet;
        // fee growth per unit of liquidity on the other side of this tick (relative to the current tick)
        // only has relative meaning, not absolute - the value depends on when the tick is initialized
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
    }

    struct SrPoolState {
        Slot0 offer; // swapping token1 for token0
        Slot0 bid;
        uint128 liquidity;
        uint128 bidLiquidity;
        uint128 virtualBidLiquidity;
        uint128 virtualOfferLiquidity;
        uint160 slotStartSqrtPriceX96;
        mapping(int24 => TickInfo) ticks;
        mapping(int16 => uint256) tickBitmap;
        mapping(bytes32 => Position.Info) positions;
    }

    struct TickVirtualInfo {
        // the total virtual position liquidity that references this tick
        uint128 virtualLiquidityGross;
    }

    struct ModifyLiquidityParams {
        // the address that owns the position
        address owner;
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // any changes in liquidity
        int128 liquidityDelta;
        // the spacing between ticks
        int24 tickSpacing;
        // used to distinguish positions of the same owner, at the same tick range
        bytes32 salt;
    }

    struct ModifyLiquidityState {
        bool flippedLower;
        uint128 liquidityGrossAfterLower;
        bool flippedUpper;
        uint128 liquidityGrossAfterUpper;
    }

    /// @notice Thrown when tickLower is not below tickUpper
    /// @param tickLower The invalid tickLower
    /// @param tickUpper The invalid tickUpper
    error TicksMisordered(int24 tickLower, int24 tickUpper);

    /// @notice Thrown when tickLower is less than min tick
    /// @param tickLower The invalid tickLower
    error TickLowerOutOfBounds(int24 tickLower);

    /// @notice Thrown when tickUpper exceeds max tick
    /// @param tickUpper The invalid tickUpper
    error TickUpperOutOfBounds(int24 tickUpper);

    /// @notice For the tick spacing, the tick has too much liquidity
    error TickLiquidityOverflow(int24 tick);

    /// @notice Thrown when interacting with an uninitialized tick that must be initialized
    /// @param tick The uninitialized tick
    error TickNotInitialized(int24 tick);

    /// @notice Thrown when trying to initialize an already initialized pool
    error PoolAlreadyInitialized();

    /// @notice Thrown when trying to interact with non-initialized pool
    error PoolNotInitialized();

    /// @notice Thrown when sqrtPriceLimitX96 on a swap has already exceeded its limit
    /// @param sqrtPriceCurrentX96 The invalid, already surpassed sqrtPriceLimitX96
    /// @param sqrtPriceLimitX96 The surpassed price limit
    error PriceLimitAlreadyExceeded(uint160 sqrtPriceCurrentX96, uint160 sqrtPriceLimitX96);

    /// @notice Thrown when sqrtPriceLimitX96 lies outside of valid tick/price range
    /// @param sqrtPriceLimitX96 The invalid, out-of-bounds sqrtPriceLimitX96
    error PriceLimitOutOfBounds(uint160 sqrtPriceLimitX96);

    /// @notice Thrown by donate if there is currently 0 liquidity, since the fees will not go to any liquidity providers
    error NoLiquidityToReceiveFees();

    /// @notice Thrown when trying to swap with max lp fee and specifying an output amount
    error InvalidFeeForExactOut();

    /// @dev Common checks for valid tick inputs
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        if (tickLower >= tickUpper) {
            TicksMisordered.selector.revertWith(tickLower, tickUpper);
        }
        if (tickLower < TickMath.MIN_TICK) {
            TickLowerOutOfBounds.selector.revertWith(tickLower);
        }
        if (tickUpper > TickMath.MAX_TICK) {
            TickUpperOutOfBounds.selector.revertWith(tickUpper);
        }
    }

    function initialize(SrPoolState storage self, uint160 sqrtPriceX96, uint24 protocolFee, uint24 lpFee)
        internal
        returns (int24 bidTick, int24 offerTick)
    {
        if (self.bid.sqrtPriceX96() != 0 && self.offer.sqrtPriceX96() != 0) {
            PoolAlreadyInitialized.selector.revertWith();
        }

        // set same price for both initially
        bidTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        offerTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        self.bid = Slot0.wrap(bytes32(0)).setSqrtPriceX96(sqrtPriceX96).setTick(bidTick).setProtocolFee(protocolFee)
            .setLpFee(lpFee);
        self.offer = Slot0.wrap(bytes32(0)).setSqrtPriceX96(sqrtPriceX96).setTick(offerTick).setProtocolFee(protocolFee)
            .setLpFee(lpFee);
    }

    function initializeAtNewSlot(SrPoolState storage self) internal returns (Slot0 bid) {
        Slot0 offerLast = self.offer;

        // should be reset at every slot change
        self.slotStartSqrtPriceX96 = offerLast.sqrtPriceX96();

        self.bid = Slot0.wrap(bytes32(0)).setSqrtPriceX96(offerLast.sqrtPriceX96()).setTick(offerLast.tick());
        return self.bid;
    }

    /// @notice Effect changes to a position in a pool
    /// @dev PoolManager checks that the pool is initialized before calling this function
    /// @param params the position details and the change to the position's liquidity to effect
    /// @return delta of the token balances of the pool, from the liquidity change
    /// @return feeDelta the fees generated by the liquidity range
    function modifyLiquidity(SrPoolState storage self, ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta, BalanceDelta feeDelta)
    {
        int128 liquidityDelta = params.liquidityDelta;
        int24 tickLower = params.tickLower;
        int24 tickUpper = params.tickUpper;
        checkTicks(tickLower, tickUpper);

        {
            ModifyLiquidityState memory state;

            // If we need to update the ticks, do it
            if (liquidityDelta != 0) {
                (state.flippedLower, state.liquidityGrossAfterLower) =
                    updateTick(self, tickLower, liquidityDelta, false);
                (state.flippedUpper, state.liquidityGrossAfterUpper) = updateTick(self, tickUpper, liquidityDelta, true);

                // `>` and `>=` are logivally equivalent here but `>=` is cheaper
                if (liquidityDelta >= 0) {
                    uint128 maxLiquidityPerTick = tickSpacingToMaxLiquidityPerTick(params.tickSpacing);
                    if (state.liquidityGrossAfterLower > maxLiquidityPerTick) {
                        TickLiquidityOverflow.selector.revertWith(tickLower);
                    }
                    if (state.liquidityGrossAfterUpper > maxLiquidityPerTick) {
                        TickLiquidityOverflow.selector.revertWith(tickUpper);
                    }
                }

                if (state.flippedLower) {
                    self.tickBitmap.flipTick(tickLower, params.tickSpacing);
                }
                if (state.flippedUpper) {
                    self.tickBitmap.flipTick(tickUpper, params.tickSpacing);
                }
            }

            {
                Position.Info storage position = self.positions.get(params.owner, tickLower, tickUpper, params.salt);
                (uint256 feesOwed0, uint256 feesOwed1) = position.update(
                    liquidityDelta,
                    0, // feeGrowthInside0X128
                    0 // feeGrowthInside1X128
                );

                // Fees earned from LPing are added to the user's currency delta
                feeDelta = toBalanceDelta(feesOwed0.toInt128(), feesOwed1.toInt128());
            }

            // clear any tick data that is no longer needed
            if (liquidityDelta < 0) {
                if (state.flippedLower) {
                    clearTick(self, tickLower);
                }
                if (state.flippedUpper) {
                    clearTick(self, tickUpper);
                }
            }
        }

        if (liquidityDelta != 0) {
            Slot0 _slot0 = self.offer;
            (int24 tick, uint160 sqrtPriceX96) = (_slot0.tick(), _slot0.sqrtPriceX96());
            if (tick < tickLower) {
                // current tick is below the passed range; liquidity can only become in range by crossing from left to right
                // when we'll need more currency0 (it's becoming more valuable) so user must provide it
                delta = toBalanceDelta(
                    SqrtPriceMath.getAmount0Delta(
                        TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidityDelta
                    ).toInt128(),
                    0
                );
            } else if (tick < tickUpper) {
                delta = toBalanceDelta(
                    SqrtPriceMath.getAmount0Delta(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickUpper), liquidityDelta)
                        .toInt128(),
                    SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceX96, liquidityDelta)
                        .toInt128()
                );

                self.liquidity = LiquidityMath.addDelta(self.liquidity, liquidityDelta);

                // only allow modification before at start of new slot
                self.bidLiquidity = self.liquidity;
            } else {
                // current tick is above the passed range; liquidity can only become in range by crossing from right to left
                // when we'll need more currency1 (it's becoming more valuable) so user must provide it
                delta = toBalanceDelta(
                    0,
                    SqrtPriceMath.getAmount1Delta(
                        TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidityDelta
                    ).toInt128()
                );
            }
        }
    }

    // The top level state of the swap, the results of which are recorded in storage at the end
    struct SrSwapState {
        // The amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // The amount already swapped in/out of the input/output asset
        int256 amountCalculated;
        // Current sqrt(price)
        uint160 sqrtPriceX96;
        // virtual bid sqrt(price)
        uint160 sqrtBidPriceX96;
        // slotStart price
        uint160 slotStartSqrtPriceX96;
        // the tick associated with the current price
        int24 tick;
        // the tick associated with the virtual bid price
        int24 bidTick;
        // the global fee growth of the input token
        uint256 feeGrowthGlobalX128;
        // the current liquidity in range
        uint128 liquidity;
        // the current liqudity at bid price
        uint128 bidLiquidity;
        // the current virtual liquidity at bid price current slot
        uint128 virtualBidLiquidity;
        // the current virtual liquidity at offer price current slot
        uint128 virtualOfferLiquidity;
    }

    struct StepComputations {
        // the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        // how much is being swapped in this step
        uint256 amountIn;
        // how much is being swapped out in this step
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
    }

    struct SwapParams {
        int24 tickSpacing;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        uint24 lpFeeOverride;
    }

    /// @notice Executes a swap agains the state, and returns the amonut deltas of the pool
    /// @dev PoolManager checks that the pool is initialized before calling
    function swap(SrPoolState storage self, SwapParams memory params)
        internal
        returns (BalanceDelta result, uint256 feeForProtocol, uint24 swapFee, SrSwapState memory srSwapState)
    {
        Slot0 offerSlotStart = self.offer;
        Slot0 bidSlotStart = self.bid;

        // console.log("zeroForOne");
        // console.log(params.zeroForOne);
        // console.log(offerSlotStart.sqrtPriceX96());
        // console.log(bidSlotStart.sqrtPriceX96());

        // if we are swapping zeroForOne token0 for token1
        // ticks moves right to left, considered as a sell trade at bidPrice
        bool zeroForOne = params.zeroForOne;
        srSwapState.slotStartSqrtPriceX96 = self.slotStartSqrtPriceX96;

        uint128 liquidityStart = self.liquidity;
        // retrieve last value of virtual liquidity
        // should be 0 at beginning of each slot
        // this includes the actual liquidity at the bid tick
        // if virtual bid liquidity is zero, that means its not initialized before
        // initially it will be same as offerTick
        uint128 bidLiquidityStart = self.bidLiquidity;
        // uint128 virtualBidLiquidityStart = self.virtualBidliquidity;
        // uint128 virtualOfferLiquidityStart = self.virtualOfferliquidity;
        //
        // if (self.virtualBidliquidity == 0) {
        //     self.virtualBidliquidity = liquidityStart;
        //     virutalBidLiquidityStart = liquidityStart;
        // } else {
        //     virutalBidLiquidityStart = self.virtualBidliquidity;
        // }

        //  virutalBidLiquidityStart = self.virtualBidliquidity == 0
        //     ? self.liquidity // + self.virtualBidliquidity
        //     : self.virtualBidliquidity;
        console.log("virtualLiquidity");
        console.log(bidLiquidityStart);

        srSwapState.amountSpecifiedRemaining = params.amountSpecified;
        srSwapState.amountCalculated = 0;

        // loading from pool state to swap state
        srSwapState.sqrtPriceX96 = offerSlotStart.sqrtPriceX96();
        srSwapState.tick = offerSlotStart.tick();

        // loading bid side from pool state to swap state
        srSwapState.sqrtPriceX96 = bidSlotStart.sqrtPriceX96();
        srSwapState.bidTick = bidSlotStart.tick();

        srSwapState.liquidity = liquidityStart;
        srSwapState.bidLiquidity = bidLiquidityStart;
        // we need to maintain virtual liquidity for both bid and offer
        srSwapState.virtualOfferLiquidity = self.virtualOfferLiquidity;
        srSwapState.virtualBidLiquidity = self.virtualBidLiquidity;

        // if the beforeSwap hook returned a valid fee override, use that as the LP fee, otherwise load from storage
        {
            swapFee = offerSlotStart.lpFee();
        }

        bool exactInput = params.amountSpecified < 0;

        if (!exactInput && (swapFee == LPFeeLibrary.MAX_LP_FEE)) {
            InvalidFeeForExactOut.selector.revertWith();
        }

        if (params.amountSpecified == 0) {
            return (BalanceDeltaLibrary.ZERO_DELTA, 0, swapFee, srSwapState);
        }

        // zeroForOne is selling at the bid price
        // so we use bidSlot for this
        if (zeroForOne) {
            if (params.sqrtPriceLimitX96 >= bidSlotStart.sqrtPriceX96()) {
                PriceLimitAlreadyExceeded.selector.revertWith(bidSlotStart.sqrtPriceX96(), params.sqrtPriceLimitX96);
            }
            if (params.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) {
                PriceLimitOutOfBounds.selector.revertWith(params.sqrtPriceLimitX96);
            }
        } else {
            if (params.sqrtPriceLimitX96 <= offerSlotStart.sqrtPriceX96()) {
                PriceLimitAlreadyExceeded.selector.revertWith(offerSlotStart.sqrtPriceX96(), params.sqrtPriceLimitX96);
            }
            if (params.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
                PriceLimitOutOfBounds.selector.revertWith(params.sqrtPriceLimitX96);
            }
        }

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        SrSwapState memory newSrSwapState;

        newSrSwapState = computeSwapStepForOneSide(self, params, srSwapState, zeroForOne);
        // console.log("amountSpecified Post BidSide");
        // console.logInt(srSwapState.amountCalculated.toInt128());
        // console.logInt(srSwapState.amountSpecifiedRemaining);

        // moving right to left and offer side is greater than slot start
        // update offerside
        if (zeroForOne && srSwapState.slotStartSqrtPriceX96 < srSwapState.sqrtBidPriceX96) {
            newSrSwapState = computeSwapStepForOneSide(self, params, srSwapState, false);
        }

        // moving left to right and bid side is greater less than slot start
        // update bidside
        if (zeroForOne && srSwapState.slotStartSqrtPriceX96 < srSwapState.sqrtBidPriceX96) {
            newSrSwapState = computeSwapStepForOneSide(self, params, srSwapState, true);
        }

        // console.log("amountSpecified Post SellSide");
        // console.logInt(srSwapState.amountCalculated.toInt128());
        // console.logInt(srSwapState.amountSpecifiedRemaining);

        srSwapState = newSrSwapState;

        self.offer = offerSlotStart.setTick(srSwapState.tick).setSqrtPriceX96(srSwapState.sqrtPriceX96);
        self.bid = bidSlotStart.setTick(srSwapState.bidTick).setSqrtPriceX96(srSwapState.sqrtBidPriceX96);

        // console.log("Ticks post swap");
        // console.logInt(self.offer.tick());
        // console.logInt(self.bid.tick());

        {
            // update liquidity if it changed
            if (liquidityStart != srSwapState.liquidity) {
                self.liquidity = srSwapState.liquidity;
            }

            if (self.virtualOfferLiquidity != srSwapState.virtualOfferLiquidity) {
                self.virtualOfferLiquidity = srSwapState.virtualOfferLiquidity;
            }

            // update new virtual liquidity in the state/storage
            if (bidLiquidityStart != srSwapState.bidLiquidity) {
                self.bidLiquidity = srSwapState.bidLiquidity;
            }

            if (self.virtualBidLiquidity != srSwapState.virtualBidLiquidity) {
                self.virtualBidLiquidity = srSwapState.virtualBidLiquidity;
            }
        }

        unchecked {
            if (zeroForOne != exactInput) {
                result = toBalanceDelta(
                    srSwapState.amountCalculated.toInt128(),
                    (params.amountSpecified - srSwapState.amountSpecifiedRemaining).toInt128()
                );
            } else {
                result = toBalanceDelta(
                    (params.amountSpecified - srSwapState.amountSpecifiedRemaining).toInt128(),
                    srSwapState.amountCalculated.toInt128()
                );
            }
        }
    }

    function computeSwapStepForOneSide(
        SrPoolState storage self,
        SwapParams memory params,
        SrSwapState memory srSwapState,
        bool isBidSide
    ) internal returns (SrSwapState memory) {
        bool zeroForOne = params.zeroForOne;
        StepComputations memory step;
        uint24 swapFee = self.offer.lpFee();
        bool exactInput = params.amountSpecified < 0;

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        while (
            // short circuit
            !(
                srSwapState.amountSpecifiedRemaining == 0 || srSwapState.sqrtBidPriceX96 == params.sqrtPriceLimitX96
                    || srSwapState.sqrtPriceX96 == params.sqrtPriceLimitX96
            )
        ) {
            step.sqrtPriceStartX96 = isBidSide ? srSwapState.sqrtBidPriceX96 : srSwapState.sqrtPriceX96;

            // console.log("computeSwapStepForOneSide: step.sqrtPriceStartX96");
            // console.log(step.sqrtPriceStartX96);

            (step.tickNext, step.initialized) = self.tickBitmap.nextInitializedTickWithinOneWord(
                isBidSide ? srSwapState.bidTick : srSwapState.tick, params.tickSpacing, zeroForOne
            );

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (step.tickNext <= TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            }

            if (step.tickNext >= TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(step.tickNext);

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted

            uint160 computedSqrtPriceX96;
            // compute steps
            (computedSqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                isBidSide ? srSwapState.sqrtBidPriceX96 : srSwapState.sqrtPriceX96,
                SwapMath.getSqrtPriceTarget(zeroForOne, step.sqrtPriceNextX96, params.sqrtPriceLimitX96),
                // problem with this approach is that when the price moves
                // from left to right and goes beyond the first tick spacing window
                // will appropriately adjust the liquidity
                // should we just mantain virtual separately without liquidity?
                isBidSide
                    ? srSwapState.virtualBidLiquidity + srSwapState.bidLiquidity
                    : srSwapState.liquidity + srSwapState.virtualOfferLiquidity, // includes virtual and real liquidity
                srSwapState.amountSpecifiedRemaining,
                swapFee
            );

            // we also compute price for the sell offer as it should decrease as well
            // in accordance with xy=k curve

            if (isBidSide) {
                srSwapState.sqrtBidPriceX96 = computedSqrtPriceX96;
            } else {
                srSwapState.sqrtPriceX96 = computedSqrtPriceX96;
            }

            if (!exactInput) {
                unchecked {
                    srSwapState.amountSpecifiedRemaining -= step.amountOut.toInt256();
                }
                srSwapState.amountCalculated =
                    srSwapState.amountCalculated - (step.amountIn + step.feeAmount).toInt256();
            } else {
                // safe because we test that amountSpecified > amountIn + feeAmount in SwapMath
                unchecked {
                    srSwapState.amountSpecifiedRemaining += (step.amountIn + step.feeAmount).toInt256();
                }

                srSwapState.amountCalculated = srSwapState.amountCalculated + step.amountOut.toInt256();
            }

            // ignore for now - update global fee tracker
            // shift tick if we reached the next price
            // zeroForOne - selling toke0 at bidPrice
            // tick moves right to left

            // we want to reduce virtual liquidity as well, apart from actual liquidity
            // we want to reduce the bid price and also reduce offer price normally
            // bidPrice will become equal to offerPrice at next slot
            // shift tick if we reached the next price

            bool hasPricedMoveToNextTick = isBidSide
                ? srSwapState.sqrtBidPriceX96 == step.sqrtPriceNextX96
                : srSwapState.sqrtPriceX96 == step.sqrtPriceNextX96;

            if (hasPricedMoveToNextTick) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    // skip handling feeGlobalGrowth
                    int128 liquidityNet = SrPool.crossTick(self, step.tickNext);
                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    unchecked {
                        if (zeroForOne) liquidityNet = -liquidityNet;
                    }

                    // maintain virtual liquidity for bid tick
                    if (isBidSide) {
                        // verify the math here
                        srSwapState.bidLiquidity = LiquidityMath.addDelta(srSwapState.bidLiquidity, liquidityNet);

                        // since the tick is shifted make virtual liquidity 0
                        // better to save virtual liquidity at tick info
                        srSwapState.virtualBidLiquidity = 0;

                        // increase liquidity on offer side if price at start point
                        if (srSwapState.slotStartSqrtPriceX96 == srSwapState.sqrtBidPriceX96) {
                            srSwapState.virtualOfferLiquidity += uint128(
                                SqrtPriceMath.getAmount0Delta(
                                    srSwapState.sqrtBidPriceX96, step.sqrtPriceStartX96, srSwapState.bidLiquidity, true
                                ).toInt128()
                            );
                        }
                    } else {
                        srSwapState.liquidity = LiquidityMath.addDelta(srSwapState.liquidity, liquidityNet);

                        srSwapState.virtualOfferLiquidity = 0;

                        // increase liquidity on bid side only if price is at slot start price
                        if (srSwapState.slotStartSqrtPriceX96 == srSwapState.sqrtBidPriceX96) {
                            srSwapState.virtualBidLiquidity += uint128(
                                SqrtPriceMath.getAmount1Delta(
                                    step.sqrtPriceStartX96, srSwapState.sqrtPriceX96, srSwapState.liquidity, true
                                ).toInt128()
                            );
                        }
                    }
                }

                // Equivalent to `state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;`
                unchecked {
                    // cannot cast a bool to an int24 in Solidity
                    int24 _zeroForOne;
                    assembly {
                        _zeroForOne := zeroForOne
                    }
                    // validate
                    if (isBidSide) {
                        srSwapState.bidTick = step.tickNext - _zeroForOne;
                    } else {
                        srSwapState.tick = step.tickNext - _zeroForOne;
                    }
                }
            } else if (isBidSide && srSwapState.sqrtBidPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e already transitioned ticks), and haven't moved
                srSwapState.bidTick = TickMath.getTickAtSqrtPrice(srSwapState.sqrtBidPriceX96);

                if (srSwapState.slotStartSqrtPriceX96 == srSwapState.sqrtBidPriceX96) {
                    console.log(srSwapState.sqrtBidPriceX96);
                    console.log(step.sqrtPriceStartX96);
                    srSwapState.virtualOfferLiquidity += uint128(
                        SqrtPriceMath.getAmount0Delta(
                            srSwapState.sqrtBidPriceX96, step.sqrtPriceStartX96, srSwapState.bidLiquidity, true
                        ).toInt128()
                    );
                }
            }
            // we also want to adjust sell price
            else if (!isBidSide && srSwapState.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e already transitioned ticks), and haven't moved
                srSwapState.tick = TickMath.getTickAtSqrtPrice(srSwapState.sqrtPriceX96);

                if (srSwapState.slotStartSqrtPriceX96 == srSwapState.sqrtBidPriceX96) {
                    srSwapState.virtualBidLiquidity += uint128(
                        SqrtPriceMath.getAmount1Delta(
                            step.sqrtPriceStartX96, srSwapState.sqrtPriceX96, srSwapState.liquidity, true
                        ).toInt128()
                    );
                }
            }
        }
        return (srSwapState);
    }

    /// @notice Updates a tick and returns true if the tick was flipped from initialized to uninitialized or vice versa
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The tick that will be updated
    /// @param liquidityDelta A new amount of liquidity to be added (subtracted) when tick is crossed from left to right (right to left)
    /// @param upper true for updating a position's upper tick, false for updating a position's lower tick
    /// @return flipped Whether the tick was flipped from initialized to uninitialized or vice versa
    /// @return liquidityGrossAfter The total amount of liquidity for all positions that references the tick after the update
    function updateTick(SrPoolState storage self, int24 tick, int128 liquidityDelta, bool upper)
        internal
        returns (bool flipped, uint128 liquidityGrossAfter)
    {
        TickInfo storage info = self.ticks[tick];

        uint128 liquidityGrossBefore;
        int128 liquidityNetBefore;

        assembly {
            // load first slot of info which contains liquidityGross and liquidityNet packed
            // where the top 128 bits are liquidityNet and the bottom 128 bits are liquidityGross
            let liquidity := sload(info.slot)
            // slice off top 128 bits of liquidity (liquidityNet) to get just liquidityGross
            liquidityGrossBefore := shr(128, shl(128, liquidity))
            // signed shift right 128 bits to get just liquidityNet
            liquidityNetBefore := sar(128, liquidity)
        }

        liquidityGrossAfter = LiquidityMath.addDelta(liquidityGrossBefore, liquidityDelta);

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            // by convention, we assume that all growth before a tick was initialized happened below the tick
            // int24 currentTick = isBidTick ? self.bid.tick() : self.offer.tick();
            // if (tick <= currentTick) {
            //   info.feeGrowthOutside0X128 = self.feeGrowthGlobal0X128;
            //   info.feeGrowthOutside1X128 = self.feeGrowthGlobal1X128;
            // }
        }

        // When the lower (upper) tick is crossed left to right (right to left), liquidity must be added (removed)
        int128 liquidityNet = upper ? liquidityNetBefore - liquidityDelta : liquidityNetBefore + liquidityDelta;

        assembly {
            // liquidityGrossAfter and liquidityNet are packed into a single storage slot of `info`
            // So we can store them with a single sstore by packing them ourselves first
            sstore(
                info.slot,
                // bitwise OR to pack liquidityGrossAfter and liquidityNet
                or(
                    // liquidityGross is in the low bits, upper bits are zeroed
                    liquidityGrossAfter,
                    // shift liquidityNet to take the upper bits and lower bits get filled with 0
                    shl(128, liquidityNet)
                )
            )
        }
    }

    /// @notice Derives max liquidity per tick from given tick spacing
    /// @dev Executed within the pool constructor
    /// @param tickSpacing The amount of required tick separation, realized in multiples of `tickSpacing`
    ///  e.g a tickSpacing of 3 requires ticks to be initialized every 3rd tick i.e, ... , -6, -3, 0, 3, 6, ...
    /// @return result The max liquidity per tick
    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128 result) {
        // Equivalent to:
        // int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        // int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        // uint24 numTicks = uint24((maxTick - minTick) / tickSpacing) + 1;
        // return type(uint128).max / numTicks;
        int24 MAX_TICK = TickMath.MAX_TICK;
        int24 MIN_TICK = TickMath.MIN_TICK;
        // tick spacing will never be 0 since TickMath.MIN_TICK_SPACING is 1
        assembly {
            let minTick := mul(sdiv(MIN_TICK, tickSpacing), tickSpacing)
            let maxTick := mul(sdiv(MAX_TICK, tickSpacing), tickSpacing)
            let numTicks := add(sdiv(sub(maxTick, minTick), tickSpacing), 1)
            result := div(sub(shl(128, 1), 1), numTicks)
        }
    }

    /// @notice Reverts if the given pool has not been initialized
    function checkPoolInitialized(SrPoolState storage self) internal view {
        if (self.bid.sqrtPriceX96() == 0 && self.offer.sqrtPriceX96() == 0) {
            PoolNotInitialized.selector.revertWith();
        }
    }

    /// @notice Clears tick data
    /// @param self The mapping containing all initialized tick information for initialized ticks
    /// @param tick The tick that will be cleared
    function clearTick(SrPoolState storage self, int24 tick) internal {
        delete self.ticks[tick];
    }

    /// @notice Transitions to next tick as needed by price movement
    /// @param self The pool state struct
    /// @param tick The destination tick of the transition
    /// @return liquidityNet The amount of liquidity added (subtracted) when tick is crossed from left to right (right to left)
    function crossTick(SrPoolState storage self, int24 tick) internal view returns (int128 liquidityNet) {
        unchecked {
            TickInfo storage info = self.ticks[tick];
            liquidityNet = info.liquidityNet;
        }
    }
}
