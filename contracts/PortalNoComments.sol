// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {MintBurnToken} from "./MintBurnToken.sol";
import {IStaking} from "./interfaces/IStaking.sol";
import {ICompounder} from "./interfaces/ICompounder.sol";
import {IRewarder} from "./interfaces/IRewarder.sol";
contract Portal is ReentrancyGuard {
    constructor(uint256 _fundingPhaseDuration, 
        uint256 _fundingExchangeRatio,
        uint256 _fundingRewardRate, 
        address _principalToken, 
        address _bToken, 
        address _portalEnergyToken, 
        address _tokenToAcquire, 
        uint256 _terminalMaxLockDuration, 
        uint256 _amountToConvert)
        {
            fundingPhaseDuration = _fundingPhaseDuration;
            fundingExchangeRatio = _fundingExchangeRatio;
            fundingRewardRate = _fundingRewardRate;
            principalToken = _principalToken;
            bToken = _bToken;
            portalEnergyToken = _portalEnergyToken;
            tokenToAcquire = _tokenToAcquire;
            terminalMaxLockDuration = _terminalMaxLockDuration;
            amountToConvert = _amountToConvert;
            creationTime = block.timestamp;
    }
    using SafeERC20 for IERC20;
    address immutable public bToken;
    address immutable public portalEnergyToken;
    address immutable public tokenToAcquire;
    uint256 immutable public amountToConvert;
    uint256 immutable public terminalMaxLockDuration;
    uint256 immutable public creationTime;
    uint256 constant private secondsPerYear = 31536000;
    uint256 public maxLockDuration = 7776000;
    uint256 public totalPrincipalStaked;
    bool private lockDurationUpdateable = true;
    address immutable public principalToken;
    address payable private constant compounderAddress = payable (0x8E5D083BA7A46f13afccC27BFB7da372E9dFEF22);
    address payable private constant HLPstakingAddress = payable (0xbE8f8AF5953869222eA8D39F1Be9d03766010B1C);
    address private constant HLPprotocolRewarder = 0x665099B3e59367f02E5f9e039C3450E31c338788;
    address private constant HLPemissionsRewarder = 0x6D2c18B559C5343CB0703bB55AADB5f22152cC32;
    address private constant HMXstakingAddress = 0x92E586B8D4Bf59f4001604209A292621c716539a;
    address private constant HMXprotocolRewarder = 0xB698829C4C187C85859AD2085B24f308fC1195D3;
    address private constant HMXemissionsRewarder = 0x94c22459b145F012F1c6791F2D729F7a22c44764;
    address private constant HMXdragonPointsRewarder = 0xbEDd351c62111FB7216683C2A26319743a06F273;
    uint256 immutable private fundingPhaseDuration;
    uint256 public fundingBalance;
    uint256 public fundingRewardPool;
    uint256 public fundingRewardsCollected;
    uint256 public fundingMaxRewards;
    uint256 immutable public fundingRewardRate;
    uint256 immutable private fundingExchangeRatio;
    uint256 constant public fundingRewardShare = 10;
    bool public isActivePortal = false;
    uint256 public constantProduct;
    struct Account {
        bool isExist;
        uint256 lastUpdateTime;
        uint256 stakedBalance;
        uint256 maxStakeDebt;
        uint256 portalEnergy;
        uint256 availableToWithdraw;
    }
    mapping(address => Account) public accounts;
    event PortalActivated(address indexed, uint256 fundingBalance);
    event FundingReceived(address indexed, uint256 amount);
    event portalEnergyBuyExecuted(address indexed, uint256 amount);
    event portalEnergySellExecuted(address indexed, uint256 amount);
    event TokenStaked(address indexed user, uint256 amountStaked);
    event TokenUnstaked(address indexed user, uint256 amountUnstaked);
    event RewardsClaimed(address[] indexed pools, address[][] rewarders, uint256 timeStamp);
    event StakePositionUpdated(address indexed user, 
        uint256 lastUpdateTime,
        uint256 stakedBalance,
        uint256 maxStakeDebt,
        uint256 portalEnergy,
        uint256 availableToWithdraw);
    function _updateAccount(address _user, uint256 _amount) private {
        uint256 portalEnergyEarned = (accounts[_user].stakedBalance * 
            (block.timestamp - accounts[_user].lastUpdateTime)) / secondsPerYear;
        accounts[_user].lastUpdateTime = block.timestamp;
        accounts[_user].stakedBalance += _amount;
        accounts[_user].maxStakeDebt += (_amount * maxLockDuration) / secondsPerYear;
        accounts[_user].portalEnergy += portalEnergyEarned;
        if (accounts[_user].portalEnergy >= accounts[_user].maxStakeDebt) {
            accounts[_user].availableToWithdraw = accounts[_user].stakedBalance;
        } else {
            accounts[_user].availableToWithdraw = (accounts[_user].stakedBalance * accounts[_user].portalEnergy) / accounts[_user].maxStakeDebt;
        }
    }
    function stake(uint256 _amount) external nonReentrant {
        require(isActivePortal);
        IERC20(principalToken).safeTransferFrom(msg.sender, address(this), _amount);
        totalPrincipalStaked += _amount;
        _depositToYieldSource();
        if(accounts[msg.sender].isExist == true){
            _updateAccount(msg.sender, _amount);
        } 
        else {
            uint256 maxStakeDebt = (_amount * maxLockDuration) / secondsPerYear;
            uint256 availableToWithdraw = _amount;
            uint256 portalEnergy = maxStakeDebt;
            accounts[msg.sender] = Account(true, 
                block.timestamp, 
                _amount, 
                maxStakeDebt, 
                portalEnergy,
                availableToWithdraw);     
        }
        emit StakePositionUpdated(msg.sender, 
        accounts[msg.sender].lastUpdateTime,
        accounts[msg.sender].stakedBalance,
        accounts[msg.sender].maxStakeDebt, 
        accounts[msg.sender].portalEnergy, 
        accounts[msg.sender].availableToWithdraw);
    }
    function unstake(uint256 _amount) external nonReentrant {
        require(accounts[msg.sender].isExist == true,"User has no stake");
        _updateAccount(msg.sender,0);
        require(_amount <= accounts[msg.sender].availableToWithdraw, "Insufficient withdrawable balance");
        require(_amount <= accounts[msg.sender].stakedBalance, "Insufficient stake balance");
        _withdrawFromYieldSource(_amount);
        accounts[msg.sender].stakedBalance -= _amount;
        accounts[msg.sender].maxStakeDebt -= (_amount * maxLockDuration) / secondsPerYear;
        accounts[msg.sender].availableToWithdraw -= _amount;
        totalPrincipalStaked -= _amount;
        IERC20(principalToken).safeTransfer(msg.sender, _amount);
        emit StakePositionUpdated(msg.sender, 
        accounts[msg.sender].lastUpdateTime,
        accounts[msg.sender].stakedBalance,
        accounts[msg.sender].maxStakeDebt, 
        accounts[msg.sender].portalEnergy,
        accounts[msg.sender].availableToWithdraw);
    }
    function forceUnstakeAll() external nonReentrant {
        require(accounts[msg.sender].isExist == true,"User has no stake");
        _updateAccount(msg.sender,0);
        if(accounts[msg.sender].portalEnergy < accounts[msg.sender].maxStakeDebt) {
            uint256 remainingDebt = accounts[msg.sender].maxStakeDebt - accounts[msg.sender].portalEnergy;
            require(IERC20(portalEnergyToken).balanceOf(address(msg.sender)) >= remainingDebt, "Not enough Portal Energy Tokens");
            _burnPortalEnergyToken(msg.sender, remainingDebt);
        }
        uint256 balance = accounts[msg.sender].stakedBalance;
        _withdrawFromYieldSource(balance);
        accounts[msg.sender].stakedBalance = 0;
        accounts[msg.sender].maxStakeDebt = 0;
        accounts[msg.sender].portalEnergy -= (balance * maxLockDuration) / secondsPerYear;
        accounts[msg.sender].availableToWithdraw = 0;
        IERC20(principalToken).safeTransferFrom(msg.sender, address(this), balance);
        totalPrincipalStaked -= balance;
        emit StakePositionUpdated(msg.sender, 
        accounts[msg.sender].lastUpdateTime,
        accounts[msg.sender].stakedBalance,
        accounts[msg.sender].maxStakeDebt, 
        accounts[msg.sender].portalEnergy,
        accounts[msg.sender].availableToWithdraw);
    }
    function _depositToYieldSource() private {
        uint256 balance = IERC20(principalToken).balanceOf(address(this));
        IERC20(principalToken).approve(HLPstakingAddress, balance);
        IStaking(HLPstakingAddress).deposit(address(this), balance);
        emit TokenStaked(msg.sender, balance);
    }
    function _withdrawFromYieldSource(uint256 _amount) private {
        IStaking(HLPstakingAddress).withdraw(_amount);
        emit TokenUnstaked(msg.sender, _amount);
    }
    function claimRewardsHLPandHMX() external {
        address[] memory pools = new address[](2);
        pools[0] = HLPstakingAddress;
        pools[1] = HMXstakingAddress; 
        address[][] memory rewarders = new address[][](2);
        rewarders[0] = new address[](2);
        rewarders[0][0] = HLPprotocolRewarder;
        rewarders[0][1] = HLPemissionsRewarder;
        rewarders[1] = new address[](3);
        rewarders[1][0] = HMXprotocolRewarder;
        rewarders[1][1] = HMXemissionsRewarder;
        rewarders[1][2] = HMXdragonPointsRewarder;
        ICompounder(compounderAddress).compound(
            pools,
            rewarders,
            1689206400,
            115792089237316195423570985008687907853269984665640564039457584007913129639935,
            new uint256[](0)
        );
        emit RewardsClaimed(pools, rewarders, block.timestamp);
    }
    function claimRewardsManual(address[] memory _pools, address[][] memory _rewarders) external {
        ICompounder(compounderAddress).compound(
            _pools,
            _rewarders,
            1689206400,
            115792089237316195423570985008687907853269984665640564039457584007913129639935,
            new uint256[](0)
        );
        emit RewardsClaimed(_pools, _rewarders, block.timestamp);
    }
    function buyPortalEnergy(uint256 _amountInput, uint256 _minReceived) external nonReentrant {
        require(accounts[msg.sender].isExist == true,"User has no stake");
        _updateAccount(msg.sender,0);
        require(IERC20(tokenToAcquire).balanceOf(msg.sender) >= _amountInput, "Insufficient balance");
        uint256 reserve0 = IERC20(tokenToAcquire).balanceOf(address(this)) - fundingRewardPool;
        uint256 reserve1 = constantProduct / reserve0;
        uint256 amountReceived = (_amountInput * reserve1) / (_amountInput + reserve0);
        require(amountReceived >= _minReceived, "Output too small");
        IERC20(tokenToAcquire).safeTransferFrom(msg.sender, address(this), _amountInput);
        accounts[msg.sender].portalEnergy += amountReceived;
        emit portalEnergyBuyExecuted(msg.sender, amountReceived);
    }
    function sellPortalEnergy(uint256 _amountInput, uint256 _minReceived) external nonReentrant {
        require(accounts[msg.sender].isExist == true,"User has no stake");
        _updateAccount(msg.sender,0);
        require(accounts[msg.sender].portalEnergy >= _amountInput, "Insufficient balance");
        uint256 reserve0 = IERC20(tokenToAcquire).balanceOf(address(this)) - fundingRewardPool;
        uint256 reserve1 = constantProduct / reserve0;
        uint256 amountReceived = (_amountInput * reserve0) / (_amountInput + reserve1);
        require(amountReceived >= _minReceived, "Output too small");
        accounts[msg.sender].portalEnergy -= _amountInput;
        IERC20(tokenToAcquire).safeTransfer(msg.sender, amountReceived);
        emit portalEnergySellExecuted(msg.sender, _amountInput);
    }
    function quoteBuyPortalEnergy(uint256 _amountInput) public view returns(uint256) {
        uint256 reserve0 = IERC20(tokenToAcquire).balanceOf(address(this)) - fundingRewardPool;
        uint256 reserve1 = constantProduct / reserve0;
        uint256 amountReceived = (_amountInput * reserve1) / (_amountInput + reserve0);

        return (amountReceived);
    }
    function quoteSellPortalEnergy(uint256 _amountInput) public view returns(uint256) {
        uint256 reserve0 = IERC20(tokenToAcquire).balanceOf(address(this)) - fundingRewardPool;
        uint256 reserve1 = constantProduct / reserve0;
        uint256 amountReceived = (_amountInput * reserve0) / (_amountInput + reserve1);

        return (amountReceived);
    }
    function convert(address _token, uint256 _minReceived) external nonReentrant {
        require(_token != tokenToAcquire, "Cannot receive the input token");
        require(_token != principalToken, "Cannot receive the stake token");
        uint256 contractBalance = IERC20(_token).balanceOf(address(this));
        require (contractBalance >= _minReceived, "Not enough tokens in contract");
        IERC20(tokenToAcquire).safeTransferFrom(msg.sender, address(this), amountToConvert); 
        if (IERC20(bToken).totalSupply() > 0 && fundingRewardsCollected < fundingMaxRewards) {
            uint256 newRewards = (fundingRewardShare * amountToConvert) / 100;
            fundingRewardPool += newRewards;
            fundingRewardsCollected += newRewards;
        }
        IERC20(_token).safeTransfer(msg.sender, contractBalance);
    }
    function contributeFunding(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Invalid amount");
        require(isActivePortal == false,"Funding phase concluded");
        fundingBalance += _amount;
        uint256 mintableAmount = _amount * fundingRewardRate;
        IERC20(tokenToAcquire).safeTransferFrom(msg.sender, address(this), _amount); 
        MintBurnToken(bToken).mint(msg.sender, mintableAmount);
        emit FundingReceived(msg.sender, mintableAmount);
    }
    function getBurnValuePSM(uint256 _amount) public view returns(uint256 burnValue) {
        burnValue = (fundingRewardPool * _amount) / IERC20(bToken).totalSupply();
        return burnValue;
    }
    function burnBtokens(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Invalid amount");
        require(isActivePortal = true, "Portal not active");
        uint256 amountToReceive = getBurnValuePSM(_amount);
        MintBurnToken(bToken).burnFrom(msg.sender, _amount);
        fundingRewardPool -= amountToReceive;
        IERC20(tokenToAcquire).safeTransfer(msg.sender, amountToReceive);
    }
    function activatePortal() external {
        require(isActivePortal = false, "Portal already active");
        require(block.timestamp >= creationTime + fundingPhaseDuration,"Funding phase ongoing");
        uint256 requiredPortalEnergyLiquidity = fundingBalance * fundingExchangeRatio;
        constantProduct = fundingBalance * requiredPortalEnergyLiquidity;
        fundingMaxRewards = IERC20(bToken).totalSupply();
        isActivePortal = true;
        emit PortalActivated(address(this), fundingBalance);
    }
    function mintPortalEnergyToken(address _recipient, uint256 _amount) external nonReentrant {
        require(accounts[msg.sender].portalEnergy >= _amount, "Insufficient portalEnergy");
        accounts[msg.sender].portalEnergy -= _amount;
        MintBurnToken(portalEnergyToken).mint(_recipient, _amount);
    }
    function burnPortalEnergyToken(address _recipient, uint256 _amount) external nonReentrant {
        require(accounts[_recipient].isExist == true);
        MintBurnToken(portalEnergyToken).burnFrom(msg.sender, _amount);
        accounts[_recipient].portalEnergy += _amount;
    }
    function _burnPortalEnergyToken(address _user, uint256 _amount) private {
        require(accounts[_user].isExist == true);
        MintBurnToken(portalEnergyToken).burnFrom(_user, _amount);
        accounts[_user].portalEnergy += _amount;
    }
    function updateMaxLockDuration() external {  
        require(lockDurationUpdateable == true,"Lock duration cannot increase");
        uint256 newValue = 2 * (block.timestamp - creationTime);

        if (newValue >= terminalMaxLockDuration) {
            maxLockDuration = terminalMaxLockDuration;
            lockDurationUpdateable = false;
        } 
        else if (newValue > maxLockDuration) {
            maxLockDuration = newValue;
        }
    }
    function getUpdateAccount(address _user, uint256 _amount) public view returns(
        address user,
        uint256 lastUpdateTime,
        uint256 stakedBalance,
        uint256 maxStakeDebt,
        uint256 portalEnergy,
        uint256 availableToWithdraw) {
        uint256 portalEnergyEarned = (accounts[_user].stakedBalance * 
            (block.timestamp - accounts[_user].lastUpdateTime)) / secondsPerYear;
        lastUpdateTime = block.timestamp;
        stakedBalance = accounts[_user].stakedBalance + _amount;
        maxStakeDebt = accounts[_user].maxStakeDebt + (_amount * maxLockDuration) / secondsPerYear;
        portalEnergy = accounts[_user].portalEnergy + portalEnergyEarned;
        if (portalEnergy >= maxStakeDebt) {
            availableToWithdraw = stakedBalance;
        } else {
            availableToWithdraw = (stakedBalance * portalEnergy) / maxStakeDebt;
        }
    return (_user, lastUpdateTime, stakedBalance, maxStakeDebt, portalEnergy, availableToWithdraw);
    }
    function quoteforceUnstakeAll(address _user) public view returns(uint256 portalEnergyTokenToBurn) {
        (, , , uint256 maxStakeDebt, uint256 portalEnergy,) = getUpdateAccount(_user,0);
        if(maxStakeDebt > portalEnergy) {
            portalEnergyTokenToBurn = maxStakeDebt - portalEnergy;
        }
        return portalEnergyTokenToBurn; 
    }
    function getBalanceOfToken(address _token) public view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }
    function getPendingRewards(address _rewarder) public view returns(uint256 claimableReward){
        claimableReward = IRewarder(_rewarder).pendingReward(address(this));
        return(claimableReward);
    }
}