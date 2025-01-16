// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./TenderContract.sol";

/**
 * @title FactoryContract
 * @dev Main factory contract for managing tenders, user roles, and platform operations
 * @notice This contract handles user registration, tender deployment, reputation management,
 * and stake management for the decentralized tendering platform
 */
contract FactoryContract is 
    Initializable, 
    AccessControlUpgradeable, 
    PausableUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    using EnumerableSet for EnumerableSet.AddressSet;

    // Role definitions
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ORGANIZATION_ROLE = keccak256("ORGANIZATION_ROLE");
    bytes32 public constant BIDDER_ROLE = keccak256("BIDDER_ROLE");

    // Implementation contract address
    address public tenderImplementation;

    // Events for implementation management
    event ImplementationUpdated(address indexed oldImplementation, address indexed newImplementation);

    // Constants
    uint256 public constant REPUTATION_MAX_SCORE = 100;
    uint256 public constant MIN_STAKE_AMOUNT = 0.1 ether; // Minimum stake required in ETH

    struct UserProfile {
        string metadata;           // IPFS hash containing user details
        uint256 reputation;        // Current reputation score
        uint256 stakedAmount;      // Amount of ETH staked
    }

    struct TenderInfo {
        address tenderContract;    // Address of deployed tender contract
        address organization;      // Organization that created the tender
        string ipfsHash;          // IPFS hash containing tender details
        uint256 creationTime;     // Creation timestamp
        bool isActive;            // Active status
    }

    struct Analytics {
        uint256 totalBids;
        uint256 tendersWon;
        uint256 totalTendersParticipated;
        uint256 averageBidAmount;
        uint256 lastActivityTime;
    }

    // Events
    event OrganizationRegistered(address indexed organization, string metadata);
    event BidderRegistered(address indexed bidder, string metadata);
    event TenderDeployed(address indexed tenderAddress, address indexed organization, string ipfsHash);
    event ReputationUpdated(address indexed user, uint256 newScore, uint256 previousScore);
    event StakeDeposited(address indexed user, uint256 amount);
    event StakeWithdrawn(address indexed user, uint256 amount);
    event UserSlashed(address indexed user, uint256 amount, string reason);

    // State Variables
    mapping(address => UserProfile) private userProfiles;
    mapping(address => Analytics) public userAnalytics;
    mapping(address => mapping(uint256 => uint256)) public reputationHistory;
    mapping(address => EnumerableSet.AddressSet) private userTenders;
    
    TenderInfo[] public tenders;
    uint256 public totalStaked;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract with admin and implementation
     * @param admin Address of the initial admin
     * @param _implementation Address of the tender implementation contract
     */
    function initialize(address admin, address _implementation) public initializer {
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        
        require(_implementation != address(0), "Invalid implementation address");
        tenderImplementation = _implementation;
        emit ImplementationUpdated(address(0), _implementation);
    }

    /**
     * @dev Update the implementation contract address
     * @param newImplementation Address of the new implementation contract
     */
    function updateImplementation(address newImplementation) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        require(newImplementation != address(0), "Invalid implementation address");
        address oldImplementation = tenderImplementation;
        tenderImplementation = newImplementation;
        emit ImplementationUpdated(oldImplementation, newImplementation);
    }

    /**
     * @dev Register a new organization
     * @param organization Address of the organization
     * @param metadata IPFS hash containing organization details
     */
    function registerOrganization(address organization, string calldata metadata) 
        external 
        payable
        onlyRole(ADMIN_ROLE) 
        whenNotPaused 
    {
        require(organization != address(0), "Invalid organization address");
        require(!hasRole(ORGANIZATION_ROLE, organization), "Already registered");
        require(msg.value >= MIN_STAKE_AMOUNT, "Insufficient stake amount");
        
        grantRole(ORGANIZATION_ROLE, organization);
        
        userProfiles[organization].metadata = metadata;
        userProfiles[organization].reputation = REPUTATION_MAX_SCORE;
        userProfiles[organization].stakedAmount = msg.value;
        
        totalStaked += msg.value;
        emit OrganizationRegistered(organization, metadata);
        emit StakeDeposited(organization, msg.value);
    }

    /**
     * @dev Register a new bidder
     * @param metadata IPFS hash containing bidder details
     */
    function registerBidder(string calldata metadata) 
        external 
        payable
        nonReentrant 
        whenNotPaused 
    {
        require(!hasRole(BIDDER_ROLE, msg.sender), "Already registered");
        require(msg.value >= MIN_STAKE_AMOUNT, "Insufficient stake amount");
        
        grantRole(BIDDER_ROLE, msg.sender);
        
        userProfiles[msg.sender].metadata = metadata;
        userProfiles[msg.sender].reputation = REPUTATION_MAX_SCORE / 2;
        userProfiles[msg.sender].stakedAmount = msg.value;
        
        totalStaked += msg.value;
        emit BidderRegistered(msg.sender, metadata);
        emit StakeDeposited(msg.sender, msg.value);
    }

    /**
     * @dev Deploy a new tender contract
     * @param metadata General tender metadata
     * @param ipfsHash IPFS hash containing detailed tender information
     * @param startTime Start time for the tender
     * @param endTime End time for the tender
     * @param minimumBid Minimum bid amount
     * @param bidWeight Weight for bid amount in scoring (0-100)
     * @param reputationWeight Weight for reputation in scoring (0-100)
     */
    function deployTender(
        string calldata metadata,
        string calldata ipfsHash,
        uint256 startTime,
        uint256 endTime,
        uint256 minimumBid,
        uint256 bidWeight,
        uint256 reputationWeight
    ) 
        external 
        onlyRole(ORGANIZATION_ROLE) 
        whenNotPaused 
        nonReentrant 
        returns (address) 
    {
        require(tenderImplementation != address(0), "Implementation not set");
        require(startTime >= block.timestamp, "Start time must be future");
        require(endTime > startTime, "Invalid end time");
        require(bidWeight + reputationWeight == 100, "Invalid weights");
        
        // Deploy clone
        address clone = _deployClone(tenderImplementation);
        
        // Initialize the clone
        TenderContract(clone).initialize(
            msg.sender,
            ipfsHash,
            startTime,
            endTime,
            minimumBid,
            bidWeight,
            reputationWeight
        );
        
        // Update user profile and tender list
        addUserTender(msg.sender, clone);
        tenders.push(TenderInfo({
            tenderContract: clone,
            organization: msg.sender,
            ipfsHash: ipfsHash,
            creationTime: block.timestamp,
            isActive: true
        }));
        
        emit TenderDeployed(clone, msg.sender, ipfsHash);
        return clone;
    }

    /**
     * @dev Update analytics after tender completion
     * @param winner Address of the winning bidder
     * @param amount Winning bid amount
     * @param success Whether the tender was successfully completed
     */
    function updateAnalytics(
        address winner,
        uint256 amount,
        bool success
    ) 
        external 
    {
        // Only allow calls from deployed tender contracts
        bool isTenderContract = false;
        for (uint256 i = 0; i < tenders.length; i++) {
            if (tenders[i].tenderContract == msg.sender) {
                isTenderContract = true;
                break;
            }
        }
        require(isTenderContract, "Caller not a tender contract");

        // Update winner analytics
        if (success && winner != address(0)) {
            Analytics storage analytics = userAnalytics[winner];
            analytics.tendersWon++;
            analytics.totalBids++;
            analytics.totalTendersParticipated++;
            
            // Update average bid amount
            if (analytics.averageBidAmount == 0) {
                analytics.averageBidAmount = amount;
            } else {
                analytics.averageBidAmount = (analytics.averageBidAmount + amount) / 2;
            }
            
            analytics.lastActivityTime = block.timestamp;
            
            // Update reputation if needed
            if (userProfiles[winner].reputation < REPUTATION_MAX_SCORE) {
                userProfiles[winner].reputation += 1;
                emit ReputationUpdated(
                    winner,
                    userProfiles[winner].reputation,
                    userProfiles[winner].reputation - 1
                );
            }
        }
    }

    /**
     * @dev Update user reputation
     * @param user Address of the user
     * @param newScore New reputation score
     */
    function updateReputation(address user, uint256 newScore) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        require(newScore <= REPUTATION_MAX_SCORE, "Score exceeds maximum");
        UserProfile storage profile = userProfiles[user];

        uint256 previousScore = profile.reputation;
        profile.reputation = newScore;
        
        // Store in history
        reputationHistory[user][block.timestamp] = newScore;
        
        emit ReputationUpdated(user, newScore, previousScore);
    }

    /**
     * @dev Increase stake amount
     */
    function increaseStake() 
        external 
        payable
        nonReentrant 
        whenNotPaused 
    {
        require(msg.value > 0, "Amount must be positive");
        
        userProfiles[msg.sender].stakedAmount += msg.value;
        totalStaked += msg.value;
        
        emit StakeDeposited(msg.sender, msg.value);
    }

    /**
     * @dev Withdraw staked ETH
     * @param amount Amount of ETH to withdraw
     */
    function withdrawStake(uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        UserProfile storage profile = userProfiles[msg.sender];
        require(amount <= profile.stakedAmount, "Insufficient stake");
        
        profile.stakedAmount -= amount;
        totalStaked -= amount;
        
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
        
        emit StakeWithdrawn(msg.sender, amount);
    }

    /**
     * @dev Slash user's stake for rule violations
     * @param user Address of the user to slash
     * @param amount Amount to slash
     * @param reason Reason for slashing
     */
    function slashStake(
        address user, 
        uint256 amount, 
        string calldata reason
    ) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        UserProfile storage profile = userProfiles[user];
        require(amount <= profile.stakedAmount, "Amount exceeds stake");
        
        profile.stakedAmount -= amount;
        totalStaked -= amount;
        
        emit UserSlashed(user, amount, reason);
    }

    /**
     * @dev Update user analytics
     * @param user Address of the user
     * @param bidAmount Bid amount
     * @param wonTender Whether the user won the tender
     */
    function updateAnalytics(
        address user,
        uint256 bidAmount,
        bool wonTender
    ) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        Analytics storage analytics = userAnalytics[user];
        analytics.totalBids++;
        if (wonTender) {
            analytics.tendersWon++;
        }
        analytics.totalTendersParticipated++;
        analytics.averageBidAmount = (analytics.averageBidAmount * (analytics.totalBids - 1) + bidAmount) / analytics.totalBids;
        analytics.lastActivityTime = block.timestamp;
    }

    /**
     * @dev Activate a deployed tender for bidding
     * @param tenderAddress Address of the tender to activate
     */
    function activateTender(address tenderAddress) 
        external 
        onlyRole(ORGANIZATION_ROLE)
        whenNotPaused
        nonReentrant
    {
        require(tenderAddress != address(0), "Invalid tender address");
        
        bool found = false;
        for (uint256 i = 0; i < tenders.length; i++) {
            if (tenders[i].tenderContract == tenderAddress) {
                require(tenders[i].organization == msg.sender, "Not tender owner");
                require(tenders[i].isActive, "Tender not active in factory");
                found = true;
                break;
            }
        }
        require(found, "Tender not found");
        
        TenderContract(tenderAddress).activate();
    }

    // View Functions
    /**
     * @dev Get user profile information
     * @param user Address of the user
     */
    function getUserProfile(address user) 
        external 
        view 
        returns (
            string memory metadata,
            uint256 reputation,
            uint256 stakedAmount
        ) 
    {
        UserProfile storage profile = userProfiles[user];
        return (
            profile.metadata,
            profile.reputation,
            profile.stakedAmount
        );
    }

    /**
     * @dev Get user's tenders
     * @param user Address of the user
     */
    function getUserTenders(address user) 
        external 
        view 
        returns (address[] memory) 
    {
        return EnumerableSet.values(userTenders[user]);
    }

    /**
     * @dev Get all tenders
     */
    function getAllTenders() 
        external 
        view 
        returns (TenderInfo[] memory) 
    {
        return tenders;
    }

    /**
     * @dev Get user analytics
     * @param user Address of the user
     */
    function getUserAnalytics(address user) 
        external 
        view 
        returns (
            uint256 totalBids,
            uint256 tendersWon,
            uint256 totalTendersParticipated,
            uint256 averageBidAmount,
            uint256 lastActivityTime
        ) 
    {
        Analytics storage analytics = userAnalytics[user];
        return (
            analytics.totalBids,
            analytics.tendersWon,
            analytics.totalTendersParticipated,
            analytics.averageBidAmount,
            analytics.lastActivityTime
        );
    }

    /**
     * @dev Internal function to deploy a clone of the tender implementation
     * @param implementation Address of the implementation contract
     */
    function _deployClone(address implementation) 
        internal 
        returns (address) 
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
        
        return clone;
    }

    // Admin Functions
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // Add receive function to accept ETH
    receive() external payable {
        revert("Direct ETH transfers not allowed");
    }

    // Add fallback function
    fallback() external payable {
        revert("Direct ETH transfers not allowed");
    }

    // Add a function to manage user tenders
    function addUserTender(address user, address tenderAddress) internal {
        EnumerableSet.add(userTenders[user], tenderAddress);
    }
} 
