// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "../base/BaseTest.t.sol";
import { GuessOurBlockReceiver, IGuessOurBlock } from "src/GuessOurBlockReceiver.sol";
import { Origin } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IDripVault } from "src/dripVaults/IDripVault.sol";

contract GuessOurBlockReceiverTest is BaseTest {
    uint128 private constant COST = 0.025 ether;
    uint32 private constant OLDEST_BLOCK = 392_813;
    uint32 private constant ONE_DAY_BLOCKS = 7200;
    uint32 public constant MAX_BPS = 10_000;
    uint32 public constant GROUP_SIZE = 100;

    address private owner;
    address private user_A;
    address private user_B;
    address private validator;
    address private treasury;
    address private mockLzEndpoint;
    address private mockDripVault;

    IGuessOurBlock.FeeStructure DEFAULT_FEE =
        IGuessOurBlock.FeeStructure({ treasury: 200, validator: 300, nextRound: 1500 });

    GuessOurBlockReceiverHarness private underTest;

    function setUp() public pranking {
        prepareTest();

        vm.mockCall(mockDripVault, abi.encodeWithSelector(IDripVault.getTotalDeposit.selector), abi.encode(0));
        vm.mockCall(mockDripVault, abi.encodeWithSelector(IDripVault.withdraw.selector), abi.encode(true));
        vm.mockCall(mockDripVault, abi.encodeWithSelector(IDripVault.deposit.selector), abi.encode(true));

        vm.mockCall(mockLzEndpoint, abi.encodeWithSignature("setDelegate(address)"), abi.encode(true));
        underTest = new GuessOurBlockReceiverHarness(mockLzEndpoint, owner, treasury, mockDripVault);

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
        mockDripVault = generateAddress("Drip Vault");
    }

    function test_constructor_thenContractWellConfigured() external {
        underTest = new GuessOurBlockReceiverHarness(mockLzEndpoint, owner, treasury, mockDripVault);

        assertEq(underTest.owner(), owner);
        assertEq(underTest.treasury(), treasury);
        assertEq(address(underTest.dripVault()), mockDripVault);

        assertEq(underTest.fullWeightCost(), COST);
        assertEq(abi.encode(underTest.getFeeStructure()), abi.encode(DEFAULT_FEE));
    }

    function test_guess_givenInvalidAmount_thenReverts() external prankAs(user_A) {
        uint32 latestTailBlock = underTest.getLatestTail();

        vm.expectRevert(IGuessOurBlock.InvalidAmount.selector);
        underTest.guess{ value: 0 }(latestTailBlock);
    }

    function test_guess_givenOldBlock_thenReverts() external prankAs(user_A) {
        vm.roll(OLDEST_BLOCK);
        uint32 latestTailBlock = underTest.getLatestTail();

        vm.expectRevert(IGuessOurBlock.BlockTooSoon.selector);
        underTest.guess{ value: COST }(latestTailBlock - GROUP_SIZE);

        changePrank(owner);
        underTest.updateMinimumBlockAge(ONE_DAY_BLOCKS + 101);

        changePrank(user_A);
        vm.expectRevert(IGuessOurBlock.BlockTooSoon.selector);
        underTest.guess{ value: COST }(latestTailBlock);
    }

    function test_guess_givenInvalidTail_thenReverts() external prankAs(user_A) {
        uint32 latestTailBlock = underTest.getLatestTail();

        vm.expectRevert(IGuessOurBlock.InvalidTailBlockNumber.selector);
        underTest.guess{ value: COST }(latestTailBlock + 1);
    }

    function test_guess_thenUpdatesGuesses() external prankAs(user_A) {
        uint32 blockId_One = underTest.getLatestTail();
        uint32 blockId_Two = underTest.getLatestTail() + GROUP_SIZE;

        uint128 sendingEth_One = 0.8 ether;
        uint128 sendingEth_Two = 0.05 ether;
        uint128 sendingEth_Three = 0.25 ether;

        uint128 weight_One = getGuessWeight(sendingEth_One);
        uint128 weight_Two = getGuessWeight(sendingEth_Two);
        uint128 weight_Three = getGuessWeight(sendingEth_Three);

        uint256 expectingBalance = sendingEth_One + sendingEth_Two + sendingEth_Three;

        expectExactEmit();
        emit IGuessOurBlock.Guessed(user_A, blockId_One, weight_One, sendingEth_One);
        underTest.guess{ value: sendingEth_One }(blockId_One);

        expectExactEmit();
        emit IGuessOurBlock.Guessed(user_A, blockId_Two, weight_Two, sendingEth_Two);
        underTest.guess{ value: sendingEth_Two }(blockId_Two);

        expectExactEmit();
        emit IGuessOurBlock.Guessed(user_A, blockId_One, weight_Three, sendingEth_Three);
        vm.expectCall(mockDripVault, sendingEth_Three, abi.encodeWithSelector(IDripVault.deposit.selector));
        underTest.guess{ value: sendingEth_Three }(blockId_One);

        IGuessOurBlock.BlockAction memory actions_One = underTest.getUserAction(user_A, blockId_One);
        IGuessOurBlock.BlockAction memory actions_Two = underTest.getUserAction(user_A, blockId_Two);

        IGuessOurBlock.BlockMetadata memory blockData_One = underTest.getBlockData(blockId_One);
        IGuessOurBlock.BlockMetadata memory blockData_Two = underTest.getBlockData(blockId_Two);

        assertEq(actions_One.guessWeight, weight_One + weight_Three);
        assertEq(actions_Two.guessWeight, weight_Two);
        assertEq(address(underTest).balance, expectingBalance);

        assertEq(blockData_One.totalGuessWeight, weight_One + weight_Three);
        assertEq(blockData_Two.totalGuessWeight, weight_Two);

        assertEq(underTest.lot(), expectingBalance);
    }

    function test_guess_givenDifferentUser_thenUpdatesGuesses() external pranking {
        uint32 blockId = underTest.getLatestTail();

        uint128 sendingEthA = 0.26e18;
        uint128 sendingEthB = 1.2e18;

        uint128 totalGuess_A = getGuessWeight(sendingEthA);
        uint128 totalGuess_B = getGuessWeight(sendingEthB);
        uint128 totalGuess = totalGuess_A + totalGuess_B;
        uint256 expectingBalance = sendingEthA + sendingEthB;

        changePrank(user_A);

        expectExactEmit();
        emit IGuessOurBlock.Guessed(user_A, blockId, totalGuess_A, sendingEthA);
        underTest.guess{ value: sendingEthA }(blockId);

        changePrank(user_B);
        emit IGuessOurBlock.Guessed(user_B, blockId, totalGuess_B, sendingEthB);
        underTest.guess{ value: sendingEthB }(blockId);

        IGuessOurBlock.BlockAction memory actions_A = underTest.getUserAction(user_A, blockId);
        IGuessOurBlock.BlockAction memory actions_B = underTest.getUserAction(user_B, blockId);
        IGuessOurBlock.BlockMetadata memory blockData = underTest.getBlockData(blockId);

        assertEq(actions_A.guessWeight, totalGuess_A);
        assertEq(actions_B.guessWeight, totalGuess_B);
        assertEq(address(underTest).balance, expectingBalance);

        assertEq(blockData.totalGuessWeight, totalGuess);
        assertEq(blockData.winningLot, 0);

        assertEq(underTest.lot(), expectingBalance);
    }

    function test_multiGuess_givenMisMatchLengthArrays_thenReverts() external prankAs(user_A) {
        uint32[] memory blocks = new uint32[](2);
        uint128[] memory guesses = new uint128[](3);

        vm.expectRevert(IGuessOurBlock.MismatchArrays.selector);
        underTest.multiGuess(blocks, guesses);
    }

    function test_multiGuess_givenInvalidAmount_thenReverts() external prankAs(user_A) {
        uint32[] memory blocks = new uint32[](2);
        blocks[0] = underTest.getLatestTail();
        blocks[1] = underTest.getLatestTail() + GROUP_SIZE;

        uint128[] memory guesses = new uint128[](2);
        guesses[0] = 1.1e18;
        guesses[1] = 0.9e18;

        uint128 totalEth = guesses[0] + guesses[1];

        vm.expectRevert(IGuessOurBlock.InvalidAmount.selector);
        underTest.multiGuess{ value: totalEth - 1 }(blocks, guesses);

        vm.expectRevert(IGuessOurBlock.InvalidAmount.selector);
        underTest.multiGuess{ value: totalEth + 1 }(blocks, guesses);

        guesses[1] = 0;
        vm.expectRevert(IGuessOurBlock.InvalidAmount.selector);
        underTest.multiGuess{ value: totalEth }(blocks, guesses);
    }

    function test_multiGuess_givenOldBlock_thenReverts() external prankAs(user_A) {
        uint32[] memory blocks = new uint32[](2);
        blocks[0] = underTest.getLatestTail() - 100;
        blocks[1] = underTest.getLatestTail();

        uint128[] memory guesses = new uint128[](2);
        guesses[0] = 1e18;
        guesses[1] = 1e18;

        vm.expectRevert(IGuessOurBlock.BlockTooSoon.selector);
        underTest.multiGuess{ value: 2e18 }(blocks, guesses);
    }

    function test_multiGuess_givenInvalidTail_thenReverts() external prankAs(user_A) {
        uint32[] memory blocks = new uint32[](2);
        blocks[0] = underTest.getLatestTail() - 1;
        blocks[1] = underTest.getLatestTail();

        uint128[] memory guesses = new uint128[](2);
        guesses[0] = 1e18;
        guesses[1] = 1e18;

        vm.expectRevert(IGuessOurBlock.InvalidTailBlockNumber.selector);
        underTest.multiGuess{ value: 2e18 }(blocks, guesses);
    }

    function test_multiGuess_thenUpdatesGuesses() external prankAs(user_A) {
        uint32[] memory blocks = new uint32[](3);
        blocks[0] = underTest.getLatestTail();
        blocks[1] = underTest.getLatestTail() + 100;
        blocks[2] = underTest.getLatestTail() + 200;

        uint128[] memory guesses = new uint128[](3);
        guesses[0] = 0.1e18;
        guesses[1] = 0.3e18;
        guesses[2] = 0.5e18;

        uint256 totalGuessA = getGuessWeight(guesses[0]);
        uint256 totalGuessB = getGuessWeight(guesses[1]);
        uint256 totalGuessC = getGuessWeight(guesses[2]);

        uint128 totalSentEth = guesses[0] + guesses[1] + guesses[2];

        for (uint256 i = 0; i < blocks.length; ++i) {
            expectExactEmit();
            emit IGuessOurBlock.Guessed(user_A, blocks[i], getGuessWeight(guesses[i]), guesses[i]);
        }

        vm.expectCall(mockDripVault, totalSentEth, abi.encodeWithSelector(IDripVault.deposit.selector));
        underTest.multiGuess{ value: totalSentEth }(blocks, guesses);

        IGuessOurBlock.BlockAction memory actions_A = underTest.getUserAction(user_A, blocks[0]);
        IGuessOurBlock.BlockAction memory actions_B = underTest.getUserAction(user_A, blocks[1]);
        IGuessOurBlock.BlockAction memory actions_C = underTest.getUserAction(user_A, blocks[2]);
        IGuessOurBlock.BlockMetadata memory blockDataA = underTest.getBlockData(blocks[0]);
        IGuessOurBlock.BlockMetadata memory blockDataB = underTest.getBlockData(blocks[1]);
        IGuessOurBlock.BlockMetadata memory blockDataC = underTest.getBlockData(blocks[2]);

        assertEq(actions_A.guessWeight, totalGuessA);
        assertEq(actions_B.guessWeight, totalGuessB);
        assertEq(actions_C.guessWeight, totalGuessC);
        assertEq(address(underTest).balance, totalSentEth);

        assertEq(blockDataA.totalGuessWeight, totalGuessA);
        assertEq(blockDataB.totalGuessWeight, totalGuessB);
        assertEq(blockDataC.totalGuessWeight, totalGuessC);
        assertEq(blockDataA.winningLot, 0);

        assertEq(underTest.lot(), totalSentEth);
    }

    function test_lzReceive_whenBlockAlreadyCompleted_thenEmitsErrorBlockAlreadyCompleted() external {
        uint32 winningBlock = 299_322;
        uint32 sanitizedBlock = winningBlock - winningBlock % GROUP_SIZE;

        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));

        skip(10 weeks);

        expectExactEmit();
        emit IGuessOurBlock.ErrorBlockAlreadyCompleted(sanitizedBlock);
        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));
    }

    function test_lzReceive_whenBlockWins_thenCallEvents() external prankAs(user_A) {
        uint32 winningBlock = 999_322;
        uint32 sanitizedBlock = winningBlock - winningBlock % GROUP_SIZE;
        uint128 donate = 23e18;

        vm.expectCall(mockDripVault, donate, abi.encodeWithSelector(IDripVault.deposit.selector));
        underTest.donate{ value: donate }();

        bytes32 guid = underTest.MOCKED_GUID();

        expectExactEmit();
        emit IGuessOurBlock.BlockWon(guid, sanitizedBlock, donate);

        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));
    }

    function test_lzReceive_givenAtLeastAWinner_whenRewardIsTooLowerForNextRound_thenGivesAll() external {
        uint32 winningBlock = 999_322;
        uint32 guessBlock = winningBlock - winningBlock % GROUP_SIZE;

        uint256 donate = underTest.TOO_LOW_BALANCE() - COST;

        underTest.guess{ value: COST }(guessBlock);
        underTest.donate{ value: donate }();

        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));

        assertEq(underTest.lot(), 0);
    }

    function test_lzReceive_givenAtLeastAWinner_whenHigherThanMinimumForNextRound_thenMovesSomeToNextRound()
        external
        prankAs(user_A)
    {
        uint32 winningBlock = 999_322;
        uint32 guessBlock = winningBlock - winningBlock % GROUP_SIZE;

        uint256 donate = underTest.TOO_LOW_BALANCE() * 10;
        uint256 reward = donate + COST;
        uint128 nextRound = uint128(Math.mulDiv(reward, DEFAULT_FEE.nextRound, MAX_BPS));

        underTest.guess{ value: COST }(guessBlock);
        underTest.donate{ value: donate }();

        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));

        assertEq(underTest.lot(), nextRound);
    }

    function test_lzReceive_whenLessThanOneFullTicket_thenReduceLot() external prankAs(user_A) {
        uint32 winningBlock = 999_322;
        uint32 guessBlock = winningBlock - winningBlock % GROUP_SIZE;

        uint128 sendingEth = COST / 5;
        uint128 donate = 6e18;
        uint128 reward = donate + sendingEth;

        uint128 reducedReward = uint128(Math.mulDiv(reward, getGuessWeight(sendingEth), 1e18));
        uint128 nextRound = reward - reducedReward;

        reward = reducedReward;
        nextRound += uint128(Math.mulDiv(reducedReward, DEFAULT_FEE.nextRound, MAX_BPS));

        underTest.guess{ value: sendingEth }(guessBlock);
        underTest.donate{ value: donate }();

        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));

        assertEq(underTest.lot(), nextRound);
    }

    function test_lzReceive_whenWinner_thenApplyFeesAndSetBlockMetadataWins() external prankAs(user_A) {
        uint32 winningBlock = 999_322;
        uint32 guessBlock = winningBlock - winningBlock % GROUP_SIZE;

        uint256 donate = underTest.TOO_LOW_BALANCE() * 10;
        uint256 reward = donate + COST;

        uint128 expectedTreasuryTax = uint128(Math.mulDiv(reward, DEFAULT_FEE.treasury, MAX_BPS));
        uint128 expectedValidatorTax = uint128(Math.mulDiv(reward, DEFAULT_FEE.validator, MAX_BPS));
        uint128 expectedNextRound = uint128(Math.mulDiv(reward, DEFAULT_FEE.nextRound, MAX_BPS));

        underTest.guess{ value: COST }(guessBlock);
        underTest.donate{ value: donate }();

        vm.expectCall(
            mockDripVault, abi.encodeWithSelector(IDripVault.withdraw.selector, validator, expectedValidatorTax)
        );
        vm.expectCall(
            mockDripVault, abi.encodeWithSelector(IDripVault.withdraw.selector, treasury, expectedTreasuryTax)
        );

        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));

        assertEq(underTest.lot(), expectedNextRound);
        assertEq(
            underTest.getBlockData(guessBlock).winningLot,
            reward - (expectedTreasuryTax + expectedValidatorTax + expectedNextRound)
        );
    }

    function test_claim_whenNotVoted_thenReverts() external prankAs(user_A) {
        uint32 winningBlock = underTest.getLatestTail();

        vm.expectRevert(IGuessOurBlock.NoReward.selector);
        underTest.claim(winningBlock);
    }

    function test_claim_whenNoWinningPot_thenReverts() external prankAs(user_A) {
        uint32 winningBlock = underTest.getLatestTail();

        underTest.guess{ value: COST }(winningBlock);

        vm.expectRevert(IGuessOurBlock.NoReward.selector);
        underTest.claim(winningBlock);
    }

    function test_claim_whenAlreadyClaimed_thenReverts() external prankAs(user_A) {
        uint32 winningBlock = underTest.getLatestTail();

        underTest.guess{ value: COST }(winningBlock);
        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));

        underTest.claim(winningBlock);
        vm.expectRevert(IGuessOurBlock.AlreadyClaimed.selector);
        underTest.claim(winningBlock);
    }

    function test_claim_thenSendsReward() external pranking {
        uint32 winningBlock = underTest.getLatestTail();
        uint128 userASendingEth = 1e18;
        uint128 userBSendingEth = 2e18;

        uint128 userAVote = getGuessWeight(userASendingEth);
        uint128 userBVote = getGuessWeight(userBSendingEth);
        uint256 totalVotes = userAVote + userBVote;

        for (uint256 i = 0; i < 10; ++i) {
            address caller = generateAddress(COST);

            totalVotes += getGuessWeight(COST);
            changePrank(caller);
            underTest.guess{ value: COST }(winningBlock);
        }

        changePrank(user_A);
        underTest.guess{ value: userASendingEth }(winningBlock);

        changePrank(user_B);
        vm.deal(user_B, 100e18);
        underTest.guess{ value: userBSendingEth }(winningBlock);

        underTest.exposed_lzReceiver(generateOrigin(), abi.encode(winningBlock, validator));

        uint256 lot = underTest.getBlockData(winningBlock).winningLot;
        uint128 userAPot = uint128(Math.mulDiv(lot, userAVote, totalVotes));
        uint128 userBPot = uint128(Math.mulDiv(lot, userBVote, totalVotes));

        assertEq(underTest.getPendingReward(user_A, winningBlock), userAPot);
        assertEq(underTest.getPendingReward(user_B, winningBlock), userBPot);

        changePrank(user_A);
        expectExactEmit();
        emit IGuessOurBlock.Claimed(user_A, winningBlock, userAPot);

        vm.expectCall(mockDripVault, abi.encodeWithSelector(IDripVault.withdraw.selector, user_A, userAPot));
        underTest.claim(winningBlock);

        changePrank(user_B);
        expectExactEmit();
        emit IGuessOurBlock.Claimed(user_B, winningBlock, userBPot);

        vm.expectCall(mockDripVault, abi.encodeWithSelector(IDripVault.withdraw.selector, user_B, userBPot));
        underTest.claim(winningBlock);

        assertEq(underTest.getPendingReward(user_A, winningBlock), 0);
        assertEq(underTest.getPendingReward(user_B, winningBlock), 0);
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

    function test_updateGroupSize_asNonOwner_thenReverts() external prankAs(user_A) {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user_A));
        underTest.updateGroupSize(1);
    }

    function test_updateGroupSize_thenUpdates() external prankAs(owner) {
        uint32 newGroupSize = 200;

        expectExactEmit();
        emit IGuessOurBlock.GroupSizeUpdated(newGroupSize);
        underTest.updateGroupSize(newGroupSize);

        assertEq(underTest.groupSize(), newGroupSize);
    }

    function test_updateDripVault_asNonOwner_thenReverts() external prankAs(user_A) {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user_A));
        underTest.updateDripVault(address(0));
    }

    function test_updateDripVault_whenDripVaultIsZero_thenReverts() external prankAs(owner) {
        vm.expectRevert(IGuessOurBlock.DripVaultCannotBeZero.selector);
        underTest.updateDripVault(address(0));
    }

    function test_updateDripVault_whenDripVaultIsPermanentlySet_thenReverts() external prankAs(owner) {
        underTest.setPermanentlySetDripVault();

        vm.expectRevert(IGuessOurBlock.CanNoLongerUpdateDripVault.selector);
        underTest.updateDripVault(generateAddress());
    }

    function test_updateDripVault_thenUpdatesAndActiveMigration() external prankAs(owner) {
        address newDripVault = generateAddress();

        expectExactEmit();
        emit IGuessOurBlock.DripVaultUpdated(newDripVault);
        underTest.updateDripVault(newDripVault);

        assertEq(address(underTest.dripVault()), newDripVault);
        assertEq(underTest.isMigratingDripVault(), true);
    }

    function test_completeDripVaultMigration_asNonOwner_thenReverts() external prankAs(user_A) {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user_A));
        underTest.completeDripVaultMigration();
    }

    function test_completeDripVaultMigration_thenUpdates() external prankAs(owner) {
        underTest.updateDripVault(generateAddress());
        assertEq(underTest.isMigratingDripVault(), true);

        expectExactEmit();
        emit IGuessOurBlock.DripVaultMigrationCompleted();
        underTest.completeDripVaultMigration();

        assertEq(underTest.isMigratingDripVault(), false);
    }

    function test_setPermanentlySetDripVault_asNonOwner_thenReverts() external prankAs(user_A) {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user_A));
        underTest.setPermanentlySetDripVault();
    }

    function test_setPermanentlySetDripVault_thenUpdates() external prankAs(owner) {
        expectExactEmit();
        emit IGuessOurBlock.DripVaultIsPermanentlySet();
        underTest.setPermanentlySetDripVault();

        assertEq(underTest.permanentlySetDripVault(), true);
    }

    function test_getLatestTail_thenReturnsLatestTail() external {
        vm.roll(10_087);
        assertEq(underTest.getLatestTail(), 17_300);
        vm.roll(10_088);
        assertEq(underTest.getLatestTail(), 17_300);
        vm.roll(10_100);
        assertEq(underTest.getLatestTail(), 17_300);
        vm.roll(10_101);
        assertEq(underTest.getLatestTail(), 17_400);
    }

    function generateOrigin() private view returns (Origin memory) {
        return Origin({ srcEid: 1, sender: bytes32(abi.encode(address(this))), nonce: 1 });
    }

    function getGuessWeight(uint256 _nativeSent) private view returns (uint128) {
        return uint128(Math.mulDiv(_nativeSent, 1e18, underTest.fullWeightCost()));
    }
}

contract GuessOurBlockReceiverHarness is GuessOurBlockReceiver {
    bytes32 public constant MOCKED_GUID = keccak256("HelloWorld");

    constructor(address _lzEndpoint, address _owner, address _treasury, address _dripVault)
        GuessOurBlockReceiver(_lzEndpoint, _owner, _treasury, _dripVault)
    { }

    function exposed_lzReceiver(Origin calldata _origin, bytes calldata _message) external {
        _lzReceive(_origin, MOCKED_GUID, _message, address(this), _message);
    }
}
