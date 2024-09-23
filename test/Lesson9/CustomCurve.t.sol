// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {CSMM} from "src/Lesson9/CustomCurve.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

contract CSMMTest is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    CSMM hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        address hookAddress = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            )
        );
        deployCodeTo("CustomCurve.sol", abi.encode(manager), hookAddress);
        hook = CSMM(hookAddress);

        (key,) = initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        // Add some initial liquidity through the custom `addLiquidity` function

        IERC20Minimal(Currency.unwrap(key.currency0)).approve(hookAddress, 1000 ether);
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(hookAddress, 1000 ether);

        hook.addLiquidity(key, 1000e18);
    }

    // Test that ensure the default modify liquidity behavior is disabled by the hook
    function test_cannotModifyLiquidity() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    // Test that ensure the default remove liquidity behavior is disabled by the hook
    function test_cannotModifyRemoveLiquidity() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1e18, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    // Test if the hook actually got the claim tokens it should when we added liquidity in setUp()
    function test_claimTokenBalances() public view {
        // We add 1000 * (10^18) of liquidity of each token to the CSMM pool
        // The actual tokens will move into the PM
        // But the hook should get equivalent amount of claim tokens for each token
        uint256 token0ClaimID = CurrencyLibrary.toId(currency0);
        uint256 token1ClaimID = CurrencyLibrary.toId(currency1);

        uint256 token0ClaimsBalance = manager.balanceOf(address(hook), token0ClaimID);
        uint256 token1ClaimsBalance = manager.balanceOf(address(hook), token1ClaimID);

        assertEq(token0ClaimsBalance, 1000e18);
        assertEq(token1ClaimsBalance, 1000e18);
    }

    // zero for one exact input swap for 100 tokens and check that 100 token 0 got deducted from the user and we got 100 token 1 back
    function test_swap_exactInput_zeroForOne() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Swap exact input 100 Token A
        uint256 balanceOfTokenABefore = key.currency0.balanceOfSelf();
        uint256 balanceOfTokenBBefore = key.currency1.balanceOfSelf();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -100e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        uint256 balanceOfTokenAAfter = key.currency0.balanceOfSelf();
        uint256 balanceOfTokenBAfter = key.currency1.balanceOfSelf();

        assertEq(balanceOfTokenBAfter - balanceOfTokenBBefore, 100e18);
        assertEq(balanceOfTokenABefore - balanceOfTokenAAfter, 100e18);
    }

    // test exact output configuration of a similar swap
    function test_swap_exactOutput_zeroForOne() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Swap exact output 100 Token A
        uint256 balanceOfTokenABefore = key.currency0.balanceOfSelf();
        uint256 balanceOfTokenBBefore = key.currency1.balanceOfSelf();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 100e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        uint256 balanceOfTokenAAfter = key.currency0.balanceOfSelf();
        uint256 balanceOfTokenBAfter = key.currency1.balanceOfSelf();

        assertEq(balanceOfTokenBAfter - balanceOfTokenBBefore, 100e18);
        assertEq(balanceOfTokenABefore - balanceOfTokenAAfter, 100e18);
    }
}
