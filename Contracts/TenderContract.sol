// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./IFactoryContract.sol";

/**
 * @title TenderContract
 * @dev Manages individual tenders with bidding, stake management, and winner selection
 * @notice Handles the complete lifecycle of a tender from creation to completion
 *
 * State Flow:
 * 1. Created: Initial state after initialization
 * 2. Active: Accepting bids from qualified bidders
 * 3. Closed: Winner selected and stakes refunded
 * 4. Cancelled: Terminated early with stake refunds
 */
contract TenderContract is ReentrancyGuard, Pausable {
    // Constants with clear purposes
    /// @dev Minimum duration for bidding period (7 days)
    uint256 public constant MINIMUM_BID_DURATION = 7 days;
    /// @dev Required stake amount for bid submission (0.1 ETH)
    uint256 public constant REQUIRED_STAKE = 0.1 ether;
    /// @dev Minimum number of bidders required for valid tender
    uint256 public constant MINIMUM_BIDDERS = 5;

    /**
     * @dev Tracks the current state of the tender
     */
    enum TenderStatus { 
        Created,    // Initial state
        Active,     // Accepting bids
        Closed,     // Winner selected
        Cancelled   // Early termination
    }

    /**
     * @dev Tracks the state of individual bids
     */
    enum BidStatus { 
        None,       // Default state
        Active,     // Valid bid
        Withdrawn,  // Removed by bidder
        Refunded    // Stake returned
    }

    /**
     * @dev Stores complete tender information
     */
    struct TenderDetails {
        address organization;      // Organization managing tender
        string ipfsHash;          // Tender documents hash
        uint256 startTime;        // Start timestamp
        uint256 endTime;          // End timestamp
        uint256 minimumBid;       // Minimum bid amount
        uint256 bidWeight;        // Bid score weight (0-100)
        uint256 reputationWeight; // Reputation score weight (0-100)
        TenderStatus status;      // Current status
        address winner;           // Selected winner
        bool isInitialized;       // Initialization check
        uint256 activeBidders;    // Active bid count
    }

    /**
     * @dev Stores individual bid information
     */
    struct Bid {
        uint256 amount;           // Bid amount
        uint256 stake;           // Stake amount
        string ipfsHash;         // Technical details hash
        BidStatus status;        // Current status
    }

    // State Variables
    /// @dev Reference to factory contract
    IFactoryContract public immutable factory;
    /// @dev Main tender information
    TenderDetails public tenderDetails;
    /// @dev Total stakes held by contract
    uint256 public totalStakeHeld;
    /// @dev Mapping of bidder addresses to their bids
    mapping(address => Bid) public bids;
    /// @dev List of all bidder addresses
    address[] public bidders;
    /// @dev Emergency stop flag
    bool public emergencyStop;

    // Events for tracking important state changes
    event TenderInitialized(string ipfsHash, uint256 startTime, uint256 endTime);
    event BidSubmitted(address indexed bidder, uint256 bidAmount, uint256 stake, string ipfsHash);
    event BidWithdrawn(address indexed bidder, uint256 bidAmount, uint256 stake);
    event WinnerSelected(address indexed winner, uint256 amount, uint256 score);
    event TenderStatusUpdated(TenderStatus newStatus, uint256 timestamp);
    event BidderScores(address indexed bidder, uint256 score, uint256 bidAmount, uint256 reputation);
    event TenderParametersUpdated(uint256 newEndTime, uint256 newMinimumBid);
    event TenderCancelled(string reason, uint256 timestamp);
    event EmergencyWithdrawal(address indexed to, uint256 amount);
    event BidStatusAndStakeUpdated(
        address indexed bidder, 
        BidStatus newStatus, 
        uint256 stakeAmount,
        uint256 timestamp
    );
    event EmergencyStateChanged(bool isEmergency, string reason, uint256 timestamp);

    // Modifiers for access control and state validation
    /**
     * @dev Ensures caller is the tender organization
     */
    modifier onlyOrganization() {
        require(
            msg.sender == tenderDetails.organization,
            "Access denied: Caller is not the tender organization"
        );
        _;
    }

    /**
     * @dev Ensures caller is the factory contract
     */
    modifier onlyFactory() {
        require(
            msg.sender == address(factory),
            "Access denied: Caller is not the factory contract"
        );
        _;
    }

    /**
     * @dev Ensures operation is before tender end time
     */
    modifier onlyBeforeEndTime() {
        require(
            block.timestamp < tenderDetails.endTime,
            "Time error: Bidding period has ended"
        );
        _;
    }

    /**
     * @dev Ensures operation is after tender end time
     */
    modifier onlyAfterEndTime() {
        require(
            block.timestamp >= tenderDetails.endTime,
            "Time error: Bidding period is still active"
        );
        _;
    }

    /**
     * @dev Ensures tender is not already initialized
     */
    modifier notInitialized() {
        require(
            !tenderDetails.isInitialized,
            "State error: Tender already initialized"
        );
        _;
    }

    /**
     * @dev Ensures contract is not in emergency state
     */
    modifier whenNotEmergency() {
        require(
            !emergencyStop,
            "State error: Contract is in emergency stop"
        );
        _;
    }

    /**
     * @dev Sets up the tender contract with factory reference
     * @param _factory Address of the factory contract
     */
    constructor(address _factory) {
        require(
            _factory != address(0),
            "Input error: Factory address cannot be zero"
        );
        factory = IFactoryContract(_factory);
    }

    /**
     * @dev Initializes a new tender with specified parameters
     * @param _organization Address of the organization managing the tender
     * @param _ipfsHash IPFS hash containing tender documents
     * @param _startTime Start time for the bidding period
     * @param _endTime End time for the bidding period
     * @param _minimumBid Minimum acceptable bid amount
     * @param _bidWeight Weight for bid amount in scoring (0-100)
     * @param _reputationWeight Weight for reputation in scoring (0-100)
     * @notice Weights must sum to 100
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
        // Add initialization check
        require(msg.sender == address(factory), "Only factory can initialize");
        
        require(_organization != address(0), "Invalid organization address");
        require(_endTime > _startTime + MINIMUM_BID_DURATION, "Duration too short");
        require(_bidWeight + _reputationWeight == 100, "Weights must sum to 100");
        require(bytes(_ipfsHash).length > 0, "IPFS hash cannot be empty");
        require(_minimumBid > 0, "Minimum bid must be positive");
        require(_startTime >= block.timestamp, "Start time must be future");
        
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
     * @dev Submits a bid with required stake
     * @param _bidAmount Amount being bid
     * @param _ipfsHash IPFS hash containing technical proposal
     * @notice Requires REQUIRED_STAKE in ETH to be sent with transaction
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
     * @dev Withdraws a bid and returns stake to bidder
     * @notice Can only be called before tender end time
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
     * @dev Selects winner based on bid amount and reputation scores
     * @notice Requires minimum number of bidders and tender end time reached
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
     * @dev Cancels tender and refunds all stakes
     * @param reason Reason for cancellation
     * @notice Can only be called by organization before end time
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
     * @dev Handles emergency withdrawal of contract funds
     * @param to Address to receive withdrawn funds
     * @notice Only callable by factory when in emergency state
     */
    function emergencyWithdraw(address payable to) 
        external 
        nonReentrant
        onlyFactory 
    {
        require(to != address(0), "Invalid address");
        require(emergencyStop, "Not in emergency state");
        require(
            tenderDetails.status == TenderStatus.Cancelled,
            "Tender must be cancelled for emergency withdrawal"
        );
        
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance to withdraw");
        require(balance <= totalStakeHeld, "Balance exceeds total stakes");
        
        // Update state before transfer
        uint256 amountToWithdraw = balance;
        totalStakeHeld = 0;  // Clear all stakes as they're being withdrawn
        
        // Events before transfer
        emit EmergencyWithdrawal(to, amountToWithdraw);
        
        // Transfer after state updates
        (bool success, ) = to.call{value: amountToWithdraw}("");
        require(success, "Withdrawal failed");
    }

    /**
     * @dev Updates tender parameters before bidding starts
     * @param newEndTime New end time for bidding period
     * @param newMinimumBid New minimum bid amount
     * @notice Only callable with no active bids
     */
    function updateParameters(uint256 newEndTime, uint256 newMinimumBid) 
        external 
        onlyOrganization 
        onlyBeforeEndTime
        whenNotEmergency
    {
        require(
            tenderDetails.status == TenderStatus.Created || 
            tenderDetails.status == TenderStatus.Active, 
            "Invalid tender status"
        );
        require(tenderDetails.activeBidders == 0, "Cannot update with active bids");
        
        // Time validations
        require(newEndTime > block.timestamp + MINIMUM_BID_DURATION, "End time too soon");
        require(newEndTime <= block.timestamp + 365 days, "End time too far");
        require(newEndTime != tenderDetails.endTime, "Same end time");
        
        // Bid amount validations
        require(newMinimumBid > 0, "Invalid minimum bid");
        require(newMinimumBid <= type(uint256).max / 100, "Minimum bid too high");
        require(newMinimumBid != tenderDetails.minimumBid, "Same minimum bid");
        
        // Update state
        tenderDetails.endTime = newEndTime;
        tenderDetails.minimumBid = newMinimumBid;
        
        emit TenderParametersUpdated(newEndTime, newMinimumBid);
    }

    /**
     * @dev Toggles emergency state of contract
     * @param reason Reason for state change
     * @notice Only callable by factory contract
     */
    function toggleEmergencyStop(string memory reason) 
        external 
        onlyFactory 
    {
        require(bytes(reason).length > 0 && bytes(reason).length <= 100, "Invalid reason length");
        
        // If enabling emergency stop, check tender state
        if (!emergencyStop) {
            require(
                tenderDetails.status != TenderStatus.Closed,
                "Cannot enable emergency: tender already closed"
            );
        }
        
        emergencyStop = !emergencyStop;
        
        emit EmergencyStateChanged(
            emergencyStop,
            reason,
            block.timestamp
        );
    }

    /**
     * @dev Activates the tender for bidding
     * @notice Only callable by factory when tender is in Created state
     */
    function activate() 
        external 
        onlyFactory
        whenNotPaused
        whenNotEmergency 
    {
        require(tenderDetails.status == TenderStatus.Created, "Invalid status");
        require(block.timestamp < tenderDetails.endTime, "Already ended");
        require(block.timestamp >= tenderDetails.startTime, "Not started");
        
        tenderDetails.status = TenderStatus.Active;
        emit TenderStatusUpdated(TenderStatus.Active, block.timestamp);
    }

    // Internal Functions
    
    /**
     * @dev Internal function to refund stakes to all bidders
     * @notice Follows CEI pattern and has gas limit protection
     */
    function _refundAllStakes() internal {
        // Check contract balance
        uint256 contractBalance = address(this).balance;
        require(contractBalance >= totalStakeHeld, "Insufficient balance for refunds");
        
        // Gas limit protection
        require(bidders.length <= 100, "Too many bidders for mass refund");
        
        // Track successful refunds
        uint256 refundedAmount = 0;
        
        for (uint256 i = 0; i < bidders.length; i++) {
            address bidder = bidders[i];
            Bid storage bid = bids[bidder];
            
            if (bid.status == BidStatus.Active && bid.stake > 0) {
                uint256 stakeAmount = bid.stake;
                
                // Update state before transfer (CEI pattern)
                bid.stake = 0;
                bid.status = BidStatus.Refunded;
                totalStakeHeld -= stakeAmount;
                refundedAmount += stakeAmount;
                
                // Emit event before transfer
                emit BidStatusAndStakeUpdated(bidder, BidStatus.Refunded, stakeAmount, block.timestamp);
                
                // Perform transfer last
                (bool success, ) = payable(bidder).call{value: stakeAmount}("");
                require(success, "Stake refund failed");
            }
        }
        
        // Verify all stakes were refunded
        require(refundedAmount <= contractBalance, "Refund amount exceeds balance");
    }

    /**
     * @dev Calculates bid score based on amount and reputation
     * @param _bidAmount Bid amount to evaluate
     * @param _reputation Bidder reputation score (0-100)
     * @return Weighted score combining bid and reputation
     */
    function calculateScore(uint256 _bidAmount, uint256 _reputation) 
        public 
        view 
        returns (uint256) 
    {
        require(_bidAmount > 0, "Invalid bid amount");
        require(_reputation <= 100, "Invalid reputation score");
        
        // Prevent overflow in normalization
        require(tenderDetails.minimumBid <= type(uint256).max / 100, "Minimum bid too high");
        
        // Normalize bid amount (inverse because lower bid is better)
        uint256 normalizedBid = (tenderDetails.minimumBid * 100) / _bidAmount;
        
        // Calculate weighted score
        return (normalizedBid * tenderDetails.bidWeight + 
                _reputation * tenderDetails.reputationWeight) / 100;
    }

    // View Functions
    
    /**
     * @dev Returns list of all bidder addresses
     * @return Array of bidder addresses
     */
    function getBidders() 
        external 
        view 
        returns (address[] memory) 
    {
        return bidders;
    }

    /**
     * @dev Returns list of currently active bidder addresses
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
     * @dev Returns current tender status
     * @return Current TenderStatus
     */
    function getTenderStatus() 
        external 
        view 
        returns (TenderStatus) 
    {
        return tenderDetails.status;
    }

    /**
     * @dev Returns tender statistics
     * @return activeBidCount Number of active bids
     * @return totalBids Total number of bids received
     * @return totalStake Total stake amount held
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
     * @dev Returns detailed bid information
     * @param bidder Address of bidder
     * @return amount Bid amount
     * @return stake Stake amount
     * @return ipfsHash Technical details hash
     * @return status Current bid status
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

    /**
     * @dev Returns basic tender information
     * @return organization Address of organization
     * @return endTime Bidding end time
     * @return minimumBid Minimum bid amount
     * @return status Current tender status
     * @return winner Selected winner address
     */
    function getTenderDetails() 
        external 
        view 
        returns (
            address organization,
            uint256 endTime,
            uint256 minimumBid,
            TenderStatus status,
            address winner
        ) 
    {
        return (
            tenderDetails.organization,
            tenderDetails.endTime,
            tenderDetails.minimumBid,
            tenderDetails.status,
            tenderDetails.winner
        );
    }

    // Admin Functions
    
    /**
     * @dev Pauses contract operations
     * @notice Only callable by factory
     */
    function pause() 
        external 
        onlyFactory 
    {
        _pause();
    }

    /**
     * @dev Unpauses contract operations
     * @notice Only callable by factory
     */
    function unpause() 
        external 
        onlyFactory 
    {
        _unpause();
    }

    // ETH Handling

    /**
     * @dev Prevents direct ETH transfers
     */
    receive() external payable {
        revert("Direct ETH transfers not allowed");
    }

    /**
     * @dev Prevents direct ETH transfers
     */
    fallback() external payable {
        revert("Direct ETH transfers not allowed");
    }
} 
