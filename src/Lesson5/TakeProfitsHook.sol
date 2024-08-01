// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

/**
 * @title TakeProfitsHook
 * @notice An onchain orderbook directly integrated into Uniswap through a hook
 * @dev a take-profit is a type of order where the user wants to sell a token once it's price
 * increases to hit a certain price. For Example, if ETH is currently trading at 3,500 USDC
 * I can place a take-profit order that would represent something like "Sell 1 ETH when it's
 * trading at 4,000 USDC". This is useful for traders who want to automate their trading
 *
 * Mechanism Design:
 * - Ability to place an order
 * - Ability to cancel an order after placing (if not filled yet)
 * - Ability to withdraw/redeem tokens after order is filled
 *
 * Assume a pool of two tokens A and B and assume A is Token 0 and B is Token 1. Let's say current
 * tick of the pool is tick = 600, i.e A is more expensive than B
 *
 * There are two types of "take profit" orders possible here:
 * 1. Sell some amount of A when price of A goes up further
 * 2. Sell some amount of B when the price of B goes up
 *
 * For case(1) - a price increase of A is represented by the tick of the pool increasing, since A is Token 0
 * For case(2) - a price increase of B is represented by the tick of the pool decreasing, since B is Token 1
 *
 * ERC-1155 is used to issue "claim" tokens to the users proportional to how many input tokens they provided for their order,
 * and will use that to calculate how many output tokens they have available to claim
 *
 */
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

contract TakeProfitsHook is BaseHook, ERC1155 {
    // StateLibrary is new here and we haven't seen that before
    // It's used to add helper functions to the PoolManager to read
    // storage values
    // In this case, we use it for accessing `currentTick` values
    // from the pool manager
    using StateLibrary for IPoolManager;

    // PoolIdLibrary used to convert PoolKeys to IDs
    using PoolIdLibrary for PoolKey;
    // Used to represent Currency types and helper functions like `.isNative()`
    using CurrencyLibrary for Currency;
    // Used for helpful math operations like `mulDiv`
    using FixedPointMathLib for uint256;

    // Nested mapping to store pending orders based on position
    // e.g pendingOrders[poolKey.toId()][tickToSellAt][zeroForOne] = inputTokensAmount
    mapping(PoolId poolId => mapping(int24 tickToSellAt => mapping(bool zeroForOne => uint256 inputAmount))) public
        pendingOrders;

    // Mapping to store the position as a uint256 to use it as the Token ID for ERC-1155 claim tokens
    mapping(uint256 positionId => uint256 claimsSupply) public claimTokensSupply;

    // Mapping to redeem output tokens
    mapping(uint256 positionId => uint256 outputClaimable) public claimableOutputTokens;

    // Errors
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();

    // Constructor
    constructor(IPoolManager _manager, string memory _uri) BaseHook(_manager) ERC1155(_uri) {}

    // BaseHook Functions
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick, bytes calldata)
        external
        override
        onlyByPoolManager
        returns (bytes4)
    {
        return this.afterInitialize.selector;
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override onlyByPoolManager returns (bytes4, int128) {
        return (this.afterSwap.selector, 0);
    }

    ////////////////////////// Helper Functions //////////////////////////
    /**
     * @notice Getting the closest lower tick that is actually usable given an arbitrary tick value
     */
    function getLowerUsableTick(int24 tick, int24 tickSpacing) private pure returns (int24) {
        // E.g tickSpacing = 60, tick = -100
        // closest usable tick rounded-down will be -120

        // intervals = -100/60 = -1 (integer division)
        int24 intervals = tick / tickSpacing;

        // since tick < 0, we round `intervals` down to -2
        // if tick > 0, `intervals` is fine as it is
        if (tick < 0 && tick % tickSpacing != 0) intervals--; // round towards negative infinity

        // actual usable tick, then is intervals * tickSpacing
        // i.e -2 * 60 = -120
        return intervals * tickSpacing;
    }

    function getPositionId(PoolKey calldata key, int24 tick, bool zeroForOne) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }

    function placeOrder(PoolKey calldata key, int24 tickToSellAt, bool zeroForOne, uint256 inputAmount)
        external
        returns (int24)
    {
        // Get lower actually usable tick given `tickToSellAt`
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);

        // Create a pending order
        pendingOrders[key.toId()][tick][zeroForOne] += inputAmount;

        // Mint claim tokens to user equal to their `inputAmount`
        uint256 positionId = getPositionId(key, tick, zeroForOne);
        claimTokensSupply[positionId] += inputAmount;
        _mint(msg.sender, positionId, inputAmount, "");

        // Depending on direction of swap, we select the proper input token
        // and request a transfer of those tokens to the hook contract
        address sellToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(sellToken).transferFrom(msg.sender, address(this), inputAmount);

        // Return the tick at which the order was actually placed
        return tick;
    }

    /**
     * @notice Cancel an order if it hasn't been filled yet
     * @dev Delete the pending order from the mapping, burn the claim tokens
     * reduce the claim token total supply, and send their input tokens back to them
     */
    function cancelOrder(PoolKey calldata key, int24 tickToSellAt, bool zeroForOne) external {
        // Get lower actually usable tick given `tickToSellAt`
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 positionId = getPositionId(key, tick, zeroForOne);

        // Check how many claim tokens they have for this position
        uint256 positionTokens = balanceOf(msg.sender, positionId);
        if (positionTokens == 0) revert InvalidOrder();

        // Remove their `positionTokens` worth of position from pending orders
        // NOTE: We don't want to zero this out directly becuase other users may have the same position
        pendingOrders[key.toId()][tick][zeroForOne] -= positionTokens;
        // Reduce claim token total supply and burn their share
        claimTokensSupply[positionId] -= positionTokens;
        _burn(msg.sender, positionId, positionTokens);

        // Send them their input token
        Currency token = zeroForOne ? key.currency0 : key.currency1;
        token.transfer(msg.sender, positionTokens);
    }

    /**
     * @notice Redemption of output tokens after an order has been filled
     * @dev What does the redeem output tokens back out:
     * 1. We need to store the amount of output tokens that are redeemable a specific position
     * 2. The user has claim tokens equivalent to their amount
     * 3. We calculate their share of output tokens
     * 4. Reduce that amount from the redeemable output tokens storage value
     * 5. Burn their claim tokens
     * 6. Transfer the output tokens to them
     * @dev How do we calculate the user's share of output tokens:
     * 1. positionTokens = amount of claimable input tokens they have. This is equal to how many input tokens they provided
     * 2. totalClaimableForPosition = amount of output tokens we have from executing this position
     * (not necessarily just for this user, but all users who placed this order)
     * 3. totalInputAmountForPosition = total supply of input tokens for this tokens for this position placed across limit orders
     * we are tracking (across all users)
     *
     * The user's output token amount then is a percentage of the total claimable output tokens that is
     * proportional to their share of input tokens for this position
     *
     * User's % share of input amount = positionTokens / totalInputAmountForPosition
     * User's share of output tokens = totalClaimableForPosition * (positionTokens / totalInputAmountForPosition)
     * Which is equal to (positionTokens * totalClaimableForPosition) / totalInputAmountForPosition
     */
    function redeem(PoolKey calldata key, int24 tickToSellAt, bool zeroForOne, uint256 inputAmountToClaimFor)
        external
    {
        // Get lower actually usable tick for their order
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 positionId = getPositionId(key, tick, zeroForOne);

        // If no output tokens can be claimed yet i.e order hasn't been filled throw error
        if (claimableOutputTokens[positionId] == 0) revert NothingToClaim();

        // they must have claim tokens >= inputAmountToClaimFor
        uint256 positionTokens = balanceOf(msg.sender, positionId);
        if (positionTokens < inputAmountToClaimFor) revert NotEnoughToClaim();

        uint256 totalClaimableForPosition = claimableOutputTokens[positionId];
        uint256 totalInputAmountForPosition = claimTokensSupply[positionId];

        // outputAmount = (inputAmountToClaimFor * totalClaimableForPosition) / totalInputAmountForPosition
        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(totalClaimableForPosition, totalInputAmountForPosition);

        // Reduce claimable output tokens amount
        // Reduce claim token total supply for position
        // Burn claim tokens
        claimableOutputTokens[positionId] -= outputAmount;
        claimTokensSupply[positionId] -= inputAmountToClaimFor;
        _burn(msg.sender, positionId, inputAmountToClaimFor);

        // Transfer output tokens to user
        Currency token = zeroForOne ? key.currency1 : key.currency0;
        token.transfer(msg.sender, outputAmount);
    }

    ////////////////////////// Internal Functions //////////////////////////

    /**
     * @notice Execute an order in afterSwap
     * @dev Assuming the order information is provided to us by a higher-level function (afterSwap)
     * 1. Call poolManager.swap to conduct the actual swap. This will return a BalanceDelta
     * 2. Settle all balances with the pool manager
     * 3. Remove the swapped amount of input tokens from the pendingOrders mapping
     * 4. Increase the amount of output tokens now claimable for this position in the claimableOutputTokens mapping
     */
    function swapAndSettleBalances(PoolKey calldata key, IPoolManager.SwapParams memory params)
        internal
        returns (BalanceDelta)
    {
        // Conduct the swap inside the Pool Manager
        BalanceDelta delta = poolManager.swap(key, params, "");

        // If we just did a zeroForOne swap
        // We need to send Token 0 to PM, and receive Token 1 from PM
        if (params.zeroForOne) {
            // Negative Value => Money leaving user's wallet
            // Settle with PoolManager
            if (delta.amount0() < 0) {
                _settle(key.currency0, uint128(-delta.amount0()));
            }
        } else {
            if (delta.amount1() < 0) {
                _settle(key.currency1, uint128(-delta.amount1()));
            }

            if (delta.amount0() > 0) {
                _settle(key.currency0, uint128(delta.amount0()));
            }
        }

        return delta;
    }

    /**
     * @notice Execute order of a given details on specific pending order to do the swap, settle balances, and update all mappings
     */
    function executeOrder(PoolKey calldata key, int24 tick, bool zeroForOne, uint256 inputAmount) internal {
        // Do the actual swap and settle all balances
        BalanceDelta delta = swapAndSettleBalances(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                // We provide a negative value here to signify an "exact input for output" swap
                amountSpecified: -int256(inputAmount),
                // No slippage limits (maximum slippage possible)
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // `inputAmount` has been deducted from this position
        pendingOrders[key.toId()][tick][zeroForOne] -= inputAmount;
        uint256 positionId = getPositionId(key, tick, zeroForOne);
        uint256 outputAmount = zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));

        // `outputAmount` worth of tokens now can be claimed/redeemed by position holders
        claimableOutputTokens[positionId] += outputAmount;
    }

    function _settle(Currency currency, uint128 amount) internal {
        // Transfer tokens to PM and let it know
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, uint128 amount) internal {
        // Take tokens out of PM to our hook contract
        poolManager.take(currency, address(this), amount);
    }
}
