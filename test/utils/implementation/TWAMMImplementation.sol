// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {TWAMM} from "src/Tutorial/TWAMM/TWAMM.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract TWAMMImplementation is TWAMM {
    constructor(IPoolManager poolManager, uint256 interval, TWAMM addressToEtch) TWAMM(poolManager, interval) {
        Hooks.validateHookPermissions(addressToEtch, getHookPermissions());
    }

    // make this a no-op testing
    function validateHookAddress(BaseHook _this) internal pure override {}
}
