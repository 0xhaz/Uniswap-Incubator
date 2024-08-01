// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

// Imagine you have some memecoin-type coin called TOKEN. We want to attach our hook into ETH <> TOKEN pools.
// Our goal is to incentivize swappers to buy TOKEN in exchange for ETH, and for LPs to add liquidity to our pool.
// Also, we want to allow people to refer other users such that the referrer will earn some commission every time the referree buys TOKEN for ETH or adds liquidity to the pool.
//This incentivization happens through the hook issuing a second POINTS token when desired actions occur. For simplicity, we'll set some basic rules and assumptions:
// When a user gets referred, we will mint a hardcoded amount of POINTS token to the referrer - in our case, 500 POINTS
// When a swap takes place which buys TOKEN for ETH - we will issue POINTS equivalent to how much ETH was swapped in to the user, and 10% of that amount to the referrer (if any).
// When someone adds liquidity, we will issue POINTS equivalent to how much ETH they added, and 10% of that amount to the referrer (if any).

contract PointsHook is BaseHook, ERC20 {
    // Use CurrencyLibrary and BalanceDeltaLibrary to handle currency and balance delta operations
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    // Keeping track of user => referrer
    mapping(address => address) public referredBy;

    // Amount of points someone gets for referring someone
    uint256 public constant REFERRAL_POINTS = 500 * 10 ** 18;

    constructor(IPoolManager _manager, string memory _name, string memory _symbol)
        BaseHook(_manager)
        ERC20(_name, _symbol, 18)
    {}

    // Set up hook permissions to return `true` for the two hook functions we are using
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
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

    // Stub implementation of `afterSwap`
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData // attach arbitrary data for usage in the hook
    ) external override onlyByPoolManager returns (bytes4, int128) {
        // if this is not ETH-TOKEN pool with this hook attached, return
        if (!key.currency0.isNative()) return (this.afterSwap.selector, 0);

        // We only mint points if user is buying TOKEN with ETH
        if (!swapParams.zeroForOne) return (this.afterSwap.selector, 0);

        // Mint points equal to 20% of the amount of ETH they spent
        // Since its a zeroForOne swap:
        // if amountSpecified < 0:
        //    this is a "exact input for output" swap
        ///   amount of ETH they spent is equal to amountSpecified
        // if amountSpecified > 0:
        //    this is a "exact output for input" swap
        //    amount of ETH they spent is equal to BalanceDelta.amount0()
        uint256 ethSpendAmount =
            swapParams.amountSpecified < 0 ? uint256(-swapParams.amountSpecified) : uint256(int256(-delta.amount0()));
        uint256 pointsForSwap = ethSpendAmount / 5;

        // Mint the points including any referreal points
        _assignPoints(hookData, pointsForSwap);

        return (this.afterSwap.selector, 0);
    }

    // Stub implementation of `afterAddLiquidity`
    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyByPoolManager returns (bytes4, BalanceDelta) {
        // If this is not an ETH-TOKEN pool with this hook attached, return
        if (!key.currency0.isNative()) return (this.afterAddLiquidity.selector, delta);

        // Mint points equal to how much ETH they added
        uint256 pointsForAddLiquidity = uint256(int256(-delta.amount0()));

        // Mint the points including any referreal points
        _assignPoints(hookData, pointsForAddLiquidity);

        return (this.afterAddLiquidity.selector, delta);
    }

    // Helper function to mint POINTS to a user
    // Encode data bout who the referrer and the referree are
    function getHookData(address referrer, address referree) public pure returns (bytes memory) {
        return abi.encode(referrer, referree);
    }

    // assignPoints function to assign automatically gives the referrer a cut
    function _assignPoints(bytes calldata hookData, uint256 referreePoints) internal {
        // if no referrer/referree specified, no points will be assigned to anyone
        if (hookData.length == 0) return;

        // Decode the referrer and referree address
        (address referrer, address referree) = abi.decode(hookData, (address, address));

        // If referree is the zero address ,return
        if (referree == address(0)) return;

        // If the referree is being referred by someone for the first time
        // set the given referrer address as their referrer
        // and mint REFERAL_POINTS to the referrer
        if (referredBy[referree] == address(0) && referrer != address(0)) {
            referredBy[referree] = referrer;
            _mint(referrer, REFERRAL_POINTS);
        }

        // Mint 10% worth of the referree's points to the referrer
        if (referredBy[referree] != address(0)) {
            _mint(referrer, referreePoints / 10);
        }

        // Mint the appropriate number of points to the referree
        _mint(referree, referreePoints);
    }
}
