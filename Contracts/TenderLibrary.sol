// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TenderLibrary
 * @dev Library containing helper functions for tender operations
 */
library TenderLibrary {
    /**
     * @dev Calculates bid score based on amount and reputation
     * @param minimumBid Minimum bid amount allowed
     * @param bidAmount Actual bid amount
     * @param reputation Bidder reputation score (0-100)
     * @param bidWeight Weight for bid amount in scoring (0-100)
     * @param reputationWeight Weight for reputation in scoring (0-100)
     * @return Weighted score combining bid and reputation
     */
    function calculateScore(
        uint256 minimumBid,
        uint256 bidAmount,
        uint256 reputation,
        uint256 bidWeight,
        uint256 reputationWeight
    ) 
        public 
        pure 
        returns (uint256) 
    {
        require(bidAmount > 0, "Invalid bid");
        require(reputation <= 100, "Invalid reputation");
        require(minimumBid <= type(uint256).max / 100, "Bid too high");
        
        // Normalize bid amount (inverse because lower bid is better)
        uint256 normalizedBid = (minimumBid * 100) / bidAmount;
        
        // Calculate weighted score
        return (normalizedBid * bidWeight + reputation * reputationWeight) / 100;
    }

    /**
     * @dev Validates tender parameters
     */
    function validateTenderParams(
        uint256 startTime,
        uint256 endTime,
        uint256 minimumBid,
        uint256 bidWeight,
        uint256 reputationWeight
    ) 
        public 
        view 
    {
        require(startTime >= block.timestamp, "Invalid start");
        require(endTime > startTime, "Invalid end");
        require(bidWeight + reputationWeight == 100, "Invalid weights");
        require(minimumBid > 0, "Invalid min bid");
    }
} 