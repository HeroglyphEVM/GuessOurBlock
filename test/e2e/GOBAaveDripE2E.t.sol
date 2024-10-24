// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import { Origin } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import "../base/BaseTest.t.sol";
import { GuessOurBlockReceiver } from "src/GuessOurBlockReceiver.sol";
import { AaveVault } from "src/dripVaults/implementations/AaveVault.sol";

contract GOBAaveDripE2E is BaseTest {
    GuessOurBlockReceiverHarness private underTest;

    address private owner;
    address private validator;
    address private treasury;
    address private mockLzEndpoint;
    AaveVault private aaveDripVault;

    address private user;
    address private aavePool = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address private weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private aWETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;

    uint256 private fork;

    function setUp() external {
        fork = vm.createSelectFork(vm.envString("RPC_MAINNET"));
        prepareTest();

        aaveDripVault = new AaveVault(owner, address(0), aavePool, aWETH, weth, treasury);

        vm.mockCall(mockLzEndpoint, abi.encodeWithSignature("setDelegate(address)"), abi.encode(true));
        underTest = new GuessOurBlockReceiverHarness(mockLzEndpoint, owner, treasury);

        vm.prank(owner);
        underTest.updateDripVault(address(aaveDripVault));

        skip(1 weeks);
    }

    function prepareTest() internal {
        owner = generateAddress("Owner");
        user = generateAddress("User", 1000e18);
        validator = generateAddress("Validator");
        treasury = generateAddress("Treasury");
        mockLzEndpoint = generateAddress("Lz Endpoint");
    }

    function test_onRun_thenFlowWorks() external prankAs(user) {
        uint32 winningBlock = underTest.getLatestTail() + 20_000;

        underTest.donate{ value: 35e18 }();
        underTest.guess{ value: 15e18 }(winningBlock);

        uint256 beforeWinUserBalance = user.balance;

        skip(30 days);

        changePrank(validator);
        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));

        uint256 afterTreasuryWinFeeBalance = treasury.balance;

        assertGt(afterTreasuryWinFeeBalance, 0);
        assertGt(validator.balance, 0);

        skip(30 days);

        changePrank(user);
        underTest.claim(winningBlock);

        assertGt(treasury.balance, afterTreasuryWinFeeBalance);
        assertGt(user.balance, beforeWinUserBalance);
        assertEq(aaveDripVault.getTotalDeposit(), underTest.lot());
    }

    function generateOrigin() private view returns (Origin memory) {
        return Origin({ srcEid: 1, sender: bytes32(abi.encode(address(this))), nonce: 1 });
    }
}

contract GuessOurBlockReceiverHarness is GuessOurBlockReceiver {
    bytes32 public constant MOCKED_GUID = keccak256("HelloWorld");

    constructor(address _lzEndpoint, address _owner, address _treasury)
        GuessOurBlockReceiver(_lzEndpoint, _owner, _treasury)
    { }

    function exposed_lzReceiver(Origin calldata _origin, bytes calldata _message) external {
        _lzReceive(_origin, MOCKED_GUID, _message, address(this), _message);
    }
}
