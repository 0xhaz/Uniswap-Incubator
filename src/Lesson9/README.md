NoOp Hooks aka Return Delta Hooks.
NoOp stands for No Operation - A Computer Science term that refers to the machine instruction which
ask the machine to do "nothing".
In the context of Uniswap V4, NoOp hooks are called such becuase they have the ability to ask the core
PoolManager smart contract to do "nothing".
There are 4 types of NoOp hook functions:

- beforeSwapReturnDelta
- afterSwapReturnDelta
- afterAddLiquidityReturnDelta
- afterRemoveLiquidityReturnDelta
  All 4 of these need to be used in conjunction with their "normal" counterparts.
  i.e you cannot use beforeSwapReturnDelta if your hook also does not have the beforeSwap permission
  On a high level they all have different capabilities:
- beforeSwapReturnDelta: has the ability to partially, or completely, bypass the core swap logic
  of the pool manager by taking care of the swap request itself inside beforeSwap
- afterSwapReturnDelta: has the ability to extract tokens to keep for itself from the swap's output
  amount, ask the user to send more than the input amount of the swap with excess going to the hook,
  or add additional tokens to the swap's output amount for the user
- afterAddLiquidityReturnDelta: has the ability to charge the user an additional amount over what
  they're adding as liquidity, or send some tokens
- afterRemoveLiquidityReturnDelta: same as above but for removing liquidity

BeforeDelta - the type of returned from functions like swap and modifyLiquidity.
BalanceDelta is of the form (amount0, amount1) and represents the delta of token0 and token1 respectively after
the user performs an action. The user's responsibility is to account for this balance delta and receive the token
it's supposed to receive, and pay the token it's supposed to pay, from and to the PoolManager

BeforeSwapDelta is kind of similar. It's a distinct type that can be returned from the beforeSwap hook function
if the beforeSwapReturnDelta flag has been enabled
BeforeDelta is in the form of (amount0, amount1), BeforeSwapDelta is in the form of (amountSpecified, amountUnspecified)
amountSpecified refers to the delta amount of the token which was "specified" by the user.
amountUnspecified is the opposite.
Recall that there are 4 different types of swap configurations that are possible:

1. Exact Input Zero For One
2. Exact Output Zero For One
3. Exact Input One For Zero
4. Exact Output One For Zero

For (1), we specify zeroForOne = true and amountSpecified = a negative number in the swap parameters. This implies
that we're specifying an amount of token0 to exactly take out of the user's wallet to use for the swap.
In this case, the "specified" token is token0

For (2), we specify zeroForOne = true and amountSpecified = a positive number in the swap parameters. This implies
that we're specifying an amount of token1 to exactly receive in the user's wallet as the output of the swap.
In this case, the "specified" token is token1

Similarly, for (3) the specified token is token1 and for (4) the specified token is token0

Therefore, BeforeSwapDelta varies from BalanceDelta in it's format. BalanceDelta always has the first delta
representing token0 and the second representing token1. In BeforeSwapDelta, howevery, the first delta
is for the specified token - which can be, but not necessarily, token0 and the second delta is for the unspecified
token- which can be, but not necessarily, token1

/// @inheritdoc IPoolManager
function swap(PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata hookData)
external
onlyWhenUnlocked
NoDelegateCall
returns (BalanceDelta swapDelta)
{
BeforeSwapDelta beforeSwapDelta;
{
int256 amountToSwap;
uint24 lpFeeOverride;
(amountToSwap, beforeSwapDelta, lpFeeOverride) = key.hooks.beforeSwap(key, params, hookData);

          // execute swap, account protocol fees, and emit swap event
          // _swap is needed to avoid stack too deep error
          swapDelta = _swap(
              pool,
              id,
              Pool.SwapParams({
                  tickSpacing: key.tickSpacing,
                  zeroForOne: params.zeroForOne,
                  amountSpecified: amountToSwap,
                  sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                  lpFeeOverride: lpFeeOverride
              }),
              params.zeroForOne ? key.currency0 : key.currency1 // input token
          )
      }

}

- swap() is called with params
- params contains the amountSpecified and zeroForOne values provided by the user
- key.hooks.beforeSwap is called, which returns amountToSwap
- Then, the internal function \_swap is called with amountSpecified = amountToSwap

The important part here being the fact that the internal \_swap function doesn't actually get called with
params.amountSpecified. Instead it's called with amountToSwap that's returned from the key.hooks.beforeSwap call

/// @notice calls beforeSwap hook if permissioned and validates return value
function beforeSwap(IHooks self, PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata hookData)
internal
returns (int256 amountToSwap, BeforeSwapDelta hookReturn, uint24 lpFeeOverride)
{
amountToSwap = params.amountSpecified;

    if (self.hasPermission(BEFORE_SWAP_FLAG)) {
        bytes memory result = callHook(self, abi.encodeCall(IHooks.beforeSwap, (msg.sender, key, params, hookData)));

        // skip this logic for the case where the hook return is 0
        if (self.hasPermission(BEFORE_SWAP_RETURNS_DELTA_FLAG)) {
            hookReturn = BeforeSwapDelta.wrap(result.parseReturnDelta());

            // any return in unspecified is passed to the afterSwap hook for handling
            int128 hookDeltaSpecified = hookReturn.getSpecifiedDelta();

            // Update the swap amount according to the hook return, and check that the swap type doesn't change (exact input / output)
            if (hookDeltaSpecified != 0) {
                bool exactInput = amountToSwap < 0;
                amountToSwap += hookDeltaSpecified;
                if (exactInput ? amountToSwap > 0 : amountToSwap < 0) {
                    hookDeltaExceedsSwapAmount.selector.revertWith();
                }
            }
        }
    }

}

- Initially, we start off with amountToSwap = params.amountSpecified
- Then we call beforeSwap on the hook contract (assuming permission is set)
- Then we check if the hook also has permission for beforeSwapReturnDelta
- If yes, we extract the returned BeforeSwapDelta value
- If the BeforeSwapDelta value contains a "specified delta" (i.e delta of the specified token), then we modify amountToSwap

Simplified Example
Assume a pool exists for tokens A and B where Alice wants to do an exact input swap to sell 1 Token A for B

Regular flow of swap on pool with no hooks or hooks without NoOp

1. User calls swap on the swap router with zeroForOne = true and amountSpecified = -1
2. Swap router calls swap or the pool manager
3. Pool manager calls beforeSwap on the hook for whatever it needs to do (if enabled)
4. Pool manager calls pools[id].swap with zeroForOne = true and amountSpecified = -1
5. Pool manager gets a BalanceDelta of the form (-1 A, +x B) representing the fact that the user
   owes 1 Token A to the PM, and is owed some amount x of Token B from the PM
6. Pool manager calls afterSwap on hook (if enabled)
7. Swap router gets the BalanceDelta value and sends the Token A to PM and receives Token B from PM to the user
8. Transaction complete

Similar situation - but with beforeSwapReturnDelta being enabled

1. User calls swap on swap router with zeroForOne = true and amountSpecified = -1
2. Swap router calls swap on the pool manager
3. Pool Manager calls beforeSwap on the hook
4. beforeSwap returns a BeforeSwapDelta of the form (+1 A, -x B). The value of x here is not important for now
5. The BeforeSwapDelta having +1 A implies that the hook has "consumed" the -1 A delta from the user
   This sets amountToSwap = -1 + 1 => amountToSwap = 0
6. Because amountToSwap is zero, the core swap logic is skipped. Note that pools[id].sap is
   is still called, but inside that is an if condition which checks if amountToSwap = 0 which returns early
7. Pool Manager calls afterSwap on hook
8. Swap router gets the BalanceDelta value of (-1 A, +x B) with the amount x being dictated by our hook in this case.
   It settles the balances
9. Transaction complete

By setting BeforeSwapDelta such that is "consumed" the user's Token A delta, we prevented the core swap logic
from running. The hook could give the user some amount of Token B it calculates as well in the process -
which basically what enables the creation of custom pricing curves
