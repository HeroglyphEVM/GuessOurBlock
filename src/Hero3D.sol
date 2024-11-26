// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IHero3D } from "./IHero3D.sol";
import { TickerOperator } from "heroglyph-library/src/TickerOperator.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Hero3D
 * @author HeroGlyph
 * @notice Simplified version of GuessOurBlockReceiver.sol -- Used when Hero3D is hosted on the same chain as Heroglyphs
 * & We do not stake the lot.
 * @dev Arbitrum block.number reflects Ethereum Mainnet blocks;
 * https://docs.arbitrum.io/build-decentralized-apps/arbitrum-vs-ethereum/block-numbers-and-time#arbitrum-block-numbers
 */
contract Hero3D is IHero3D, Ownable, TickerOperator {
    uint256 private constant PRECISION = 1e18;
    uint32 public constant MAX_BPS = 10_000;
    uint128 public constant TOO_LOW_BALANCE = 0.1e18;
    uint128 public constant MINIMUM_GUESS_AMOUNT = 0.005 ether;
    // Validator can know their next block at least 1 Epoch (32 blocks) in advance.
    uint32 public constant MINIMUM_BLOCK_AGE = 33;
    uint32 public constant GROUP_SIZE = 10;

    address public treasury;
    uint32 public minimumBlockAge;

    FeeStructure private feeBps;

    // 1 complete ticket cost
    uint128 public fullWeightCost;
    uint128 public lot;

    mapping(uint32 blockId => BlockMetadata) private blockDatas;
    mapping(address user => mapping(uint32 blockId => BlockAction)) private actions;

    constructor(address _heroglyphRelay, address _owner, address _treasury)
        TickerOperator(_owner, _heroglyphRelay, address(0))
    {
        treasury = _treasury;
        fullWeightCost = 0.1 ether;
        feeBps = FeeStructure({ treasury: 200, validator: 300, nextRound: 1500 });

        // Note: Even if the minimum block age is 33, we are setting it to two epoch to be safe
        minimumBlockAge = MINIMUM_BLOCK_AGE * 2;
    }

    /// @inheritdoc IHero3D
    function guess(uint32 _blockNumber) external payable override {
        _guess(_blockNumber, uint128(msg.value));
    }

    /// @inheritdoc IHero3D
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

    function onValidatorTriggered(uint32, uint32 _blockNumber, address _validatorWithdrawer, uint128 _heroglyphFee)
        external
        override
        onlyRelay
    {
        _repayHeroglyph(_heroglyphFee);

        FeeStructure memory cachedFee = feeBps;
        uint128 winningLot = lot;
        uint128 newLot = 0;

        uint32 blockNumberTail = _blockNumber - (_blockNumber % GROUP_SIZE);
        BlockMetadata storage blockMetadata = blockDatas[blockNumberTail];

        uint128 cachedTotalGuessWeight = blockMetadata.totalGuessWeight;

        // Simply process the message to avoid LZ blockage.
        if (blockMetadata.isCompleted) {
            emit ErrorBlockAlreadyCompleted(blockNumberTail);
            return;
        }

        blockMetadata.isCompleted = true;

        emit BlockWon(blockNumberTail, winningLot);

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

        if (cachedFee.validator != 0 && _validatorWithdrawer != address(0)) {
            winningLot -= validatorTax;
            _sendNative(_validatorWithdrawer, validatorTax);
        }

        if (cachedFee.treasury != 0) {
            winningLot -= treasuryTax;
            _sendNative(treasury, treasuryTax);
        }

        lot = newLot;
        blockMetadata.winningLot = winningLot;
    }

    /// @inheritdoc IHero3D
    function claim(uint32 _blockTailNumber) external override returns (uint128 toUser_) {
        BlockAction storage action = actions[msg.sender][_blockTailNumber];
        BlockMetadata memory data = blockDatas[_blockTailNumber];

        if (action.claimed) revert AlreadyClaimed();
        action.claimed = true;

        toUser_ = _getSanitizedUserWinnings(data.winningLot, action.guessWeight, data.totalGuessWeight);
        if (toUser_ == 0) revert NoReward();

        _sendNative(msg.sender, toUser_);

        emit Claimed(msg.sender, _blockTailNumber, toUser_);

        return toUser_;
    }

    function _sendNative(address _to, uint128 _amount) internal {
        (bool success,) = _to.call{ value: _amount }("");
        if (!success) revert FailedToSendETH();
    }

    /// @inheritdoc IHero3D
    function donate() external payable override {
        lot += uint128(msg.value);
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

    /// @inheritdoc IHero3D
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

    /// @inheritdoc IHero3D
    function getFeeStructure() external view override returns (FeeStructure memory) {
        return feeBps;
    }

    /// @inheritdoc IHero3D
    function getUserAction(address _user, uint32 _blockId) external view override returns (BlockAction memory) {
        return actions[_user][_blockId];
    }

    /// @inheritdoc IHero3D
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
