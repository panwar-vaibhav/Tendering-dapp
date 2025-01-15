// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./FactoryContract.sol";

/**
 * @title TenderContract
 * @dev Contract for managing individual tenders with bidding, stake management, and winner selection
 * @notice This contract handles the complete lifecycle of a tender:
 * State transitions: Created -> Active -> (Closed/Cancelled/Expired)
 */
contract TenderContract is ReentrancyGuard, Pausable {
    // Constants
    uint256 public constant MINIMUM_BID_DURATION = 7 days;
    uint256 public constant REQUIRED_STAKE = 0.1 ether;
    uint256 public constant MINIMUM_BIDDERS = 5;

    // Enums
    /**
     * @dev TenderStatus tracks the lifecycle of the tender
     * Created: Initial state
     * Active: Accepting bids
     * Closed: Winner selected
     * Cancelled: Terminated early
     */
    enum TenderStatus { Created, Active, Closed, Cancelled }

    /**
     * @dev BidStatus tracks the state of individual bids
     * None: Default state
     * Active: Valid and considered
     * Withdrawn: Removed by bidder
     * Refunded: Stake returned
     */
    enum BidStatus { None, Active, Withdrawn, Refunded }

    // Structs
    struct TenderDetails {
        address organization;      // Organization managing the tender
        string ipfsHash;          // IPFS hash for detailed documents
        uint256 startTime;        // Tender start timestamp
        uint256 endTime;          // Tender end timestamp
        uint256 minimumBid;       // Minimum acceptable bid amount
        uint256 bidWeight;        // Weight for bid amount in scoring (0-100)
        uint256 reputationWeight; // Weight for reputation in scoring (0-100)
        TenderStatus status;      // Current tender status
        address winner;           // Selected winner address
        bool isInitialized;       // Initialization flag
        uint256 activeBidders;    // Count of active bidders
    }

    struct Bid {
        uint256 amount;           // Bid amount
        uint256 stake;            // Stake amount held
        string ipfsHash;          // IPFS hash containing technical details
        BidStatus status;         // Bid status (None, Active, Withdrawn, Refunded)
    }

    // State Variables with detailed comments
    FactoryContract public immutable factory;  // Factory contract reference (immutable for gas savings)
    TenderDetails public tenderDetails;        // Main tender information
    uint256 public totalStakeHeld;            // Total stake amount held by contract
    
    mapping(address => Bid) public bids;       // Bidder address to bid details
    address[] public bidders;                  // List of all bidders
    
    // Emergency control
    bool public emergencyStop;                 // Emergency stop flag

    // Events with detailed comments
    event TenderInitialized(
        string ipfsHash,     // IPFS hash containing all tender details
        uint256 startTime,
        uint256 endTime
    );
    event BidSubmitted(address indexed bidder, uint256 bidAmount, uint256 stake, string ipfsHash);
    event BidWithdrawn(address indexed bidder, uint256 bidAmount, uint256 stake);
    event WinnerSelected(address indexed winner, uint256 amount, uint256 score);
    event TenderStatusUpdated(TenderStatus newStatus, uint256 timestamp);
    event BidderScores(address indexed bidder, uint256 score, uint256 bidAmount, uint256 reputation);
    event TenderParametersUpdated(uint256 newEndTime, uint256 newMinimumBid);
    event TenderCancelled(string reason, uint256 timestamp);
    event EmergencyWithdrawal(address indexed to, uint256 amount);
    // Combined event for bid status changes and stake refunds
    event BidStatusAndStakeUpdated(
        address indexed bidder, 
        BidStatus newStatus, 
        uint256 stakeAmount,
        uint256 timestamp
    );

    // Modifiers with detailed error messages
    modifier onlyOrganization() {
        require(
            msg.sender == tenderDetails.organization,
            "Access denied: Caller is not the tender organization"
        );
        _;
    }

    modifier onlyFactory() {
        require(
            msg.sender == address(factory),
            "Access denied: Caller is not the factory contract"
        );
        _;
    }

    modifier onlyBeforeEndTime() {
        require(
            block.timestamp < tenderDetails.endTime,
            "Time error: Bidding period has ended"
        );
        _;
    }

    modifier onlyAfterEndTime() {
        require(
            block.timestamp >= tenderDetails.endTime,
            "Time error: Bidding period is still active"
        );
        _;
    }

    modifier notInitialized() {
        require(
            !tenderDetails.isInitialized,
            "State error: Tender already initialized"
        );
        _;
    }

    modifier whenNotEmergency() {
        require(
            !emergencyStop,
            "State error: Contract is in emergency stop"
        );
        _;
    }

    // Constructor with validation
    constructor(address _factory) {
        require(
            _factory != address(0),
            "Input error: Factory address cannot be zero"
        );
        factory = FactoryContract(_factory);
    }

    /**
     * @dev Initialize a new tender
     * @param _organization Address of the organization
     * @param _ipfsHash IPFS hash containing detailed tender documents
     * @param _startTime Start time of the tender
     * @param _endTime End time of the tender
     * @param _minimumBid Minimum bid amount
     * @param _bidWeight Weight for bid amount in scoring
     * @param _reputationWeight Weight for reputation in scoring
     */
    function initialize(
        address _organization,
        string memory _ipfsHash,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _minimumBid,
        uint256 _bidWeight,
        uint256 _reputationWeight
    ) 
        external 
        notInitialized 
    {
        require(_organization != address(0), "Invalid organization address");
        require(_endTime > _startTime + MINIMUM_BID_DURATION, "Duration too short");
        require(_bidWeight + _reputationWeight == 100, "Weights must sum to 100");
        require(bytes(_ipfsHash).length > 0, "IPFS hash cannot be empty");
        require(_minimumBid > 0, "Minimum bid must be positive");
        
        tenderDetails = TenderDetails({
            organization: _organization,
            ipfsHash: _ipfsHash,
            startTime: _startTime,
            endTime: _endTime,
            minimumBid: _minimumBid,
            bidWeight: _bidWeight,
            reputationWeight: _reputationWeight,
            status: TenderStatus.Created,
            winner: address(0),
            isInitialized: true,
            activeBidders: 0
        });
        
        emit TenderInitialized(_ipfsHash, _startTime, _endTime);
    }

    /**
     * @dev Submit a bid for the tender
     * @param _bidAmount Amount being bid
     * @param _ipfsHash IPFS hash containing technical proposal
     * @param _technicalDetails Additional technical details
     */
    function submitBid(
        uint256 _bidAmount, 
        string memory _ipfsHash
    ) 
        external 
        payable
        nonReentrant 
        onlyBeforeEndTime
        whenNotPaused 
        whenNotEmergency
    {
        require(tenderDetails.status == TenderStatus.Active, "Tender not active");
        require(factory.hasRole(factory.BIDDER_ROLE(), msg.sender), "Not a registered bidder");
        require(_bidAmount >= tenderDetails.minimumBid, "Bid too low");
        require(bids[msg.sender].status == BidStatus.None, "Bid already exists");
        require(msg.value == REQUIRED_STAKE, "Incorrect stake amount");
        require(bytes(_ipfsHash).length > 0 && bytes(_ipfsHash).length <= 100, "Invalid IPFS hash length");
        
        uint256 newTotalStake = totalStakeHeld + msg.value;
        require(newTotalStake >= totalStakeHeld, "Overflow check");
        totalStakeHeld = newTotalStake;
        
        bids[msg.sender] = Bid({
            amount: _bidAmount,
            stake: msg.value,
            ipfsHash: _ipfsHash,
            status: BidStatus.Active
        });
        
        tenderDetails.activeBidders++;
        bidders.push(msg.sender);
        
        emit BidSubmitted(msg.sender, _bidAmount, msg.value, _ipfsHash);
        emit BidStatusAndStakeUpdated(msg.sender, BidStatus.Active, msg.value, block.timestamp);
    }

    /**
     * @dev Withdraw a bid and reclaim stake
     */
    function withdrawBid() 
        external 
        nonReentrant 
        onlyBeforeEndTime
        whenNotEmergency
    {
        require(tenderDetails.status == TenderStatus.Active, "Tender not active");
        
        Bid storage bid = bids[msg.sender];
        require(bid.status == BidStatus.Active, "No active bid found");
        
        uint256 stakeAmount = bid.stake;
        require(totalStakeHeld >= stakeAmount, "Underflow check");

        // Update state before transfer (CEI pattern)
        bid.stake = 0;
        bid.status = BidStatus.Withdrawn;
        tenderDetails.activeBidders--;
        totalStakeHeld -= stakeAmount;
        
        // Events before transfer
        emit BidWithdrawn(msg.sender, bid.amount, stakeAmount);
        emit BidStatusAndStakeUpdated(msg.sender, BidStatus.Withdrawn, stakeAmount, block.timestamp);
        
        // Transfer after state updates
        (bool success, ) = payable(msg.sender).call{value: stakeAmount}("");
        require(success, "Stake refund failed");
    }

    /**
     * @dev Select winner based on bid amount and reputation
     */
    function selectWinner() 
        external 
        nonReentrant
        onlyOrganization 
        onlyAfterEndTime
        whenNotPaused 
        whenNotEmergency
    {
        require(tenderDetails.status == TenderStatus.Active, "Invalid status");
        require(tenderDetails.activeBidders >= MINIMUM_BIDDERS, "Insufficient bidders");
        require(tenderDetails.winner == address(0), "Winner already selected");

        address winner = address(0);
        uint256 highestScore = 0;

        // Add gas limit protection
        require(bidders.length <= 100, "Too many bidders for selection");

        // Calculate scores and find winner
        for (uint256 i = 0; i < bidders.length; i++) {
            address bidder = bidders[i];
            Bid storage bid = bids[bidder];
            
            if (bid.status != BidStatus.Active) continue;

            (,uint256 reputation,,,,) = factory.getUserProfile(bidder);
            
            // Add score overflow protection
            require(bid.amount <= type(uint256).max / 100, "Bid amount too high for scoring");
            uint256 score = calculateScore(bid.amount, reputation);
            
            emit BidderScores(bidder, score, bid.amount, reputation);

            if (score > highestScore) {
                highestScore = score;
                winner = bidder;
            }
        }

        require(winner != address(0), "No valid winner found");
        
        // Update state before external calls (CEI pattern)
        tenderDetails.winner = winner;
        tenderDetails.status = TenderStatus.Closed;
        
        emit WinnerSelected(winner, bids[winner].amount, highestScore);
        emit TenderStatusUpdated(TenderStatus.Closed, block.timestamp);

        // External calls after state updates
        _refundAllStakes();
        factory.updateAnalytics(winner, bids[winner].amount, true);
    }

    /**
     * @dev Cancel the tender and refund all stakes
     * @param reason Reason for cancellation
     */
    function cancelTender(string memory reason) 
        external 
        nonReentrant
        onlyOrganization 
        whenNotEmergency 
    {
        require(tenderDetails.status == TenderStatus.Active, "Invalid status");
        require(bytes(reason).length > 0 && bytes(reason).length <= 100, "Invalid reason length");
        require(block.timestamp < tenderDetails.endTime, "Cannot cancel after end time");
        
        // Update state before external calls (CEI pattern)
        tenderDetails.status = TenderStatus.Cancelled;
        
        // Events before external calls
        emit TenderCancelled(reason, block.timestamp);
        emit TenderStatusUpdated(TenderStatus.Cancelled, block.timestamp);
        
        // External calls last
        _refundAllStakes();
    }

    /**
     * @dev Emergency withdrawal of stuck funds
     * @param to Address to send funds to
     */
    function emergencyWithdraw(address payable to) 
        external 
        onlyFactory 
    {
        require(to != address(0), "Invalid address");
        require(
            tenderDetails.status == TenderStatus.Cancelled,
            "Tender must be cancelled for emergency withdrawal"
        );
        
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance to withdraw");
        
        (bool success, ) = to.call{value: balance}("");
        require(success, "Withdrawal failed");
        
        emit EmergencyWithdrawal(to, balance);
    }

    /**
     * @dev Update tender parameters
     * @param newEndTime New end time for the tender
     * @param newMinimumBid New minimum bid amount
     */
    function updateParameters(uint256 newEndTime, uint256 newMinimumBid) 
        external 
        onlyOrganization 
        onlyBeforeEndTime
        whenNotEmergency
    {
        require(newEndTime > block.timestamp + MINIMUM_BID_DURATION, "Invalid end time");
        require(newMinimumBid > 0, "Invalid minimum bid");
        require(tenderDetails.activeBidders == 0, "Cannot update with active bids");
        
        tenderDetails.endTime = newEndTime;
        tenderDetails.minimumBid = newMinimumBid;
        
        emit TenderParametersUpdated(newEndTime, newMinimumBid);
    }

    /**
     * @dev Toggle emergency stop
     */
    function toggleEmergencyStop() 
        external 
        onlyFactory 
    {
        emergencyStop = !emergencyStop;
    }

    // Internal Functions
    
    /**
     * @dev Refund stakes to all bidders
     */
    function _refundAllStakes() internal {
        for (uint256 i = 0; i < bidders.length; i++) {
            address bidder = bidders[i];
            Bid storage bid = bids[bidder];
            
            if (bid.status == BidStatus.Active && bid.stake > 0) {
                uint256 stakeAmount = bid.stake;
                bid.stake = 0;
                bid.status = BidStatus.Refunded;
                totalStakeHeld -= stakeAmount;
                
                (bool success, ) = payable(bidder).call{value: stakeAmount}("");
                require(success, "Stake refund failed");
                emit BidStatusAndStakeUpdated(bidder, BidStatus.Refunded, stakeAmount, block.timestamp);
            }
        }
    }

    /**
     * @dev Calculate bid score
     * @param _bidAmount Bid amount
     * @param _reputation Bidder reputation
     */
    function calculateScore(uint256 _bidAmount, uint256 _reputation) 
        public 
        view 
        returns (uint256) 
    {
        require(_bidAmount > 0, "Invalid bid amount");
        require(_reputation <= 100, "Invalid reputation score");
        
        // Normalize bid amount (inverse because lower bid is better)
        uint256 normalizedBid = (tenderDetails.minimumBid * 100) / _bidAmount;
        
        // Calculate weighted score
        return (normalizedBid * tenderDetails.bidWeight + 
                _reputation * tenderDetails.reputationWeight) / 100;
    }

    // View Functions
    
    /**
     * @dev Get all bidders
     * @return Array of all bidder addresses
     */
    function getBidders() 
        external 
        view 
        returns (address[] memory) 
    {
        return bidders;
    }

    /**
     * @dev Get active bidders
     * @return Array of active bidder addresses
     */
    function getActiveBidders() 
        external 
        view 
        returns (address[] memory) 
    {
        // Count active bidders first
        uint256 activeCount = 0;
        for (uint256 i = 0; i < bidders.length; i++) {
            if (bids[bidders[i]].status == BidStatus.Active) {
                activeCount++;
            }
        }
        
        // Create array of exact size needed
        address[] memory activeBidders = new address[](activeCount);
        uint256 index = 0;
        
        // Fill array with active bidders
        for (uint256 i = 0; i < bidders.length && index < activeCount; i++) {
            if (bids[bidders[i]].status == BidStatus.Active) {
                activeBidders[index] = bidders[i];
                index++;
            }
        }
        
        return activeBidders;
    }

    /**
     * @dev Get tender status
     */
    function getTenderStatus() 
        external 
        view 
        returns (TenderStatus) 
    {
        return tenderDetails.status;
    }

    /**
     * @dev Get tender statistics
     */
    function getTenderStats() 
        external 
        view 
        returns (
            uint256 activeBidCount,
            uint256 totalBids,
            uint256 totalStake
        ) 
    {
        return (
            tenderDetails.activeBidders,
            bidders.length,
            totalStakeHeld
        );
    }

    /**
     * @dev Get detailed bid information
     */
    function getBidDetails(address bidder) 
        external 
        view 
        returns (
            uint256 amount,
            uint256 stake,
            string memory ipfsHash,
            BidStatus status
        ) 
    {
        Bid storage bid = bids[bidder];
        return (
            bid.amount,
            bid.stake,
            bid.ipfsHash,
            bid.status
        );
    }

    // Admin Functions
    function pause() 
        external 
        onlyFactory 
    {
        _pause();
    }

    function unpause() 
        external 
        onlyFactory 
    {
        _unpause();
    }

    // To receive ETH
    receive() external payable {
        revert("Direct ETH transfers not allowed");
    }

    fallback() external payable {
        revert("Direct ETH transfers not allowed");
    }
} 
