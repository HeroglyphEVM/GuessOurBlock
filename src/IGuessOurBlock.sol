// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IGuessOurBlock {
    error InvalidAmount();
    error BlockTooSoon();
    error MismatchArrays();
    error NotVoted();
    error AlreadyClaimed();
    error NoReward();
    error InvalidGuessAmount();
    error RoundNotStarted();
    error ExceedBPSMaximum();
    error BlockAlreadyCompleted();
    error FailedToSendETH();
    error NoFailedETHPending();

    event BlockWon(bytes32 indexed lzGuid, uint32 indexed blockId, uint128 lot);
    event Guessed(address indexed wallet, uint32 indexed blockId, uint128 quantityGuess);
    event Claimed(address indexed wallet, uint32 indexed blockId, uint128 winningPot);
    event Donated(address indexed from, uint256 amount);
    event MinimumBlockAgeUpdated(uint32 minimumAgeInSeconds);
    event RoundPauseTimerUpdated(uint32 pauseTimer);
    event FeeUpdated(FeeStructure fee);

    struct BlockMetadata {
        uint128 winningLot;
        uint32 totalGuess;
        bool isCompleted;
    }

    struct BlockAction {
        uint32 voted;
        bool claimed;
    }

    struct FeeStructure {
        uint32 treasury;
        uint32 validator;
        uint32 nextRound;
    }

    function guess(uint32 _blockNumber, uint32 _quantityGuess) external payable;

    function multiGuess(uint32[] calldata _blockNumbers, uint32[] calldata _quantityGuesses) external payable;
}
