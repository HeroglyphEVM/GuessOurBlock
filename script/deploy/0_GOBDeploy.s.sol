// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../BaseScript.sol";
import { GuessOurBlockReceiver } from "src/GuessOurBlockReceiver.sol";
import { GuessOurBlockSender } from "src/GuessOurBlockSender.sol";
import { ApxETHVault } from "src/dripVaults/implementations/ApxETHVault.sol";
import { MockVault } from "src/dripVaults/implementations/MockVault.sol";

contract GOBDeploy is BaseScript {
    string private constant CONFIG_FILE = "ProtocolConfig";
    string private constant GOB_RECEIVER_CONTRACT_NAME = "GOBReceiver";
    string private constant GOB_SENDER_CONTRACT_NAME = "GOBSender";
    string private constant APX_ETH_CONTRACT_NAME = "ApxEth";
    string private constant MOCK_VAULT_CONTRACT_NAME = "MockVault";
    address private constant HEROGLYPH_RELAY = 0xa30cCE750cbE9664A0e46C323Fa2ed5376B25A93;
    address private constant APX_ETH = 0x9Ba021B0a9b958B5E75cE9f6dff97C7eE52cb3E6;
    address private constant GAS_POOL = 0xe7fcF5465253eBBc47472ECc9708E23d1Bc4958F;

    struct ProtocolConfig {
        address owner;
        address treasury;
        uint32 senderLzId;
        uint32 receiverLzId;
        address senderLzEndpoint;
        address receiverLzEndpoint;
    }

    ProtocolConfig private config;

    address private gobSender;
    bool private gobSenderExists;
    address private gobReceiver;
    bool private gobReceiverExists;
    address private vault;
    bool private vaultExists;

    function run() external override {
        config = abi.decode(vm.parseJson(_getConfig(CONFIG_FILE), string.concat(".", _getNetwork())), (ProtocolConfig));
        _loadContracts(false);

        // Arbitrum
        if (block.chainid == 42_161) {
            console.logBytes(
                abi.encode(
                    config.receiverLzId, config.senderLzEndpoint, HEROGLYPH_RELAY, _getDeployerAddress(), GAS_POOL
                )
            );

            (gobSender, gobSenderExists) = _tryDeployContract(
                GOB_SENDER_CONTRACT_NAME,
                0,
                type(GuessOurBlockSender).creationCode,
                abi.encode(
                    config.receiverLzId, config.senderLzEndpoint, HEROGLYPH_RELAY, _getDeployerAddress(), GAS_POOL
                )
            );
        }
        // Ethereum
        else if (block.chainid == 1) {
            (gobReceiver, gobReceiverExists) = _tryDeployContract(
                GOB_RECEIVER_CONTRACT_NAME,
                0,
                type(GuessOurBlockReceiver).creationCode,
                abi.encode(config.receiverLzEndpoint, _getDeployerAddress(), config.treasury, address(0))
            );
            (vault, vaultExists) = _tryDeployContract(
                APX_ETH_CONTRACT_NAME,
                0,
                type(ApxETHVault).creationCode,
                abi.encode(_getDeployerAddress(), gobReceiver, APX_ETH, config.treasury)
            );
        }
        // Sepolia
        else if (block.chainid == 11_155_111) {
            (gobReceiver, gobReceiverExists) = _tryDeployContract(
                GOB_RECEIVER_CONTRACT_NAME,
                0,
                type(GuessOurBlockReceiver).creationCode,
                abi.encode(config.receiverLzEndpoint, _getDeployerAddress(), _getDeployerAddress())
            );
            (vault,) = _tryDeployContract(
                MOCK_VAULT_CONTRACT_NAME,
                0,
                type(MockVault).creationCode,
                abi.encode(_getDeployerAddress(), gobReceiver, config.treasury)
            );
        } else {
            revert("Unsupported network");
        }

        if (!gobReceiverExists && block.chainid != 42_161) {
            vm.broadcast(_getDeployerPrivateKey());
            GuessOurBlockReceiver(payable(gobReceiver)).updateDripVault(vault);
        }

        test_deployment();
    }

    function test_deployment() internal view {
        if (!_isSimulation()) return;

        if (block.chainid == 42_161 && !gobSenderExists) {
            GuessOurBlockSender gobSenderContract = GuessOurBlockSender(payable(gobSender));

            assert(gobSenderContract.lzEndpointReceiverId() == config.receiverLzId);
            assert(gobSenderContract.heroglyphRelay() == HEROGLYPH_RELAY);
            assert(address(gobSenderContract.endpoint()) == config.senderLzEndpoint);
            assert(gobSenderContract.owner() == _getDeployerAddress());
        } else if (block.chainid == 1) {
            if (!gobReceiverExists) {
                GuessOurBlockReceiver gobReceiverContract = GuessOurBlockReceiver(payable(gobReceiver));

                assert(gobReceiverContract.owner() == _getDeployerAddress());
                assert(gobReceiverContract.treasury() == config.treasury);
                assert(address(gobReceiverContract.endpoint()) == config.receiverLzEndpoint);
            }
            if (!vaultExists) {
                ApxETHVault vaultContract = ApxETHVault(payable(vault));

                assert(vaultContract.owner() == _getDeployerAddress());
                assert(vaultContract.gob() == gobReceiver);
                assert(vaultContract.rateReceiver() == config.treasury);
                assert(address(vaultContract.apxETH()) == APX_ETH);
            }
        }
    }
}
