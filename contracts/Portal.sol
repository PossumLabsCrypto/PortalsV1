// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {eToken} from "./eToken.sol";
import {PortalEnergy} from "./PortalEnergy.sol";


// OPTIMISATION
// change uint of constantProduct (huge number)


// REQUIRED TO DOS:
// Strategy-related
// function: depositIntoYieldSource -> deposits a certain amount into source
// function: withdrawFromYieldSource -> withdraws a certain amount and send to user
// function: claimFromYieldSource -> claims yield from source and redirects protocol share
// function: VIEW getClaimableYield (from yield source)


contract Portal is ReentrancyGuard {
    constructor(uint256 _fundingPhaseDuration, 
        uint256 _fundingExchangeRatio, 
        uint256 _minimumFundingAmount,
        address _principalToken, 
        address _eTokenAddress, 
        address _portalEnergyAddress, 
        address _tokenToAcquire, 
        uint256 _terminalMaxLockDuration, 
        uint256 _amountToConvert){
            fundingPhaseDuration = _fundingPhaseDuration;
            fundingExchangeRatio = _fundingExchangeRatio;
            minimumFundingAmount = _minimumFundingAmount;
            principalToken = _principalToken;
            eTokenAddress = _eTokenAddress;
            portalEnergyAddress = _portalEnergyAddress;
            tokenToAcquire = _tokenToAcquire;
            terminalMaxLockDuration = _terminalMaxLockDuration;
            amountToConvert = _amountToConvert;
            creationTime = block.timestamp;
    }

    // ============================================
    // ==        GLOBAL VARIABLES & EVENTS       ==
    // ============================================
    using SafeERC20 for IERC20;
    
    // related to yield management
    address immutable public principalToken;                    // address of the token accepted by the strategy as deposit
    address immutable public eTokenAddress;                     // address of the eToken which is the receipt token from bootstrapping
    address immutable public portalEnergyAddress;               // address of PortalEnergy, the ERC20 representation of creditLine
    address immutable public tokenToAcquire;                    // address of PSM
    uint256 immutable public amountToConvert;                   // constant amount of PSM tokens required to withdraw yield in the contract
    uint256 immutable public terminalMaxLockDuration;           // terminal maximum lock duration of user´s balance in seconds
    uint256 immutable internal creationTime;                    // time stamp of deployment
    uint256 constant internal secondsPerYear = 31536000;        // seconds in a 365 day year
    address constant public yieldSourceAddress = address(0x32456); // replace with contract address that holds the principal to generate yield
    uint256 public maxLockDuration = 7776000;                   // starting value for maximum allowed lock duration of user´s balance in seconds (90 days)
    uint256 public totalPrincipalStaked;                        // shows how much principal is staked by all users combined
    bool private lockDurationUpdateable = true;                 // flag to signal if the lock duration can still be updated

    // bootstrapping related
    uint256 immutable public fundingPhaseDuration;              // seconds that the funding phase lasts before Portal can be activated
    uint256 immutable public minimumFundingAmount;              // minimum amount of PSM tokens to successfully conclude the funding phase
    uint256 public fundingBalance;                              // sum of all PSM funding contributions
    uint256 public fundingRewardPool;                           // amount of PSM available for redemption against eTokens
    uint256 immutable public fundingExchangeRatio;              // amount of creditLine per PSM for calculating k during funding process
    uint256 constant public fundingRewardShare = 10;            // 10% of yield goes to the funding pool until investors are paid back
    bool public isActivePortal = false;                         // this will be set to true when funding phase ends.

    // exchange related
    uint256 private constantProduct;                            // the K constant of the constant product formula
    uint256 public reserve0;                                    // reserve of PSM tokens for LP calculations
    uint256 public reserve1;                                    // reserve of creditLine for LP calculations

    struct Account {                                            // contains information of user stake positions
    bool isExist;
    uint256 lastUpdateTime;
    uint256 stakedBalance;
    uint256 maxStakeDebt;
    uint256 creditLine;
    uint256 availableToWithdraw;
    }

    mapping(address => Account) public accounts;            // Associate users with their stake position

    // Events related to the funding phase
    event PortalActivated(address indexed, uint256 fundingBalance);
    event FundingReceived(address indexed, uint256 amount);

    // Events for buying and selling creditLine against PSM
    event CreditLineBuyExecuted(address indexed, uint256 amount);
    event CreditLineSellExecuted(address indexed, uint256 amount);

    // Event to inform over any storage updates of user information
    event StakePositionUpdated(address indexed user, 
        uint256 lastUpdateTime,
        uint256 stakedBalance,
        uint256 maxStakeDebt,
        uint256 creditLine,                                 // creditLine = stakeSurplus + maxStakeDebt - stakeDebt
        uint256 availableToWithdraw);                       // principal available to withdraw


    // ============================================
    // ==           STAKING & UNSTAKING          ==
    // ============================================

    // Update user data to the current state. Only callable by the Vault
    function updateAccount(address _user, uint256 _amount) private {
        // Calculate accrued creditLine since last update
        uint256 creditEarned = (accounts[_user].stakedBalance * 
            (block.timestamp - accounts[_user].lastUpdateTime)) / secondsPerYear;
      
        // Update the Last Update Time Stamp
        accounts[_user].lastUpdateTime = block.timestamp;

        // Update user staked balance
        accounts[_user].stakedBalance += _amount;

        // Update user maxStakeDebt
        accounts[_user].maxStakeDebt += (_amount * maxLockDuration) / secondsPerYear;

        // update user creditLine
        accounts[_user].creditLine += creditEarned;

        // Update amount available to unstake
        if (accounts[_user].creditLine >= accounts[_user].maxStakeDebt) {
            accounts[_user].availableToWithdraw = accounts[_user].stakedBalance;
        } else {
            accounts[_user].availableToWithdraw = (accounts[_user].stakedBalance * accounts[_user].creditLine) / accounts[_user].maxStakeDebt;
        }
    }


    // User stake the strategy´s principal token into the contract & redirect principal to yield source
    function stake(uint256 _amount) external nonReentrant {
        // Check if Portal has closed the funding phase and is active
        require(isActivePortal);
        
        // Transfer user principal tokens to the contract
        IERC20(principalToken).safeTransferFrom(msg.sender, address(this), _amount);
        
        // Update total stake balance
        totalPrincipalStaked += _amount;

        // Call function to deposit principal into yield source
        depositToYieldSource(_amount);

        // Check if user has a staking position, else initialize with this stake.
        if(accounts[msg.sender].isExist == true){
            // update the user´s stake info
            updateAccount(msg.sender, _amount);
        } 
        else {
            uint256 maxStakeDebt = (_amount * maxLockDuration) / secondsPerYear;
            uint256 availableToWithdraw = _amount;
            uint256 creditLine = maxStakeDebt;
            
            accounts[msg.sender] = Account(true, 
                block.timestamp, 
                _amount, 
                maxStakeDebt, 
                creditLine,
                availableToWithdraw);     
        }
        
        // Emit event with updated stake information
        emit StakePositionUpdated(msg.sender, 
        accounts[msg.sender].lastUpdateTime,
        accounts[msg.sender].stakedBalance,
        accounts[msg.sender].maxStakeDebt, 
        accounts[msg.sender].creditLine, 
        accounts[msg.sender].availableToWithdraw);
    }


    // Serves unstaking requests
    function unstake(uint256 _amount) external nonReentrant {
        // Check if user has a stake and update user stake data
        require(accounts[msg.sender].isExist == true,"User has no stake");
        updateAccount(msg.sender,0);

        // Check if amount can be unstaked
        require(_amount <= accounts[msg.sender].availableToWithdraw, "Insufficient withdrawable balance");
        require(_amount <= accounts[msg.sender].stakedBalance, "Insufficient stake balance");

        // Withdraw matching amount of principal from yield source to pay user
        withdrawFromYieldSource(_amount);

        // Update user stake balance
        accounts[msg.sender].stakedBalance -= _amount;

        // Update user maximum stake debt
        accounts[msg.sender].maxStakeDebt -= (_amount * maxLockDuration) / secondsPerYear;

        // Update user withdrawable balance
        accounts[msg.sender].availableToWithdraw -= _amount;

        // update the global tracker of staked principal
        totalPrincipalStaked -= _amount;

        // Send principal tokens to user
        IERC20(principalToken).safeTransfer(msg.sender, _amount);

        // Emit event with updated stake information
        emit StakePositionUpdated(msg.sender, 
        accounts[msg.sender].lastUpdateTime,
        accounts[msg.sender].stakedBalance,
        accounts[msg.sender].maxStakeDebt, 
        accounts[msg.sender].creditLine,
        accounts[msg.sender].availableToWithdraw);
    }


    // Force unstaking via burning PortalEnergy from user wallet to decrease debt sufficiently to unstake all
    function forceUnstakeAll() external nonReentrant {
        // Check if user has a stake and update user stake data
        require(accounts[msg.sender].isExist == true,"User has no stake");
        updateAccount(msg.sender,0);

        // Calculate how much PortalEnergy must be burned from user wallet, if any
        if(accounts[msg.sender].creditLine < accounts[msg.sender].maxStakeDebt) {

            uint256 remainingDebt = accounts[msg.sender].maxStakeDebt - accounts[msg.sender].creditLine;

            // burn appropriate PortalEnergy from user wallet to increase creditLine sufficiently
            require(IERC20(portalEnergyAddress).balanceOf(address(msg.sender)) >= remainingDebt, "Not enough Portal Energy");
            priv_burnPortalEnergy(msg.sender, remainingDebt);
        }

        // Withdraw principal from yield source to pay user
        uint256 balance = accounts[msg.sender].stakedBalance;
        withdrawFromYieldSource(balance);

        // Update user information
        accounts[msg.sender].stakedBalance = 0;
        accounts[msg.sender].maxStakeDebt = 0;
        accounts[msg.sender].creditLine -= (balance * maxLockDuration) / secondsPerYear;        // There can be a positive remainder
        accounts[msg.sender].availableToWithdraw = 0;

        // Send full stake balance to user
        IERC20(principalToken).safeTransferFrom(msg.sender, address(this), balance);
        totalPrincipalStaked -= balance;

        // Emit event with updated stake information
        emit StakePositionUpdated(msg.sender, 
        accounts[msg.sender].lastUpdateTime,
        accounts[msg.sender].stakedBalance,
        accounts[msg.sender].maxStakeDebt, 
        accounts[msg.sender].creditLine,
        accounts[msg.sender].availableToWithdraw);
    }

    // ============================================
    // ==           PRINCIPAL MANAGEMENT         ==
    // ============================================

    // Deposit principal into yield source
    function depositToYieldSource(uint256 _amount) private {

    }


    // Withdraw principal from yield source
    function withdrawFromYieldSource(uint256 _amount) private {

    }


    // Claim yield from yield source to contract and send a split to protocol converter
    function claimYield() public {

        // call read function to get pending yield
        uint256 claimableYield = getClaimableYield();

        // claim the yield from yield source to contract
        IERC20(principalToken).safeTransferFrom(yieldSourceAddress, address(this), claimableYield);

    }


    // ============================================
    // ==               INTERNAL LP              ==
    // ============================================

    // Sell PSM into contract to top up creditLine balance of recipient
    function buyCreditLine(uint256 _amountInput, uint256 _minReceived) external nonReentrant {
        // Check if user has a stake and update stake data
        require(accounts[msg.sender].isExist == true,"User has no stake");
        updateAccount(msg.sender,0);

        // Check if user has enough input tokens
        require(IERC20(tokenToAcquire).balanceOf(msg.sender) >= _amountInput, "Insufficient balance");
        
        // Update inputToken reserve
        reserve0 = IERC20(tokenToAcquire).balanceOf(address(this)) - fundingRewardPool;

        // Calculate reserve of creditLine (Output)
        reserve1 = constantProduct / reserve0;

        // Calculate amount of creditLine received
        uint256 amountReceived = (_amountInput * reserve1) / (_amountInput + reserve0);

        // Check if amount at least matches expected output
        require(amountReceived >= _minReceived, "Output too small");

        // transfer input tokens from user to contract
        IERC20(tokenToAcquire).safeTransferFrom(msg.sender, address(this), _amountInput);

        // Increase creditLine of user
        accounts[msg.sender].creditLine += amountReceived;

        // emit event that swap was successful
        emit CreditLineBuyExecuted(msg.sender, amountReceived);
    }


    function sellCreditLine(uint256 _amountInput, uint256 _minReceived) external nonReentrant {
        // Check if user has a stake and update stake data
        require(accounts[msg.sender].isExist == true,"User has no stake");
        updateAccount(msg.sender,0);
        
        // Check if user has enough creditLine to sell
        require(accounts[msg.sender].creditLine >= _amountInput, "Insufficient balance");

        // Update outputToken reserve
        reserve0 = IERC20(tokenToAcquire).balanceOf(address(this)) - fundingRewardPool;

        // Calculate reserve of creditLine (Input)
        reserve1 = constantProduct / reserve0;

        // Calculate amount of outputToken received
        uint256 amountReceived = (_amountInput * reserve0) / (_amountInput + reserve1);

        // Check if amount at least matches expected output
        require(amountReceived >= _minReceived, "Output too small");

        // reduce creditLine balance of user
        accounts[msg.sender].creditLine -= _amountInput;

        // send outputToken to user
        IERC20(tokenToAcquire).safeTransfer(msg.sender, amountReceived);

        // emit event that swap was successful
        emit CreditLineSellExecuted(msg.sender, _amountInput);
 
    }


    // ============================================
    // ==              PSM CONVERTER             ==
    // ============================================

    // handle the arbitrage conversion of tokens inside the contract for LP tokens
    function convert(address _token, uint256 _minReceived) external nonReentrant {

        // Check that the output token is not the input token (PSM)
        require(_token != tokenToAcquire, "Cannot receive the input token");

        // Check if sufficient output token is available in the contract (frontrun protection)
        uint256 contractBalance = IERC20(_token).balanceOf(address(this));
        require (contractBalance >= _minReceived, "Not enough tokens in contract");

        // Transfer input (PSM) token from user to contract
        IERC20(tokenToAcquire).safeTransferFrom(msg.sender, address(this), amountToConvert); 

        // update funding reward pool balance
        fundingRewardPool += (fundingRewardShare * amountToConvert) / 100;

        // update reserve0 (PSM) to keep internal exchange price accurate
        reserve0 = IERC20(tokenToAcquire).balanceOf(address(this)) - fundingRewardPool;

        // Transfer output token from contract to user
        IERC20(_token).safeTransfer(msg.sender, contractBalance);
    }




    // ============================================
    // ==              BOOTSTRAPPING             ==
    // ============================================
    
    // Allow users to deposit PSM to provide initial upfront yield
    //@dev: Contract MUST BE OWNER of the eToken to work
    function contributeFunding(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Invalid amount");
        require(isActivePortal == false,"Funding phase concluded");

        // increase the funding tracker balance
        fundingBalance += _amount;

        // transer PSM to Contract
        IERC20(tokenToAcquire).safeTransferFrom(msg.sender, address(this), _amount); 

        // mint eToken to user
        eToken(eTokenAddress).mint(msg.sender, _amount);

        // emit event that funding was received
        emit FundingReceived(msg.sender, _amount);
    }


    // Calculate the current burn value of amount eTokens. Return value is amount PSM tokens
    function getBurnValuePsm(uint256 _amount) public view returns(uint256 burnValue) {
        burnValue = (fundingRewardPool * _amount) / IERC20(eTokenAddress).totalSupply();
        return burnValue;
    }


    // Burn user eTokens to receive PSM
    function burnEtokens(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Invalid amount");
        require(isActivePortal = true, "Portal not active");

        // calculate how many PSM user receives
        uint256 amountToReceive = getBurnValuePsm(_amount);

        // burn eTokens from user
        eToken(eTokenAddress).burnFrom(msg.sender, _amount);

        // reduce funding reward pool by amount of PSM payable to user
        fundingRewardPool -= amountToReceive;

        // transfer PSM to user
        IERC20(tokenToAcquire).safeTransfer(msg.sender, amountToReceive);
    }


    // End the funding phase and enable normal contract functionality
    function activatePortal() external {
        require(isActivePortal = false, "Portal already active");
        require(block.timestamp >= creationTime + fundingPhaseDuration,"Funding phase ongoing");
        require(fundingBalance > minimumFundingAmount,"Insufficient funding to activate");

        // calculate the amount of creditLine to match the funding amount in internal LP
        uint256 requiredCreditLiquidity = fundingBalance * fundingExchangeRatio;
        
        // set the constant product K
        constantProduct = fundingBalance * requiredCreditLiquidity;

        // activate the Portal and emit event
        isActivePortal = true;
        emit PortalActivated(address(this), fundingBalance);
    }


    // ============================================
    // ==           GENERAL FUNCTIONS            ==
    // ============================================
    
    // Mint portal energy tokens to recipient and decrease creditLine of caller equally
    function storePortalEnergy(address _recipient, uint256 _amount) external nonReentrant {   
        // Check if caller has sufficient creditLine
        require(accounts[msg.sender].creditLine >= _amount, "Insufficient credit line");

        // decrease the creditLine of caller
        accounts[msg.sender].creditLine -= _amount;

        // mint tokens to recipient wallet
        PortalEnergy(portalEnergyAddress).mint(_recipient, _amount);
    }


    // Mint portal energy tokens to user and decrease creditLine of user equally
    function priv_storePortalEnergy(address _user, uint256 _amount) private nonReentrant {   
        // Check if user has sufficient creditLine
        require(accounts[_user].creditLine >= _amount, "Insufficient credit line");

        // decrease the creditLine of user
        accounts[_user].creditLine -= _amount;

        // mint tokens to user wallet
        PortalEnergy(portalEnergyAddress).mint(_user, _amount);
    }


    // Burn portal energy tokens from user wallet and increase creditLine of recipient equally
    function burnPortalEnergy(address _recipient, uint256 _amount) external nonReentrant {   
        // Check if recipient has a stake position
        require(accounts[_recipient].isExist == true);

        // burn tokens from caller wallet
        PortalEnergy(portalEnergyAddress).burnFrom(msg.sender, _amount);

        // increase the creditLine of recipient
        accounts[_recipient].creditLine += _amount;
    }


    // Burn portal energy tokens from user wallet and increase creditLine of user equally
    function priv_burnPortalEnergy(address _user, uint256 _amount) private nonReentrant {   
        // Check if user has a stake position
        require(accounts[_user].isExist == true);

        // burn tokens from caller wallet
        PortalEnergy(portalEnergyAddress).burnFrom(_user, _amount);

        // increase the creditLine of user
        accounts[_user].creditLine += _amount;
    }


    // updates the maximum lock duration up to the terminal value
    function updateMaxLockDuration() external {
        require(lockDurationUpdateable == true,"Lock duration cannot increase");

        uint256 newValue = block.timestamp - creationTime;

        if (newValue >= terminalMaxLockDuration) {
            maxLockDuration = terminalMaxLockDuration;
            lockDurationUpdateable = false;
        } 
        else if (newValue > maxLockDuration) {
            maxLockDuration = newValue;
        }
    }


    // Simulates updating a user stake position and returns the values without updating the struct
    function getUpdateAccount(address _user, uint256 _amount) public view returns(
        address user,
        uint256 lastUpdateTime,
        uint256 stakedBalance,
        uint256 maxStakeDebt,
        uint256 creditLine,
        uint256 availableToWithdraw) {

        // Calculate accrued creditLine since last update
        uint256 creditEarned = (accounts[_user].stakedBalance * 
            (block.timestamp - accounts[_user].lastUpdateTime)) / secondsPerYear;
      
        // Get the current Time Stamp
        lastUpdateTime = block.timestamp;

        // calculate user staked balance
        stakedBalance = accounts[_user].stakedBalance + _amount;

        // Update user maxStakeDebt
        maxStakeDebt = accounts[_user].maxStakeDebt + (_amount * maxLockDuration) / secondsPerYear;

        // update user creditLine
        creditLine = accounts[_user].creditLine + creditEarned;

        // Update amount available to unstake
        if (creditLine >= maxStakeDebt) {
            availableToWithdraw = stakedBalance;
        } else {
            availableToWithdraw = (stakedBalance * creditLine) / maxStakeDebt;
        }

    return (_user, lastUpdateTime, stakedBalance, maxStakeDebt, creditLine, availableToWithdraw);
    }


    // Simulates forced unstake and returns the number of portal energy tokens to be burned      
    function quoteforceUnstakeAll(address _user) public view returns(uint256 portalEnergyToBurn) {

        // get relevant data from simulated account update
        (, , , uint256 maxStakeDebt, uint256 creditLine,) = getUpdateAccount(_user,0);

        // Calculate how many portal energy tokens must be burned
        if(maxStakeDebt > creditLine) {
            portalEnergyToBurn = maxStakeDebt - creditLine;
        }

        // return amount of portal energy to be burned for full unstake
        return portalEnergyToBurn; 
    }


    // View balances of tokens inside the contract
    function getBalanceOfToken(address _token) public view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }


    // view claimable, pending yield from yield source
    function getClaimableYield() public pure returns(uint256) {

        uint256 claimableYield;

        return claimableYield;
    }
}