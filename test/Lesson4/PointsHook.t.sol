// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PointsHook} from "src/Lesson4/PointsHook.sol";

contract TestPointsHook is Test, Deployers {
    using CurrencyLibrary for Currency;

    MockERC20 token; // our token to use in ETH <> TOKEN pools

    // Native tokens are represented by address(0)
    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    PointsHook hook;

    function setUp() public {
        // Deploy Pool Manager and Router contracts
        deployFreshManagerAndRouters();

        // Deploy our TOKEN contract
        token = new MockERC20("Test Token", "TEST", 18);
        tokenCurrency = Currency.wrap(address(token));

        // Mint a bunch of TOKEN to ourselves and to address(1)
        token.mint(address(this), 1000 ether);
        token.mint(address(1), 1000 ether);

        // Deploy hook to an address that has the proper FLAGS set
        uint160 flags = uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);

        deployCodeTo("PointsHook.sol", abi.encode(manager, "Points Token", "TEST_POINTS"), address(flags));

        // Deploy our hook
        hook = PointsHook(address(flags));

        // Approve our TOKEN for spending on the swap router and modify liquidity router
        // These variables are coming from the `Deployers` contract
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initializes the pool
        (key,) = initPool(
            ethCurrency, // Currency 0 = ETH
            tokenCurrency, // Currency 1 = TOKEN
            hook, // Hook
            3000, // Swap fee
            SQRT_PRICE_1_1, // Initial Sqrt(P) value = 1
            ZERO_BYTES // No additional `initData`
        );
    }

    /**
     * currentTick = 0
     *     We are adding liquidity at tickLower = -60 and tickUpper = 60
     *
     *     New liquidity must not change the token price
     *
     *     we saw an equation in "Ticks and Q64.96 Numbers" of how to calculate amounts of
     *     x and y when adding liquidity. Given the three variables - x, y and L - we need to set value of one
     *
     *     We'll set liquidityDelta = 1 ether, i.e △L = 1 ether
     *     since the `modifyLiquidity` function takes `liquidityDelta` as an argument instead of
     *     specific values for `x` and `y`
     *
     *     Then, we can calculate △x and △y using the equation from the lesson:
     *     △x = △ (L/SqrtPrice) = ( L * (SqrtPrice_tick - SqrtPrice_currentTick)) / (SqrtPrice_tick * SqrtPrice_currentTick)
     *     △y = △ (L * SqrtPrice) = L * (SqrtPrice_currentTick - SqrtPrice_tick)
     *
     *     So, we can calculate how much x and y we need to provide
     *
     *     ```py
     *    import math
     *
     *         q96 = 2**96
     *
     *         def tick_to_price(t):
     *             return 1.0001**t
     *
     *         def price_to_sqrtp(p):
     *             return int(math.sqrt(p) * q96)
     *
     *         sqrtp_low = price_to_sqrtp(tick_to_price(-60))
     *         sqrtp_cur = price_to_sqrtp(tick_to_price(0))
     *         sqrtp_upp = price_to_sqrtp(tick_to_price(60))
     *
     *         def calc_amount0(liq_delta, pa, pb):
     *         if pa > pb:
     *             pa, pb = pb, pa
     *         # Return the calculated value regardless of the comparison result
     *         return int(liq_delta * q96 * (pb - pa) / pa / pb)
     *
     *
     *         def calc_amount1(liq_delta, pa, pb):
     *         if pa > pb:
     *             pa, pb = pb, pa
     *         # Return the calculated value regardless of the comparison result
     *         return int(liq_delta * (pb - pa) / q96)
     *
     *
     *         one_ether = 10 ** 18
     *         liq = 1 * one_ether
     *         eth_amount = calc_amount0(liq, sqrtp_upp, sqrtp_cur)
     *         token_amount = calc_amount1(liq, sqrtp_low, sqrtp_cur)
     *
     *         print(dict({
     *             'eth_amount': eth_amount,
     *             'eth_amount_readable': eth_amount / 10**18,
     *             'token_amount': token_amount,
     *             'token_amount_readable': token_amount / 10**18,
     *         }))
     *     ```
     *
     *    The output of the above script is:
     *   {'eth_amount': 2995354955910434, 'eth_amount_readable': 0.002995354955910434,
     *    'token_amount': 2995354955910412, 'token_amount_readable': 0.002995354955910412}
     *
     *   Therefore, △x = 0.002995354955910434 ETH and △y = 0.002995354955910412 TOKEN
     */

    // Add liquidity + Swap without referrer -  make sure we get points for both adding liquidity and for swapping
    function test_addLiquidityAndSwap() public {
        // Set no referrer in the hook data
        bytes memory hookData = hook.getHookData(address(0), address(this));

        uint256 pointsBalanceOriginal = hook.balanceOf(address(this));

        // How we landed on 0.003 ether here is based on computing value of x and y given
        // total value of delta L (liquidity delta) = 1 ether
        // This is done by computing x and y from the equation shown in the lesson
        modifyLiquidityRouter.modifyLiquidity{value: 0.003 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1 ether,
                salt: bytes32(0)
            }),
            hookData
        );
        uint256 pointsBalanceAfterAddLiquidity = hook.balanceOf(address(this));

        // The exact amount of ETH we're adding (x)
        // is roughly 0.299535 ETH
        // Our original POINTS balance was 0
        // so after adding liquidity we should have roughly 0.299535... POINTS
        assertApproxEqAbs(
            pointsBalanceAfterAddLiquidity - pointsBalanceOriginal,
            2995354955910434,
            0.0001 ether // error margin for precision loss
        );

        // now we swap
        // we will swap 0.001 ether for tokens
        // we should get 20% of 0.001 * 10**18
        // = 2 * 10**14 = 200000000000000
        swapRouter.swap{value: 0.001 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        uint256 pointsBalanceAfterSwap = hook.balanceOf(address(this));

        assertEq(pointsBalanceAfterSwap - pointsBalanceAfterAddLiquidity, 2 * 10 ** 14);
    }

    // Add liquidity + Swap with referrer - make sure referrer get points for both adding liquidity and for swapping
    // We treat address(1) as the referrer

    function test_addLiquidityAndSwapWithReferral() public {
        bytes memory hookData = hook.getHookData(address(1), address(this));

        uint256 pointsBalanceOriginal = hook.balanceOf(address(this));
        uint256 referrerPointsBalanceOriginal = hook.balanceOf(address(1));

        modifyLiquidityRouter.modifyLiquidity{value: 0.003 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1 ether,
                salt: bytes32(0)
            }),
            hookData
        );

        uint256 pointsBalanceAfterAddLiquidity = hook.balanceOf(address(this));
        uint256 referrerPointsBalanceAfterAddLiquidity = hook.balanceOf(address(1));

        assertApproxEqAbs(pointsBalanceAfterAddLiquidity - pointsBalanceOriginal, 2995354955910434, 0.0001 ether);

        assertApproxEqAbs(
            referrerPointsBalanceAfterAddLiquidity - referrerPointsBalanceOriginal - hook.REFERRAL_POINTS(),
            299535495591078,
            0.0001 ether
        );

        // Now we swap
        // We will swap 0.001 ether for tokens
        // We should get 20% of 0.001 * 10**18 points
        // = 2 * 10**14
        // Referrer should get 10% of that - so 2 * 10**13
        swapRouter.swap{value: 0.001 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        uint256 pointsBalanceAfterSwap = hook.balanceOf(address(this));
        uint256 referrerPointsBalanceAfterSwap = hook.balanceOf(address(1));

        assertEq(pointsBalanceAfterSwap - pointsBalanceAfterAddLiquidity, 2 * 10 ** 14);
        assertEq(referrerPointsBalanceAfterSwap - referrerPointsBalanceAfterAddLiquidity, 2 * 10 ** 13);
    }
}
