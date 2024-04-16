// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { TickerOperator } from "heroglyph-library/src/TickerOperator.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { OAppSender } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppSender.sol";
import { OptionsBuilder } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import { OAppCore, MessagingFee, MessagingReceipt } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";

contract GuessOurBlockSender is TickerOperator, OAppSender {
    using OptionsBuilder for bytes;

    event SendingWinningBlock(bytes32 indexed guid, uint32 indexed blockNumber, address indexed validator);

    uint32 public lzGasLimit;
    uint32 public immutable lzEndpointId;
    uint32 public latestMintedBlock = 0;
    bytes public defaultLzOption;

    constructor(uint32 _lzEndpointId, address _lzEndpoint, address _heroglyphRelay, address _owner)
        TickerOperator(_owner, _heroglyphRelay, address(0))
        OAppCore(_lzEndpoint, _owner)
    {
        lzEndpointId = _lzEndpointId;
        lzGasLimit = 200_000;
        defaultLzOption = OptionsBuilder.newOptions().addExecutorLzReceiveOption(lzGasLimit, 0);
    }

    function onValidatorTriggered(uint32, uint32 _blockNumber, address _validatorWithdrawer, uint128)
        external
        override
        onlyRelay
    {
        if (latestMintedBlock > _blockNumber) return;
        latestMintedBlock = _blockNumber;

        bytes memory option = defaultLzOption;
        bytes memory payload = abi.encode(_blockNumber, _validatorWithdrawer);
        MessagingFee memory fee = _quote(lzEndpointId, payload, option, false);
        MessagingReceipt memory msgReceipt = _lzSend(lzEndpointId, payload, option, fee, payable(address(this)));

        emit SendingWinningBlock(msgReceipt.guid, _blockNumber, _validatorWithdrawer);

        _repayHeroglyph();
    }

    function updateLzGasLimit(uint32 _gasLimit) external onlyOwner {
        lzGasLimit = _gasLimit;
    }
}
