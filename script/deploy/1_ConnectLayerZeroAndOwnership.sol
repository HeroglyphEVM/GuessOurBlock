// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { BaseScript } from "../BaseScript.sol";
import { GuessOurBlockReceiver } from "src/GuessOurBlockReceiver.sol";
import { GuessOurBlockSender } from "src/GuessOurBlockSender.sol";

contract GOBDeploy is BaseScript {
    string private constant CONFIG_FILE = "ProtocolConfig";
    string private constant GOB_RECEIVER_CONTRACT_NAME = "GOBReceiver";
    string private constant GOB_SENDER_CONTRACT_NAME = "GOBSender";

    string private constant ETHEREUM_NAME = "ethereum";
    string private constant ARBITRUM_NAME = "arbitrum";

    struct ProtocolConfig {
        address owner;
        address treasury;
        uint32 senderLzId;
        uint32 receiverLzId;
        address senderLzEndpoint;
        address receiverLzEndpoint;
    }

    ProtocolConfig private config;

    function run() external override {
        config = abi.decode(vm.parseJson(_getConfig(CONFIG_FILE), string.concat(".", _getNetwork())), (ProtocolConfig));
        _loadContracts(false);

        address receiver = contracts[GOB_RECEIVER_CONTRACT_NAME];
        address sender = contracts[GOB_SENDER_CONTRACT_NAME];

        // Arbitrum
        if (block.chainid == 42_161) {
            _loadOtherContractNetwork(false, ETHEREUM_NAME);
            receiver = contractsOtherNetworks[ETHEREUM_NAME][GOB_RECEIVER_CONTRACT_NAME];

            if (sender == address(0)) {
                revert("Sender not deployed");
            }
            if (receiver == address(0)) {
                revert("Receiver not deployed on ethereum");
            }

            vm.startBroadcast(_getDeployerAddress());
            GuessOurBlockSender(payable(sender)).setPeer(config.receiverLzId, bytes32(abi.encode(receiver)));
            GuessOurBlockSender(payable(sender)).setDelegate(config.owner);
            vm.stopBroadcast();
        }
        // Ethereum
        else if (block.chainid == 1) {
            _loadOtherContractNetwork(false, ARBITRUM_NAME);
            sender = contractsOtherNetworks[ARBITRUM_NAME][GOB_SENDER_CONTRACT_NAME];

            if (receiver == address(0)) {
                revert("Receiver not deployed");
            }
            if (sender == address(0)) {
                revert("Sender not deployed on arbitrum");
            }

            vm.startBroadcast(_getDeployerAddress());
            GuessOurBlockReceiver(payable(receiver)).setPeer(config.senderLzId, bytes32(abi.encode(sender)));
            GuessOurBlockSender(payable(sender)).setDelegate(config.owner);
            vm.stopBroadcast();
        }
    }
}
