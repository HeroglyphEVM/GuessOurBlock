// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseDripVault } from "../BaseDripVault.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IApxETH is IERC4626 {
    function pirexEth() external view returns (address);
    function harvest() external;
    function assetsPerShare() external view returns (uint256);
}

interface IPirexEth {
    function deposit(address receiver, bool shouldCompound)
        external
        payable
        returns (uint256 postFeeAmount, uint256 feeAmount);
}

contract ApxETHVault is BaseDripVault {
    IApxETH public immutable apxETH;
    IPirexEth public immutable pirexEth;

    constructor(address _owner, address _gob, address _apxETH, address _rateReceiver)
        BaseDripVault(_owner, _gob, _rateReceiver)
    {
        apxETH = IApxETH(_apxETH);
        pirexEth = IPirexEth(apxETH.pirexEth());
    }

    function _afterDeposit(uint256 _amount) internal override {
        pirexEth.deposit{ value: _amount }(address(this), true);
    }

    function _beforeWithdrawal(address _to, uint256 _amount) internal override {
        uint256 cachedTotalDeposit = getTotalDeposit();
        uint256 maxRedeemInETH = apxETH.convertToAssets(apxETH.maxRedeem(address(this)));
        uint256 amountInApx = apxETH.convertToShares(_amount);
        uint256 interestInApx;

        if (maxRedeemInETH > cachedTotalDeposit) {
            interestInApx = apxETH.convertToShares(maxRedeemInETH - cachedTotalDeposit);
        }

        _transfer(address(apxETH), rateReceiver, interestInApx);
        _transfer(address(apxETH), _to, amountInApx);
    }
}
