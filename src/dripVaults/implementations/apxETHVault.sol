// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseDripVault } from "../BaseDripVault.sol";

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

contract apxETHVault is BaseDripVault {
    IApxETH public apxETH;
    IPirexEth public pirexEth;
    IERC20 public pxETH;

    constructor(address _owner, address _gob, address _apxETH, address _rateReceiver)
        BaseDripVault(_owner, _gob, _rateReceiver)
    {
        apxETH = IApxETH(_apxETH);
        pirexEth = IPirexEth(apxETH.pirexEth());
        pxETH = IERC20(apxETH.asset());

        pxETH.approve(address(apxETH), type(uint256).max);
    }

    function _afterDeposit(uint256 _amount) internal override {
        pirexEth.deposit{ value: _amount }(address(this), true);
    }

    function _beforeWithdrawal(address _to, uint256 _amount) internal override {
        uint128 exitedPx = uint128(apxETH.redeem(apxETH.maxRedeem(address(this)), address(this), address(this)));
        uint256 interestInPx;
        uint256 cachedTotalDeposit = getTotalDeposit();

        uint256 amountInPx = apxETH.convertToShares(_amount);
        uint256 exitedInETH = apxETH.convertToAssets(exitedPx);

        //Shares scales down, in full exit, we might find less than the total deposit
        if (exitedInETH > cachedTotalDeposit) {
            interestInPx = apxETH.convertToShares(exitedInETH - cachedTotalDeposit);
        }

        _transfer(address(pxETH), rateReceiver, interestInPx);
        _transfer(address(pxETH), _to, amountInPx);

        if (cachedTotalDeposit - _amount != 0) {
            apxETH.deposit(pxETH.balanceOf(address(this)), address(this));
        } else {
            // Transfer the remaining balance of pxETH to the rateReceiver, left over from shares conversion
            _transfer(address(pxETH), rateReceiver, pxETH.balanceOf(address(this)));
        }
    }
}
