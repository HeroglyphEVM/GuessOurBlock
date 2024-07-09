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
    event MinimumBlockAgeUpdated(uint32 minimumAgeInBlockNumber);
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

    /**
     * @notice Guess the block number that will be called by a heroglyph validator using GOB's ticker
     * @param _blockNumber The block number to guess
     * @param _quantityGuess The quantity of guesses to make
     * @dev The user must pay the amount of ETH equivalent to the quantity of guesses they want to make
     * @dev The guess amount cannot be zero
     * @dev the guessed block needs to be older than the `minimumBlockAge` compared to the current block
     * @dev the block needs to be after the `nextRoundStart` timestamp
     */
    function guess(uint32 _blockNumber, uint32 _quantityGuess) external payable;

    /**
     * @notice Guess the block number that will be called by a heroglyph validator using GOB's ticker
     * @param _blockNumbers The block numbers to guess
     * @param _quantityGuesses The quantity of guesses to make
     * @dev The user must pay the amount of ETH equivalent to the quantity of guesses they want to make
     * @dev The guess amount cannot be zero
     * @dev the guessed block needs to be older than the `minimumBlockAge` compared to the current block
     * @dev the block needs to be after the `nextRoundStart` timestamp
     */
    function multiGuess(uint32[] calldata _blockNumbers, uint32[] calldata _quantityGuesses) external payable;

    /**
     * @notice Claim the winning pot of a block
     * @param _blockId The block id to claim
     */
    function claim(uint32 _blockId) external;

    /**
     * @notice If the system failed to send ETH, you can retry the transaction with this function
     */
    function retryNativeSend() external;

    /**
     * @notice Donate ETH to the contract to increase the lot reward
     * @dev There is no advantage to donate. It's just to increase the lot reward
     */
    function donate() external payable;

    /**
     * @notice Get the pending reward of a user for a block
     * @param _user The address of the user
     * @param _blockId The block id
     */
    function getPendingReward(address _user, uint32 _blockId) external view returns (uint256);

    /**
     * @notice Get the fee structure
     */
    function getFeeStructure() external view returns (FeeStructure memory);

    /**
     * @notice Get the user action for a block
     * @param _user The address of the user
     * @param _blockId The block id
     */
    function getUserAction(address _user, uint32 _blockId) external view returns (BlockAction memory);

    /**
     * @notice Get the block data
     * @param _blockId The block id
     */
    function getBlockData(uint32 _blockId) external view returns (BlockMetadata memory);

    /**
     * @notice Get the failed native of a user
     * @param _user The address of the user
     */
    function getFailedNative(address _user) external view returns (uint128);
}
