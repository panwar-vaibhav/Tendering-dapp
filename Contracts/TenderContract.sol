// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./IFactoryContract.sol";
import "./TenderLibrary.sol";
import "./TenderOperations.sol";

contract TenderContract is ReentrancyGuard, Pausable {
    using TenderLibrary for uint256;
    using TenderOperations for TenderOperations.Bid;
    using TenderOperations for TenderOperations.TenderDetails;

    uint256 public constant MINIMUM_BID_DURATION = 7 days;
    uint256 public constant REQUIRED_STAKE = 0.1 ether;
    uint256 public constant MINIMUM_BIDDERS = 5;

    // Using uint8 constants instead of enums to save gas
    uint8 public constant STATUS_CREATED = 0;
    uint8 public constant STATUS_ACTIVE = 1;
    uint8 public constant STATUS_CLOSED = 2;
    uint8 public constant STATUS_CANCELLED = 3;

    uint8 public constant BID_STATUS_NONE = 0;
    uint8 public constant BID_STATUS_ACTIVE = 1;
    uint8 public constant BID_STATUS_WITHDRAWN = 2;
    uint8 public constant BID_STATUS_REFUNDED = 3;

    IFactoryContract public immutable factory;
    TenderOperations.TenderDetails public tenderDetails;
    uint256 public totalStakeHeld;
    bool public emergencyStop;

    mapping(address => TenderOperations.Bid) public bids;
    address[] public bidders;

    event TenderInitialized(string ipfsHash, uint256 startTime, uint256 endTime);
    event BidSubmitted(address indexed bidder, uint256 bidAmount, uint256 stake, string ipfsHash);
    event BidWithdrawn(address indexed bidder, uint256 bidAmount, uint256 stake);
    event WinnerSelected(address indexed winner, uint256 amount, uint256 score);
    event TenderStatusUpdated(uint8 newStatus, uint256 timestamp);
    event BidderScores(address indexed bidder, uint256 score, uint256 bidAmount, uint256 reputation);
    event BidStatusAndStakeUpdated(address indexed bidder, uint8 newStatus, uint256 stakeAmount, uint256 timestamp);

    modifier onlyOrganization() {
        require(msg.sender == tenderDetails.organization, "Not org");
        _;
    }

    modifier onlyFactory() {
        require(msg.sender == address(factory), "Not factory");
        _;
    }

    modifier onlyBeforeEndTime() {
        require(block.timestamp < tenderDetails.endTime, "Ended");
        _;
    }

    modifier onlyAfterEndTime() {
        require(block.timestamp >= tenderDetails.endTime, "Not ended");
        _;
    }

    modifier notInitialized() {
        require(!tenderDetails.isInitialized, "Init");
        _;
    }

    modifier whenNotEmergency() {
        require(!emergencyStop, "Emergency");
        _;
    }

    constructor(address _factory) {
        require(_factory != address(0), "Bad factory");
        factory = IFactoryContract(_factory);
    }

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
        require(msg.sender == address(factory), "Not factory");
        require(_organization != address(0), "Bad org");
        
        TenderLibrary.validateTenderParams(
            _startTime,
            _endTime,
            _minimumBid,
            _bidWeight,
            _reputationWeight
        );
        
        tenderDetails.organization = _organization;
        tenderDetails.ipfsHash = _ipfsHash;
        tenderDetails.startTime = _startTime;
        tenderDetails.endTime = _endTime;
        tenderDetails.minimumBid = _minimumBid;
        tenderDetails.bidWeight = _bidWeight;
        tenderDetails.reputationWeight = _reputationWeight;
        tenderDetails.status = STATUS_CREATED;
        tenderDetails.isInitialized = true;
        
        emit TenderInitialized(_ipfsHash, _startTime, _endTime);
    }

    function submitBid(uint256 _bidAmount, string memory _ipfsHash) 
        external 
        payable
        nonReentrant 
        onlyBeforeEndTime
        whenNotPaused 
        whenNotEmergency
    {
        require(tenderDetails.status == STATUS_ACTIVE, "Not active");
        require(factory.hasRole(factory.BIDDER_ROLE(), msg.sender), "Not bidder");
        require(bids[msg.sender].status == BID_STATUS_NONE, "Has bid");
        
        TenderOperations.validateBid(
            _bidAmount,
            tenderDetails.minimumBid,
            REQUIRED_STAKE,
            msg.value,
            bytes(_ipfsHash)
        );
        
        totalStakeHeld += msg.value;
        
        bids[msg.sender] = TenderOperations.Bid({
            amount: _bidAmount,
            stake: msg.value,
            ipfsHash: _ipfsHash,
            status: BID_STATUS_ACTIVE
        });
        
        tenderDetails.activeBidders++;
        bidders.push(msg.sender);
        
        emit BidSubmitted(msg.sender, _bidAmount, msg.value, _ipfsHash);
        emit BidStatusAndStakeUpdated(msg.sender, BID_STATUS_ACTIVE, msg.value, block.timestamp);
    }

    function selectWinner() 
        external 
        nonReentrant
        onlyOrganization 
        onlyAfterEndTime
        whenNotPaused 
        whenNotEmergency
    {
        TenderOperations.validateTenderState(
            tenderDetails.status,
            tenderDetails.activeBidders,
            MINIMUM_BIDDERS,
            tenderDetails.winner
        );

        address winner = address(0);
        uint256 highestScore = 0;

        require(bidders.length <= 100, "Too many");

        for (uint256 i = 0; i < bidders.length; i++) {
            address bidder = bidders[i];
            TenderOperations.Bid storage bid = bids[bidder];
            
            if (bid.status != BID_STATUS_ACTIVE) continue;

            (, uint256 reputation,) = factory.getUserProfile(bidder);
            
            require(bid.amount <= type(uint256).max / 100, "Bid too high");
            uint256 score = calculateScore(bid.amount, reputation);
            
            emit BidderScores(bidder, score, bid.amount, reputation);

            if (score > highestScore) {
                highestScore = score;
                winner = bidder;
            }
        }

        require(winner != address(0), "No winner");
        
        tenderDetails.winner = winner;
        tenderDetails.status = STATUS_CLOSED;
        
        emit WinnerSelected(winner, bids[winner].amount, highestScore);
        emit TenderStatusUpdated(STATUS_CLOSED, block.timestamp);

        _refundAllStakes();
        factory.updateAnalytics(winner, bids[winner].amount, true);
    }

    function _refundAllStakes() internal {
        TenderOperations.validateWithdrawal(
            address(this).balance,
            totalStakeHeld,
            bidders.length
        );
        
        uint256 refundedAmount = 0;
        
        for (uint256 i = 0; i < bidders.length; i++) {
            address bidder = bidders[i];
            TenderOperations.Bid storage bid = bids[bidder];
            
            if (bid.status == BID_STATUS_ACTIVE && bid.stake > 0) {
                uint256 stakeAmount = bid.stake;
                
                TenderOperations.updateBidStatus(bid, BID_STATUS_REFUNDED);
                totalStakeHeld -= stakeAmount;
                refundedAmount += stakeAmount;
                
                emit BidStatusAndStakeUpdated(bidder, BID_STATUS_REFUNDED, stakeAmount, block.timestamp);
                
                require(TenderOperations.refundStake(bidder, stakeAmount), "Refund fail");
            }
        }
        
        require(refundedAmount <= address(this).balance, "Balance low");
    }

    function calculateScore(uint256 _bidAmount, uint256 _reputation) 
        public 
        view 
        returns (uint256) 
    {
        return TenderLibrary.calculateScore(
            tenderDetails.minimumBid,
            _bidAmount,
            _reputation,
            tenderDetails.bidWeight,
            tenderDetails.reputationWeight
        );
    }

    function activate() 
        external 
        onlyFactory
        whenNotPaused
        whenNotEmergency 
    {
        require(tenderDetails.status == STATUS_CREATED, "Wrong status");
        require(block.timestamp < tenderDetails.endTime, "Too late");
        require(block.timestamp >= tenderDetails.startTime, "Too early");
        
        tenderDetails.status = STATUS_ACTIVE;
        emit TenderStatusUpdated(STATUS_ACTIVE, block.timestamp);
    }

    // View functions remain the same...

    receive() external payable {
        revert("No ETH");
    }

    fallback() external payable {
        revert("No ETH");
    }
} 
