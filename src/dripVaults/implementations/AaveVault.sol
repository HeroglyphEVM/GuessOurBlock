// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseDripVault, IERC20 } from "../BaseDripVault.sol";

interface IWETH is IERC20 {
    function deposit() external payable;

    function transfer(address to, uint256 value) external returns (bool);

    function withdraw(uint256) external;
}

interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    function getReserveNormalizedIncome(address asset) external view returns (uint256);
}

contract AaveVault is BaseDripVault {
    event ReferalCodeUpdated(uint16 referalCode);

    IAaveV3Pool public immutable aaveV3Pool;
    IERC20 public immutable aWETH;
    IWETH public immutable weth;

    uint16 public referalCode = 0;

    constructor(address _owner, address _gob, address _aaveV3Pool, address _aWETH, address _weth, address _rateReceiver)
        BaseDripVault(_owner, _gob, _rateReceiver)
    {
        aaveV3Pool = IAaveV3Pool(_aaveV3Pool);
        weth = IWETH(_weth);
        aWETH = IERC20(_aWETH);

        weth.approve(_aaveV3Pool, type(uint256).max);
    }

    function _afterDeposit(uint256 _amount) internal override {
        weth.deposit{ value: _amount }();
        aaveV3Pool.supply(address(weth), _amount, address(this), referalCode);
    }

    function _beforeWithdrawal(address _to, uint256 _amount) internal override {
        uint256 currentBalance = aWETH.balanceOf(address(this));
        uint256 cachedTotalDeposit = getTotalDeposit();
        uint256 interest = currentBalance - cachedTotalDeposit;

        aaveV3Pool.withdraw(address(weth), _amount, address(this));

        _transfer(address(aWETH), rateReceiver, interest);
        _transfer(address(weth), _to, _amount);
    }

    function setReferalCode(uint16 _referalCode) external onlyOwner {
        referalCode = _referalCode;
        emit ReferalCodeUpdated(referalCode);
    }
}
