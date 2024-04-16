// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "../base/BaseTest.t.sol";
import { GuessOurBlockReceiver, IGuessOurBlock } from "src/GuessOurBlockReceiver.sol";
import { Origin } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { FailOnReceive } from "test/mock/contract/FailOnReceive.t.sol";

contract GuessOurBlockReceiverTest is BaseTest {
    uint128 private constant COST = 0.025 ether;
    uint32 private constant OLDEST_BLOCK = 392_813;
    uint32 private constant ONE_DAY_BLOCKS = 7200;
    uint32 public constant MAX_BPS = 10_000;

    address private owner;
    address private user_A;
    address private user_B;
    address private validator;
    address private treasury;
    address private mockLzEndpoint;

    IGuessOurBlock.FeeStructure DEFAULT_FEE =
        IGuessOurBlock.FeeStructure({ treasury: 200, validator: 300, nextRound: 1500 });

    GuessOurBlockReceiverHarness private underTest;

    function setUp() public pranking {
        prepareTest();

        vm.mockCall(mockLzEndpoint, abi.encodeWithSignature("setDelegate(address)"), abi.encode(true));
        underTest = new GuessOurBlockReceiverHarness(mockLzEndpoint, owner, treasury);

        vm.roll(OLDEST_BLOCK);
        skip(2 weeks);
    }

    function prepareTest() internal {
        owner = generateAddress("Owner");
        user_A = generateAddress("User A", 100e18);
        user_B = generateAddress("User B", 100e18);
        validator = generateAddress("Validator");
        treasury = generateAddress("Treasury");
        mockLzEndpoint = generateAddress("Lz Endpoint");
    }

    function test_constructor_thenContractWellConfigured() external {
        underTest = new GuessOurBlockReceiverHarness(mockLzEndpoint, owner, treasury);

        assertEq(underTest.owner(), owner);
        assertEq(underTest.treasury(), treasury);

        assertEq(underTest.cost(), COST);
        assertEq(abi.encode(underTest.getFeeStructure()), abi.encode(DEFAULT_FEE));
    }

    function test_guess_givenInvalidAmount_thenReverts() external prankAs(user_A) {
        vm.expectRevert(IGuessOurBlock.InvalidAmount.selector);
        underTest.guess{ value: COST - 1 }(OLDEST_BLOCK + 1, 1);

        vm.expectRevert(IGuessOurBlock.InvalidAmount.selector);
        underTest.guess{ value: COST + 1 }(OLDEST_BLOCK + 1, 1);

        vm.expectRevert(IGuessOurBlock.InvalidAmount.selector);
        underTest.guess{ value: COST }(OLDEST_BLOCK + 1, 0);
    }

    function test_gest_whenRoundNotStarted_thenReverts() external prankAs(user_A) {
        vm.warp(underTest.nextRoundStart() - 1);

        vm.expectRevert(IGuessOurBlock.RoundNotStarted.selector);
        underTest.guess{ value: COST }(OLDEST_BLOCK + 1, 1);
    }

    function test_guess_givenOldBlock_thenReverts() external prankAs(user_A) {
        vm.roll(OLDEST_BLOCK);
        vm.expectRevert(IGuessOurBlock.BlockTooSoon.selector);
        underTest.guess{ value: COST }(OLDEST_BLOCK, 1);

        vm.expectRevert(IGuessOurBlock.BlockTooSoon.selector);
        underTest.guess{ value: COST }(OLDEST_BLOCK - 1, 1);
    }

    function test_guess_thenUpdatesGuesses() external prankAs(user_A) {
        uint32 blockId_A = OLDEST_BLOCK + ONE_DAY_BLOCKS;
        uint32 blockId_B = OLDEST_BLOCK + ONE_DAY_BLOCKS + 1;

        uint256 totalGuessA = 5;
        uint256 totalGuessB = 3;
        uint256 expectingBalance = COST * (totalGuessA + totalGuessB);

        expectExactEmit();
        emit IGuessOurBlock.Guessed(user_A, blockId_A, 1);
        underTest.guess{ value: COST }(blockId_A, 1);

        expectExactEmit();
        emit IGuessOurBlock.Guessed(user_A, blockId_B, 3);
        underTest.guess{ value: 3 * COST }(blockId_B, 3);

        expectExactEmit();
        emit IGuessOurBlock.Guessed(user_A, blockId_A, 4);
        underTest.guess{ value: 4 * COST }(blockId_A, 4);

        IGuessOurBlock.BlockAction memory actions_A = underTest.getUserAction(user_A, blockId_A);
        IGuessOurBlock.BlockAction memory actions_B = underTest.getUserAction(user_A, blockId_B);

        IGuessOurBlock.BlockMetadata memory blockData_A = underTest.getBlockData(blockId_A);
        IGuessOurBlock.BlockMetadata memory blockData_B = underTest.getBlockData(blockId_B);

        assertEq(actions_A.voted, totalGuessA);
        assertEq(actions_B.voted, totalGuessB);
        assertEq(address(underTest).balance, expectingBalance);

        assertEq(blockData_A.totalGuess, totalGuessA);
        assertEq(blockData_B.totalGuess, totalGuessB);

        assertEq(underTest.lot(), expectingBalance);
    }

    function test_guess_givenDifferentUser_thenUpdatesGuesses() external pranking {
        uint32 blockId = OLDEST_BLOCK + ONE_DAY_BLOCKS;

        uint32 totalGuess_A = 2;
        uint32 totalGuess_B = 6;
        uint32 totalGuess = totalGuess_A + totalGuess_B;
        uint256 expectingBalance = COST * (totalGuess);

        changePrank(user_A);

        expectExactEmit();
        emit IGuessOurBlock.Guessed(user_A, blockId, totalGuess_A);
        underTest.guess{ value: totalGuess_A * COST }(blockId, totalGuess_A);

        changePrank(user_B);
        emit IGuessOurBlock.Guessed(user_B, blockId, totalGuess_B);
        underTest.guess{ value: totalGuess_B * COST }(blockId, totalGuess_B);

        IGuessOurBlock.BlockAction memory actions_A = underTest.getUserAction(user_A, blockId);
        IGuessOurBlock.BlockAction memory actions_B = underTest.getUserAction(user_B, blockId);
        IGuessOurBlock.BlockMetadata memory blockData = underTest.getBlockData(blockId);

        assertEq(actions_A.voted, totalGuess_A);
        assertEq(actions_B.voted, totalGuess_B);
        assertEq(address(underTest).balance, expectingBalance);

        assertEq(blockData.totalGuess, totalGuess);
        assertEq(blockData.winningLot, 0);

        assertEq(underTest.lot(), expectingBalance);
    }

    function test_multiGuess_givenMisMatchLengthArrays_thenReverts() external prankAs(user_A) {
        uint32[] memory blocks = new uint32[](2);
        uint32[] memory guesses = new uint32[](3);

        vm.expectRevert(IGuessOurBlock.MismatchArrays.selector);
        underTest.multiGuess(blocks, guesses);
    }

    function test_multiGuess_givenInvalidAmount_thenReverts() external prankAs(user_A) {
        uint32[] memory blocks = new uint32[](2);
        blocks[0] = OLDEST_BLOCK + ONE_DAY_BLOCKS + 1;
        blocks[1] = OLDEST_BLOCK + ONE_DAY_BLOCKS + 2;

        uint32[] memory guesses = new uint32[](2);
        guesses[0] = 1;
        guesses[1] = 1;

        vm.expectRevert(IGuessOurBlock.InvalidAmount.selector);
        underTest.multiGuess{ value: COST * 2 - 1 }(blocks, guesses);

        vm.expectRevert(IGuessOurBlock.InvalidAmount.selector);
        underTest.multiGuess{ value: COST * 2 + 1 }(blocks, guesses);

        guesses[1] = 0;
        vm.expectRevert(IGuessOurBlock.InvalidGuessAmount.selector);
        underTest.multiGuess{ value: COST }(blocks, guesses);
    }

    function test_multiGuess_givenOldBlock_thenReverts() external prankAs(user_A) {
        uint32[] memory blocks = new uint32[](2);
        blocks[0] = OLDEST_BLOCK + ONE_DAY_BLOCKS - 1;
        blocks[1] = OLDEST_BLOCK + ONE_DAY_BLOCKS;

        uint32[] memory guesses = new uint32[](2);
        guesses[0] = 1;
        guesses[1] = 1;

        vm.expectRevert(IGuessOurBlock.BlockTooSoon.selector);
        underTest.multiGuess{ value: COST * 2 }(blocks, guesses);
    }

    function test_multiGuess_thenUpdatesGuesses() external prankAs(user_A) {
        uint256 totalGuessA = 4;
        uint256 totalGuessB = 5;

        uint256 expectingBalance = COST * (totalGuessA + totalGuessB);

        uint32[] memory blocks = new uint32[](3);
        blocks[0] = OLDEST_BLOCK + ONE_DAY_BLOCKS + 1;
        blocks[1] = OLDEST_BLOCK + ONE_DAY_BLOCKS + 1;
        blocks[2] = OLDEST_BLOCK + ONE_DAY_BLOCKS + 2;

        uint32[] memory guesses = new uint32[](3);
        guesses[0] = 1;
        guesses[1] = 3;
        guesses[2] = 5;

        for (uint256 i = 0; i < blocks.length; ++i) {
            expectExactEmit();
            emit IGuessOurBlock.Guessed(user_A, blocks[i], guesses[i]);
        }
        underTest.multiGuess{ value: expectingBalance }(blocks, guesses);

        IGuessOurBlock.BlockAction memory actions_A = underTest.getUserAction(user_A, blocks[0]);
        IGuessOurBlock.BlockAction memory actions_B = underTest.getUserAction(user_A, blocks[2]);
        IGuessOurBlock.BlockMetadata memory blockDataA = underTest.getBlockData(blocks[1]);
        IGuessOurBlock.BlockMetadata memory blockDataB = underTest.getBlockData(blocks[2]);

        assertEq(actions_A.voted, totalGuessA);
        assertEq(actions_B.voted, totalGuessB);
        assertEq(address(underTest).balance, expectingBalance);

        assertEq(blockDataA.totalGuess, totalGuessA);
        assertEq(blockDataB.totalGuess, totalGuessB);
        assertEq(blockDataA.winningLot, 0);
        assertEq(blockDataB.winningLot, 0);

        assertEq(underTest.lot(), expectingBalance);
    }

    function test_lzReceive_whenBlockAlreadyCompleted_thenReverts() external {
        uint32 winningBlock = 299_322;

        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));

        vm.expectRevert(IGuessOurBlock.BlockAlreadyCompleted.selector);
        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));
    }

    function test_lzReceive_whenBlockWins_thenCallEvents() external prankAs(user_A) {
        uint32 winningBlock = 999_322;
        uint128 donate = 23e18;

        underTest.donate{ value: donate }();

        bytes32 guid = underTest.MOCKED_GUID();

        expectExactEmit();
        emit IGuessOurBlock.BlockWon(guid, winningBlock, donate);

        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));
    }

    function test_lzReceive_givenAtLeastAWinner_whenRewardIsTooLowerForNextRound_thenGivesAll()
        external
        prankAs(user_A)
    {
        uint32 winningBlock = 999_322;
        uint256 donate = underTest.TOO_LOW_BALANCE() - COST;

        underTest.guess{ value: COST }(winningBlock, 1);
        underTest.donate{ value: donate }();

        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));

        assertEq(underTest.lot(), 0);
    }

    function test_lzReceive_givenAtLeastAWinner_whenHigherThanMinimumForNextRound_thenMovesSomeToNextRound()
        external
        prankAs(user_A)
    {
        uint32 winningBlock = 999_322;
        uint256 donate = underTest.TOO_LOW_BALANCE() * 10;
        uint256 reward = donate + COST;
        uint128 nextRound = uint128(Math.mulDiv(reward, DEFAULT_FEE.nextRound, MAX_BPS));

        underTest.guess{ value: COST }(winningBlock, 1);
        underTest.donate{ value: donate }();

        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));

        assertEq(underTest.lot(), nextRound);
    }

    function test_lzReceive_whenNoWinner_thenApplyFeesAndSetAllForNextRound() external prankAs(user_A) {
        uint32 winningBlock = 999_322;
        uint256 reward = underTest.TOO_LOW_BALANCE();

        uint128 expectedTreasuryTax = uint128(Math.mulDiv(reward, DEFAULT_FEE.treasury, MAX_BPS));
        uint128 expectedValidatorTax = uint128(Math.mulDiv(reward, DEFAULT_FEE.validator, MAX_BPS));

        underTest.donate{ value: reward }();

        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));

        assertEq(underTest.lot(), reward - (expectedTreasuryTax + expectedValidatorTax));
        assertEq(treasury.balance, expectedTreasuryTax);
        assertEq(validator.balance, expectedValidatorTax);
    }

    function test_lzReceive_whenWinner_thenApplyFeesAndSetBlockMetadataWins() external prankAs(user_A) {
        uint32 winningBlock = 999_322;
        uint256 donate = underTest.TOO_LOW_BALANCE() * 10;
        uint256 reward = donate + COST;

        uint128 expectedTreasuryTax = uint128(Math.mulDiv(reward, DEFAULT_FEE.treasury, MAX_BPS));
        uint128 expectedValidatorTax = uint128(Math.mulDiv(reward, DEFAULT_FEE.validator, MAX_BPS));
        uint128 expectedNextRound = uint128(Math.mulDiv(reward, DEFAULT_FEE.nextRound, MAX_BPS));

        underTest.guess{ value: COST }(winningBlock, 1);
        underTest.donate{ value: donate }();

        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));

        assertEq(underTest.lot(), expectedNextRound);
        assertEq(treasury.balance, expectedTreasuryTax);
        assertEq(validator.balance, expectedValidatorTax);
        assertEq(
            underTest.getBlockData(winningBlock).winningLot,
            reward - (expectedTreasuryTax + expectedValidatorTax + expectedNextRound)
        );
    }

    function test_claim_whenNotVoted_thenReverts() external prankAs(user_A) {
        uint32 winningBlock = 999_322;

        vm.expectRevert(IGuessOurBlock.NotVoted.selector);
        underTest.claim(winningBlock);
    }

    function test_claim_whenNoWinningPot_thenReverts() external prankAs(user_A) {
        uint32 winningBlock = 999_322;

        underTest.guess{ value: COST }(winningBlock, 1);

        vm.expectRevert(IGuessOurBlock.NoReward.selector);
        underTest.claim(winningBlock);
    }

    function test_claim_whenAlreadyClaimed_thenReverts() external prankAs(user_A) {
        uint32 winningBlock = 999_322;

        underTest.guess{ value: COST }(winningBlock, 1);
        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));

        underTest.claim(winningBlock);
        vm.expectRevert(IGuessOurBlock.AlreadyClaimed.selector);
        underTest.claim(winningBlock);
    }

    function test_claim_thenSendsReward() external pranking {
        uint32 winningBlock = 999_322;
        uint32 userAVote = 1;
        uint32 userBVote = 5;
        uint256 totalVotes = userAVote + userBVote;

        for (uint256 i = 0; i < 10; ++i) {
            address caller = generateAddress(COST);

            totalVotes++;
            changePrank(caller);
            underTest.guess{ value: COST }(winningBlock, 1);
        }

        changePrank(user_A);
        underTest.guess{ value: COST * userAVote }(winningBlock, userAVote);

        changePrank(user_B);
        vm.deal(user_B, 100e18);
        underTest.guess{ value: COST * userBVote }(winningBlock, userBVote);

        uint256 userBalanceABefore = user_A.balance;
        uint256 userBalanceBBefore = user_B.balance;

        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));

        uint256 lot = underTest.getBlockData(winningBlock).winningLot;
        console.log(lot);
        uint128 userAPot = uint128(lot / totalVotes * userAVote);
        uint128 userBPot = uint128(lot / totalVotes * userBVote);

        assertEq(underTest.getPendingReward(user_A, winningBlock), userAPot);
        assertEq(underTest.getPendingReward(user_B, winningBlock), userBPot);

        changePrank(user_A);
        expectExactEmit();
        emit IGuessOurBlock.Claimed(user_A, winningBlock, userAPot);
        underTest.claim(winningBlock);

        changePrank(user_B);
        expectExactEmit();
        emit IGuessOurBlock.Claimed(user_B, winningBlock, userBPot);
        underTest.claim(winningBlock);

        assertEq(user_A.balance - userBalanceABefore, userAPot);
        assertEq(user_B.balance - userBalanceBBefore, userBPot);
        assertEq(underTest.getPendingReward(user_B, winningBlock), 0);
        assertEq(underTest.getPendingReward(user_B, winningBlock), 0);
    }

    function test_sendNative_whenFailed_thenReverts() external {
        uint128 sending = 28.32e18;
        vm.deal(address(underTest), sending);

        address errorWallet = address(new FailOnReceive());

        underTest.exposed_sendNative(errorWallet, sending);
        assertEq(underTest.getFailedNative(errorWallet), sending);
    }

    function test_sendNative_thenSends() external {
        uint128 sending = 28.32e18;
        vm.deal(address(underTest), sending);

        address to = generateAddress();

        underTest.exposed_sendNative(to, sending);
        assertEq(to.balance, sending);
    }

    function test_retryNativeSend_whenNothing_thenReverts() external prankAs(user_A) {
        vm.expectRevert(IGuessOurBlock.NoFailedETHPending.selector);
        underTest.retryNativeSend();
    }

    function test_retryNativeSend_whenFailingSendingEth_thenReverts() external {
        uint128 sending = 28.32e18;
        vm.deal(address(underTest), sending);

        address errorWallet = address(new FailOnReceive());

        underTest.exposed_sendNative(errorWallet, sending);

        vm.expectRevert(IGuessOurBlock.FailedToSendETH.selector);

        vm.prank(errorWallet);
        underTest.retryNativeSend();
    }

    function test_retryNativeSend_thenSends() external {
        uint128 sending = 28.32e18;
        vm.deal(address(underTest), sending);

        address to = address(new FailOnReceive());
        underTest.exposed_sendNative(to, sending);

        vm.etch(to, "");

        vm.prank(to);
        underTest.retryNativeSend();

        assertEq(to.balance, sending);
    }

    function test_donate_thenUpdatesLot() external prankAs(user_A) {
        uint256 donate = 1.32e18;

        expectExactEmit();
        emit IGuessOurBlock.Donated(user_A, donate);
        underTest.donate{ value: donate }();

        assertEq(underTest.lot(), donate);
    }

    function test_updateFee_asNonOwner_thenReverts() external prankAs(user_A) {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user_A));
        underTest.updateFee(DEFAULT_FEE);
    }

    function test_updateFee_whenHigherThanMaxBPS_thenReverts() external prankAs(owner) {
        IGuessOurBlock.FeeStructure memory newFee =
            IGuessOurBlock.FeeStructure({ treasury: 3333, validator: 3333, nextRound: 3335 });

        vm.expectRevert(IGuessOurBlock.ExceedBPSMaximum.selector);
        underTest.updateFee(newFee);
    }

    function test_updateFee_thenUpdates() external prankAs(owner) {
        IGuessOurBlock.FeeStructure memory newFee =
            IGuessOurBlock.FeeStructure({ treasury: 3200, validator: 100, nextRound: 900 });

        expectExactEmit();
        emit IGuessOurBlock.FeeUpdated(newFee);
        underTest.updateFee(newFee);

        assertEq(abi.encode(underTest.getFeeStructure()), abi.encode(newFee));
    }

    function test_updatePauseTimer_asNonOwner_thenReverts() external prankAs(user_A) {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user_A));
        underTest.updatePauseTimer(1);
    }

    function test_updatePauseTimer_thenUpdates() external prankAs(owner) {
        uint32 newPauseTimer = 100;

        expectExactEmit();
        emit IGuessOurBlock.RoundPauseTimerUpdated(newPauseTimer);
        underTest.updatePauseTimer(newPauseTimer);

        assertEq(underTest.pauseRoundTimer(), newPauseTimer);
    }

    function test_updateMinimumBlockAge_asNonOwner_thenReverts() external prankAs(user_A) {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user_A));
        underTest.updateMinimumBlockAge(1);
    }

    function test_updateMinimumBlockAge_thenUpdates() external prankAs(owner) {
        uint32 newMinimumBlockAge = 100;

        expectExactEmit();
        emit IGuessOurBlock.MinimumBlockAgeUpdated(newMinimumBlockAge);
        underTest.updateMinimumBlockAge(newMinimumBlockAge);

        assertEq(underTest.minimumBlockAge(), newMinimumBlockAge);
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

    function exposed_sendNative(address _to, uint128 _amount) external {
        _sendNative(_to, _amount);
    }
}
