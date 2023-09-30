// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract PortalConverter is ReentrancyGuard{
    constructor(address _tokenToAcquire, address _tokenToStake, uint256 _amountToConvert, uint256 _annualRewardRate){
        tokenToAcquire = _tokenToAcquire;
        tokenToStake = _tokenToStake;
        amountToConvert = _amountToConvert;
        annualRewardRate = _annualRewardRate;
        lastUpdate = block.timestamp;
    }

    // ============================================
    // ==        GLOBAL VARIABLES & EVENTS       ==
    // ============================================
    using SafeERC20 for IERC20;

    address public immutable tokenToAcquire;    // address of the LP token that is acquired in the converter
    address public immutable tokenToStake;      // address of the staking token
    uint256 public immutable amountToConvert;   // constant amount of LP tokens that is required to convert
    uint256 public immutable annualRewardRate;  // percentage of LP tokens in contract that are distributed annually to stakers
    uint256 internal constant secondsPerYear = 31536000;    // seconds in a 365 day year
    
    uint256 public lpBalanceLessRewards;        // the amount of LP tokens in the contract excluding harvested rewards
    uint256 public totalStaked;                 // The amount of PSM staked in this contract
    uint256 public pendingRewards;              // pending reward balance total
    uint256 public accruedRewards;              // rewards that are harvested but not withdrawn / claimed by users
    uint256 public rewardPerTokenStaked;        // claimed rewards per staked token, ever increasing
    uint256 public lastUpdate;                  // time of the last staking reward calculation
    uint256 private passedTime;                 // time difference in seconds to last reward calculation

    mapping(address => Stake) public stakes;    // maps user addresses to their stake information
    
    struct Stake {                              // stake information per user
        uint256 balanceStaked;
        uint256 userRewardsPerTokenClaimed;
    }

    event StakePositionUpdated(address indexed user, 
        uint256 lastUpdateTime,
        uint256 userStakedBalance,
        uint256 totalStakedBalance);
        
    event RewardsClaimed(address indexed user, 
        uint256 lastUpdateTime,
        uint256 UserRewardsClaimed,
        uint256 accruedRewardsTotal);

    // ============================================
    // ==           STAKING & UNSTAKING          ==
    // ============================================

    function harvest() internal {
        // update LP Balance from which rewards are taken (exclude harvested but unclaimed rewards of LP token)
        passedTime = block.timestamp - lastUpdate;
        lpBalanceLessRewards = IERC20(tokenToAcquire).balanceOf(address(this)) - accruedRewards;

        // calculate pending staking rewards and record update time stamp
        pendingRewards += (passedTime * annualRewardRate * lpBalanceLessRewards) / 100 / secondsPerYear;
        lastUpdate = block.timestamp;

        // update reward per token staked and accrued rewards if there are tokens staked
        if (totalStaked > 0) {
        rewardPerTokenStaked += pendingRewards / totalStaked;
        accruedRewards += pendingRewards;
        pendingRewards = 0;
        }
    }

    // claims user rewards and send to wallet
    function claim(address _user) public nonReentrant {
        // call harvest() to update global staking information
        harvest();

        // calculate user claimable rewards since last claim & update user info (Stake struct)
        uint256 claimableRewards = (rewardPerTokenStaked - stakes[_user].userRewardsPerTokenClaimed) * stakes[_user].balanceStaked;  
        stakes[_user].userRewardsPerTokenClaimed = rewardPerTokenStaked;

        // update global stake information
        accruedRewards -= claimableRewards;

        // transfer claimable rewards to user wallet
        IERC20(tokenToAcquire).safeTransfer(_user, claimableRewards);

        // emit claim update event
        emit RewardsClaimed(_user, lastUpdate, claimableRewards, accruedRewards);
    }


    // handle new stakes
    function stake(uint256 _amount) external nonReentrant {
       // Do not allow 0 value stakes
       require(_amount > 0);

       // call claim() to update user information & global information (via nested harvest)
        claim(msg.sender);

        // update user and global stake balance
        stakes[msg.sender].balanceStaked += _amount;
        totalStaked += _amount;

        // transfer staking token from user to contract
        IERC20(tokenToStake).safeTransferFrom(msg.sender, address(this), _amount);

        // emit stake update event
        emit StakePositionUpdated(msg.sender, lastUpdate, stakes[msg.sender].balanceStaked, totalStaked);
    }


    function unstake(uint256 _amount) external nonReentrant {
       // check if user has sufficient staked balance & prevent 0 value unstakes
       require(_amount >0 && _amount <= stakes[msg.sender].balanceStaked);
       
       // call claim() to update user information & global information (via nested harvest)
        claim(msg.sender);

        // update user and global stake balance
        stakes[msg.sender].balanceStaked -= _amount;
        totalStaked -= _amount;

        // transfer staking token from user to contract
        IERC20(tokenToStake).safeTransferFrom(msg.sender, address(this), _amount);

        // emit stake update event
        emit StakePositionUpdated(msg.sender, lastUpdate, stakes[msg.sender].balanceStaked, totalStaked);
    }

    // ============================================
    // ==           LIQUIDITY CONVERTER          ==
    // ============================================

    // handles the arbitrage conversion of tokens inside the contract for LP tokens
    function convert(address _token, uint256 _minReceived) external nonReentrant {

        // Check that the output token is not the input token (LP)
        require(_token != tokenToAcquire, "Cannot receive the input token");

        // Check if sufficient output token is available in the contract (frontrun protection)
        uint256 contractBalance = IERC20(_token).balanceOf(address(this));
        require (contractBalance >= _minReceived, "Not enough tokens in contract");

        // Transfer input (LP) token from user to contract
        IERC20(tokenToAcquire).safeTransferFrom(msg.sender, address(this), amountToConvert); 

        // Transfer output token from contract to user
        IERC20(_token).safeTransfer(msg.sender, contractBalance);
    }

    // ============================================
    // ==             VIEW FUNCTIONS             ==
    // ============================================

    function getClaimableRewards(address _user) public view returns(uint256 claimableRewardsSim) {
        // check if user has staking balance
        require(stakes[_user].balanceStaked >0, "User has no stake");
        
        // update LP Balance from which rewards are taken (exclude harvested but unclaimed rewards of LP token)
        uint256 passedTimeSim = block.timestamp - lastUpdate;
        uint256 lpBalanceLessRewardsSim = IERC20(tokenToAcquire).balanceOf(address(this)) - accruedRewards;

        // calculate pending staking rewards & rewards per token
        uint256 pendingRewardsSim = (passedTimeSim * annualRewardRate * lpBalanceLessRewardsSim) / 100 / secondsPerYear + pendingRewards;
        uint256 rewardPerTokenStakedSim = pendingRewardsSim / totalStaked + rewardPerTokenStaked;

        // calculate & return the reward amount for the input address
        claimableRewardsSim = (rewardPerTokenStakedSim - stakes[_user].userRewardsPerTokenClaimed) * stakes[_user].balanceStaked;
        return claimableRewardsSim;
    }


    // View balances of tokens inside the contract
    function getBalanceOfToken(address _token) public view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }


    // View stake position of users
    function getStakePosition(address _user) public view returns (Stake memory) {
        return stakes[_user];
    }
}