// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../BaseScript.sol";
import { Hero3D } from "src/Hero3D.sol";

contract Hero3DDeployScript is BaseScript {
    string private constant CONFIG_FILE = "ProtocolConfig";
    string private constant HERO3D_CONTRACT_NAME = "Hero3D";
    address private constant HEROGLYPH_RELAY = 0xa30cCE750cbE9664A0e46C323Fa2ed5376B25A93;

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

        _tryDeployContract(
            HERO3D_CONTRACT_NAME,
            0,
            type(Hero3D).creationCode,
            abi.encode(HEROGLYPH_RELAY, config.owner, config.treasury)
        );
    }
}
