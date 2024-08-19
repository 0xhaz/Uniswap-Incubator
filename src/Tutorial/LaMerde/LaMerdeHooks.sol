// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LiquidityMath} from "v4-core/libraries/LiquidityMath.sol";
import {SwapMath} from "v4-core/libraries/SwapMath.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";
import {ProtocolFeeLibrary} from "v4-core/libraries/ProtocolFeeLibrary.sol";
import {Slot0} from "v4-core/types/Slot0.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {CurrencyDelta} from "v4-core/libraries/CurrencyDelta.sol";

contract LaMerdeHooks is BaseHook, ERC20 {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    mapping(address => address) public referredBy;
    uint256 public constant POINTS_FOR_REFERRAL = 500e18;

    constructor(IPoolManager _manager, string memory _name, string memory _symbol)
        BaseHook(_manager)
        ERC20(_name, _symbol, 18)
    {}

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

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyByPoolManager returns (bytes4, int128) {
        if (!key.currency0.isNative()) return (this.afterSwap.selector, 0);

        // We only mint points if user is buying TOKEN with ETH
        if (!swapParams.zeroForOne) return (this.afterSwap.selector, 0);

        uint256 ethSpendAmount =
            swapParams.amountSpecified < 0 ? uint256(-swapParams.amountSpecified) : uint256(int256(-delta.amount0()));
        uint256 pointsForSwap = ethSpendAmount / 5;

        _assignPoints(hookData, pointsForSwap);
        return (this.afterSwap.selector, 0);
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyByPoolManager returns (bytes4, BalanceDelta) {
        return (this.afterAddLiquidity.selector, delta);
    }

    ///////////////////////////// Helper Functions /////////////////////////////

    function getHookData(address referrer, address referree) public pure returns (bytes memory) {
        return abi.encode(referrer, referree);
    }

    function _assignPoints(bytes calldata hookData, uint256 referralPoints) internal {
        if (hookData.length == 0) return;

        (address referrer, address referree) = abi.decode(hookData, (address, address));

        // Assign points for referral
        // if referree is being transferred by someone for the first time
        // and mint points for referrer
        if (referredBy[referree] == address(0) && referrer != address(0)) {
            referredBy[referree] = referrer;
            _mint(referrer, POINTS_FOR_REFERRAL);
        }

        // Mint 10% worth of referree points to referrer
        if (referredBy[referree] != address(0)) {
            _mint(referredBy[referree], referralPoints / 10);
        }

        // Mint points for referree
        _mint(referree, referralPoints);
    }
}
