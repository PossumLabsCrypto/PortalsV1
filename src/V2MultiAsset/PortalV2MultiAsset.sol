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
}

// ============================================
// ==              CUSTOM ERRORS             ==
// ============================================
error DeadlineExpired();
error DurationLocked();
error DurationTooLow();
error EmptyAccount();
error InactiveLP();
error InsufficientBalance();
error InsufficientReceived();
error InsufficientStakeBalance();
error InvalidAddress();
error InvalidAmount();
error InvalidConstructor();
error NativeTokenNotAllowed();
error TokenExists();

/// @title Portal Contract V2 with shared Virtual LP
/// @author Possum Labs
/** @notice This contract accepts user deposits and withdrawals of a specific token
 * The deposits are redirected to an external protocol to generate yield
 * Yield is claimed and collected with this contract
 * Users accrue portalEnergy points over time while staking their tokens
 * portalEnergy can be exchanged against the PSM token using the internal Liquidity Pool or minted as ERC20
 * PortalEnergy Tokens can be burned to increase a recipient internal portalEnergy balance
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
        uint256 _CONSTANT_PRODUCT,
        address _PRINCIPAL_TOKEN_ADDRESS,
        uint256 _DECIMALS,
        string memory _PRINCIPAL_NAME,
        string memory _PRINCIPAL_SYMBOL,
        string memory _META_DATA_URI
    ) {
        if (_VIRTUAL_LP == address(0)) {
            revert InvalidConstructor();
        }
        if (_CONSTANT_PRODUCT < 1e25) {
            revert InvalidConstructor();
        }
        if (_DECIMALS == 0) {
            revert InvalidConstructor();
        }
        if (keccak256(bytes(_PRINCIPAL_NAME)) == keccak256(bytes(""))) {
            revert InvalidConstructor();
        }
        if (keccak256(bytes(_PRINCIPAL_SYMBOL)) == keccak256(bytes(""))) {
            revert InvalidConstructor();
        }
        if (keccak256(bytes(_META_DATA_URI)) == keccak256(bytes(""))) {
            revert InvalidConstructor();
        }

        VIRTUAL_LP = _VIRTUAL_LP;
        CONSTANT_PRODUCT = _CONSTANT_PRODUCT;
        PRINCIPAL_TOKEN_ADDRESS = _PRINCIPAL_TOKEN_ADDRESS;
        DECIMALS_ADJUSTMENT = 10 ** _DECIMALS;
        NFT_META_DATA = _META_DATA_URI;
        PRINCIPAL_NAME = _PRINCIPAL_NAME;
        PRINCIPAL_SYMBOL = _PRINCIPAL_SYMBOL;
        CREATION_TIME = block.timestamp;
        virtualLP = IVirtualLP(VIRTUAL_LP);
        DENOMINATOR = SECONDS_PER_YEAR * DECIMALS_ADJUSTMENT;
    }

    // ============================================
    // ==            GLOBAL VARIABLES            ==
    // ============================================
    using SafeERC20 for IERC20;

    // general
    address constant WETH_ADDRESS = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant PSM_ADDRESS = 0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5; // address of PSM token
    uint256 constant TERMINAL_MAX_LOCK_DURATION = 157680000; // terminal maximum lock duration of a user stake in seconds (5y)
    uint256 constant SECONDS_PER_YEAR = 31536000; // seconds in a 365 day year
    string PRINCIPAL_NAME; // Name of the staking token
    string PRINCIPAL_SYMBOL; // Symbol of the staking token

    uint256 public immutable CREATION_TIME; // time stamp of deployment
    uint256 public immutable DECIMALS_ADJUSTMENT; // scaling factor to account for the decimals of the principal token
    uint256 private immutable DENOMINATOR;

    MintBurnToken public portalEnergyToken; // the ERC20 representation of portalEnergy
    PortalNFT public portalNFT; // The NFT contract deployed by the Portal that can store accounts
    bool public portalEnergyTokenCreated; // flag for PE token deployment
    bool public portalNFTcreated; // flag for Portal NFT contract deployment

    address public immutable PRINCIPAL_TOKEN_ADDRESS; // address of the token accepted by the strategy as deposit
    string public NFT_META_DATA; // IPFS uri for Portal Position NFTs metadata
    uint256 public maxLockDuration = 7776000; // starting value for maximum allowed lock duration of user balance in seconds (90 days)
    uint256 public totalPrincipalStaked; // returns how much principal is staked by all users combined
    bool public lockDurationUpdateable = true; // flag to signal if the lock duration can still be updated

    // exchange related
    IVirtualLP private virtualLP;
    uint256 public immutable CONSTANT_PRODUCT; // The constantProduct with which the Portal will be activated
    address public immutable VIRTUAL_LP; // Address of the collective, virtual LP
    uint256 public constant LP_PROTECTION_HURDLE = 1; // percent reduction of output amount when minting or buying PE

    // staking related
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
        address indexed caller,
        address indexed recipient,
        uint256 amount
    );
    event PortalEnergyBurned(
        address indexed caller,
        address indexed recipient,
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

    event StakePositionUpdated(
        address indexed user,
        uint256 lastUpdateTime,
        uint256 lastMaxLockDuration,
        uint256 stakedBalance,
        uint256 maxStakeDebt,
        uint256 portalEnergy
    );

    // ============================================
    // ==               MODIFIERS                ==
    // ============================================
    modifier activeLP() {
        if (!virtualLP.isActiveLP()) {
            revert InactiveLP();
        }
        _;
    }

    // ============================================
    // ==           STAKING & UNSTAKING          ==
    // ============================================
    /// @notice Simulate updating a user stake position and return the values without updating the struct
    /// @dev Returns the simulated up-to-date user stake information
    /// @dev Considers changes from staking or unstaking including burning amount of PE tokens
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
        returns (
            uint256 lastUpdateTime,
            uint256 lastMaxLockDuration,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,
            uint256 availableToWithdraw,
            uint256 portalEnergyTokensRequired
        )
    {
        /// @dev Load user account into memory
        Account memory account = accounts[_user];

        /// @dev initialize helper variables
        uint256 amount = _amount; // to avoid stack too deep issue
        bool isPositive = _isPositiveAmount; // to avoid stack too deep issue
        uint256 portalEnergyNetChange;
        uint256 timePassed = block.timestamp - account.lastUpdateTime;
        uint256 maxLockDifference = maxLockDuration -
            account.lastMaxLockDuration;
        uint256 adjustedPE = amount * maxLockDuration * 1e18;
        stakedBalance = account.stakedBalance;

        /// @dev Check that the Stake Balance is sufficient for unstaking the amount
        if (!isPositive && amount > stakedBalance) {
            revert InsufficientStakeBalance();
        }

        /// @dev Check the user account state based on lastUpdateTime
        /// @dev If this variable is 0, the user never staked and could not earn PE
        if (account.lastUpdateTime > 0) {
            /// @dev Calculate the Portal Energy earned since the last update
            uint256 portalEnergyEarned = stakedBalance * timePassed;

            /// @dev Calculate the gain of Portal Energy from maxLockDuration increase
            uint256 portalEnergyIncrease = stakedBalance * maxLockDifference;

            /// @dev Summarize Portal Energy changes and divide by common denominator
            portalEnergyNetChange =
                ((portalEnergyEarned + portalEnergyIncrease) * 1e18) /
                DENOMINATOR;
        }

        /// @dev Calculate the adjustment of Portal Energy from balance change
        uint256 portalEnergyAdjustment = adjustedPE / DENOMINATOR;

        /// @dev Calculate the amount of Portal Energy Tokens to be burned for unstaking the amount
        portalEnergyTokensRequired = !isPositive &&
            portalEnergyAdjustment >
            (account.portalEnergy + portalEnergyNetChange)
            ? portalEnergyAdjustment -
                (account.portalEnergy + portalEnergyNetChange)
            : 0;

        /// @dev Set the last update time to the current timestamp
        lastUpdateTime = block.timestamp;

        /// @dev Update the last maxLockDuration
        lastMaxLockDuration = maxLockDuration;

        /// @dev Update the user's staked balance and consider stake or unstake
        stakedBalance = isPositive
            ? stakedBalance + amount
            : stakedBalance - amount;

        /// @dev Update the user's max stake debt
        maxStakeDebt = (stakedBalance * maxLockDuration * 1e18) / DENOMINATOR;

        /// @dev Update the user's portalEnergy and account for stake or unstake
        /// @dev This will be 0 if Portal Energy Tokens must be burned
        portalEnergy = isPositive
            ? account.portalEnergy +
                portalEnergyNetChange +
                portalEnergyAdjustment
            : account.portalEnergy +
                portalEnergyTokensRequired +
                portalEnergyNetChange -
                portalEnergyAdjustment;

        /// @dev Update amount available to withdraw
        availableToWithdraw = portalEnergy >= maxStakeDebt
            ? stakedBalance
            : (stakedBalance * portalEnergy) / maxStakeDebt;
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
        /// @dev Update the user account data
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
    /// @dev Can only be called if LP is active
    /// @dev Does not follow CEI pattern for optimisation reasons. The handled tokens are trusted.
    /// @dev Update the user account
    /// @dev Update the global tracker of staked principal
    /// @dev Deposit the principal into the yield source (external protocol)
    /// @param _amount The amount of tokens to stake
    function stake(uint256 _amount) external payable activeLP nonReentrant {
        /// @dev Convert native ETH to WETH for contract, then send to LP
        /// @dev This section must sit before using _amount elsewhere to guarantee consistency
        /// @dev This knowingly deviates from the CEI pattern
        if (PRINCIPAL_TOKEN_ADDRESS == address(0)) {
            /// @dev Wrap ETH into WETH received by the contract
            _amount = msg.value;
            IWETH(WETH_ADDRESS).deposit{value: _amount}();

            /// @dev Send WETH to virtual LP
            IERC20(WETH_ADDRESS).transfer(VIRTUAL_LP, _amount);
        } else {
            /// @dev If not native ETH, transfer principal token to contract
            /// @dev Prevent contract from receiving ETH when principal is ERC20
            if (msg.value > 0) {
                revert NativeTokenNotAllowed();
            }

            /// @dev Transfer token from user to virtual LP
            IERC20(PRINCIPAL_TOKEN_ADDRESS).safeTransferFrom(
                msg.sender,
                VIRTUAL_LP,
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
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,
            ,

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
    /// @dev Update the user account
    /// @dev Update the global tracker of staked principal
    /// @dev Burn Portal Energy Tokens from caller to top up account balance if required
    /// @dev Withdraw the matching amount of principal from the yield source (external protocol)
    /// @dev Send the principal tokens to the user
    /// @param _amount The amount of tokens to unstake
    function unstake(uint256 _amount) external nonReentrant {
        /// @dev Check that the unstaked amount is greater than zero
        if (_amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Get the current state of the user stake
        /// @dev Throws if caller tries to unstake more than stake balance
        /// @dev Will burn Portal Energy tokens if account has insufficient Portal Energy
        (
            ,
            ,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,
            ,
            uint256 portalEnergyTokensRequired
        ) = getUpdateAccount(msg.sender, _amount, false);

        /// @dev Update the user stake struct
        _updateAccount(msg.sender, stakedBalance, maxStakeDebt, portalEnergy);

        /// @dev Update the global tracker of staked principal
        totalPrincipalStaked -= _amount;

        /// @dev Burn portalEnergyToken from the caller's wallet, throws if insufficient balance
        if (portalEnergyTokensRequired > 0) {
            portalEnergyToken.burnFrom(msg.sender, portalEnergyTokensRequired);
        }

        /// @dev Withdraw the assets from external Protocol and send to user
        virtualLP.withdrawFromYieldSource(
            PRINCIPAL_TOKEN_ADDRESS,
            msg.sender,
            _amount
        );

        /// @dev Emit event that tokens have been unstaked
        emit PrincipalUnstaked(msg.sender, _amount);
    }

    // ============================================
    // ==         NFT Position Management        ==
    // ============================================
    /// @notice This function deploys the NFT contract unique to this Portal
    /// @dev Deploy an NFT contract with name and symbol related to the principal token
    /// @dev Can only be called once
    function create_portalNFT() external {
        // Check if the NFT contract is already deployed
        if (portalNFTcreated) {
            revert TokenExists();
        }

        /// @dev Update the token creation flag to prevent future calls
        portalNFTcreated = true;

        /// @dev Build the NFT contract with name and symbol based on the principal token of this Portal
        string memory name = concatenate("Portal-Position-", PRINCIPAL_NAME);

        string memory symbol = concatenate("P-", PRINCIPAL_SYMBOL);

        /// @dev Deploy the token and update the related storage variable so that other functions can work
        portalNFT = new PortalNFT(
            DECIMALS_ADJUSTMENT,
            name,
            symbol,
            NFT_META_DATA
        );
    }

    /// @notice This function allows users to store their Account in a transferrable NFT
    /// @dev Mint a Portal NFT with the vital information of caller account to a recipient
    /// @dev Delete the caller account
    function mintNFTposition(address _recipient) external {
        /// @dev Check that the recipient is a valid address
        if (_recipient == address(0)) {
            revert InvalidAddress();
        }

        /// @dev Get the current state of the user stake
        (
            ,
            uint256 lastMaxLockDuration,
            uint256 stakedBalance,
            ,
            uint256 portalEnergy,
            ,

        ) = getUpdateAccount(msg.sender, 0, true);

        // check that caller has an account with PE or staked balance > 0
        if (portalEnergy == 0 && stakedBalance == 0) {
            revert EmptyAccount();
        }
        /// @dev delete the caller account
        delete accounts[msg.sender];

        /// @dev mint NFT to recipient containing the account information, get the returned ID
        uint256 nftID = portalNFT.mint(
            _recipient,
            lastMaxLockDuration,
            stakedBalance,
            portalEnergy
        );

        /// @dev Emit event that the NFT was minted
        emit PortalNFTminted(msg.sender, _recipient, nftID);
    }

    /// @notice This function allows users to redeem (burn) their PortalNFT for its content
    /// @dev Update the user account to current state. Required because stake balance can change which impacts PE earning
    /// @dev Burn the NFT and retrieve its balances (stake balance & portalEnergy)
    /// @dev Add the NFT values to the account of the user
    function redeemNFTposition(uint256 _tokenId) external {
        /// @dev Get the current state of the user Account
        (
            ,
            ,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,
            ,

        ) = getUpdateAccount(msg.sender, 0, true);

        /// @dev Redeem the NFT and get the returned paramters
        (uint256 stakedBalanceNFT, uint256 portalEnergyNFT) = portalNFT.redeem(
            msg.sender,
            _tokenId
        );

        /// @dev Update user Account
        stakedBalance += stakedBalanceNFT;
        portalEnergy += portalEnergyNFT;
        maxStakeDebt = (stakedBalance * maxLockDuration * 1e18) / DENOMINATOR;
        _updateAccount(msg.sender, stakedBalance, maxStakeDebt, portalEnergy);

        /// @dev Emit event that the Portal NFT was redeemed
        emit PortalNFTredeemed(msg.sender, msg.sender, _tokenId);
    }

    // ============================================
    // ==               VIRTUAL LP               ==
    // ============================================
    /// @notice Users sell PSM into the Portal to top up portalEnergy balance of a recipient
    /// @dev This function allows users to sell PSM tokens to the contract to increase a recipient portalEnergy
    /// @dev Get the correct price from the quote function
    /// @dev Increase the portalEnergy of the recipient by the amount of portalEnergy received
    /// @dev Transfer the PSM tokens from the caller to the contract
    /// @param _recipient The recipient of the Portal Energy credit
    /// @param _amountInputPSM The amount of PSM tokens to sell
    /// @param _minReceived The minimum amount of portalEnergy to receive
    /// @param _deadline The unix timestamp that marks the deadline for order execution
    function buyPortalEnergy(
        address _recipient,
        uint256 _amountInputPSM,
        uint256 _minReceived,
        uint256 _deadline
    ) external nonReentrant {
        /// @dev Check that the input amount & minimum received is greater than zero
        if (_amountInputPSM == 0 || _minReceived == 0) {
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
        uint256 amountReceived = quoteBuyPortalEnergy(_amountInputPSM);

        /// @dev Check that the amount of portalEnergy received is greater than or equal to the minimum expected output
        if (amountReceived < _minReceived) {
            revert InsufficientReceived();
        }

        /// @dev Increase the portalEnergy of the recipient by the amount of portalEnergy received
        accounts[_recipient].portalEnergy += amountReceived;

        /// @dev Transfer the PSM tokens from the caller to the Virtual LP
        IERC20(PSM_ADDRESS).transferFrom(
            msg.sender,
            VIRTUAL_LP,
            _amountInputPSM
        );

        /// @dev Emit the portalEnergyBuyExecuted event
        emit PortalEnergyBuyExecuted(msg.sender, _recipient, amountReceived);
    }

    /// @notice Users sell portalEnergy into the Portal to receive PSM to a recipient address
    /// @dev This function allows users to sell portalEnergy to the contract to increase a recipient PSM
    /// @dev Get the output amount from the quote function
    /// @dev Reduce the portalEnergy balance of the caller by the amount of portalEnergy sold
    /// @dev Send PSM to the recipient
    /// @param _recipient The recipient of the PSM tokens
    /// @param _amountInputPE The amount of Portal Energy to sell
    /// @param _minReceived The minimum amount of PSM to receive
    /// @param _deadline The unix timestamp that marks the deadline for order execution
    function sellPortalEnergy(
        address _recipient,
        uint256 _amountInputPE,
        uint256 _minReceived,
        uint256 _deadline
    ) external nonReentrant {
        /// @dev Check that the input amount & minimum received is greater than zero
        if (_amountInputPE == 0 || _minReceived == 0) {
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
            ,
            ,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,
            ,

        ) = getUpdateAccount(msg.sender, 0, true);

        /// @dev Require that the user has enough portalEnergy to sell
        if (portalEnergy < _amountInputPE) {
            revert InsufficientBalance();
        }

        /// @dev Calculate the amount of output token received based on the amount of portalEnergy sold
        uint256 amountReceived = quoteSellPortalEnergy(_amountInputPE);

        /// @dev Check that the amount of output token received is greater than or equal to the minimum expected output
        if (amountReceived < _minReceived) {
            revert InsufficientReceived();
        }

        /// @dev Calculate the user post-trade Portal Energy balance
        portalEnergy -= _amountInputPE;

        /// @dev Update the user stake struct
        _updateAccount(msg.sender, stakedBalance, maxStakeDebt, portalEnergy);

        /// @dev Instruct the Virtual LP to send PSM directly to the recipient
        virtualLP.PSM_sendToPortalUser(_recipient, amountReceived);

        /// @dev Emit the portalEnergySellExecuted event
        emit PortalEnergySellExecuted(msg.sender, _recipient, _amountInputPE);
    }

    /// @notice Simulate buying portalEnergy (output) with PSM tokens (input) and return amount received (output)
    /// @dev This function allows the caller to simulate a portalEnergy buy order of any size
    /// @dev Can only be called when the LP is active to avoid bad output and to prevent exchange
    /// @dev Update the token reserves to get the exchange price
    /// @param _amountInputPSM The amount of PSM tokens sold
    /// @return amountReceived The amount of portalEnergy received by the recipient
    function quoteBuyPortalEnergy(
        uint256 _amountInputPSM
    ) public view activeLP returns (uint256 amountReceived) {
        /// @dev Calculate the PSM token reserve (input)
        uint256 reserve0 = IERC20(PSM_ADDRESS).balanceOf(VIRTUAL_LP) -
            virtualLP.fundingRewardPool();

        /// @dev Calculate the reserve of portalEnergy (output)
        uint256 reserve1 = CONSTANT_PRODUCT / reserve0;

        /// @dev Reduce amount by the LP Protection Hurdle to prevent sandwich attacks
        _amountInputPSM =
            (_amountInputPSM * (100 - LP_PROTECTION_HURDLE)) /
            100;

        /// @dev Calculate the amount of portalEnergy received based on the amount of PSM tokens sold
        amountReceived =
            (_amountInputPSM * reserve1) /
            (_amountInputPSM + reserve0);
    }

    /// @notice Simulate selling portalEnergy (input) against PSM tokens (output) and return amount received (output)
    /// @dev This function allows the caller to simulate a portalEnergy sell order of any size
    /// @dev Can only be called when the LP is active to avoid bad output and to prevent exchange
    /// @dev Update the token reserves to get the exchange price
    /// @param _amountInputPE The amount of Portal Energy sold
    /// @return amountReceived The amount of PSM tokens received by the recipient
    function quoteSellPortalEnergy(
        uint256 _amountInputPE
    ) public view activeLP returns (uint256 amountReceived) {
        /// @dev Calculate the PSM token reserve (output)
        uint256 reserve0 = IERC20(PSM_ADDRESS).balanceOf(VIRTUAL_LP) -
            virtualLP.fundingRewardPool();

        /// @dev Calculate the reserve of portalEnergy (input)
        /// @dev Avoid zero value to prevent theoretical drainer attack by donating PSM before selling 1 PE
        uint256 reserve1 = (reserve0 > CONSTANT_PRODUCT)
            ? 1
            : CONSTANT_PRODUCT / reserve0;

        /// @dev Calculate the amount of PSM tokens received based on the amount of portalEnergy sold
        amountReceived =
            (_amountInputPE * reserve0) /
            (_amountInputPE + reserve1);
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
    /// @dev Can only be called once
    function create_portalEnergyToken() external {
        if (portalEnergyTokenCreated) {
            revert TokenExists();
        }

        /// @dev Update the token creation flag to prevent future calls.
        portalEnergyTokenCreated = true;

        /// @dev Build the token name and symbol based on the principal token of this Portal.
        string memory name = concatenate("PE-", PRINCIPAL_NAME);

        string memory symbol = concatenate("PE-", PRINCIPAL_SYMBOL);

        /// @dev Deploy the token and update the related storage variable so that other functions can work.
        portalEnergyToken = new MintBurnToken(name, symbol);
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
            ,
            ,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,
            ,

        ) = getUpdateAccount(msg.sender, 0, true);

        /// @dev Check that the caller has sufficient portalEnergy to mint the amount of portalEnergyToken
        if (portalEnergy < _amount) {
            revert InsufficientBalance();
        }

        /// @dev Reduce the portalEnergy of the caller by the amount of minted tokens
        portalEnergy -= _amount;

        /// @dev Update the user stake struct
        _updateAccount(msg.sender, stakedBalance, maxStakeDebt, portalEnergy);

        /// @dev Mint portal energy tokens to the recipient's wallet
        portalEnergyToken.mint(_recipient, _amount);

        /// @dev Emit the event that the ERC20 representation has been minted to recipient
        emit PortalEnergyMinted(msg.sender, _recipient, _amount);
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
            revert DurationTooLow();
        }

        if (newValue >= TERMINAL_MAX_LOCK_DURATION) {
            maxLockDuration = TERMINAL_MAX_LOCK_DURATION;
            lockDurationUpdateable = false;
        } else if (newValue > maxLockDuration) {
            maxLockDuration = newValue;
        }
    }
}
