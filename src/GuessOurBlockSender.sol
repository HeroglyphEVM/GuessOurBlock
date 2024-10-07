// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { TickerOperator } from "heroglyph-library/src/TickerOperator.sol";

import { OAppSender } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppSender.sol";
import { OptionsBuilder } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import { OAppCore, MessagingFee, MessagingReceipt } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";

contract GuessOurBlockSender is TickerOperator, OAppSender {
    using OptionsBuilder for bytes;

    error GasLimitTooLow();
    error NotEnoughToPayLayerZero();

    event SendingWinningBlock(bytes32 indexed guid, uint32 indexed blockNumber, address indexed validator);
    event LzEndpointReceiverIdUpdated(uint32 indexed lzEndpointReceiverId);

    uint32 public lzGasLimit;
    uint32 public lzEndpointReceiverId;
    uint32 public latestMintedBlock;
    bytes public defaultLzOption;

    constructor(uint32 _lzEndpointReceiverId, address _lzEndpoint, address _heroglyphRelay, address _owner)
        TickerOperator(_owner, _heroglyphRelay, address(0))
        OAppCore(_lzEndpoint, _owner)
    {
        lzEndpointReceiverId = _lzEndpointReceiverId;
        lzGasLimit = 200_000;
        defaultLzOption = OptionsBuilder.newOptions().addExecutorLzReceiveOption(lzGasLimit, 0);
    }

    function onValidatorTriggered(uint32, uint32 _blockNumber, address _validatorWithdrawer, uint128 _heroglyphFee)
        external
        override
        onlyRelay
    {
        _repayHeroglyph(_heroglyphFee);

        // return instead a revert for gas optimization on Heroglyph side.
        if (latestMintedBlock >= _blockNumber) return;
        latestMintedBlock = _blockNumber;

        bytes memory option = defaultLzOption;
        bytes memory payload = abi.encode(_blockNumber, _validatorWithdrawer);
        MessagingFee memory fee = _quote(lzEndpointReceiverId, payload, option, false);

        if (!_askFeePayerToPay(address(this), uint128(fee.nativeFee))) revert NotEnoughToPayLayerZero();

        MessagingReceipt memory msgReceipt = _lzSend(lzEndpointReceiverId, payload, option, fee, payable(address(this)));
        emit SendingWinningBlock(msgReceipt.guid, _blockNumber, _validatorWithdrawer);
    }

    function _payNative(uint256 _nativeFee) internal override returns (uint256 nativeFee) {
        uint256 balance = address(this).balance;

        if (msg.value != 0 && msg.value != _nativeFee) revert NotEnoughNative(msg.value);
        if (msg.value == 0 && balance < _nativeFee) revert NotEnoughNative(balance);

        return _nativeFee;
    }

    function updateLzGasLimit(uint32 _gasLimit) external onlyOwner {
        if (_gasLimit < 50_000) revert GasLimitTooLow();

        lzGasLimit = _gasLimit;
        defaultLzOption = OptionsBuilder.newOptions().addExecutorLzReceiveOption(lzGasLimit, 0);
    }

    function updateLzEndpointReceiverId(uint32 _lzEndpointReceiverId) external onlyOwner {
        lzEndpointReceiverId = _lzEndpointReceiverId;
        emit LzEndpointReceiverIdUpdated(_lzEndpointReceiverId);
    }
}
