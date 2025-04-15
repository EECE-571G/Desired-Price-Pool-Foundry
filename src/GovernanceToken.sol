// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

import {IGovernanceToken} from "./interfaces/IGovernanceToken.sol";
import {IGovernanceTokenOwner} from "./interfaces/IGovernanceTokenOwner.sol";

contract GovernanceToken is IGovernanceToken, IGovernanceTokenOwner, ERC20Pausable, Owned {
    using CustomRevert for bytes4;

    error BalanceLocked(uint256 totalLockedBalance);
    error NotCreator(address sender);

    string constant NAME = "Desired Price Pool Token";
    string constant SYMBOL = "DPP";
    uint256 constant TOTAL_SUPPLY = 1_000_000 * 1e18; // 1 million tokens

    address private immutable _creator;
    uint256 public totalLockedBalance;
    mapping(address => uint256) private _lockedBalances;

    constructor(address owner) ERC20(NAME, SYMBOL) Owned(owner) {
        _creator = _msgSender();
        _mint(address(this), TOTAL_SUPPLY);
        // For testing purpose
        _approve(address(this), owner, type(uint256).max);
    }

    modifier onlyCreator() {
        if (_msgSender() != _creator) {
            NotCreator.selector.revertWith(_msgSender());
        }
        _;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(this)) {
            uint256 selfBalance = balanceOf(from);
            uint256 locked = totalLockedBalance;
            if (selfBalance < value + locked) {
                revert BalanceLocked(locked);
            }
        }
        super._update(from, to, value);
    }

    function lockedBalanceOf(address account) external view returns (uint256) {
        return _lockedBalances[account];
    }

    function isPaused() external view returns (bool) {
        return paused();
    }

    function pauseGovernanceToken() external onlyOwner {
        _pause();
    }

    function unpauseGovernanceToken() external onlyOwner {
        _unpause();
    }

    function lock(address account, uint256 amount) public onlyCreator {
        _lockedBalances[account] += amount;
        totalLockedBalance += amount;
        _update(account, address(this), amount);
    }

    function unlock(address account, uint256 amount) public onlyCreator {
        _lockedBalances[account] -= amount;
        totalLockedBalance -= amount;
        _update(address(this), account, amount);
    }
}