// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IFactoryContract
 * @dev Interface for Factory Contract functions needed by Tender Contract
 */
interface IFactoryContract {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function BIDDER_ROLE() external view returns (bytes32);
    function getUserProfile(address user) external view returns (
        string memory metadata,
        uint256 reputation,
        uint256 stakedAmount
    );
    function updateAnalytics(address winner, uint256 amount, bool success) external;
} 
