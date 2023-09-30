// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract TimeRift is Ownable, ReentrancyGuard {
    constructor(address _tokenIn, address _tokenOut, address _recipient){   
        tokenIn = _tokenIn;
        tokenOut = _tokenOut;
        recipient = _recipient;
    }

    // ============================================
    // ==        GLOBAL VARIABLES & EVENTS       ==
    // ============================================
    using SafeERC20 for IERC20;

    address public immutable tokenIn;                       // address of the token accepted for conversion
    address public immutable tokenOut;                      // address of the token received after conversion
    address public recipient;                               // recipient address of the converted tokens
    uint256 public constant convertDuration = 31536000;     // seconds delay between staking tokenIn and getting tokenOut
    uint256 public constant convertRatio = 1;               // how many tokenOut the user gets for every tokenIn
    uint256 public constant budgetRatio = 2;                // how many tokenOut can the user direct to whitelisted LPs over the duration?
    uint256 public constant exitPenalty = 5;                // percentage penalty on withdrawals before convert

    uint256 public totalStaked;                             // The amount of tokens staked for conversion
    uint256 public reservedForConvert;                      // amount of tokenOut that is reserved to service conversions

    struct Stake {                                          // contains information about user stake positions
    uint256 stakeTime;
    uint256 stakedBalance;
    uint256 lastDistributionTime;
    uint256 distributedBudget;
    }
    mapping(address => Stake) public stakes;                // Associate users with their stake position

    mapping(address => bool) public whitelist;              // LP whitelist tracking

    event StakePositionUpdated(address indexed user,        // broadcast updates to user stake positions
        uint256 stakeTime,
        uint256 userStakedBalance,
        uint256 totalStakedBalance);

    event ConversionExecuted(address indexed user,          // broadcast update when a conversion was completed
        uint256 amountReceived,
        uint256 totalStakedBalance);

    event BudgetDistributed (address indexed user,          // broadcast the budget distribution
        uint256 amount,
        address token);

    event TokenWhitelisted(address indexed token);          // broadcast whitelist additions
    event TokenRemovedFromWhitelist(address indexed token); // broadcast whitelist removals

    // ============================================
    // ==           STAKING & UNSTAKING          ==
    // ============================================

    // Handle user deposits and (re-)start timer
    function stake(uint256 _amount) external nonReentrant {
        // Prevent 0 deposit calls
        require(_amount > 0,"Invalid amount");

        // check if enough output tokens can be reserved for the conversion
        uint256 availableToConvert = getBalanceOfToken(tokenOut) - reservedForConvert;
        require(availableToConvert > (_amount * convertRatio),"not enough output token available");

        // update relevant user stake information
        stakes[msg.sender].stakedBalance += _amount;
        stakes[msg.sender].stakeTime = block.timestamp;
        stakes[msg.sender].lastDistributionTime = block.timestamp;

        // update global information & reserve output token
        totalStaked += _amount;
        reservedForConvert += (_amount * convertRatio);

        // Transfer stake token from user to contract
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), _amount); 

        // emit event with updated stake information
        emit StakePositionUpdated(msg.sender,stakes[msg.sender].stakeTime,stakes[msg.sender].stakedBalance,totalStaked);
    }


    // Allow pre-mature withdrawals with penalty (chicken out)
    function unstake(uint256 _amount) external nonReentrant {
        // Prevent 0 withdraw calls
        require(_amount > 0,"Invalid amount");
        require(_amount <= stakes[msg.sender].stakedBalance,"Not enough stake balance");

        // update relevant user stake information
        stakes[msg.sender].stakedBalance -= _amount;

        // update global information & free up the reserved output tokens
        totalStaked -= _amount;
        reservedForConvert -= (_amount * convertRatio);

        // apply early exit penalty
        uint256 exitCost = (exitPenalty * _amount) / 100;
        uint256 amountToUser = _amount - exitCost;

        // Transfer token from contract to user & penalty to recipient
        IERC20(tokenIn).safeTransfer(msg.sender, amountToUser);
        IERC20(tokenIn).safeTransfer(recipient, exitCost);

        // emit event with updated stake information
        emit StakePositionUpdated(msg.sender,stakes[msg.sender].stakeTime,stakes[msg.sender].stakedBalance,totalStaked);
    }


    // execute conversion after duration expiry, transfer tokenOut to user, tokenIn to recipient
    function executeConversion() external nonReentrant {
        // calculate passed time since staking
        uint256 passedTime = block.timestamp - stakes[msg.sender].stakeTime;

        // check if duration has expired
        require(passedTime >= convertDuration);

        // get balances to transfer
        uint256 amountToRecipient = stakes[msg.sender].stakedBalance;
        uint256 amountToUser = stakes[msg.sender].stakedBalance * convertRatio;

        // update stake information
        totalStaked -= amountToRecipient;
        delete stakes[msg.sender];

        // transfer tokens
        IERC20(tokenIn).safeTransfer(recipient, amountToRecipient);
        IERC20(tokenOut).safeTransfer(msg.sender, amountToUser);
        
        // emit information
        emit ConversionExecuted(msg.sender, amountToUser, totalStaked);
    }


    // ============================================
    // ==           BUDGET DISTRIBUTION          ==
    // ============================================

    // function: distribute time-based budget to one of the whitelisted pools (simple transfer)
    function distributeBudget(address _to, uint256 _amount) external nonReentrant {
        // check if recipient is whitelisted LP
        require(whitelist[_to],"LP not whitelisted");
        
        // get the budget the user can distribute currently
        uint256 budgetAvailable = getUserBudgetToDistribute(msg.sender);

        // checks if user has enough budget to distribute _amount
        require(_amount <= budgetAvailable, "Insufficient budget to distribute");

        // check if contract has enough budget to distribute when considering reserved tokens, else distribute rest
        uint256 distributableBalance = getBalanceOfToken(tokenOut) - reservedForConvert;
        if (_amount > distributableBalance) {
            _amount = distributableBalance;
        }
        
        // updates user budget info
        stakes[msg.sender].lastDistributionTime = block.timestamp;
        stakes[msg.sender].distributedBudget += _amount;

        // Transfer tokens to target, whitelisted LP
        IERC20(tokenOut).safeTransfer(_to, _amount);

        emit BudgetDistributed(msg.sender,_amount,_to) ;
    }


    // View how much budget is available to be allocated by a user
    function getUserBudgetToDistribute(address _user) public view returns(uint256 budgetToDistribute) {
        // calculate passed time since last allocation
        uint256 passedTime = block.timestamp - stakes[_user].lastDistributionTime;

        // calculate the maximum budget and current budget to distribute
        uint256 maxBudgetToDistribute = stakes[_user].stakedBalance * budgetRatio;
        budgetToDistribute = (stakes[_user].stakedBalance * budgetRatio * passedTime) / convertDuration;

        if (budgetToDistribute >= (maxBudgetToDistribute - stakes[_user].distributedBudget)) {
            budgetToDistribute = maxBudgetToDistribute - stakes[_user].distributedBudget;
        }

        return (budgetToDistribute);
    } 


    // ============================================
    // ==          WHITELIST MANAGEMENT          ==
    // ============================================

    // Whitelist new LP token
    function addToWhitelist(address _LPtoken) external onlyOwner {
        whitelist[_LPtoken] = true;
        
        emit TokenWhitelisted(_LPtoken);
    }


    // Remove LP token from whitelist
    function removeFromWhitelist(address _LPtoken) external onlyOwner {
        delete whitelist[_LPtoken];

        emit TokenRemovedFromWhitelist(_LPtoken);
    }


    // ============================================
    // ==                 OTHER                  ==
    // ============================================

    // View balances of tokens inside the contract
    function getBalanceOfToken(address _token) public view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }


    // View the end timestamp of the stake of a user
    function getStakeEndTime(address _user) public view returns (uint256 endTime) {
        endTime = stakes[_user].stakeTime + convertDuration;
        return (endTime);
    }


    // change recipient of input tokens
    function changeRecipient(address _newRecipient) external onlyOwner {
        recipient = _newRecipient;
    }
}