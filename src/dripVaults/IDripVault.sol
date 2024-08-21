pragma solidity ^0.8.0;

interface IDripVault {
    error FailedToSendETH();
    error InvalidAmount();
    error NotGob();

    event GobUpdated(address indexed gob);
    event RateReceiverUpdated(address indexed rateReceiver);

    function deposit(uint256 _amount) external payable;
    function withdraw(address _to, uint256 _amount) external;
    function getTotalDeposit() external view returns (uint256);
}
