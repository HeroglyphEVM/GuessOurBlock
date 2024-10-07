// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IDripVault } from "../dripVaults/IDripVault.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

abstract contract BaseDripVault is IDripVault, Ownable, ReentrancyGuard {
    address public immutable gob;
    address public rateReceiver;
    uint256 private totalDeposit;

    modifier onlyGob() {
        if (msg.sender != gob) revert NotGob();
        _;
    }

    constructor(address _owner, address _gob, address _rateReceiver) Ownable(_owner) {
        gob = _gob;
        rateReceiver = _rateReceiver;
    }

    function deposit() external payable override onlyGob {
        if (msg.value == 0) revert InvalidAmount();
        totalDeposit += msg.value;

        _afterDeposit(msg.value);
    }

    function _afterDeposit(uint256 _amount) internal virtual;

    function withdraw(address _to, uint256 _amount) external override nonReentrant onlyGob {
        _beforeWithdrawal(_to, _amount);
        totalDeposit -= _amount;
    }

    function _beforeWithdrawal(address _to, uint256 _amount) internal virtual;

    function _transfer(address _asset, address _to, uint256 _amount) internal {
        if (_amount == 0) return;

        if (_asset == address(0)) {
            (bool success,) = _to.call{ value: _amount }("");
            if (!success) revert FailedToSendETH();
        } else {
            SafeERC20.safeTransfer(IERC20(_asset), _to, _amount);
        }
    }

    function setRateReceiver(address _rateReceiver) external onlyOwner {
        rateReceiver = _rateReceiver;
        emit RateReceiverUpdated(_rateReceiver);
    }

    function getTotalDeposit() public view override returns (uint256) {
        return totalDeposit;
    }

    receive() external payable { }
}
