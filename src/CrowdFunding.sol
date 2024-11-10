// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title AdvancedCrowdfunding
 * @dev A comprehensive crowdfunding contract with multiple features
 * Including milestone-based funding, refund mechanisms, and governance
 */
contract AdvancedCrowdfunding is ReentrancyGuard, Pausable, AccessControl {
    bytes32 public constant CAMPAIGN_MANAGER_ROLE = keccak256("CAMPAIGN_MANAGER_ROLE");
    
    struct Campaign {
        address payable creator;
        string title;
        string description;
        uint256 goalAmount;
        uint256 raisedAmount;
        uint256 deadline;
        uint256 minContribution;
        uint256 maxContribution;
        bool claimed;
        CampaignStatus status;
        Milestone[] milestones;
        uint256 currentMilestone;
        bool acceptsTokens;
        mapping(address => bool) acceptedTokens;
        mapping(address => uint256) contributions;
        mapping(address => mapping(address => uint256)) tokenContributions;
    }
    
    struct Milestone {
        string description;
        uint256 percentage;
        uint256 deadline;
        bool released;
        uint256 votesNeeded;
        mapping(address => bool) voters;
        uint256 votesReceived;
    }
    
    enum CampaignStatus {
        Active,
        Successful,
        Failed,
        Cancelled
    }
    
    event CampaignCreated(uint256 indexed campaignId, address indexed creator, string title);
    event ContributionMade(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    event TokenContributionMade(uint256 indexed campaignId, address indexed contributor, address token, uint256 amount);
    event MilestoneCompleted(uint256 indexed campaignId, uint256 milestoneIndex);
    event FundsReleased(uint256 indexed campaignId, uint256 amount);
    event CampaignCancelled(uint256 indexed campaignId);
    event RefundIssued(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    
    mapping(uint256 => Campaign) public campaigns;
    uint256 public campaignCount;
    uint256 public platformFee; // in basis points (1/100 of a percent)
    address payable public feeCollector;
    
    constructor(address payable _feeCollector, uint256 _platformFee) {
        require(_platformFee <= 1000, "Fee cannot exceed 10%");
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        feeCollector = _feeCollector;
        platformFee = _platformFee;
    }
    
    function createCampaign(
        string memory _title,
        string memory _description,
        uint256 _goalAmount,
        uint256 _duration,
        uint256 _minContribution,
        uint256 _maxContribution,
        bool _acceptsTokens,
        address[] memory _acceptedTokens,
        uint256[] memory _milestonePercentages,
        string[] memory _milestoneDescriptions,
        uint256[] memory _milestoneDurations
    ) external whenNotPaused returns (uint256) {
        require(_goalAmount > 0, "Goal must be greater than 0");
        require(_duration > 0, "Duration must be greater than 0");
        require(_minContribution > 0, "Min contribution must be greater than 0");
        require(_maxContribution >= _minContribution, "Max contribution must be >= min");
        require(_milestonePercentages.length == _milestoneDescriptions.length, "Milestone arrays length mismatch");
        require(_milestonePercentages.length == _milestoneDurations.length, "Milestone arrays length mismatch");
        
        uint256 campaignId = campaignCount++;
        Campaign storage campaign = campaigns[campaignId];
        
        campaign.creator = payable(msg.sender);
        campaign.title = _title;
        campaign.description = _description;
        campaign.goalAmount = _goalAmount;
        campaign.deadline = block.timestamp + _duration;
        campaign.minContribution = _minContribution;
        campaign.maxContribution = _maxContribution;
        campaign.status = CampaignStatus.Active;
        campaign.acceptsTokens = _acceptsTokens;
        
        if (_acceptsTokens) {
            for (uint256 i = 0; i < _acceptedTokens.length; i++) {
                campaign.acceptedTokens[_acceptedTokens[i]] = true;
            }
        }
        
        uint256 totalPercentage;
        for (uint256 i = 0; i < _milestonePercentages.length; i++) {
            totalPercentage += _milestonePercentages[i];
            Milestone storage milestone = campaign.milestones.push();
            milestone.description = _milestoneDescriptions[i];
            milestone.percentage = _milestonePercentages[i];
            milestone.deadline = block.timestamp + _milestoneDurations[i];
            milestone.votesNeeded = 3; // Default number of votes needed
        }
        require(totalPercentage == 100, "Milestone percentages must total 100");
        
        _setupRole(CAMPAIGN_MANAGER_ROLE, msg.sender);
        emit CampaignCreated(campaignId, msg.sender, _title);
        return campaignId;
    }
    
    function contribute(uint256 _campaignId) external payable nonReentrant whenNotPaused {
        Campaign storage campaign = campaigns[_campaignId];
        require(campaign.status == CampaignStatus.Active, "Campaign is not active");
        require(block.timestamp < campaign.deadline, "Campaign has ended");
        require(msg.value >= campaign.minContribution, "Contribution below minimum");
        require(msg.value <= campaign.maxContribution, "Contribution above maximum");
        require(campaign.contributions[msg.sender] + msg.value <= campaign.maxContribution, "Would exceed max contribution");
        
        campaign.contributions[msg.sender] += msg.value;
        campaign.raisedAmount += msg.value;
        
        emit ContributionMade(_campaignId, msg.sender, msg.value);
        
        if (campaign.raisedAmount >= campaign.goalAmount) {
            campaign.status = CampaignStatus.Successful;
        }
    }
    
    function contributeWithToken(uint256 _campaignId, address _token, uint256 _amount) external nonReentrant whenNotPaused {
        Campaign storage campaign = campaigns[_campaignId];
        require(campaign.acceptsTokens, "Campaign doesn't accept tokens");
        require(campaign.acceptedTokens[_token], "Token not accepted");
        require(campaign.status == CampaignStatus.Active, "Campaign is not active");
        require(block.timestamp < campaign.deadline, "Campaign has ended");
        
        IERC20 token = IERC20(_token);
        require(token.transferFrom(msg.sender, address(this), _amount), "Token transfer failed");
        
        campaign.tokenContributions[msg.sender][_token] += _amount;
        emit TokenContributionMade(_campaignId, msg.sender, _token, _amount);
    }
    
    function voteMilestoneCompletion(uint256 _campaignId) external {
        Campaign storage campaign = campaigns[_campaignId];
        require(campaign.status == CampaignStatus.Successful, "Campaign not successful");
        require(campaign.currentMilestone < campaign.milestones.length, "No more milestones");
        
        Milestone storage milestone = campaign.milestones[campaign.currentMilestone];
        require(!milestone.voters[msg.sender], "Already voted");
        require(campaign.contributions[msg.sender] > 0 || hasTokenContribution(campaign, msg.sender), "Not a contributor");
        
        milestone.voters[msg.sender] = true;
        milestone.votesReceived++;
        
        if (milestone.votesReceived >= milestone.votesNeeded) {
            milestone.released = true;
            uint256 releaseAmount = (campaign.raisedAmount * milestone.percentage) / 100;
            uint256 fee = (releaseAmount * platformFee) / 10000;
            
            require(payable(campaign.creator).send(releaseAmount - fee), "Transfer failed");
            require(feeCollector.send(fee), "Fee transfer failed");
            
            emit MilestoneCompleted(_campaignId, campaign.currentMilestone);
            campaign.currentMilestone++;
        }
    }
    
    function cancelCampaign(uint256 _campaignId) external {
        Campaign storage campaign = campaigns[_campaignId];
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || msg.sender == campaign.creator, "Not authorized");
        require(campaign.status == CampaignStatus.Active, "Campaign not active");
        
        campaign.status = CampaignStatus.Cancelled;
        emit CampaignCancelled(_campaignId);
    }
    
    function claimRefund(uint256 _campaignId) external nonReentrant {
        Campaign storage campaign = campaigns[_campaignId];
        require(campaign.status == CampaignStatus.Failed || campaign.status == CampaignStatus.Cancelled, "No refund available");
        require(campaign.contributions[msg.sender] > 0, "No contribution found");
        
        uint256 refundAmount = campaign.contributions[msg.sender];
        campaign.contributions[msg.sender] = 0;
        
        require(payable(msg.sender).send(refundAmount), "Refund transfer failed");
        emit RefundIssued(_campaignId, msg.sender, refundAmount);
    }
    
    function hasTokenContribution(Campaign storage campaign, address contributor) internal view returns (bool) {
        // Check if the contributor has made any token contributions
        for (uint256 i = 0; i < 5; i++) { // Assuming max 5 accepted tokens
            address token = address(uint160(i)); // This is a simplified way to iterate through tokens
            if (campaign.acceptedTokens[token] && campaign.tokenContributions[contributor][token] > 0) {
                return true;
            }
        }
        return false;
    }
    
    function updatePlatformFee(uint256 _newFee) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not admin");
        require(_newFee <= 1000, "Fee cannot exceed 10%");
        platformFee = _newFee;
    }
    
    function updateFeeCollector(address payable _newCollector) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not admin");
        require(_newCollector != address(0), "Invalid address");
        feeCollector = _newCollector;
    }
    
    function pause() external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not admin");
        _pause();
    }
    
    function unpause() external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not admin");
        _unpause();
    }
    
    // Function to get campaign details
    function getCampaignDetails(uint256 _campaignId) external view returns (
        address creator,
        string memory title,
        string memory description,
        uint256 goalAmount,
        uint256 raisedAmount,
        uint256 deadline,
        CampaignStatus status,
        uint256 currentMilestone,
        bool acceptsTokens
    ) {
        Campaign storage campaign = campaigns[_campaignId];
        return (
            campaign.creator,
            campaign.title,
            campaign.description,
            campaign.goalAmount,
            campaign.raisedAmount,
            campaign.deadline,
            campaign.status,
            campaign.currentMilestone,
            campaign.acceptsTokens
        );
    }
    
    receive() external payable {
        revert("Use contribute() function to make contributions");
    }
}