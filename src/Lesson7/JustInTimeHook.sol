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
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

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

    constructor(IPoolManager _manager) BaseHook(_manager) {}
}
