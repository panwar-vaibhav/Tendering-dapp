// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

library FactoryLibrary {
    using EnumerableSet for EnumerableSet.AddressSet;

    struct UserProfile {
        string metadata;           
        uint256 reputation;        
        uint256 stakedAmount;      
    }

    struct Analytics {
        uint256 totalBids;
        uint256 tendersWon;
        uint256 totalTendersParticipated;
        uint256 averageBidAmount;
        uint256 lastActivityTime;
    }

    function updateAnalytics(
        Analytics storage analytics,
        uint256 bidAmount,
        bool wonTender
    ) 
        internal 
    {
        analytics.totalBids++;
        if (wonTender) {
            analytics.tendersWon++;
        }
        analytics.totalTendersParticipated++;
        
        if (analytics.averageBidAmount == 0) {
            analytics.averageBidAmount = bidAmount;
        } else {
            analytics.averageBidAmount = (analytics.averageBidAmount + bidAmount) / 2;
        }
        analytics.lastActivityTime = block.timestamp;
    }

    function validateStake(
        uint256 stakeAmount,
        uint256 minStakeAmount
    ) 
        internal 
        pure 
    {
        require(stakeAmount >= minStakeAmount, "Low stake");
    }

    function deployClone(address implementation) 
        internal 
        returns (address payable) 
    {
        bytes20 implementationBytes = bytes20(implementation);
        address clone;
        
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), implementationBytes)
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            clone := create(0, ptr, 0x37)
        }
        
        return payable(clone);
    }
} 