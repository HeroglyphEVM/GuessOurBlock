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
    IAaveV3Pool public aaveV3Pool;
    IWETH public weth;

    constructor(address _owner, address _gob, address _aaveV3Pool, address _weth, address _rateReceiver)
        BaseDripVault(_owner, _gob, _rateReceiver)
    {
        aaveV3Pool = IAaveV3Pool(_aaveV3Pool);
        weth = IWETH(_weth);

        weth.approve(_aaveV3Pool, type(uint256).max);
    }

    function _afterDeposit(uint256 _amount) internal override {
        weth.deposit{ value: _amount }();
        aaveV3Pool.supply(address(weth), _amount, address(this), 0);
    }

    function _beforeWithdrawal(address _to, uint256 _amount) internal override {
        uint128 exited = uint128(aaveV3Pool.withdraw(address(weth), type(uint256).max, address(this)));

        uint256 cachedTotalDeposit = getTotalDeposit();
        uint256 interest = exited - cachedTotalDeposit;
        uint256 amountToSupply = cachedTotalDeposit - _amount;

        if (amountToSupply > 0) {
            aaveV3Pool.supply(address(weth), amountToSupply, address(this), 0);
        }

        weth.withdraw(_amount + interest);

        _transfer(address(0), rateReceiver, interest);
        _transfer(address(0), _to, _amount);
    }
}
