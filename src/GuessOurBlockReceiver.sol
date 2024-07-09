// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IGuessOurBlock } from "./IGuessOurBlock.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { OAppReceiver } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppReceiver.sol";
import { OAppCore, Origin } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract GuessOurBlockReceiver is IGuessOurBlock, OAppReceiver {
    uint32 public constant NATIVE_SEND_GAS_LIMIT = 32_000;
    uint32 public constant MAX_BPS = 10_000;
    uint128 public constant TOO_LOW_BALANCE = 0.1e18;

    FeeStructure private feeBps;
    address public treasury;
    uint128 public cost;
    uint128 public lot;

    mapping(uint32 blockId => BlockMetadata) private blockDatas;
    mapping(address user => mapping(uint32 blockId => BlockAction)) private actions;
    mapping(address wallet => uint128) private failedNativeSend;

    uint32 public pauseRoundTimer;
    uint32 public nextRoundStart;
    uint32 public minimumBlockAge;

    constructor(address _lzEndpoint, address _owner, address _treasury) OAppCore(_lzEndpoint, _owner) Ownable(_owner) {
        treasury = _treasury;
        cost = 0.025 ether;
        feeBps = FeeStructure({ treasury: 200, validator: 300, nextRound: 1500 });

        minimumBlockAge = 7200;
        pauseRoundTimer = 1 weeks;
        nextRoundStart = uint32(block.timestamp) + pauseRoundTimer;
    }

    /// @inheritdoc IGuessOurBlock
    function guess(uint32 _blockNumber, uint32 _guessAmount) external payable override {
        if (msg.value != (cost * _guessAmount)) revert InvalidAmount();
        _guess(_blockNumber, _guessAmount);
    }

    /// @inheritdoc IGuessOurBlock
    function multiGuess(uint32[] calldata _blockNumbers, uint32[] calldata _guessAmounts) external payable override {
        if (_blockNumbers.length != _guessAmounts.length) revert MismatchArrays();

        uint256 totalCost = 0;
        uint32 guesses;

        for (uint256 i = 0; i < _blockNumbers.length; ++i) {
            guesses = _guessAmounts[i];
            totalCost += guesses * cost;
            _guess(_blockNumbers[i], guesses);
        }

        if (msg.value != totalCost || totalCost == 0) revert InvalidAmount();
    }

    function _guess(uint32 _blockNumber, uint32 _guessAmount) internal {
        if (_guessAmount == 0) revert InvalidGuessAmount();
        if (nextRoundStart > block.timestamp) revert RoundNotStarted();

        //We estimated the timestamp, which will be inaccurate, but we don't need it to be.
        if (block.number > _blockNumber || _blockNumber - block.number < minimumBlockAge) {
            revert BlockTooSoon();
        }

        BlockAction storage action = actions[msg.sender][_blockNumber];
        action.voted += _guessAmount;

        blockDatas[_blockNumber].totalGuess += _guessAmount;
        lot += uint128(cost * _guessAmount);

        emit Guessed(msg.sender, _blockNumber, _guessAmount);
    }

    function _lzReceive(
        Origin calldata,
        bytes32 _guid,
        bytes calldata _message,
        address, /*_executor*/ // @dev unused in the default implementation.
        bytes calldata /*_extraData*/ // @dev unused in the default implementation.
    ) internal virtual override {
        FeeStructure memory cachedFee = feeBps;
        uint128 winningLot = lot;
        lot = 0;

        (uint32 blockNumber, address validator) = abi.decode(_message, (uint32, address));
        BlockMetadata storage blockMetadata = blockDatas[blockNumber];

        if (blockMetadata.isCompleted) revert BlockAlreadyCompleted();

        nextRoundStart = uint32(block.timestamp) + pauseRoundTimer;
        blockMetadata.isCompleted = true;

        emit BlockWon(_guid, blockNumber, winningLot);
        if (winningLot == 0) return;

        uint128 treasuryTax = uint128(Math.mulDiv(winningLot, cachedFee.treasury, MAX_BPS));
        uint128 validatorTax = uint128(Math.mulDiv(winningLot, cachedFee.validator, MAX_BPS));
        uint128 nextRound = uint128(Math.mulDiv(winningLot, cachedFee.nextRound, MAX_BPS));

        if (nextRound > TOO_LOW_BALANCE) {
            lot = nextRound;
            winningLot -= nextRound;
        }

        if (cachedFee.validator != 0 && validator != address(0)) {
            winningLot -= validatorTax;
            _sendNative(validator, validatorTax);
        }

        if (cachedFee.treasury != 0) {
            winningLot -= treasuryTax;
            _sendNative(treasury, treasuryTax);
        }

        if (blockMetadata.totalGuess == 0) {
            lot += winningLot;
        } else {
            blockMetadata.winningLot = winningLot;
        }
    }

    /// @inheritdoc IGuessOurBlock
    function claim(uint32 _blockId) external override {
        BlockAction storage action = actions[msg.sender][_blockId];
        BlockMetadata memory data = blockDatas[_blockId];

        if (action.voted == 0) revert NotVoted();
        if (action.claimed) revert AlreadyClaimed();

        uint128 winningPot = uint128(data.winningLot / data.totalGuess * action.voted);
        if (winningPot == 0) revert NoReward();

        action.claimed = true;

        _sendNative(msg.sender, winningPot);
        emit Claimed(msg.sender, _blockId, winningPot);
    }

    function _sendNative(address _to, uint128 _amount) internal {
        (bool success,) = _to.call{ value: _amount, gas: NATIVE_SEND_GAS_LIMIT }("");

        if (!success) {
            failedNativeSend[_to] += _amount;
        }
    }

    /// @inheritdoc IGuessOurBlock
    function retryNativeSend() external override {
        uint128 pending = failedNativeSend[msg.sender];
        if (pending == 0) revert NoFailedETHPending();

        failedNativeSend[msg.sender] = 0;

        (bool success,) = msg.sender.call{ value: pending }("");
        if (!success) revert FailedToSendETH();
    }

    /// @inheritdoc IGuessOurBlock
    function donate() external payable override {
        lot += uint128(msg.value);
        emit Donated(msg.sender, msg.value);
    }

    function updateFee(FeeStructure calldata _fee) external onlyOwner {
        feeBps = _fee;
        if (_fee.treasury + _fee.validator + _fee.nextRound > MAX_BPS) revert ExceedBPSMaximum();

        emit FeeUpdated(_fee);
    }

    function updatePauseTimer(uint32 _pauseTimerInSecond) external onlyOwner {
        pauseRoundTimer = _pauseTimerInSecond;
        emit RoundPauseTimerUpdated(_pauseTimerInSecond);
    }

    function updateMinimumBlockAge(uint32 _minimumBlockAgeInBlock) external onlyOwner {
        minimumBlockAge = _minimumBlockAgeInBlock;
        emit MinimumBlockAgeUpdated(_minimumBlockAgeInBlock);
    }

    /// @inheritdoc IGuessOurBlock
    function getPendingReward(address _user, uint32 _blockId) external view override returns (uint256) {
        BlockAction memory action = actions[_user][_blockId];
        BlockMetadata memory data = blockDatas[_blockId];
        uint256 totalGuess = data.totalGuess;

        if (action.voted == 0 || action.claimed || totalGuess == 0) return 0;

        return data.winningLot / totalGuess * action.voted;
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

    /// @inheritdoc IGuessOurBlock
    function getFailedNative(address _user) external view override returns (uint128) {
        return failedNativeSend[_user];
    }
}
