// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IGoveranceToken is IERC20, IERC20Metadata {
    function totalLockedBalance() external view returns (uint256);

    function lockedBalanceOf(address account) external view returns (uint256);

    function isPaused() external view returns (bool);
}