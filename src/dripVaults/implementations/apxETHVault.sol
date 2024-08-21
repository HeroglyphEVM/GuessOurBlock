// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseDripVault } from "../BaseDripVault.sol";

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IApxETH is IERC4626 {
    function pirexEth() external view returns (address);
}

interface IPirexEth {
    function deposit(address receiver, bool shouldCompound)
        external
        payable
        returns (uint256 postFeeAmount, uint256 feeAmount);
}

contract apxETHVault is BaseDripVault {
    IApxETH public apxETH;
    IPirexEth public pirexEth;
    IERC20 public pxETH;

    constructor(address _owner, address _gob, address _apxETH, address _rateReceiver)
        BaseDripVault(_owner, _gob, address(0), _rateReceiver)
    {
        apxETH = IApxETH(_apxETH);
        pirexEth = IPirexEth(apxETH.pirexEth());
        pxETH = IERC20(apxETH.asset());

        pxETH.approve(address(apxETH), type(uint256).max);
    }

    function _afterDeposit(uint256 _amount) internal override {
        pirexEth.deposit{ value: _amount }(address(this), true);
        apxETH.deposit(_amount, address(this));
    }

    function _beforeWithdrawal(address _to, uint256 _amount) internal override {
        uint128 exited = uint128(apxETH.withdraw(apxETH.balanceOf(address(this)), address(this), address(this)));
        uint256 interest = exited - getTotalDeposit();

        _transfer(address(pxETH), rateReceiver, interest);
        _transfer(address(pxETH), _to, _amount);
    }
}
