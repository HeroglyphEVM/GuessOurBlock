// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "../base/BaseTest.t.sol";
import { Hero3D, IHero3D } from "src/Hero3D.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract Hero3DTest is BaseTest {
    uint128 private constant COST = 0.1 ether;
    uint32 private constant OLDEST_BLOCK = 392_813;
    uint32 private constant ONE_DAY_BLOCKS = 7200;
    uint32 public constant MAX_BPS = 10_000;
    uint32 public constant GROUP_SIZE = 10;

    address private owner;
    address private user_A;
    address private user_B;
    address private mockRelayer;
    address private validator;
    address private treasury;

    IHero3D.FeeStructure DEFAULT_FEE = IHero3D.FeeStructure({ treasury: 200, validator: 300, nextRound: 1500 });

    Hero3D private underTest;

    function setUp() public {
        prepareTest();

        underTest = new Hero3D(mockRelayer, owner, treasury);

        vm.roll(OLDEST_BLOCK);
        skip(2 weeks);
    }

    function prepareTest() internal {
        owner = generateAddress("Owner");
        user_A = generateAddress("User A", 100e18);
        user_B = generateAddress("User B", 100e18);
        validator = generateAddress("Validator");
        treasury = generateAddress("Treasury");
        mockRelayer = generateAddress("Relayer");
    }

    function test_constructor_thenContractWellConfigured() external {
        underTest = new Hero3D(mockRelayer, owner, treasury);

        assertEq(underTest.owner(), owner);
        assertEq(underTest.treasury(), treasury);
        assertEq(underTest.heroglyphRelay(), mockRelayer);

        assertEq(underTest.fullWeightCost(), COST);
        assertEq(abi.encode(underTest.getFeeStructure()), abi.encode(DEFAULT_FEE));
    }

    function test_guess_givenInvalidAmount_thenReverts() external prankAs(user_A) {
        uint32 latestTailBlock = underTest.getLatestTail();
        uint128 minimumAmount = underTest.MINIMUM_GUESS_AMOUNT();

        vm.expectRevert(IHero3D.InvalidAmount.selector);
        underTest.guess{ value: minimumAmount - 1 }(latestTailBlock);
    }

    function test_guess_givenOldBlock_thenReverts() external prankAs(user_A) {
        vm.roll(OLDEST_BLOCK);

        vm.expectRevert(IHero3D.BlockTooOld.selector);
        underTest.guess{ value: COST }(100);
    }

    function test_guess_givenTooSoonBlock_thenReverts() external prankAs(user_A) {
        vm.roll(OLDEST_BLOCK);
        uint32 latestTailBlock = underTest.getLatestTail();

        vm.expectRevert(IHero3D.BlockTooSoon.selector);
        underTest.guess{ value: COST }(latestTailBlock - GROUP_SIZE);

        changePrank(owner);
        underTest.updateMinimumBlockAge(ONE_DAY_BLOCKS + 101);

        changePrank(user_A);
        vm.expectRevert(IHero3D.BlockTooSoon.selector);
        underTest.guess{ value: COST }(latestTailBlock);
    }

    function test_updateMinimumBlockAge_givenTooLow_thenReverts() external prankAs(owner) {
        uint32 minimumBlockAge = underTest.MINIMUM_BLOCK_AGE();

        vm.expectRevert(IHero3D.MinimumBlockAgeCannotBeLowerThanOneEpoch.selector);
        underTest.updateMinimumBlockAge(minimumBlockAge - 1);
    }

    function test_guess_givenInvalidTail_thenReverts() external prankAs(user_A) {
        uint32 latestTailBlock = underTest.getLatestTail();

        vm.expectRevert(IHero3D.InvalidTailBlockNumber.selector);
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
        emit IHero3D.Guessed(user_A, blockId_One, weight_One, sendingEth_One);
        underTest.guess{ value: sendingEth_One }(blockId_One);

        expectExactEmit();
        emit IHero3D.Guessed(user_A, blockId_Two, weight_Two, sendingEth_Two);
        underTest.guess{ value: sendingEth_Two }(blockId_Two);

        expectExactEmit();
        emit IHero3D.Guessed(user_A, blockId_One, weight_Three, sendingEth_Three);
        underTest.guess{ value: sendingEth_Three }(blockId_One);

        IHero3D.BlockAction memory actions_One = underTest.getUserAction(user_A, blockId_One);
        IHero3D.BlockAction memory actions_Two = underTest.getUserAction(user_A, blockId_Two);

        IHero3D.BlockMetadata memory blockData_One = underTest.getBlockData(blockId_One);
        IHero3D.BlockMetadata memory blockData_Two = underTest.getBlockData(blockId_Two);

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
        emit IHero3D.Guessed(user_A, blockId, totalGuess_A, sendingEthA);
        underTest.guess{ value: sendingEthA }(blockId);

        changePrank(user_B);
        emit IHero3D.Guessed(user_B, blockId, totalGuess_B, sendingEthB);
        underTest.guess{ value: sendingEthB }(blockId);

        IHero3D.BlockAction memory actions_A = underTest.getUserAction(user_A, blockId);
        IHero3D.BlockAction memory actions_B = underTest.getUserAction(user_B, blockId);
        IHero3D.BlockMetadata memory blockData = underTest.getBlockData(blockId);

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

        vm.expectRevert(IHero3D.MismatchArrays.selector);
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

        vm.expectRevert(IHero3D.InvalidAmount.selector);
        underTest.multiGuess{ value: totalEth - 1 }(blocks, guesses);

        vm.expectRevert(IHero3D.InvalidAmount.selector);
        underTest.multiGuess{ value: totalEth + 1 }(blocks, guesses);

        guesses[1] = 0;
        vm.expectRevert(IHero3D.InvalidAmount.selector);
        underTest.multiGuess{ value: totalEth }(blocks, guesses);
    }

    function test_multiGuess_givenOldBlock_thenReverts() external prankAs(user_A) {
        uint32[] memory blocks = new uint32[](2);
        blocks[0] = underTest.getLatestTail() - 100;
        blocks[1] = underTest.getLatestTail();

        uint128[] memory guesses = new uint128[](2);
        guesses[0] = 1e18;
        guesses[1] = 1e18;

        vm.expectRevert(IHero3D.BlockTooOld.selector);
        underTest.multiGuess{ value: 2e18 }(blocks, guesses);
    }

    function test_multiGuess_givenInvalidTail_thenReverts() external prankAs(user_A) {
        uint32[] memory blocks = new uint32[](2);
        blocks[0] = underTest.getLatestTail() - 1;
        blocks[1] = underTest.getLatestTail();

        uint128[] memory guesses = new uint128[](2);
        guesses[0] = 1e18;
        guesses[1] = 1e18;

        vm.expectRevert(IHero3D.InvalidTailBlockNumber.selector);
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
            emit IHero3D.Guessed(user_A, blocks[i], getGuessWeight(guesses[i]), guesses[i]);
        }

        underTest.multiGuess{ value: totalSentEth }(blocks, guesses);

        IHero3D.BlockAction memory actions_A = underTest.getUserAction(user_A, blocks[0]);
        IHero3D.BlockAction memory actions_B = underTest.getUserAction(user_A, blocks[1]);
        IHero3D.BlockAction memory actions_C = underTest.getUserAction(user_A, blocks[2]);
        IHero3D.BlockMetadata memory blockDataA = underTest.getBlockData(blocks[0]);
        IHero3D.BlockMetadata memory blockDataB = underTest.getBlockData(blocks[1]);
        IHero3D.BlockMetadata memory blockDataC = underTest.getBlockData(blocks[2]);

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

    function test_onValidatorTriggered_whenBlockAlreadyCompleted_thenEmitsErrorBlockAlreadyCompleted() external {
        uint32 winningBlock = 299_322;
        uint32 sanitizedBlock = winningBlock - winningBlock % GROUP_SIZE;

        changePrank(mockRelayer);
        underTest.onValidatorTriggered(0, winningBlock, validator, 0);
        changePrank(user_A);

        skip(10 weeks);

        expectExactEmit();
        emit IHero3D.ErrorBlockAlreadyCompleted(sanitizedBlock);
        changePrank(mockRelayer);
        underTest.onValidatorTriggered(0, winningBlock, validator, 0);
        changePrank(user_A);
    }

    function test_onValidatorTriggered_whenBlockWins_thenCallEvents() external prankAs(user_A) {
        uint32 winningBlock = 999_322;
        uint32 sanitizedBlock = winningBlock - winningBlock % GROUP_SIZE;
        uint128 donate = 23e18;

        underTest.donate{ value: donate }();

        expectExactEmit();
        emit IHero3D.BlockWon(sanitizedBlock, donate);

        changePrank(mockRelayer);
        underTest.onValidatorTriggered(0, winningBlock, validator, 0);
        changePrank(user_A);
    }

    function test_onValidatorTriggered_givenAtLeastAWinner_whenRewardIsTooLowerForNextRound_thenGivesAll() external {
        uint32 winningBlock = 999_322;
        uint32 guessBlock = winningBlock - winningBlock % GROUP_SIZE;

        uint256 donate = underTest.TOO_LOW_BALANCE() - COST;

        underTest.guess{ value: COST }(guessBlock);
        underTest.donate{ value: donate }();

        changePrank(mockRelayer);
        underTest.onValidatorTriggered(0, winningBlock, validator, 0);
        changePrank(user_A);

        assertEq(underTest.lot(), 0);
    }

    function test_onValidatorTriggered_givenAtLeastAWinner_whenHigherThanMinimumForNextRound_thenMovesSomeToNextRound()
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

        changePrank(mockRelayer);
        underTest.onValidatorTriggered(0, winningBlock, validator, 0);
        changePrank(user_A);

        assertEq(underTest.lot(), nextRound);
    }

    function test_onValidatorTriggered_whenLessThanOneFullTicket_thenReduceLot() external prankAs(user_A) {
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

        changePrank(mockRelayer);
        underTest.onValidatorTriggered(0, winningBlock, validator, 0);
        changePrank(user_A);

        assertEq(underTest.lot(), nextRound);
    }

    function test_onValidatorTriggered_whenWinner_thenApplyFeesAndSetBlockMetadataWins() external prankAs(user_A) {
        uint32 winningBlock = 999_322;
        uint32 guessBlock = winningBlock - winningBlock % GROUP_SIZE;

        uint256 donate = underTest.TOO_LOW_BALANCE() * 10;
        uint256 reward = donate + COST;

        uint128 expectedTreasuryTax = uint128(Math.mulDiv(reward, DEFAULT_FEE.treasury, MAX_BPS));
        uint128 expectedValidatorTax = uint128(Math.mulDiv(reward, DEFAULT_FEE.validator, MAX_BPS));
        uint128 expectedNextRound = uint128(Math.mulDiv(reward, DEFAULT_FEE.nextRound, MAX_BPS));

        underTest.guess{ value: COST }(guessBlock);
        underTest.donate{ value: donate }();

        changePrank(mockRelayer);
        underTest.onValidatorTriggered(0, winningBlock, validator, 0);
        changePrank(user_A);

        assertEq(underTest.lot(), expectedNextRound);
        assertEq(
            underTest.getBlockData(guessBlock).winningLot,
            reward - (expectedTreasuryTax + expectedValidatorTax + expectedNextRound)
        );
    }

    function test_claim_whenNotVoted_thenReverts() external prankAs(user_A) {
        uint32 winningBlock = underTest.getLatestTail();

        vm.expectRevert(IHero3D.NoReward.selector);
        underTest.claim(winningBlock);
    }

    function test_claim_whenNoWinningPot_thenReverts() external prankAs(user_A) {
        uint32 winningBlock = underTest.getLatestTail();

        underTest.guess{ value: COST }(winningBlock);

        vm.expectRevert(IHero3D.NoReward.selector);
        underTest.claim(winningBlock);
    }

    function test_claim_whenAlreadyClaimed_thenReverts() external prankAs(user_A) {
        uint32 winningBlock = underTest.getLatestTail();

        underTest.guess{ value: COST }(winningBlock);

        changePrank(mockRelayer);
        underTest.onValidatorTriggered(0, winningBlock, validator, 0);
        changePrank(user_A);

        underTest.claim(winningBlock);
        vm.expectRevert(IHero3D.AlreadyClaimed.selector);
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

        changePrank(mockRelayer);
        underTest.onValidatorTriggered(0, winningBlock, validator, 0);
        changePrank(user_B);

        uint256 lot = underTest.getBlockData(winningBlock).winningLot;
        uint128 userAPot = uint128(Math.mulDiv(lot, userAVote, totalVotes));
        uint128 userBPot = uint128(Math.mulDiv(lot, userBVote, totalVotes));

        assertEq(underTest.getPendingReward(user_A, winningBlock), userAPot);
        assertEq(underTest.getPendingReward(user_B, winningBlock), userBPot);

        changePrank(user_A);
        expectExactEmit();
        emit IHero3D.Claimed(user_A, winningBlock, userAPot);

        underTest.claim(winningBlock);

        changePrank(user_B);
        expectExactEmit();
        emit IHero3D.Claimed(user_B, winningBlock, userBPot);

        underTest.claim(winningBlock);

        assertEq(underTest.getPendingReward(user_A, winningBlock), 0);
        assertEq(underTest.getPendingReward(user_B, winningBlock), 0);
    }

    function test_donate_thenUpdatesLot() external prankAs(user_A) {
        uint256 donate = 1.32e18;

        expectExactEmit();
        emit IHero3D.Donated(user_A, donate);
        underTest.donate{ value: donate }();

        assertEq(underTest.lot(), donate);
    }

    function test_updateFee_asNonOwner_thenReverts() external prankAs(user_A) {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user_A));
        underTest.updateFee(DEFAULT_FEE);
    }

    function test_updateFee_whenHigherThanMaxBPS_thenReverts() external prankAs(owner) {
        IHero3D.FeeStructure memory newFee = IHero3D.FeeStructure({ treasury: 3333, validator: 3333, nextRound: 3335 });

        vm.expectRevert(IHero3D.ExceedBPSMaximum.selector);
        underTest.updateFee(newFee);
    }

    function test_updateFee_thenUpdates() external prankAs(owner) {
        IHero3D.FeeStructure memory newFee = IHero3D.FeeStructure({ treasury: 3200, validator: 100, nextRound: 900 });

        expectExactEmit();
        emit IHero3D.FeeUpdated(newFee);
        underTest.updateFee(newFee);

        assertEq(abi.encode(underTest.getFeeStructure()), abi.encode(newFee));
    }

    function test_updateMinimumBlockAge_asNonOwner_thenReverts() external prankAs(user_A) {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user_A));
        underTest.updateMinimumBlockAge(1);
    }

    function test_updateMinimumBlockAge_thenUpdates() external prankAs(owner) {
        uint32 newMinimumBlockAge = 7300;

        expectExactEmit();
        emit IHero3D.MinimumBlockAgeUpdated(newMinimumBlockAge);
        underTest.updateMinimumBlockAge(newMinimumBlockAge);

        assertEq(underTest.minimumBlockAge(), newMinimumBlockAge);
    }

    function test_getLatestTail_thenReturnsLatestTail() external {
        uint256 minimumBlockAge = underTest.minimumBlockAge();
        vm.roll(10_087);

        assertEq(underTest.getLatestTail(), getExpectedLatestTail(10_087, minimumBlockAge, underTest.GROUP_SIZE()));
        vm.roll(10_088);
        assertEq(underTest.getLatestTail(), getExpectedLatestTail(10_088, minimumBlockAge, underTest.GROUP_SIZE()));
        vm.roll(10_100);
        assertEq(underTest.getLatestTail(), getExpectedLatestTail(10_100, minimumBlockAge, underTest.GROUP_SIZE()));
        vm.roll(10_101);
        assertEq(underTest.getLatestTail(), getExpectedLatestTail(10_101, minimumBlockAge, underTest.GROUP_SIZE()));
    }

    function test_setTreasury_asNonOwner_thenReverts() external prankAs(user_A) {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user_A));
        underTest.setTreasury(address(0));
    }

    function test_setTreasury_whenTreasuryIsZero_thenReverts() external prankAs(owner) {
        vm.expectRevert(IHero3D.TreasuryCannotBeZero.selector);
        underTest.setTreasury(address(0));
    }

    function test_setTreasury_thenUpdates() external prankAs(owner) {
        address newTreasury = generateAddress();

        expectExactEmit();
        emit IHero3D.TreasuryUpdated(newTreasury);
        underTest.setTreasury(newTreasury);

        assertEq(underTest.treasury(), newTreasury);
    }

    function test_setFullWeightCost_asNonOwner_thenReverts() external prankAs(user_A) {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user_A));
        underTest.setFullWeightCost(0);
    }

    function test_setFullWeightCost_whenFullWeightCostIsZero_thenReverts() external prankAs(owner) {
        vm.expectRevert(IHero3D.FullWeightCostCannotBeZero.selector);
        underTest.setFullWeightCost(0);
    }

    function test_setFullWeightCost_thenUpdates() external prankAs(owner) {
        uint128 newFullWeightCost = 0.1 ether;

        expectExactEmit();
        emit IHero3D.FullWeightCostUpdated(newFullWeightCost);
        underTest.setFullWeightCost(newFullWeightCost);

        assertEq(underTest.fullWeightCost(), newFullWeightCost);
    }

    function getExpectedLatestTail(uint256 _blockNumber, uint256 _minimumBlockAge, uint256 _groupSize)
        private
        pure
        returns (uint256)
    {
        uint256 latestBlock = _blockNumber + _minimumBlockAge;
        uint256 latestTailBlock = latestBlock - (latestBlock % _groupSize);
        return latestTailBlock < _blockNumber + _minimumBlockAge ? latestTailBlock + _groupSize : latestTailBlock;
    }

    function getGuessWeight(uint256 _nativeSent) private view returns (uint128) {
        return uint128(Math.mulDiv(_nativeSent, 1e18, underTest.fullWeightCost()));
    }
}
