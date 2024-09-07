// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IGuessOurBlock {
    error InvalidAmount();
    error BlockTooSoon();
    error BlockTooOld();
    error MismatchArrays();
    error AlreadyClaimed();
    error NoReward();
    error RoundNotStarted();
    error ExceedBPSMaximum();
    error InvalidTailBlockNumber();
    error CanNoLongerUpdateDripVault();
    error DripVaultCannotBeZero();
    error InvalidSender();

    event BlockWon(bytes32 indexed lzGuid, uint32 indexed blockId, uint128 lot);
    event Guessed(address indexed wallet, uint32 indexed blockId, uint128 guessWeight, uint128 nativeSent);
    event Claimed(address indexed wallet, uint32 indexed blockId, uint128 winningPot);
    event Donated(address indexed from, uint256 amount);
    event MinimumBlockAgeUpdated(uint32 minimumAgeInBlockNumber);
    event RoundPauseTimerUpdated(uint32 pauseTimer);
    event FeeUpdated(FeeStructure fee);
    event GroupSizeUpdated(uint32 groupSize);
    event ErrorBlockAlreadyCompleted(uint32 blockId);
    event DripVaultUpdated(address indexed dripVault);
    event DripVaultMigrationStarted();
    event DripVaultMigrationCompleted();
    event DripVaultIsPermanentlySet();

    struct BlockMetadata {
        uint128 winningLot;
        uint128 totalGuessWeight;
        bool isCompleted;
    }

    struct BlockAction {
        uint128 guessWeight;
        bool claimed;
    }

    struct FeeStructure {
        uint32 treasury;
        uint32 validator;
        uint32 nextRound;
    }

    /**
     * @notice Guess the block number that will be called by a heroglyph validator using GOB's ticker
     * @param _blockNumberTail The block number tail to guess
     * @dev The user must pay the amount of ETH equivalent to the quantity of guesses they want to make
     * @dev The guess amount cannot be zero
     * @dev the guessed block needs to be older than the `minimumBlockAge` compared to the current block
     * @dev the block needs to be after the `nextRoundStart` timestamp
     */
    function guess(uint32 _blockNumberTail) external payable;

    /**
     * @notice Guess the block number that will be called by a heroglyph validator using GOB's ticker
     * @param _blockNumbers The block numbers to guess
     * @param _allocatedEthByGroups The amount of ETH allocated to each group
     * @dev The user must pay the amount of ETH equivalent to the quantity of guesses they want to make
     * @dev The guess amount cannot be zero
     * @dev the guessed block needs to be older than the `minimumBlockAge` compared to the current block
     * @dev the block needs to be after the `nextRoundStart` timestamp
     */
    function multiGuess(uint32[] calldata _blockNumbers, uint128[] calldata _allocatedEthByGroups) external payable;

    /**
     * @notice Claim the winning pot of a block
     * @param _blockTailNumber The block tail to claim
     * @return toUser_ The amount of ETH sent to the user
     */
    function claim(uint32 _blockTailNumber) external returns (uint128 toUser_);

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
     * @notice Get the latest, valid, tail block number
     */
    function getLatestTail() external view returns (uint32 latestTailBlock_);
}
