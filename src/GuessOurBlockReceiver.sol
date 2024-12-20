// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IGuessOurBlock } from "./IGuessOurBlock.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { OAppReceiver } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppReceiver.sol";
import { OAppCore, Origin } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";

import { IDripVault } from "src/dripVaults/IDripVault.sol";

contract GuessOurBlockReceiver is IGuessOurBlock, Ownable, OAppReceiver {
    uint256 private constant PRECISION = 1e18;
    uint32 public constant MAX_BPS = 10_000;
    uint128 public constant TOO_LOW_BALANCE = 0.1e18;
    uint128 public constant MINIMUM_GUESS_AMOUNT = 0.005 ether;
    // Validator can know their next block at least 1 Epoch (32 blocks) in advance.
    uint32 public constant MINIMUM_BLOCK_AGE = 33;
    uint32 public constant GROUP_SIZE = 10;

    address public treasury;
    uint32 public minimumBlockAge;
    bool public isMigratingDripVault;
    bool public permanentlySetDripVault;

    IDripVault public dripVault;
    FeeStructure private feeBps;

    // 1 complete ticket cost
    uint128 public fullWeightCost;
    uint128 public lot;

    mapping(uint32 blockId => BlockMetadata) private blockDatas;
    mapping(address user => mapping(uint32 blockId => BlockAction)) private actions;

    constructor(address _lzEndpoint, address _owner, address _treasury) OAppCore(_lzEndpoint, _owner) Ownable(_owner) {
        treasury = _treasury;
        fullWeightCost = 0.1 ether;
        feeBps = FeeStructure({ treasury: 200, validator: 300, nextRound: 1500 });

        // Note: Even if the minimum block age is 33, we are setting it to two epoch to be safe
        minimumBlockAge = MINIMUM_BLOCK_AGE * 2;
    }

    /// @inheritdoc IGuessOurBlock
    function guess(uint32 _blockNumber) external payable override {
        _guess(_blockNumber, uint128(msg.value));
        dripVault.deposit{ value: msg.value }();
    }

    /// @inheritdoc IGuessOurBlock
    function multiGuess(uint32[] calldata _tailBlockNumbers, uint128[] calldata _allocatedEthByGroups)
        external
        payable
        override
    {
        if (_tailBlockNumbers.length != _allocatedEthByGroups.length) revert MismatchArrays();

        uint128 totalCost;
        uint128 allocatedEth;

        for (uint256 i = 0; i < _tailBlockNumbers.length; ++i) {
            allocatedEth = _allocatedEthByGroups[i];
            totalCost += allocatedEth;
            _guess(_tailBlockNumbers[i], allocatedEth);
        }

        if (msg.value != totalCost || totalCost == 0) revert InvalidAmount();
        dripVault.deposit{ value: msg.value }();
    }

    function _guess(uint32 _tailBlockNumber, uint128 _nativeSent) internal {
        if (_nativeSent < MINIMUM_GUESS_AMOUNT) revert InvalidAmount();
        if (!_isValidTailBlockNumber(_tailBlockNumber)) revert InvalidTailBlockNumber();

        //We estimated the timestamp, which will be inaccurate, but we don't need it to be.
        if (block.number > _tailBlockNumber) {
            revert BlockTooOld();
        }
        if (_tailBlockNumber - block.number < minimumBlockAge) {
            revert BlockTooSoon();
        }

        BlockAction storage action = actions[msg.sender][_tailBlockNumber];
        uint128 guessWeight = uint128(Math.mulDiv(_nativeSent, PRECISION, fullWeightCost));
        action.guessWeight += guessWeight;

        blockDatas[_tailBlockNumber].totalGuessWeight += guessWeight;
        lot += _nativeSent;

        emit Guessed(msg.sender, _tailBlockNumber, guessWeight, _nativeSent);
    }

    function _isValidTailBlockNumber(uint32 _tailBlockNumber) internal pure returns (bool) {
        return _tailBlockNumber % GROUP_SIZE == 0;
    }

    function _lzReceive(
        Origin calldata,
        bytes32 _guid,
        bytes calldata _message,
        address, /*_executor*/ // @dev unused in the default implementation.
        bytes calldata /*_extraData*/ // @dev unused in the default implementation.
    ) internal virtual override {
        if (isMigratingDripVault) return;

        FeeStructure memory cachedFee = feeBps;
        uint128 winningLot = lot;
        uint128 newLot = 0;

        (uint32 blockNumber, address validator) = abi.decode(_message, (uint32, address));

        uint32 blockNumberTail = blockNumber - (blockNumber % GROUP_SIZE);
        BlockMetadata storage blockMetadata = blockDatas[blockNumberTail];

        uint128 cachedTotalGuessWeight = blockMetadata.totalGuessWeight;
        IDripVault cachedDripVault = dripVault;

        // Simply process the message to avoid LZ blockage.
        if (blockMetadata.isCompleted) {
            emit ErrorBlockAlreadyCompleted(blockNumberTail);
            return;
        }

        blockMetadata.isCompleted = true;

        emit BlockWon(_guid, blockNumberTail, winningLot);

        if (winningLot == 0) return;
        if (cachedTotalGuessWeight == 0) {
            lot = winningLot;
            return;
        }

        if (cachedTotalGuessWeight < PRECISION) {
            uint128 reducedLot = uint128(Math.mulDiv(winningLot, cachedTotalGuessWeight, PRECISION));
            newLot = winningLot - reducedLot;
            winningLot = reducedLot;
        }

        uint128 treasuryTax = uint128(Math.mulDiv(winningLot, cachedFee.treasury, MAX_BPS));
        uint128 validatorTax = uint128(Math.mulDiv(winningLot, cachedFee.validator, MAX_BPS));
        uint128 nextRound = uint128(Math.mulDiv(winningLot, cachedFee.nextRound, MAX_BPS));

        if (nextRound > TOO_LOW_BALANCE) {
            newLot += nextRound;
            winningLot -= nextRound;
        }

        if (cachedFee.validator != 0 && validator != address(0)) {
            winningLot -= validatorTax;
            cachedDripVault.withdraw(validator, validatorTax);
        }

        if (cachedFee.treasury != 0) {
            winningLot -= treasuryTax;
            cachedDripVault.withdraw(treasury, treasuryTax);
        }

        lot = newLot;
        blockMetadata.winningLot = winningLot;
    }

    /// @inheritdoc IGuessOurBlock
    function claim(uint32 _blockTailNumber) external override returns (uint128 toUser_) {
        BlockAction storage action = actions[msg.sender][_blockTailNumber];
        BlockMetadata memory data = blockDatas[_blockTailNumber];

        if (action.claimed) revert AlreadyClaimed();
        action.claimed = true;

        toUser_ = _getSanitizedUserWinnings(data.winningLot, action.guessWeight, data.totalGuessWeight);
        if (toUser_ == 0) revert NoReward();

        dripVault.withdraw(msg.sender, toUser_);

        emit Claimed(msg.sender, _blockTailNumber, toUser_);

        return toUser_;
    }

    /// @inheritdoc IGuessOurBlock
    function donate() external payable override {
        lot += uint128(msg.value);
        dripVault.deposit{ value: msg.value }();
        emit Donated(msg.sender, msg.value);
    }

    function updateFee(FeeStructure calldata _fee) external onlyOwner {
        feeBps = _fee;
        if (_fee.treasury + _fee.validator + _fee.nextRound > MAX_BPS) revert ExceedBPSMaximum();

        emit FeeUpdated(_fee);
    }

    function updateMinimumBlockAge(uint32 _minimumBlockAgeInBlock) external onlyOwner {
        if (_minimumBlockAgeInBlock < MINIMUM_BLOCK_AGE) revert MinimumBlockAgeCannotBeLowerThanOneEpoch();

        minimumBlockAge = _minimumBlockAgeInBlock;
        emit MinimumBlockAgeUpdated(_minimumBlockAgeInBlock);
    }

    /**
     * @notice Update the drip vault address. Due of some drip vaults might contains withdrawal delay, we are sending
     * the fund to the treasury first.
     * @dev If the community doesn't like it and are fine with the current drip vault, they can vote to remove this
     * function.
     */
    function updateDripVault(address _dripVault) external onlyOwner {
        address cachedDripVault = _dripVault;

        if (permanentlySetDripVault) revert CanNoLongerUpdateDripVault();
        if (cachedDripVault == address(0)) revert DripVaultCannotBeZero();
        if (isMigratingDripVault) revert AlreadyMigrating();

        if (address(dripVault) != address(0)) {
            uint256 totalDeposit = dripVault.getTotalDeposit();
            dripVault.withdraw(treasury, totalDeposit);
            isMigratingDripVault = true;
            emit DripVaultMigrationStarted();
        }

        dripVault = IDripVault(cachedDripVault);
        emit DripVaultUpdated(cachedDripVault);
    }

    function completeDripVaultMigration() external onlyOwner {
        isMigratingDripVault = false;
        emit DripVaultMigrationCompleted();
    }

    function setPermanentlySetDripVault() external onlyOwner {
        permanentlySetDripVault = true;
        emit DripVaultIsPermanentlySet();
    }

    /// @inheritdoc IGuessOurBlock
    function getPendingReward(address _user, uint32 _blockId) external view override returns (uint256 winning_) {
        BlockAction memory action = actions[_user][_blockId];
        BlockMetadata memory data = blockDatas[_blockId];

        if (action.claimed) return 0;

        return _getSanitizedUserWinnings(data.winningLot, action.guessWeight, data.totalGuessWeight);
    }

    function _getSanitizedUserWinnings(uint128 _winningLot, uint128 _userWeight, uint128 _totalGuessWeight)
        internal
        pure
        returns (uint128 /*toUser_*/ )
    {
        if (_winningLot == 0 || _userWeight == 0 || _totalGuessWeight == 0) return 0;
        return uint128(Math.mulDiv(_winningLot, _userWeight, _totalGuessWeight));
    }

    /// @inheritdoc IGuessOurBlock
    function getFeeStructure() external view override returns (FeeStructure memory) {
        return feeBps;
    }

    /// @inheritdoc IGuessOurBlock
    function getUserAction(address _user, uint32 _blockId) external view override returns (BlockAction memory) {
        return actions[_user][_blockId];
    }

    /// @inheritdoc IGuessOurBlock
    function getBlockData(uint32 _blockId) external view override returns (BlockMetadata memory) {
        return blockDatas[_blockId];
    }

    function getLatestTail() external view override returns (uint32 latestTailBlock_) {
        uint32 cachedMinimumBlockAge = minimumBlockAge;
        uint32 latestBlock = uint32(block.number + cachedMinimumBlockAge);
        latestTailBlock_ = latestBlock - (latestBlock % GROUP_SIZE);

        return
            latestTailBlock_ < block.number + cachedMinimumBlockAge ? latestTailBlock_ + GROUP_SIZE : latestTailBlock_;
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert TreasuryCannotBeZero();

        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setFullWeightCost(uint128 _fullWeightCost) external onlyOwner {
        if (_fullWeightCost == 0) revert FullWeightCostCannotBeZero();

        fullWeightCost = _fullWeightCost;
        emit FullWeightCostUpdated(_fullWeightCost);
    }
}
