// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

interface ITenderFactory {
    function getReputationScore(address bidder) external view returns (uint256);
    function updateReputation(address bidder, uint256 newScore) external;
}

contract TenderContract is AccessControl, ReentrancyGuard, Pausable {
    bytes32 public constant ORGANIZATION_ROLE = keccak256("ORGANIZATION_ROLE");
    
    struct Bid {
        uint256 amount;
        uint256 timestamp;
        uint256 score;
    }
    
    ITenderFactory public factory;
    address public organization;
    string public title;
    string public ipfsHash;
    uint256 public bidWeight;
    uint256 public reputationWeight;
    uint256 public startTime;
    uint256 public endTime;
    uint256 public minimumBid;
    
    address public winner;
    mapping(address => Bid) public bids;
    address[] public bidders;
    
    event BidPlaced(
        address indexed bidder,
        uint256 amount,
        uint256 timestamp
    );
    event WinnerSelected(
        address indexed winner,
        uint256 score
    );
    event BidderScores(
        address indexed bidder,
        uint256 score,
        uint256 bidAmount,
        uint256 reputation
    );
    
    constructor(
        address _factory,
        address _organization,
        string memory _title,
        string memory _ipfsHash,
        uint256 _bidWeight,
        uint256 _reputationWeight,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _minimumBid
    ) {
        require(_startTime > block.timestamp, "Invalid start time");
        require(_endTime > _startTime, "Invalid end time");
        require(_bidWeight + _reputationWeight == 100, "Weights must sum to 100");
        
        factory = ITenderFactory(_factory);
        organization = _organization;
        title = _title;
        ipfsHash = _ipfsHash;
        bidWeight = _bidWeight;
        reputationWeight = _reputationWeight;
        startTime = _startTime;
        endTime = _endTime;
        minimumBid = _minimumBid;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _organization);
        _grantRole(ORGANIZATION_ROLE, _organization);
    }
    
    function placeBid() external payable nonReentrant whenNotPaused {
        require(block.timestamp >= startTime, "Bidding not started");
        require(block.timestamp <= endTime, "Bidding ended");
        require(msg.value >= minimumBid, "Bid too low");
        require(bids[msg.sender].timestamp == 0, "Already bid");
        
        uint256 reputation = factory.getReputationScore(msg.sender);
        uint256 score = calculateScore(msg.value, reputation);
        
        bids[msg.sender] = Bid({
            amount: msg.value,
            timestamp: block.timestamp,
            score: score
        });
        bidders.push(msg.sender);
        
        emit BidPlaced(msg.sender, msg.value, block.timestamp);
        emit BidderScores(msg.sender, score, msg.value, reputation);
    }
    
    function selectWinner() external nonReentrant {
        require(hasRole(ORGANIZATION_ROLE, msg.sender), "Not authorized");
        require(block.timestamp > endTime, "Bidding not ended");
        require(winner == address(0), "Winner already selected");
        
        uint256 highestScore = 0;
        
        for (uint i = 0; i < bidders.length; i++) {
            address bidder = bidders[i];
            if (bids[bidder].score > highestScore) {
                highestScore = bids[bidder].score;
                winner = bidder;
            }
        }
        
        if (winner != address(0)) {
            // Update winner's reputation
            uint256 currentReputation = factory.getReputationScore(winner);
            uint256 newReputation = (currentReputation + 5) > 100 ? 100 : currentReputation + 5;
            factory.updateReputation(winner, newReputation);
            
            emit WinnerSelected(winner, highestScore);
            
            // Transfer bid amount to organization
            (bool success, ) = organization.call{value: bids[winner].amount}("");
            require(success, "Transfer failed");
        }
    }
    
    function calculateScore(
        uint256 bidAmount,
        uint256 reputation
    ) internal view returns (uint256) {
        // Normalize bid amount (inverse because lower is better)
        uint256 normalizedBid = (minimumBid * 100) / bidAmount;
        
        // Calculate weighted score
        uint256 score = (normalizedBid * bidWeight + reputation * reputationWeight) / 100;
        return score;
    }
    
    function refundBid() external nonReentrant {
        require(block.timestamp > endTime, "Bidding not ended");
        require(winner != address(0), "Winner not selected");
        require(msg.sender != winner, "Winner cannot refund");
        require(bids[msg.sender].amount > 0, "No bid to refund");
        
        uint256 amount = bids[msg.sender].amount;
        bids[msg.sender].amount = 0;
        
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Refund failed");
    }
    
    function pause() external onlyRole(ORGANIZATION_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(ORGANIZATION_ROLE) {
        _unpause();
    }
    
    // Allow contract to receive ETH
    receive() external payable {}
} 