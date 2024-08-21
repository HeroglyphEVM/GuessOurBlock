// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IGuessOurBlock } from "./IGuessOurBlock.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { OAppReceiver } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppReceiver.sol";
import { OAppCore, Origin } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";

import { IDripVault } from "src/dripVaults/IDripVault.sol";

contract GuessOurBlockReceiver is IGuessOurBlock, Ownable, OAppReceiver {
    uint32 public constant MAX_BPS = 10_000;
    uint128 public constant TOO_LOW_BALANCE = 0.1e18;

    FeeStructure private feeBps;
    address public treasury;
    IDripVault public dripVault;

    uint128 public fullWeightCost;
    uint128 public lot;
    uint32 public groupSize;

    mapping(uint32 blockId => BlockMetadata) private blockDatas;
    mapping(address user => mapping(uint32 blockId => BlockAction)) private actions;
    mapping(address wallet => uint128) private failedNativeSend;

    uint32 public pauseRoundTimer;
    uint32 public nextRoundStart;
    uint32 public minimumBlockAge;

    bool public isMigratingDripVault;
    bool public permanentlySetDripVault;

    constructor(address _lzEndpoint, address _owner, address _treasury, address _dripVault)
        OAppCore(_lzEndpoint, _owner)
        Ownable(_owner)
    {
        if (_dripVault == address(0)) revert DripVaultCannotBeZero();

        treasury = _treasury;
        fullWeightCost = 0.025 ether;
        groupSize = 100;
        feeBps = FeeStructure({ treasury: 200, validator: 300, nextRound: 1500 });

        minimumBlockAge = 7200;
        pauseRoundTimer = 1 weeks;
        nextRoundStart = uint32(block.timestamp) + pauseRoundTimer;
        dripVault = IDripVault(_dripVault);
    }

    /// @inheritdoc IGuessOurBlock
    function guess(uint32 _blockNumber) external payable override {
        _guess(_blockNumber, uint128(msg.value));
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
    }

    function _guess(uint32 _tailBlockNumber, uint128 _nativeSent) internal {
        if (_nativeSent == 0) revert InvalidAmount();
        if (nextRoundStart > block.timestamp) revert RoundNotStarted();
        if (!_isValidTailBlockNumber(_tailBlockNumber)) revert InvalidTailBlockNumber();

        //We estimated the timestamp, which will be inaccurate, but we don't need it to be.
        if (block.number > _tailBlockNumber || _tailBlockNumber - block.number < minimumBlockAge) {
            revert BlockTooSoon();
        }

        BlockAction storage action = actions[msg.sender][_tailBlockNumber];
        uint128 guessWeight = uint128(Math.mulDiv(_nativeSent, 1e18, fullWeightCost));
        action.guessWeight += guessWeight;

        blockDatas[_tailBlockNumber].totalGuessWeight += guessWeight;
        lot += uint128(_nativeSent);

        emit Guessed(msg.sender, _tailBlockNumber, guessWeight, _nativeSent);
    }

    function _isValidTailBlockNumber(uint32 _tailBlockNumber) internal view returns (bool) {
        return _tailBlockNumber % groupSize == 0;
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

        uint32 blockNumberTail = blockNumber - (blockNumber % groupSize);
        BlockMetadata storage blockMetadata = blockDatas[blockNumberTail];

        // Simply process the message to avoid LZ blockage.
        if (blockMetadata.isCompleted) {
            emit ErrorBlockAlreadyCompleted(blockNumberTail);
            return;
        }

        nextRoundStart = uint32(block.timestamp) + pauseRoundTimer;
        blockMetadata.isCompleted = true;

        emit BlockWon(_guid, blockNumberTail, winningLot);

        if (winningLot == 0) return;
        if (blockMetadata.totalGuessWeight == 0) {
            lot = winningLot;
            return;
        }

        if (blockMetadata.totalGuessWeight < 1e18) {
            uint128 reducedLot = uint128(Math.mulDiv(winningLot, blockMetadata.totalGuessWeight, 1e18));
            lot = winningLot - reducedLot;
            winningLot = reducedLot;
        }

        uint128 treasuryTax = uint128(Math.mulDiv(winningLot, cachedFee.treasury, MAX_BPS));
        uint128 validatorTax = uint128(Math.mulDiv(winningLot, cachedFee.validator, MAX_BPS));
        uint128 nextRound = uint128(Math.mulDiv(winningLot, cachedFee.nextRound, MAX_BPS));

        if (nextRound > TOO_LOW_BALANCE) {
            lot += nextRound;
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

        _sendNative(msg.sender, toUser_);
        emit Claimed(msg.sender, _blockTailNumber, toUser_);

        return toUser_;
    }

    function _sendNative(address _to, uint128 _amount) internal {
        (bool success,) = _to.call{ value: _amount }("");

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

    function updateGroupSize(uint32 _groupSize) external onlyOwner {
        groupSize = _groupSize;
        emit GroupSizeUpdated(_groupSize);
    }

    /**
     * @notice Update the drip vault address. Due of some drip vaults might contains withdrawal delay, we are sending
     * the fund to the treasury first.
     * @dev If the community doesn't like it and are fine with the current drip vault, they can vote to remove this
     * function.
     */
    function updateDripVault(address _dripVault) external onlyOwner {
        if (permanentlySetDripVault) revert CanNoLongerUpdateDripVault();
        if (_dripVault == address(0)) revert DripVaultCannotBeZero();

        uint256 totalDeposit = dripVault.getTotalDeposit();
        dripVault.withdraw(treasury, totalDeposit);

        dripVault = IDripVault(_dripVault);
        isMigratingDripVault = true;

        emit DripVaultUpdated(_dripVault);
        emit DripVaultMigrationStarted();
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

    /// @inheritdoc IGuessOurBlock
    function getFailedNative(address _user) external view override returns (uint128) {
        return failedNativeSend[_user];
    }

    function getLatestTail() external view override returns (uint32 latestTailBlock_) {
        uint32 latestBlock = uint32(block.number + minimumBlockAge);
        latestTailBlock_ = latestBlock - (latestBlock % groupSize);

        return latestTailBlock_ < block.number + minimumBlockAge ? latestTailBlock_ + groupSize : latestTailBlock_;
    }

    receive() external payable { }
}
