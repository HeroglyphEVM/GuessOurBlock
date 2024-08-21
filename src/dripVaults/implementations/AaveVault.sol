// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseDripVault } from "../BaseDripVault.sol";

interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    function getReserveNormalizedIncome(address asset) external view returns (uint256);
}

contract AaveVault is BaseDripVault {
    IAaveV3Pool public strategyService;

    constructor(address _owner, address _gob, address _strategyService, address _vaultAsset, address _rateReceiver)
        BaseDripVault(_owner, _gob, _vaultAsset, _rateReceiver)
    {
        strategyService = IAaveV3Pool(_strategyService);
    }

    function _afterDeposit(uint256 _amount) internal override {
        strategyService.supply(inAsset, _amount, address(this), 0);
    }

    function _beforeWithdrawal(address _to, uint256 _amount) internal override {
        uint128 exited = uint128(strategyService.withdraw(inAsset, type(uint256).max, address(this)));

        uint256 totalDeposit = getTotalDeposit();
        uint256 interest = exited - totalDeposit;

        strategyService.supply(inAsset, totalDeposit - _amount, address(this), 0);

        _transfer(address(0), rateReceiver, interest);
        _transfer(address(0), _to, _amount);
    }
}
