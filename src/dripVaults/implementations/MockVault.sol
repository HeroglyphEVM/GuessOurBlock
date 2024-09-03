// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseDripVault } from "../BaseDripVault.sol";

contract MockVault is BaseDripVault {
    constructor(address _owner, address _gob, address _rateReceiver) BaseDripVault(_owner, _gob, _rateReceiver) { }

    function _afterDeposit(uint256 _amount) internal override { }

    function _beforeWithdrawal(address _to, uint256 _amount) internal override {
        _transfer(address(0), _to, _amount);
    }
}
