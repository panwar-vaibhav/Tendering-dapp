// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./TenderContract.sol";

contract TenderFactory is 
    Initializable, 
    AccessControlUpgradeable, 
    PausableUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ORGANIZATION_ROLE = keccak256("ORGANIZATION_ROLE");
    
    struct TenderMetadata {
        address organization;
        uint256 createdAt;
        string ipfsHash;
        bool isActive;
    }

    // Reputation scores for bidders
    mapping(address => uint256) public reputationScores;
    
    // Organization -> their tenders
    mapping(address => address[]) public organizationTenders;
    
    // Tender address -> metadata
    mapping(address => TenderMetadata) public tenderMetadata;
    
    // Creation fee
    uint256 public tenderCreationFee;
    
    event TenderCreated(
        address indexed tenderAddress,
        address indexed organization,
        string ipfsHash
    );
    event ReputationUpdated(
        address indexed bidder, 
        uint256 newScore
    );
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        
        tenderCreationFee = 0.1 ether;
    }
    
    function createTender(
        string memory title,
        string memory ipfsHash,
        uint256 bidWeight,
        uint256 reputationWeight,
        uint256 startTime,
        uint256 endTime,
        uint256 minimumBid
    ) external payable whenNotPaused nonReentrant returns (address) {
        require(
            hasRole(ORGANIZATION_ROLE, msg.sender),
            "Must have organization role"
        );
        require(msg.value >= tenderCreationFee, "Insufficient fee");
        
        TenderContract newTender = new TenderContract(
            address(this),
            msg.sender,
            title,
            ipfsHash,
            bidWeight,
            reputationWeight,
            startTime,
            endTime,
            minimumBid
        );
        
        // Update mappings
        organizationTenders[msg.sender].push(address(newTender));
        tenderMetadata[address(newTender)] = TenderMetadata({
            organization: msg.sender,
            createdAt: block.timestamp,
            ipfsHash: ipfsHash,
            isActive: true
        });
        
        emit TenderCreated(address(newTender), msg.sender, ipfsHash);
        return address(newTender);
    }
    
    function updateReputation(
        address bidder,
        uint256 newScore
    ) external onlyRole(ADMIN_ROLE) {
        require(newScore <= 100, "Score must be <= 100");
        reputationScores[bidder] = newScore;
        emit ReputationUpdated(bidder, newScore);
    }
    
    function getReputationScore(
        address bidder
    ) external view returns (uint256) {
        return reputationScores[bidder];
    }
    
    function getOrganizationTenders(
        address organization
    ) external view returns (address[] memory) {
        return organizationTenders[organization];
    }
    
    function setTenderCreationFee(
        uint256 newFee
    ) external onlyRole(ADMIN_ROLE) {
        tenderCreationFee = newFee;
    }
    
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    // Allow contract to receive ETH
    receive() external payable {}
} 