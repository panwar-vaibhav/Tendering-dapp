// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library TenderOperations {
    struct Bid {
        uint256 amount;
        uint256 stake;
        string ipfsHash;
        uint8 status;  // Using uint8 instead of enum to save gas
    }

    struct TenderDetails {
        address organization;
        string ipfsHash;
        uint256 startTime;
        uint256 endTime;
        uint256 minimumBid;
        uint256 bidWeight;
        uint256 reputationWeight;
        uint8 status;  // Using uint8 instead of enum to save gas
        address winner;
        bool isInitialized;
        uint256 activeBidders;
    }

    function validateBid(
        uint256 bidAmount,
        uint256 minimumBid,
        uint256 requiredStake,
        uint256 msgValue,
        bytes memory ipfsHash
    ) 
        internal 
        pure 
    {
        require(bidAmount >= minimumBid, "Low bid");
        require(msgValue == requiredStake, "Wrong stake");
        require(ipfsHash.length > 0 && ipfsHash.length <= 100, "Bad hash");
    }

    function refundStake(
        address bidder,
        uint256 stakeAmount
    ) 
        internal 
        returns (bool) 
    {
        (bool success, ) = payable(bidder).call{value: stakeAmount}("");
        return success;
    }

    function validateTenderState(
        uint8 currentStatus,
        uint256 activeBidders,
        uint256 minBidders,
        address winner
    ) 
        internal 
        pure 
    {
        require(currentStatus == 1, "Not active"); // 1 = Active status
        require(activeBidders >= minBidders, "Few bidders");
        require(winner == address(0), "Has winner");
    }

    function updateBidStatus(
        Bid storage bid,
        uint8 newStatus
    ) 
        internal 
    {
        bid.stake = 0;
        bid.status = newStatus;
    }

    function validateWithdrawal(
        uint256 contractBalance,
        uint256 totalStakeHeld,
        uint256 biddersLength
    ) 
        internal 
        pure 
    {
        require(contractBalance >= totalStakeHeld, "Low balance");
        require(biddersLength <= 100, "Too many");
    }
} 