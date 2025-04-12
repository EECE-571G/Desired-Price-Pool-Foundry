// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGoveranceTokenOwner {
    function pauseGovernanceToken() external;

    function unpauseGovernanceToken() external;
}