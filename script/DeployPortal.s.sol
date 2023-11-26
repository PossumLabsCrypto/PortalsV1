// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Script.sol";
import {Portal} from "../src/Portal.sol";

contract deployPortal is Script {
    function run() external returns (Portal) {
        vm.startBroadcast();
        Portal portal = new Portal();
        vm.stopBroadcast();
    }
}
