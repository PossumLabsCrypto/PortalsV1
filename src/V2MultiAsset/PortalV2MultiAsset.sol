// SPDX-License-Identifier: GPL-2.0-only
pragma solidity =0.8.19;

import {MintBurnToken} from "./MintBurnToken.sol";
import {PortalNFT} from "./PortalNFT.sol";
import {IVirtualLP} from "./interfaces/IVirtualLP.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IWETH {
    function deposit() external payable;

    function withdraw(uint256) external;
}

// ============================================
// ==              CUSTOM ERRORS             ==
// ============================================
error InsufficientReceived();
error InvalidAddress();
error InvalidAmount();
error DeadlineExpired();
error InvalidConstructor();
error PortalNotActive();
error PortalAlreadyActive();
error DurationBelowCurrent();
error NativeTokenNotAllowed();
error TokenExists();
error EmptyAccount();
error TimeLockActive();
error FailedToSendNativeToken();
error NoProfit();
error InsufficientBalance();
error DurationLocked();
error InsufficientToWithdraw();
error InsufficientStakeBalance();

/// @title Portal Contract V2 with shared Virtual LP
/// @author Possum Labs
/** @notice This contract accepts user deposits and withdrawals of a specific token
 * The deposits are redirected to an external protocol to generate yield
 * Yield is claimed and collected with this contract
 * Users accrue portalEnergy points over time while staking their tokens
 * portalEnergy can be exchanged against the PSM token using the internal Liquidity Pool or minted as ERC20
 * PortalEnergy Tokens can be burned to increase a recipient´s internal portalEnergy balance
 * Users can buy more portalEnergy via the internal LP by spending PSM
 * The contract can receive PSM tokens during the funding phase and issues bTokens as receipt
 * bTokens received during the funding phase are used to initialize the internal LP
 * bTokens can be redeemed against the fundingRewardPool which consists of PSM tokens
 * The fundingRewardPool is filled over time by taking a 10% cut from the Converter
 * The Converter is an arbitrage mechanism that allows anyone to sweep the contract balance of a token
 * When triggering the Converter, the caller (arbitrager) must send a fixed amount of PSM tokens to the contract
 */
contract PortalV2MultiAsset is ReentrancyGuard {
    constructor(
        address _VIRTUAL_LP,
        uint256 _TARGET_CONSTANT,
        address _PRINCIPAL_TOKEN_ADDRESS,
        uint256 _DECIMALS,
        string memory _META_DATA_URI
    ) {
        if (_VIRTUAL_LP == address(0)) {
            revert InvalidConstructor();
        }
        if (_TARGET_CONSTANT < 1e25) {
            revert InvalidConstructor();
        }

        if (_TARGET_CONSTANT == 0) {
            revert InvalidConstructor();
        }
        if (_DECIMALS == 0) {
            revert InvalidConstructor();
        }
        if (keccak256(bytes(_META_DATA_URI)) == keccak256(bytes(""))) {
            revert InvalidConstructor();
        }

        VIRTUAL_LP = _VIRTUAL_LP;
        TARGET_CONSTANT = _TARGET_CONSTANT;
        PRINCIPAL_TOKEN_ADDRESS = _PRINCIPAL_TOKEN_ADDRESS;
        DECIMALS_ADJUSTMENT = 10 ** _DECIMALS;
        CREATION_TIME = block.timestamp;
        NFT_META_DATA = _META_DATA_URI;
        virtualLP = IVirtualLP(VIRTUAL_LP);
    }

    // ============================================
    // ==            GLOBAL VARIABLES            ==
    // ============================================
    using SafeERC20 for IERC20;

    // general
    address constant WETH_ADDRESS = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant PSM_ADDRESS = 0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5; // address of PSM token
    uint256 constant TERMINAL_MAX_LOCK_DURATION = 157680000; // terminal maximum lock duration of a user´s stake in seconds (5y)
    uint256 constant SECONDS_PER_YEAR = 31536000; // seconds in a 365 day year

    MintBurnToken public portalEnergyToken; // the ERC20 representation of portalEnergy
    PortalNFT public portalNFT; // The NFT contract deployed by the Portal that can store accounts
    bool public portalEnergyTokenCreated; // flag for PE token deployment
    bool public portalNFTcreated; // flag for Portal NFT contract deployment

    uint256 public immutable CREATION_TIME; // time stamp of deployment
    string public NFT_META_DATA; // IPFS uri for Portal Position NFTs metadata
    uint256 public maxLockDuration = 7776000; // starting value for maximum allowed lock duration of user´s balance in seconds (90 days)
    uint256 public totalPrincipalStaked; // returns how much principal is staked by all users combined
    bool private lockDurationUpdateable = true; // flag to signal if the lock duration can still be updated

    // principal management related - External Integration
    address public immutable PRINCIPAL_TOKEN_ADDRESS; // address of the token accepted by the strategy as deposit
    uint256 public immutable DECIMALS_ADJUSTMENT; // scaling factor to account for the decimals of the principal token

    // bootstrapping related
    IVirtualLP public virtualLP;
    uint256 private immutable TARGET_CONSTANT; // The constantProduct with which the Portal will be activated
    bool public isActivePortal; // Will be set to true when funding phase ends

    // exchange related
    uint256 public constantProduct; // the K constant of the (x*y = K) constant product formula
    address public immutable VIRTUAL_LP; // Address of the collective, virtual LP
    uint256 constant LP_PROTECTION_HURDLE = 1; // percent reduction of output amount when minting or buying PE

    // staking related
    // contains information of user stake position
    struct Account {
        uint256 lastUpdateTime;
        uint256 lastMaxLockDuration;
        uint256 stakedBalance;
        uint256 maxStakeDebt;
        uint256 portalEnergy;
    }
    mapping(address => Account) public accounts; // Associate users with their stake position

    // ============================================
    // ==                EVENTS                  ==
    // ============================================
    // --- Events related to the funding phase ---
    event PortalEnergyTokenDeployed(address PortalEnergyToken);
    event PortalNFTdeployed(address PortalNFTcontract);
    event PortalActivated(address indexed, uint256 fundingBalance);

    // --- Events related to internal exchange PSM vs. portalEnergy ---
    event PortalEnergyBuyExecuted(
        address indexed caller,
        address indexed recipient,
        uint256 amount
    );
    event PortalEnergySellExecuted(
        address indexed caller,
        address indexed recipient,
        uint256 amount
    );

    // --- Events related to minting and burning portalEnergyToken & NFTs ---
    event PortalEnergyMinted(
        address indexed,
        address recipient,
        uint256 amount
    );
    event PortalEnergyBurned(
        address indexed caller,
        address recipient,
        uint256 amount
    );

    event PortalNFTminted(
        address indexed caller,
        address indexed recipient,
        uint256 nftID
    );

    event PortalNFTredeemed(
        address indexed caller,
        address indexed recipient,
        uint256 nftID
    );

    // --- Events related to staking & unstaking ---
    event PrincipalStaked(address indexed user, uint256 amountStaked);
    event PrincipalUnstaked(address indexed user, uint256 amountUnstaked);
    event RewardsClaimed(
        address[] indexed pools,
        address[][] rewarders,
        uint256 timeStamp
    );

    event StakePositionUpdated(
        address indexed user,
        uint256 lastUpdateTime,
        uint256 lastMaxLockDuration,
        uint256 stakedBalance,
        uint256 maxStakeDebt,
        uint256 portalEnergy
    );

    event MaxLockDurationUpdated(uint256 newDuration);

    // ============================================
    // ==               MODIFIERS                ==
    // ============================================
    modifier activePortalCheck() {
        if (!isActivePortal) {
            revert PortalNotActive();
        }
        _;
    }

    modifier nonActivePortalCheck() {
        if (isActivePortal) {
            revert PortalAlreadyActive();
        }
        _;
    }

    // ============================================
    // ==           STAKING & UNSTAKING          ==
    // ============================================
    /// @notice Simulate updating a user stake position and return the values without updating the struct
    /// @dev Returns the simulated up-to-date user stake information
    /// @param _user The user whose stake position is to be updated
    /// @param _amount The amount to add or subtract from the user's stake position
    /// @param _isPositiveAmount True for staking (add), false for unstaking (subtract)
    function getUpdateAccount(
        address _user,
        uint256 _amount,
        bool _isPositiveAmount
    )
        public
        view
        activePortalCheck
        returns (
            address user,
            uint256 lastUpdateTime,
            uint256 lastMaxLockDuration,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,
            uint256 availableToWithdraw
        )
    {
        /// @dev Load user account into memory
        PortalV2MultiAsset.Account memory account = PortalV2MultiAsset.accounts[
            _user
        ];

        /// @dev initialize helper variables
        uint256 portalEnergyEarned;
        uint256 portalEnergyIncrease;
        uint256 portalEnergyNetChange;
        uint256 portalEnergyAdjustment;

        /// @dev Check the user account state based on lastUpdateTime
        /// @dev If this variable is 0, the user never staked and could not earn PE
        if (account.lastUpdateTime != 0) {
            /// @dev Calculate the Portal Energy earned since the last update
            portalEnergyEarned = (account.stakedBalance *
                (block.timestamp - account.lastUpdateTime) *
                1e18);

            /// @dev Calculate the gain of Portal Energy from maxLockDuration increase
            portalEnergyIncrease = (account.stakedBalance *
                (PortalV2MultiAsset.maxLockDuration -
                    account.lastMaxLockDuration) *
                1e18);

            /// @dev Summarize Portal Energy changes and divide by common denominator
            portalEnergyNetChange =
                (portalEnergyEarned + portalEnergyIncrease) /
                (SECONDS_PER_YEAR * PortalV2MultiAsset.DECIMALS_ADJUSTMENT);
        }

        /// @dev Calculate the adjustment of Portal Energy from balance change
        portalEnergyAdjustment =
            ((_amount * PortalV2MultiAsset.maxLockDuration) * 1e18) /
            (SECONDS_PER_YEAR * PortalV2MultiAsset.DECIMALS_ADJUSTMENT);

        /// @dev Check that user has enough Portal Energy for unstaking
        if (
            !_isPositiveAmount &&
            portalEnergyAdjustment >
            (account.portalEnergy + portalEnergyNetChange)
        ) {
            revert InsufficientToWithdraw();
        }

        /// @dev Check that the Stake Balance is sufficient for unstaking
        if (!_isPositiveAmount && _amount > account.stakedBalance) {
            revert InsufficientStakeBalance();
        }

        /// @dev Set the last update time to the current timestamp
        lastUpdateTime = block.timestamp;

        /// @dev Get the updated last maxLockDuration
        lastMaxLockDuration = PortalV2MultiAsset.maxLockDuration;

        /// @dev Calculate the user's staked balance and consider stake or unstake
        stakedBalance = _isPositiveAmount
            ? account.stakedBalance + _amount
            : account.stakedBalance - _amount;

        /// @dev Update the user's max stake debt
        maxStakeDebt =
            (stakedBalance * PortalV2MultiAsset.maxLockDuration * 1e18) /
            (SECONDS_PER_YEAR * PortalV2MultiAsset.DECIMALS_ADJUSTMENT);

        /// @dev Update the user's portalEnergy and account for stake or unstake
        portalEnergy = _isPositiveAmount
            ? account.portalEnergy +
                portalEnergyNetChange +
                portalEnergyAdjustment
            : account.portalEnergy +
                portalEnergyNetChange -
                portalEnergyAdjustment;

        /// @dev Update amount available to withdraw
        availableToWithdraw = portalEnergy >= maxStakeDebt
            ? stakedBalance
            : (stakedBalance * portalEnergy) / maxStakeDebt;

        /// @dev Set the user for the return values
        user = _user;
    }

    /// @notice Update user data to the current state
    /// @dev This function updates the user data to the current state
    /// @dev It takes memory inputs and stores them into the user account struct
    /// @param _user The user whose data is to be updated
    /// @param _stakedBalance The current Staked Balance of the user
    /// @param _maxStakeDebt The current maximum Stake Debt of the user
    /// @param _portalEnergy The current Portal Energy of the user
    function _updateAccount(
        address _user,
        uint256 _stakedBalance,
        uint256 _maxStakeDebt,
        uint256 _portalEnergy
    ) private {
        /// @dev Update the user´s account data
        Account storage account = accounts[_user];
        account.lastUpdateTime = block.timestamp;
        account.lastMaxLockDuration = maxLockDuration;
        account.stakedBalance = _stakedBalance;
        account.maxStakeDebt = _maxStakeDebt;
        account.portalEnergy = _portalEnergy;

        /// @dev Emit an event with the updated stake information
        emit StakePositionUpdated(
            _user,
            account.lastUpdateTime,
            account.lastMaxLockDuration,
            account.stakedBalance,
            account.maxStakeDebt,
            account.portalEnergy
        );
    }

    /// @notice Stake the principal token into the Portal & redirect principal to yield source
    /// @dev This function allows users to stake their principal tokens into the Portal
    /// @dev Can only be called if Portal is active
    /// @dev Update the user´s account
    /// @dev Update the global tracker of staked principal
    /// @dev Deposit the principal into the yield source (external protocol)
    /// @param _amount The amount of tokens to stake
    function stake(
        uint256 _amount
    ) external payable nonReentrant activePortalCheck {
        /// @dev Convert native ETH to WETH for contract
        /// @dev This section must sit before using _amount elsewhere to guarantee consistency
        if (PRINCIPAL_TOKEN_ADDRESS == address(0)) {
            // Wrap ETH into WETH
            _amount = msg.value;
            IWETH(WETH_ADDRESS).deposit{value: _amount}();
        }

        /// @dev If not native ETH, transfer ERC20 token to contract
        if (PRINCIPAL_TOKEN_ADDRESS != address(0)) {
            /// @dev Prevent contract from receiving ETH when principal is ERC20
            if (msg.value > 0) {
                revert NativeTokenNotAllowed();
            }

            /// @dev Transfer token from user to contract
            IERC20(PRINCIPAL_TOKEN_ADDRESS).safeTransferFrom(
                msg.sender,
                address(this),
                _amount
            );
        }

        /// @dev Revert if the staked amount is zero
        if (_amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Get the current state of the user stake
        (
            ,
            ,
            ,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,

        ) = getUpdateAccount(msg.sender, _amount, true);

        /// @dev Update the user stake struct
        _updateAccount(msg.sender, stakedBalance, maxStakeDebt, portalEnergy);

        /// @dev Update the total stake balance
        totalPrincipalStaked += _amount;

        /// @dev Deposit the principal into the yield source (external protocol)
        virtualLP.depositToYieldSource(PRINCIPAL_TOKEN_ADDRESS, _amount);

        /// @dev Emit event that the stake was successful
        emit PrincipalStaked(msg.sender, _amount);
    }

    /// @notice Serve unstaking requests & withdraw principal from yield source
    /// @dev This function allows users to unstake their tokens
    /// @dev Update the user´s account
    /// @dev Update the global tracker of staked principal
    /// @dev Withdraw the matching amount of principal from the yield source (external protocol)
    /// @dev Send the principal tokens to the user
    /// @param _amount The amount of tokens to unstake
    function unstake(uint256 _amount) external nonReentrant {
        /// @dev Check that the unstaked amount is greater than zero
        if (_amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Get the current state of the user stake
        /// @dev Throws if caller tries to unstake more than stake balance or with insufficient PE
        (
            ,
            ,
            ,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,

        ) = getUpdateAccount(msg.sender, _amount, false);

        /// @dev Update the user´s stake struct
        _updateAccount(msg.sender, stakedBalance, maxStakeDebt, portalEnergy);

        /// @dev Update the global tracker of staked principal
        totalPrincipalStaked -= _amount;

        /// @dev Withdraw the assets from external Protocol and send to user
        virtualLP.withdrawFromYieldSource(
            PRINCIPAL_TOKEN_ADDRESS,
            msg.sender,
            _amount
        );

        /// @dev Emit event that tokens have been unstaked
        emit PrincipalUnstaked(msg.sender, _amount);
    }

    /// @notice Force unstaking via burning portalEnergyToken from user wallet to decrease debt sufficiently
    /// @dev This function allows users to force unstake all of their tokens by burning portalEnergyToken from their wallet
    /// @dev Calculate how many portalEnergyToken must be burned from the user's wallet, if any
    /// @dev Burn the appropriate amount of portalEnergyToken from the user's wallet to increase portalEnergy
    /// @dev Update the user's stake data
    /// @dev Update the global tracker of staked principal
    /// @dev Withdraw the principal from the yield source (external protocol)
    /// @dev Send the retrieved stake balance to the user
    function forceUnstakeAll() external nonReentrant {
        /// @dev Get the current state of the user stake
        (
            ,
            ,
            uint256 lastMaxLockDuration,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,

        ) = getUpdateAccount(msg.sender, 0, false);

        /// @dev Calculate how many portalEnergyToken must be burned to unstake all
        if (portalEnergy < maxStakeDebt) {
            uint256 remainingDebt = maxStakeDebt - portalEnergy;

            /// @dev Burn portalEnergyToken from the caller to increase portalEnergy sufficiently
            /// @dev Throws if caller has not enough tokens or allowance is too low
            _burnPortalEnergyToken(msg.sender, remainingDebt);
        }

        /// @dev initialize helper variable
        uint256 oldStakedBalance = stakedBalance;

        /// @dev Calculate the new values of the user´s stake
        stakedBalance = 0;
        maxStakeDebt = 0;
        portalEnergy -=
            (oldStakedBalance * lastMaxLockDuration * 1e18) /
            (SECONDS_PER_YEAR * DECIMALS_ADJUSTMENT);

        /// @dev Update the user´s stake struct
        _updateAccount(msg.sender, stakedBalance, maxStakeDebt, portalEnergy);

        /// @dev Update the global tracker of staked principal
        totalPrincipalStaked -= oldStakedBalance;

        /// @dev Withdraw the principal from the yield source (external Protocol)
        virtualLP.withdrawFromYieldSource(
            PRINCIPAL_TOKEN_ADDRESS,
            msg.sender,
            oldStakedBalance
        );

        /// @dev Emit event that tokens have been unstaked
        emit PrincipalUnstaked(msg.sender, oldStakedBalance);
    }

    /// @notice Simulate forced unstake and return the number of portal energy tokens to be burned
    /// @dev Simulate forced unstake and return the number of portal energy tokens to be burned
    /// @param _user The user whose stake position is to be updated for the simulation
    /// @return portalEnergyTokenToBurn Returns the number of portal energy tokens to be burned for a full unstake
    function quoteforceUnstakeAll(
        address _user
    ) external view returns (uint256 portalEnergyTokenToBurn) {
        /// @dev Get the relevant data from the simulated account update
        (
            ,
            ,
            ,
            ,
            uint256 maxStakeDebt,
            uint256 portalEnergy,

        ) = getUpdateAccount(_user, 0, false);

        /// @dev Calculate how many Portal Energy Tokens must be burned for a full unstake
        portalEnergyTokenToBurn = maxStakeDebt > portalEnergy
            ? maxStakeDebt - portalEnergy
            : 0;
    }

    // ============================================
    // ==         NFT Position Management        ==
    // ============================================
    /// @notice This function deploys the NFT contract unique to this Portal
    /// @dev Deploy an NFT contract with name and symbol related to the principal token
    /// @dev Must be called before Portal is activated (implied condition)
    /// @dev Can only be called once
    function create_portalNFT() public {
        // Check if the NFT contract is already deployed
        if (portalNFTcreated) {
            revert TokenExists();
        }

        /// @dev Update the token creation flag to prevent future calls
        portalNFTcreated = true;

        /// @dev Build the NFT contract with name and symbol based on the principal token of this Portal
        string memory name = concatenate(
            "Portal-Position-",
            ERC20(PRINCIPAL_TOKEN_ADDRESS).name()
        );

        string memory symbol = concatenate(
            "P-",
            ERC20(PRINCIPAL_TOKEN_ADDRESS).symbol()
        );

        /// @dev Deploy the token and update the related storage variable so that other functions can work
        portalNFT = new PortalNFT(
            DECIMALS_ADJUSTMENT,
            name,
            symbol,
            NFT_META_DATA
        );

        /// @dev Emit event that the NFT contract was deployed
        emit PortalNFTdeployed(address(portalNFT));
    }

    /// @notice This function allows users to store their Account in a transferrable NFT
    /// @dev Mint a Portal NFT with the vital information of caller account to a recipient
    /// @dev Delete the caller account
    function mintNFTposition(address _recipient) public {
        /// @dev Check that the recipient is a valid address
        if (_recipient == address(0)) {
            revert InvalidAddress();
        }

        /// @dev Get the current state of the user stake
        (
            ,
            ,
            ,
            uint256 stakedBalance,
            ,
            uint256 portalEnergy,

        ) = getUpdateAccount(msg.sender, 0, false);

        // check that caller has an account with PE or staked balance > 0
        if (portalEnergy == 0 && stakedBalance == 0) {
            revert EmptyAccount();
        }
        /// @dev delete the caller account
        delete accounts[msg.sender];

        /// @dev mint NFT to recipient containing the account information, get the returned ID
        uint256 nftID = portalNFT.mint(_recipient, stakedBalance, portalEnergy);

        /// @dev Emit event that the NFT was minted
        emit PortalNFTminted(msg.sender, _recipient, nftID);
    }

    /// @notice This function allows users to redeem their PortalNFT for its content
    /// @dev Update the user account to current state. Required because stake balance can change.
    /// @dev Burn the NFT and retrieve its balances (stake balance & portalEnergy)
    /// @dev Add the NFT values to the account of the user
    function redeemNFTposition(uint256 _tokenId) public {
        /// @dev Get the current state of the user Account
        (
            ,
            ,
            ,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,

        ) = getUpdateAccount(msg.sender, 0, true);

        /// @dev Redeem the NFT and get the returned paramters
        (uint256 stakedBalanceNFT, uint256 portalEnergyNFT) = portalNFT.redeem(
            msg.sender,
            _tokenId
        );

        /// @dev Update user Account
        stakedBalance += stakedBalanceNFT;
        portalEnergy += portalEnergyNFT;
        _updateAccount(msg.sender, stakedBalance, maxStakeDebt, portalEnergy);

        /// @dev Emit event that the Portal NFT was redeemed
        emit PortalNFTredeemed(msg.sender, msg.sender, _tokenId);
    }

    // ============================================
    // ==               VIRTUAL LP               ==
    // ============================================
    /// @notice Users sell PSM into the Portal to top up portalEnergy balance of a recipient
    /// @dev This function allows users to sell PSM tokens to the contract to increase a recipient´s portalEnergy
    /// @dev Can only be called if the Portal is active (implied condition)
    /// @dev Get the correct price from the quote function
    /// @dev Increase the portalEnergy of the recipient by the amount of portalEnergy received
    /// @dev Transfer the PSM tokens from the caller to the contract
    /// @param _recipient The recipient of the Portal Energy credit
    /// @param _amountInput The amount of PSM tokens to sell
    /// @param _minReceived The minimum amount of portalEnergy to receive
    /// @param _deadline The unix timestamp that marks the deadline for order execution
    function buyPortalEnergy(
        address _recipient,
        uint256 _amountInput,
        uint256 _minReceived,
        uint256 _deadline
    ) external nonReentrant {
        /// @dev Check that the input amount & minimum received is greater than zero
        if (_amountInput == 0 || _minReceived == 0) {
            revert InvalidAmount();
        }

        /// @dev Check that the recipient is a valid address
        if (_recipient == address(0)) {
            revert InvalidAddress();
        }

        /// @dev Check that the deadline has not expired
        if (_deadline < block.timestamp) {
            revert DeadlineExpired();
        }

        /// @dev Get the amount of portalEnergy received based on the amount of PSM tokens sold
        uint256 amountReceived = quoteBuyPortalEnergy(_amountInput);

        /// @dev Check that the amount of portalEnergy received is greater than or equal to the minimum expected output
        if (amountReceived < _minReceived) {
            revert InsufficientReceived();
        }

        /// @dev Increase the portalEnergy of the recipient by the amount of portalEnergy received
        accounts[_recipient].portalEnergy += amountReceived;

        /// @dev Transfer the PSM tokens from the caller to the Virtual LP
        IERC20(PSM_ADDRESS).transferFrom(msg.sender, VIRTUAL_LP, _amountInput);

        /// @dev Emit the portalEnergyBuyExecuted event
        emit PortalEnergyBuyExecuted(msg.sender, _recipient, amountReceived);
    }

    /// @notice Users sell portalEnergy into the Portal to receive PSM to a recipient address
    /// @dev This function allows users to sell portalEnergy to the contract to increase a recipient´s PSM
    /// @dev Can only be called if the Portal is active (implied condition via quote function)
    /// @dev Get the output amount from the quote function
    /// @dev Reduce the portalEnergy balance of the caller by the amount of portalEnergy sold
    /// @dev Send PSM to the recipient
    /// @param _amountInput The amount of portalEnergy to sell
    /// @param _minReceived The minimum amount of PSM tokens to receive
    function sellPortalEnergy(
        address _recipient,
        uint256 _amountInput,
        uint256 _minReceived,
        uint256 _deadline
    ) external nonReentrant {
        /// @dev Check that the input amount & minimum received is greater than zero
        if (_amountInput == 0 || _minReceived == 0) {
            revert InvalidAmount();
        }

        /// @dev Check that the recipient is a valid address
        if (_recipient == address(0)) {
            revert InvalidAddress();
        }

        /// @dev Check that the deadline has not expired
        if (_deadline < block.timestamp) {
            revert DeadlineExpired();
        }

        /// @dev Get the current state of user stake
        (
            address user,
            ,
            ,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,

        ) = getUpdateAccount(msg.sender, 0, true);

        /// @dev Require that the user has enough portalEnergy to sell
        if (portalEnergy < _amountInput) {
            revert InsufficientBalance();
        }

        /// @dev Calculate the amount of output token received based on the amount of portalEnergy sold
        uint256 amountReceived = quoteSellPortalEnergy(_amountInput);

        /// @dev Check that the amount of output token received is greater than or equal to the minimum expected output
        if (amountReceived < _minReceived) {
            revert InsufficientReceived();
        }

        /// @dev Calculate the user post-trade Portal Energy balance
        portalEnergy -= _amountInput;

        /// @dev Update the user stake struct
        _updateAccount(user, stakedBalance, maxStakeDebt, portalEnergy);

        /// @dev Instruct the Virtual LP to send PSM directly to the recipient
        virtualLP.PSM_sendToPortalUser(_recipient, amountReceived);

        /// @dev Emit the portalEnergySellExecuted event
        emit PortalEnergySellExecuted(msg.sender, _recipient, _amountInput);
    }

    /// @notice Simulate buying portalEnergy (output) with PSM tokens (input) and return amount received (output)
    /// @dev This function allows the caller to simulate a portalEnergy buy order of any size
    /// @dev Can only be called if the Portal is active
    /// @dev Update the token reserves to get the exchange price
    /// @return amountReceived The amount of portalEnergy received by the recipient
    function quoteBuyPortalEnergy(
        uint256 _amountInput
    ) public view activePortalCheck returns (uint256 amountReceived) {
        /// @dev Calculate the PSM token reserve (input)
        uint256 reserve0 = IERC20(PSM_ADDRESS).balanceOf(
            PortalV2MultiAsset.VIRTUAL_LP
        );

        /// @dev Calculate the reserve of portalEnergy (output)
        uint256 reserve1 = PortalV2MultiAsset.constantProduct / reserve0;

        /// @dev Reduce amount by the LP Protection Hurdle to prevent sandwich attacks
        _amountInput = (_amountInput * (1 - LP_PROTECTION_HURDLE)) / 100;

        /// @dev Calculate the amount of portalEnergy received based on the amount of PSM tokens sold
        amountReceived = (_amountInput * reserve1) / (_amountInput + reserve0);
    }

    /// @notice Simulate selling portalEnergy (input) against PSM tokens (output) and return amount received (output)
    /// @dev This function allows the caller to simulate a portalEnergy sell order of any size
    /// @dev Can only be called if the Portal is active
    /// @dev Update the token reserves to get the exchange price
    /// @return amountReceived The amount of PSM tokens received by the recipient
    function quoteSellPortalEnergy(
        uint256 _amountInput
    ) public view activePortalCheck returns (uint256 amountReceived) {
        /// @dev Calculate the PSM token reserve (output)
        uint256 reserve0 = IERC20(PSM_ADDRESS).balanceOf(
            PortalV2MultiAsset.VIRTUAL_LP
        );

        /// @dev Calculate the reserve of portalEnergy (input)
        /// @dev Avoid zero value to prevent theoretical drainer attack by donating PSM before selling 1 PE
        uint256 reserve1 = (reserve0 > PortalV2MultiAsset.constantProduct)
            ? 1
            : PortalV2MultiAsset.constantProduct / reserve0;

        /// @dev Calculate the amount of PSM tokens received based on the amount of portalEnergy sold
        amountReceived = (_amountInput * reserve0) / (_amountInput + reserve1);
    }

    // ============================================
    // ==           GENERAL FUNCTIONS            ==
    // ============================================
    /// @notice Concatenates two strings and returns the result string
    /// @dev This is a helper function to concatenate two strings into one
    /// @dev Used for automatic token naming
    function concatenate(
        string memory a,
        string memory b
    ) internal pure returns (string memory) {
        return string(abi.encodePacked(a, b));
    }

    /// @notice Deploy the Portal Energy Token of this Portal
    /// @dev This function deploys the PortalEnergyToken of this Portal with the Portal as owner
    /// @dev Must be called before Portal is activated
    /// @dev Can only be called once
    function create_portalEnergyToken() external nonActivePortalCheck {
        if (portalEnergyTokenCreated) {
            revert TokenExists();
        }

        /// @dev Update the token creation flag to prevent future calls.
        portalEnergyTokenCreated = true;

        /// @dev Build the token name and symbol based on the principal token of this Portal.
        string memory name = concatenate(
            "PE-",
            ERC20(PRINCIPAL_TOKEN_ADDRESS).name()
        );

        string memory symbol = concatenate(
            "PE-",
            ERC20(PRINCIPAL_TOKEN_ADDRESS).symbol()
        );

        /// @dev Deploy the token and update the related storage variable so that other functions can work.
        portalEnergyToken = new MintBurnToken(name, symbol);

        emit PortalEnergyTokenDeployed(address(portalEnergyToken));
    }

    /// @notice Users can burn their PortalEnergyTokens to increase portalEnergy of a recipient
    /// @dev This function allows users to burn PortalEnergyTokens for internal portalEnergy
    /// @dev Burn PortalEnergyTokens of caller and increase portalEnergy of the recipient
    /// @param _recipient The recipient of the portalEnergy increase
    /// @param _amount The amount of portalEnergyToken to burn
    function burnPortalEnergyToken(
        address _recipient,
        uint256 _amount
    ) external {
        /// @dev Check for zero value inputs
        if (_amount == 0) {
            revert InvalidAmount();
        }
        if (_recipient == address(0)) {
            revert InvalidAddress();
        }

        /// @dev Increase the portalEnergy of the recipient by the amount of portalEnergyToken burned
        accounts[_recipient].portalEnergy += _amount;

        /// @dev Burn portalEnergyToken from the caller's wallet
        portalEnergyToken.burnFrom(msg.sender, _amount);

        /// @dev Emit the event that the ERC20 representation has been burned and value accrued to recipient
        emit PortalEnergyBurned(msg.sender, _recipient, _amount);
    }

    /// @notice Burn portalEnergyToken from user wallet and increase portalEnergy of user equally
    /// @dev This function is private and can only be called internally
    /// @param _user The address whose portalEnergy is to be increased
    /// @param _amount The amount of portalEnergyToken to burn
    function _burnPortalEnergyToken(address _user, uint256 _amount) private {
        /// @dev Increase the portalEnergy of the user by the amount of portalEnergyToken burned
        accounts[_user].portalEnergy += _amount;

        /// @dev Burn portalEnergyToken from the caller's wallet
        portalEnergyToken.burnFrom(_user, _amount);

        /// @dev Emit the event that the ERC20 representation has been burned and value accrued to recipient
        emit PortalEnergyBurned(_user, _user, _amount);
    }

    /// @notice Users can mint portalEnergyToken to a recipient address using their internal balance
    /// @dev This function controls the minting of PortalEnergyToken
    /// @dev Decrease portalEnergy of caller and mint PortalEnergyTokens to the recipient
    /// @dev Contract must be owner of the PortalEnergyToken
    /// @param _recipient The recipient of the portalEnergyToken
    /// @param _amount The amount of portalEnergyToken to mint
    function mintPortalEnergyToken(
        address _recipient,
        uint256 _amount
    ) external {
        /// @dev Check for zero value inputs
        if (_amount == 0) {
            revert InvalidAmount();
        }
        if (_recipient == address(0)) {
            revert InvalidAddress();
        }

        /// @dev Get the current state of the user stake
        (
            address user,
            ,
            ,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,

        ) = getUpdateAccount(msg.sender, 0, true);

        /// @dev Check that the caller has sufficient portalEnergy to mint the amount of portalEnergyToken
        if (portalEnergy < _amount) {
            revert InsufficientBalance();
        }

        /// @dev Reduce the portalEnergy of the caller by the amount of minted tokens
        portalEnergy -= _amount;

        /// @dev Update the user´s stake struct
        _updateAccount(user, stakedBalance, maxStakeDebt, portalEnergy);

        /// @dev Subtract the LP Protection Hurdle from the minted amount to prevent indirect sandwich attacks
        uint256 mintedAmount = (_amount * (100 - LP_PROTECTION_HURDLE)) / 100;

        /// @dev Mint portal energy tokens to the recipient's wallet
        portalEnergyToken.mint(_recipient, mintedAmount);

        /// @dev Emit the event that the ERC20 representation has been minted to recipient
        emit PortalEnergyMinted(address(msg.sender), _recipient, mintedAmount);
    }

    /// @notice Update the maximum lock duration up to the terminal value
    /// @dev Update the maximum lock duration up to the terminal value
    function updateMaxLockDuration() external {
        /// @dev Require that the lock duration can be updated
        if (lockDurationUpdateable == false) {
            revert DurationLocked();
        }

        /// @dev Calculate new lock duration
        uint256 newValue = 2 * (block.timestamp - CREATION_TIME);

        /// @dev Require that the new value will be larger than the existing value
        if (newValue <= maxLockDuration) {
            revert DurationBelowCurrent();
        }

        if (newValue >= TERMINAL_MAX_LOCK_DURATION) {
            maxLockDuration = TERMINAL_MAX_LOCK_DURATION;
            lockDurationUpdateable = false;
        } else if (newValue > maxLockDuration) {
            maxLockDuration = newValue;
        }

        emit MaxLockDurationUpdated(maxLockDuration);
    }

    receive() external payable {}

    fallback() external payable {}
}
