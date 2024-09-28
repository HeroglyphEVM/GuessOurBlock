// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../BaseScript.sol";
import { GuessOurBlockReceiver } from "src/GuessOurBlockReceiver.sol";
import { GuessOurBlockSender } from "src/GuessOurBlockSender.sol";
import { apxETHVault } from "src/dripVaults/implementations/apxETHVault.sol";
import { MockVault } from "src/dripVaults/implementations/MockVault.sol";

contract GOBDeploy is BaseScript {
    string private constant CONFIG_FILE = "ProtocolConfig";
    string private constant GOB_RECEIVER_CONTRACT_NAME = "GOBReceiver";
    string private constant GOB_SENDER_CONTRACT_NAME = "GOBSender";
    string private constant APX_ETH_CONTRACT_NAME = "ApxEth";
    string private constant MOCK_VAULT_CONTRACT_NAME = "MockVault";
    address private constant HEROGLYPH_RELAY = 0xa30cCE750cbE9664A0e46C323Fa2ed5376B25A93;
    address private constant APX_ETH = 0x04C154b66CB340F3Ae24111CC767e0184Ed00Cc6;

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

        address vault;
        address gobReceiver;
        bool gobExists;

        // Arbitrum
        if (block.chainid == 42_161) {
            _tryDeployContract(
                GOB_SENDER_CONTRACT_NAME,
                0,
                type(GuessOurBlockSender).creationCode,
                abi.encode(config.receiverLzId, config.senderLzEndpoint, HEROGLYPH_RELAY, _getDeployerAddress())
            );
        }
        // Ethereum
        else if (block.chainid == 1) {
            (vault,) = _tryDeployContract(
                APX_ETH_CONTRACT_NAME,
                0,
                type(apxETHVault).creationCode,
                abi.encode(_getDeployerAddress(), address(0), APX_ETH, config.treasury)
            );

            (gobReceiver, gobExists) = _tryDeployContract(
                GOB_RECEIVER_CONTRACT_NAME,
                0,
                type(GuessOurBlockReceiver).creationCode,
                abi.encode(config.receiverLzEndpoint, _getDeployerAddress(), config.treasury, address(0))
            );
        }
        // Sepolia
        else if (block.chainid == 11_155_111) {
            (vault,) = _tryDeployContract(
                MOCK_VAULT_CONTRACT_NAME,
                0,
                type(MockVault).creationCode,
                abi.encode(_getDeployerAddress(), address(0), config.treasury)
            );

            (gobReceiver, gobExists) = _tryDeployContract(
                GOB_RECEIVER_CONTRACT_NAME,
                0,
                type(GuessOurBlockReceiver).creationCode,
                abi.encode(config.receiverLzEndpoint, _getDeployerAddress(), _getDeployerAddress())
            );
        } else {
            revert("Unsupported network");
        }

        if (!gobExists) {
            vm.broadcast(_getDeployerPrivateKey());
            GuessOurBlockReceiver(payable(gobReceiver)).updateDripVault(vault);
        }
    }
}
