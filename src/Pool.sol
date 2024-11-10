// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

// Interface for the Pool contract
interface IPool {
    function initialize(address _token, address _owner) external;
    function getPoolBalance() external view returns (uint256);
    function getUserBalance(address user) external view returns (uint256);
    function getUserPercentage(address user) external view returns (uint256);
}

// Pool Factory Contract
contract PoolFactory {
    address[] public allPools;
    mapping(address => address[]) public userPools;
    mapping(address => bool) public isPool;
    
    event PoolCreated(address indexed pool, address indexed token, address indexed creator);
    
    function createPool(address _token) external returns (address pool) {
        bytes memory bytecode = type(Pool).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(_token, msg.sender, block.timestamp));
        assembly {
            pool := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        
        IPool(pool).initialize(_token, msg.sender);
        
        allPools.push(pool);
        userPools[msg.sender].push(pool);
        isPool[pool] = true;
        
        emit PoolCreated(pool, _token, msg.sender);
        return pool;
    }
    
    function getPoolsCount() external view returns (uint256) {
        return allPools.length;
    }
    
    function getUserPoolsCount(address user) external view returns (uint256) {
        return userPools[user].length;
    }
}

// Pool Contract
contract Pool is ReentrancyGuard, Pausable, Ownable {
    using SafeMath for uint256;
    
    struct UserInfo {
        uint256 balance;
        uint256 percentage;
        bool isActive;
    }
    
    IERC20 public token;
    uint256 public totalPoolBalance;
    mapping(address => UserInfo) public users;
    address[] public activeUsers;
    bool private initialized;
    
    event FundsAdded(address indexed user, uint256 amount, uint256 newPercentage);
    event FundsRemoved(address indexed user, uint256 amount);
    event PoolPaused();
    event PoolUnpaused();
    event FundsDistributed();
    
    modifier onlyInitialized() {
        require(initialized, "Pool not initialized");
        _;
    }
    
    function initialize(address _token, address _owner) external {
        require(!initialized, "Pool already initialized");
        token = IERC20(_token);
        _transferOwnership(_owner);
        initialized = true;
    }
    
    function addFunds(uint256 _amount) external nonReentrant whenNotPaused onlyInitialized {
        require(_amount > 0, "Amount must be greater than 0");
        require(token.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        
        UserInfo storage user = users[msg.sender];
        if (!user.isActive) {
            activeUsers.push(msg.sender);
            user.isActive = true;
        }
        
        uint256 newTotalBalance = totalPoolBalance.add(_amount);
        user.balance = user.balance.add(_amount);
        totalPoolBalance = newTotalBalance;
        
        // Recalculate percentages for all active users
        _updatePercentages();
        
        emit FundsAdded(msg.sender, _amount, user.percentage);
    }
    
    function removeFunds() external nonReentrant whenNotPaused onlyInitialized {
        UserInfo storage user = users[msg.sender];
        require(user.isActive, "User not in pool");
        require(user.balance > 0, "No funds to remove");
        
        uint256 amountToRemove = user.balance;
        require(token.transfer(msg.sender, amountToRemove), "Transfer failed");
        
        totalPoolBalance = totalPoolBalance.sub(amountToRemove);
        user.balance = 0;
        user.percentage = 0;
        user.isActive = false;
        
        // Remove user from activeUsers array
        _removeFromActiveUsers(msg.sender);
        
        // Recalculate percentages for remaining users
        _updatePercentages();
        
        emit FundsRemoved(msg.sender, amountToRemove);
        
        // If pool is empty, pause it
        if (totalPoolBalance == 0) {
            _pause();
            emit PoolPaused();
        }
    }
    
    function distributeFunds() external nonReentrant whenPaused onlyOwner onlyInitialized {
        require(totalPoolBalance > 0, "No funds to distribute");
        
        for (uint256 i = 0; i < activeUsers.length; i++) {
            address userAddress = activeUsers[i];
            UserInfo storage user = users[userAddress];
            if (user.isActive && user.percentage > 0) {
                uint256 userShare = totalPoolBalance.mul(user.percentage).div(10000); // percentage is in basis points
                require(token.transfer(userAddress, userShare), "Transfer failed");
                user.balance = 0;
                user.percentage = 0;
                user.isActive = false;
            }
        }
        
        totalPoolBalance = 0;
        delete activeUsers;
        
        emit FundsDistributed();
    }
    
    function _updatePercentages() internal {
        if (totalPoolBalance == 0) return;
        
        for (uint256 i = 0; i < activeUsers.length; i++) {
            address userAddress = activeUsers[i];
            UserInfo storage user = users[userAddress];
            if (user.isActive) {
                user.percentage = user.balance.mul(10000).div(totalPoolBalance); // Calculate percentage in basis points
            }
        }
    }
    
    function _removeFromActiveUsers(address userAddress) internal {
        for (uint256 i = 0; i < activeUsers.length; i++) {
            if (activeUsers[i] == userAddress) {
                activeUsers[i] = activeUsers[activeUsers.length - 1];
                activeUsers.pop();
                break;
            }
        }
    }
    
    // View functions
    function getPoolBalance() external view returns (uint256) {
        return totalPoolBalance;
    }
    
    function getUserBalance(address user) external view returns (uint256) {
        return users[user].balance;
    }
    
    function getUserPercentage(address user) external view returns (uint256) {
        return users[user].percentage;
    }
    
    function getActiveUsersCount() external view returns (uint256) {
        return activeUsers.length;
    }
    
    function isUserActive(address user) external view returns (bool) {
        return users[user].isActive;
    }
    
    // Emergency functions
    function emergencyWithdraw() external onlyOwner {
        require(token.transfer(owner(), token.balanceOf(address(this))), "Transfer failed");
        totalPoolBalance = 0;
        
        for (uint256 i = 0; i < activeUsers.length; i++) {
            address userAddress = activeUsers[i];
            UserInfo storage user = users[userAddress];
            user.balance = 0;
            user.percentage = 0;
            user.isActive = false;
        }
        
        delete activeUsers;
    }
    
    // Pause/Unpause functions
    function pausePool() external onlyOwner {
        _pause();
        emit PoolPaused();
    }
    
    function unpausePool() external onlyOwner {
        _unpause();
        emit PoolUnpaused();
    }
}