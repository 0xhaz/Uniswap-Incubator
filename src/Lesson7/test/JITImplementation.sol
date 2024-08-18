// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {JustInTimeHook} from "src/Lesson7/JustInTimeHook.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract JITImplementation is JustInTimeHook {
    constructor(IPoolManager _manager, JustInTimeHook _jitContract) JustInTimeHook(_manager) {
        Hooks.validateHookPermissions(_jitContract, getHookPermissions());
    }

    function validateHookAddress(BaseHook _this) internal pure override {}
}
