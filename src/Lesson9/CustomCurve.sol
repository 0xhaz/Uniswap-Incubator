// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.26;

/**
 * CPMM - constant-product market maker pricing curve (x*y=k)
 * CSMM - constant-sum market maker pricing curve (x+y=k) - great for stablecoins / stable assets
 * @notice this hooks will enables a custom simple pricing curve for the pool with ratio of 1:1
 * Mechanism Design:
 * 1. User calls swap on Swap Router
 * 2. Swap Router calls swap on Pool Manager
 * 3. Pool Manager calls beforeSwap on Hook
 * 4. Hook should return a BeforeSwapDelta such that it consumes the input token, and returns an equal amount of output token
 *    But how do we send the output token back
 * 5. Core swap logic gets skipped
 * 6. Pool Manager returns final BalanceDelta
 * 7. Swap Router accounts for the balances
 *
 * Step 4 - Hooks cannot just take money out of the pool manager just because they're using custom pricing curve
 * The input token in fact is going to the hook (directly or indirectly) anyway, not the Pool Manager
 * So the output token cannot be extracted from the Pool Manager reserves either
 * So in case of a custom pricing curve, the hooks needs to manage its own liquidity that it manages
 * based on its own pricing curve, since Uniswap's liquidity is managed only on the basis of Uniswap's pricing curve
 * and you cannot arbitrarily withdraw funds from it
 *
 * So, for adding liquidity to the pool,
 * 1. Disable the default add and remove liquidity behaviour (revert on beforeAddLiquidity and beforeRemoveLiquidity)
 * 2. Create a custom addLiquidity function that accepts tokens from users to use as liquidity in the pool
 *
 * To avoid unnecessary token transfers on each swap though and also since the swap router expects to
 * settle balances against the PoolManager, not the hook, we will still integrate our hook with the PoolManager
 * where it will transfer the added liquidity to the PoolManager and only mint claim tokens in exchange.
 * So the actual underlying tokens the user adds will be sent to the PM and the hook will keep ERC-6009 claim tokens
 * for itself. When a swap occurs, the hook will burn some of those ERC6909 claim tokens and allow the Swap Router to
 * withdraw the equivalent amount of underlying token from the PoolManager
 */
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

/**
 * @notice a CSMM is a pricing curve that follows the invariant `x + y = k`
 * @dev This is theoretically the ideal curve for a stablecoin or pegged asset pair (stETH-ETH, USDC-DAI, etc.)
 * @dev In practice, we don't usually see this in prod since depegs can happen and we dont want exact equal amounts
 *
 */
contract CSMM is BaseHook {
    using CurrencySettler for Currency;

    error AddLiquidityThroughHook(); // error to throw when someone tries adding liquidity directly to the PoolManager
    error RemoveLiquidityThroughHook(); // error to throw when someone tries removing liquidity directly from the PoolManager

    /**
     * @notice CallbackData that can be bassed to poolManager.unlock
     * @member amountEach Amount of each token to add as liqudity
     * @member currency0 Currency of token0
     * @member currency1 Currency of token1
     * @member sender Address of the sender
     */
    struct CallbackData {
        uint256 amountEach;
        Currency currency0;
        Currency currency1;
        address sender;
    }

    constructor(IPoolManager poolManager) BaseHook(poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true, // Dont allow adding liquidity directly to the pool
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true, // Override how swaps are done
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            // NoOp hooks
            beforeSwapReturnDelta: true, // Allow beforeSwap to return a custom delta
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // Disable adding liquidity through PoolManager
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert AddLiquidityThroughHook();
    }

    // Disable removing liquidity through PoolManager
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert RemoveLiquidityThroughHook();
    }

    // Custom add liquidity function - since now swaps can happen until we have a way to have liquidity in the pool
    function addLiquidity(PoolKey calldata key, uint256 amountEach) external {
        // This will trigger the PoolManager to initiate a callback to this hook
        poolManager.unlock(
            abi.encode(
                CallbackData({
                    amountEach: amountEach,
                    currency0: key.currency0,
                    currency1: key.currency1,
                    sender: msg.sender
                })
            )
        );
    }

    // Custom remove liquidity function - since now swaps can happen until we have a way to have liquidity in the pool
    function removeLiquidity(PoolKey calldata key, uint256 liquidity) external {
        // This will trigger the PoolManager to initiate a callback to this hook
        poolManager.unlock(
            abi.encode(
                CallbackData({
                    amountEach: liquidity,
                    currency0: key.currency0,
                    currency1: key.currency1,
                    sender: msg.sender
                })
            )
        );
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 amountInOutPositive =
            params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);

        /**
         * BalanceDelta is a packed value of (currency0Amount, currency1Amount)
         * BeforeSwapDelta varies such that it is not sorted by token0 and token1
         * Instead, it is sorted by "specifiedCurrency" and "unspecifiedCurrency"
         * Specified Currency => The currency in which the user is specifying the amount they're swapping for
         * Unspecified Currency => The other currency
         *
         * For example, in an ETH/USDC pool, there are 4 possible swap cases:
         * 1. ETH for USDC with Exact Input for Output (amountSpecified = negative value representing ETH)
         * 2. ETH for USDC with Exact Output for Input (amountSpecified = positive value representing USDC)
         * 3. USDC for ETH with Exact Input for Output (amountSpecified = negative value representing USDC)
         * 4. USDC for ETH with Exact Output for Input (amountSpecified = positive value representing ETH)
         *
         * In Case (1):
         *  - The user is specifying their swap amount in terms of ETH, so the specifiedCurrency is ETH
         *  - The unspecifiedCurrency is USDC
         *
         * In Case (2):
         * - The user is specifying their swap amount in terms of USDC, so the specifiedCurrency is USDC
         * - The unspecifiedCurrency is ETH
         *
         * In Case (3):
         * - The user is specifying their swap amount in terms of USDC, so the specifiedCurrency is USDC
         * - The unspecifiedCurrency is ETH
         *
         * In Case (4):
         * - The user is specifying their swap amount in terms of ETH, so the specifiedCurrency is ETH
         * - The unspecifiedCurrency is USDC
         *
         * Assume zeroForOne = true (without loss of generality)
         * Assume abs(amountSpecified) = 100
         *
         * For an exact input swap where amountSpecified is negative (-100):
         *  - specified token = token0
         *  - unspecified token = token1
         *  - we set deltaSpecified = -(-100) = 100
         *  - we set deltaUnspecified = -100
         *  - i.e hook is owed 100 specified token (token0) by PM (that comes from the user)
         *  - and hook owes 100 unspecified token (token1) to PM (that goes to the user)
         *
         * For an exact output swap where amountSpecified is positive (100):
         *  - specified token = token1
         *  - unspecified token = token0
         *  - we set deltaSpecified = -100
         *  - we set deltaUnspecified = 100
         *  - i.e hook is owed 100 specified token (token1) to PM (that goes to the user)
         *  - and hook owes 100 unspecified token (token0) by PM (that comes from the user)
         *
         * In either case, we can design BeforeSwapDelta as (-params.amountSpecified, params.amountSpecified)
         *
         */
        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(
            int128(-params.amountSpecified), // So `specifiedAmount` = +100
            int128(params.amountSpecified) // Unspecified amount (output delta) = -100
        );

        if (params.zeroForOne) {
            // If user is selling Token 0 and buying Token 1

            // They will be sending Token 0 to the PM, creating a debit of Token 0 in the PM
            // We will take claim tokens for that Token 0 from the PM and keep it in the hook to create an equivalent credit for ourselves
            key.currency0.take(poolManager, address(this), amountInOutPositive, true);

            // They will be receiving Token 1 from the PM, creating a credit of Token 1 in the PM
            // We will burn claim tokens for Token 1 from the hook so PM can pay the user
            key.currency1.settle(poolManager, address(this), amountInOutPositive, true);
        } else {
            key.currency0.settle(poolManager, address(this), amountInOutPositive, true);
            key.currency1.take(poolManager, address(this), amountInOutPositive, true);
        }

        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    // The BaseHook contract has the external function that will be called, so we need to override it
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        // Settle `amountEach` of each currency from the sender
        // i.e Create a debit of `amountEach` of each currency with the Pool Manager
        /// @notice Settle (pay) a currency to the PoolManager
        /// @param currency Currency to settle
        /// @param manager IPoolManager to settle to
        /// @param payer Address of the payer, the token sender
        /// @param amount Amount to send
        /// @param burn If true, burn the ERC-6909 token, otherwise ERC20-transfer to the PoolManager
        callbackData.currency0.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false // `burn` = false, we're actually transferring tokens, not burning ERC-6909 claim tokens
        );
        callbackData.currency1.settle(poolManager, callbackData.sender, callbackData.amountEach, false);

        // Since we didn't go through the regular "modify liquidity" flow,
        // The PM just has a debit of `amountEach` of each currency from us
        // We can, in exchange, get back ERC6909 claim tokens for `amountEach` of each currency
        // to create a credit of `amountEach` of each currency to us that balances out the PM's debit
        // We will store those claim tokens with the hook, so when swaps take place
        // liquidity from our CSMM can be used by minting/burning claim tokens the hook owns
        /// @notice Take (receive) a currency from the PoolManager
        /// @param currency Currency to take
        /// @param manager IPoolManager to take from
        /// @param recipient Address of the recipient, the token receiver
        /// @param amount Amount to receive
        /// @param claims If true, mint the ERC-6909 token, otherwise ERC20-transfer from the PoolManager to recipient
        callbackData.currency0.take(
            poolManager,
            address(this),
            callbackData.amountEach,
            true // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
        );
        callbackData.currency1.take(poolManager, address(this), callbackData.amountEach, true);

        return "";
    }
}
