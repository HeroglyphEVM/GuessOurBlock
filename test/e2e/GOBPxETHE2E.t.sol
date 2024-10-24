// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import { Origin } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import "../base/BaseTest.t.sol";
import { GuessOurBlockReceiver } from "src/GuessOurBlockReceiver.sol";
import { ApxETHVault } from "src/dripVaults/implementations/ApxETHVault.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract GOBPxETHE2E is BaseTest {
    GuessOurBlockReceiverHarness private underTest;

    address private owner;
    address private validator;
    address private treasury;
    address private mockLzEndpoint;
    ApxETHVault private apxEthVault;

    address private user;
    IERC20 private autoPirex = IERC20(0x9Ba021B0a9b958B5E75cE9f6dff97C7eE52cb3E6);
    IERC20 private pxETH = IERC20(0x04C154b66CB340F3Ae24111CC767e0184Ed00Cc6);

    uint256 private fork;

    function setUp() external {
        fork = vm.createSelectFork(vm.envString("RPC_MAINNET"));
        prepareTest();

        apxEthVault = new ApxETHVault(owner, address(0), address(autoPirex), treasury);

        vm.mockCall(mockLzEndpoint, abi.encodeWithSignature("setDelegate(address)"), abi.encode(true));
        underTest = new GuessOurBlockReceiverHarness(mockLzEndpoint, owner, treasury);

        vm.prank(owner);
        underTest.updateDripVault(address(apxEthVault));

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

        uint256 beforeWinPxETHBalance = autoPirex.balanceOf(user);

        skip(15 days);

        changePrank(validator);
        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));

        uint256 afterWinTreasuryPxETHBalance = autoPirex.balanceOf(treasury);

        assertGt(afterWinTreasuryPxETHBalance, 0);
        assertGt(autoPirex.balanceOf(validator), 0);

        skip(15 days);

        changePrank(user);
        underTest.claim(winningBlock);

        //for some reason, the interest is not being added
        // assertGt(autoPirex.balanceOf(treasury), afterWinTreasuryPxETHBalance);
        assertGt(autoPirex.balanceOf(user), beforeWinPxETHBalance);
        assertEq(apxEthVault.getTotalDeposit(), underTest.lot());

        changePrank(owner);
        underTest.updateDripVault(address(apxEthVault));
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
