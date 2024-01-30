// SPDX-License-Identifier: GPL-2.0-only
pragma solidity =0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {MintBurnToken} from "./MintBurnToken.sol";
import {PortalNFT} from "./PortalNFT.sol";
import {IWater} from "./interfaces/IWater.sol";
import {ISingleStaking} from "./interfaces/ISingleStaking.sol";
import {IDualStaking} from "./interfaces/IDualStaking.sol";

// ============================================
// ==          CUSTOM ERROR MESSAGES         ==
// ============================================
error bTokenNotDeployed();
error DeadlineExpired();
error DurationLocked();
error DurationBelowCurrent();
error EmptyAccount();
error FailedToSendNativeToken();
error FundingPhaseOngoing();
error FundingInsufficient();
error InsufficientBalance();
error InsufficientRewards();
error InsufficientReceived();
error InsufficientStakeBalance();
error InsufficientToWithdraw();
error InvalidAddress();
error InvalidAmount();
error InvalidConstructor();
error PEtokenNotDeployed();
error PortalNFTnotDeployed();
error PortalNotActive();
error PortalAlreadyActive();
error TokenExists();

/// @title Portal Contract V2
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
contract PortalV2 is ReentrancyGuard {
    constructor(
        uint256 _FUNDING_PHASE_DURATION,
        uint256 _FUNDING_MIN_AMOUNT,
        uint256 _FUNDING_EXCHANGE_RATIO,
        address _PRINCIPAL_TOKEN_ADDRESS,
        uint256 _DECIMALS,
        uint256 _AMOUNT_TO_CONVERT,
        string memory _METAT_DATA_URI
    ) {
        if (
            _FUNDING_PHASE_DURATION < 259200 ||
            _FUNDING_PHASE_DURATION > 2592000
        ) {
            revert InvalidConstructor();
        }
        if (_FUNDING_MIN_AMOUNT == 0) {
            revert InvalidConstructor();
        }
        if (_FUNDING_EXCHANGE_RATIO == 0) {
            revert InvalidConstructor();
        }
        if (_PRINCIPAL_TOKEN_ADDRESS == address(0)) {
            revert InvalidConstructor();
        }
        if (_DECIMALS == 0) {
            revert InvalidConstructor();
        }
        if (_AMOUNT_TO_CONVERT == 0) {
            revert InvalidConstructor();
        }
        if (keccak256(bytes(_METAT_DATA_URI)) == keccak256(bytes(""))) {
            revert InvalidConstructor();
        }

        FUNDING_PHASE_DURATION = _FUNDING_PHASE_DURATION;
        FUNDING_MIN_AMOUNT = _FUNDING_MIN_AMOUNT;
        FUNDING_EXCHANGE_RATIO = _FUNDING_EXCHANGE_RATIO;
        PRINCIPAL_TOKEN_ADDRESS = _PRINCIPAL_TOKEN_ADDRESS;
        DECIMALS_ADJUSTMENT = 10 ** _DECIMALS;
        AMOUNT_TO_CONVERT = _AMOUNT_TO_CONVERT;
        CREATION_TIME = block.timestamp;
        NFT_META_DATA = _METAT_DATA_URI;
    }

    // ============================================
    // ==        GLOBAL VARIABLES & EVENTS       ==
    // ============================================
    using SafeERC20 for IERC20;

    // general
    MintBurnToken public bToken; // the receipt token for funding the Portal
    MintBurnToken public portalEnergyToken; // the ERC20 representation of portalEnergy
    PortalNFT public portalNFT; // The NFT contract deployed by the Portal that can store accounts
    bool public bTokenCreated; // flag for bToken deployment
    bool public portalEnergyTokenCreated; // flag for PE token deployment
    bool public PortalNFTcreated; // flag for Portal NFT contract deployment

    address public constant PSM_ADDRESS =
        0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5; // address of PSM token
    uint256 public constant TERMINAL_MAX_LOCK_DURATION = 157680000; // terminal maximum lock duration of a user´s stake in seconds (5y)
    uint256 private constant SECONDS_PER_YEAR = 31536000; // seconds in a 365 day year
    uint256 public immutable AMOUNT_TO_CONVERT; // fixed amount of PSM tokens required to withdraw yield in the contract
    uint256 public immutable CREATION_TIME; // time stamp of deployment
    string public NFT_META_DATA; // IPFS uri for Portal Position NFTs metadata
    uint256 public maxLockDuration = 7776000; // starting value for maximum allowed lock duration of user´s balance in seconds (90 days)
    uint256 public totalPrincipalStaked; // shows how much principal is staked by all users combined
    bool private lockDurationUpdateable = true; // flag to signal if the lock duration can still be updated

    // principal management related
    address public immutable PRINCIPAL_TOKEN_ADDRESS; // address of the token accepted by the strategy as deposit
    uint256 public immutable DECIMALS_ADJUSTMENT; // scaling factor to account for the decimals of the principal token

    // address payable private constant COMPOUNDER_ADDRESS =
    //     payable(0x8E5D083BA7A46f13afccC27BFB7da372E9dFEF22);
    // address payable private constant HLP_STAKING =
    //     payable(0xbE8f8AF5953869222eA8D39F1Be9d03766010B1C);
    // address private constant HLP_PROTOCOL_REWARDER =
    //     0x665099B3e59367f02E5f9e039C3450E31c338788;
    // address private constant HLP_EMISSIONS_REWARDER =
    //     0x6D2c18B559C5343CB0703bB55AADB5f22152cC32;

    // address private constant HMX_STAKING =
    //     0x92E586B8D4Bf59f4001604209A292621c716539a;
    // address private constant HMX_PROTOCOL_REWARDER =
    //     0xB698829C4C187C85859AD2085B24f308fC1195D3;
    // address private constant HMX_EMISSIONS_REWARDER =
    //     0x94c22459b145F012F1c6791F2D729F7a22c44764;
    // address private constant HMX_DRAGONPOINTS_REWARDER =
    //     0xbEDd351c62111FB7216683C2A26319743a06F273;

    // uint256 private constant HMX_TIMESTAMP = 1689206400;
    // uint256 private constant HMX_NUMBER =
    //     115792089237316195423570985008687907853269984665640564039457584007913129639935;

    // bootstrapping related
    uint256 public immutable FUNDING_PHASE_DURATION; // seconds that the funding phase lasts before Portal can be activated
    uint256 public immutable FUNDING_MIN_AMOUNT; // minimum funding required before Portal can be activated
    uint256 public constant FUNDING_APR = 50; // redemption value APR increase of bTokens
    uint256 public constant FUNDING_MAX_RETURN_PERCENT = 1000; // maximum redemption value percent of bTokens (must be >100)
    uint256 public constant FUNDING_REWARD_SHARE = 10; // 10% of yield goes to the funding pool until investors are paid back

    uint256 public fundingBalance; // sum of all PSM funding contributions
    uint256 public fundingRewardPool; // amount of PSM available for redemption against bTokens
    bool public isActivePortal; // Start with false, will be set to true when funding phase ends

    // exchange related
    uint256 private immutable FUNDING_EXCHANGE_RATIO; // amount of portalEnergy per PSM for calculating k during funding process
    uint256 public constant LP_PROTECTION_HURDLE = 1; // percent reduction of output amount when minting or buying PE
    uint256 public constantProduct; // the K constant of the (x*y = K) constant product formula

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

    // --- Events related to the funding phase ---
    event bTokenDeployed(address bToken);
    event PortalEnergyTokenDeployed(address PortalEnergyToken);
    event PortalNFTdeployed(address PortalNFTcontract);

    event FundingReceived(address indexed, uint256 amount);
    event FundingWithdrawn(address indexed, uint256 amount);
    event PortalActivated(address indexed, uint256 fundingBalance);

    event RewardsRedeemed(
        address indexed,
        uint256 amountBurned,
        uint256 amountReceived
    );

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

    event ConvertExecuted(
        address indexed token,
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
    function stake(uint256 _amount) external nonReentrant activePortalCheck {
        /// @dev Revert if the staked amount is zero
        if (_amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Get the current status of the user´s stake
        (
            ,
            ,
            ,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,

        ) = getUpdateAccount(msg.sender, _amount, true);

        /// @dev Update the user´s stake struct
        _updateAccount(msg.sender, stakedBalance, maxStakeDebt, portalEnergy);

        /// @dev Update the total stake balance
        totalPrincipalStaked += _amount;

        /// @dev Transfer the user's principal tokens to the contract
        IERC20(PRINCIPAL_TOKEN_ADDRESS).safeTransferFrom(
            msg.sender,
            address(this),
            _amount
        );

        /// @dev Deposit the principal into the yield source (external protocol)
        _depositToYieldSource(_amount);

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
        /// @dev Require that the unstaked amount is greater than zero
        if (_amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Get the current status of the user´s stake
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

        /// @dev Withdraw the matching amount of principal from the yield source (external protocol)
        /// @dev Sanity check that the withdrawn amount from yield source is the amount sent to user
        uint256 balanceBefore = IERC20(PRINCIPAL_TOKEN_ADDRESS).balanceOf(
            address(this)
        );
        _withdrawFromYieldSource(_amount);
        uint256 balanceAfter = IERC20(PRINCIPAL_TOKEN_ADDRESS).balanceOf(
            address(this)
        );
        uint256 availableAmount = balanceAfter - balanceBefore;

        /// @dev Send the recovered principal tokens to the user
        IERC20(PRINCIPAL_TOKEN_ADDRESS).safeTransfer(
            msg.sender,
            availableAmount
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
        /// @dev Get the current status of the user´s stake
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
        /// @dev Sanity check that the withdrawn amount from yield source is the amount sent to user
        uint256 balanceBefore = IERC20(PRINCIPAL_TOKEN_ADDRESS).balanceOf(
            address(this)
        );

        _withdrawFromYieldSource(oldStakedBalance);
        uint256 balanceAfter = IERC20(PRINCIPAL_TOKEN_ADDRESS).balanceOf(
            address(this)
        );

        uint256 availableAmount = balanceAfter - balanceBefore;

        /// @dev Send the retrieved tokens to the user
        IERC20(PRINCIPAL_TOKEN_ADDRESS).safeTransfer(
            msg.sender,
            availableAmount
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
    /// @dev Must be called before Portal is activated
    /// @dev Can only be called once
    function create_portalNFT() public nonActivePortalCheck {
        // Check if the NFT contract is already deployed
        if (PortalNFTcreated) {
            revert TokenExists();
        }

        /// @dev Update the token creation flag to prevent future calls
        PortalNFTcreated = true;

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
    function mintNFTposition(address _recipient) public activePortalCheck {
        /// @dev Check that the recipient is a valid address
        if (_recipient == address(0)) {
            revert InvalidAddress();
        }

        /// @dev Get the current status of user stake
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
    /// @dev Burn the NFT and retrieve its information
    /// @dev Add the NFT values to the account of recipient
    function redeemNFTposition(address _recipient, uint256 _tokenId) public {
        /// @dev Check that the recipient is a valid address
        if (_recipient == address(0)) {
            revert InvalidAddress();
        }

        /// @dev Get the current status of the recipient Account
        (
            ,
            ,
            ,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,

        ) = getUpdateAccount(_recipient, 0, true);

        /// @dev Redeem the NFT and get the returned paramters
        (uint256 stakedBalanceNFT, uint256 portalEnergyNFT) = portalNFT.redeem(
            _tokenId,
            msg.sender
        );

        /// @dev Update recipient Account
        stakedBalance += stakedBalanceNFT;
        portalEnergy += portalEnergyNFT;
        _updateAccount(_recipient, stakedBalance, maxStakeDebt, portalEnergy);

        /// @dev Emit event that the Portal NFT was redeemed
        emit PortalNFTredeemed(msg.sender, _recipient, _tokenId);
    }

    // ============================================
    // ==      PRINCIPAL & REWARD MANAGEMENT     ==
    // ============================================
    /// @notice Deposit principal into the yield source
    /// @dev This function deposits principal tokens from the Portal into the external protocol
    /// @dev Approve the amount of tokens to be transferred
    /// @dev Transfer the tokens from the Portal to the external protocol via interface
    function _depositToYieldSource(uint256 _amount) private {
        /// @dev Approve the amount to be transferred
        // IERC20(PRINCIPAL_TOKEN_ADDRESS).safeIncreaseAllowance(
        //     HLP_STAKING,
        //     _amount
        // );
        /// @dev Transfer the approved balance to the external protocol using the interface
        // IStaking(HLP_STAKING).deposit(address(this), _amount);
    }

    /// @notice Withdraw principal from the yield source to the Portal
    /// @dev This function withdraws principal tokens from the external protocol to the Portal
    /// @dev It transfers the tokens from the external protocol to the Portal via interface
    /// @param _amount The amount of tokens to withdraw
    function _withdrawFromYieldSource(uint256 _amount) private {
        /// @dev Withdraw the staked balance from external protocol using the interface
        // IStaking(HLP_STAKING).withdraw(_amount);
    }

    /// @notice Claim rewards related to HLP and HMX staked by this contract
    /// @dev This function claims staking rewards from the external protocol to the Portal
    /// @dev Transfer the tokens from the external protocol to the Portal via interface
    function claimRewardsHLPandHMX() external {
        // /// @dev Initialize the first input array for the compounder and assign values
        // address[] memory pools = new address[](2);
        // pools[0] = HLP_STAKING;
        // pools[1] = HMX_STAKING;
        // /// @dev Initialize the second input array for the compounder and assign values
        // address[][] memory rewarders = new address[][](2);
        // rewarders[0] = new address[](2);
        // rewarders[0][0] = HLP_PROTOCOL_REWARDER;
        // rewarders[0][1] = HLP_EMISSIONS_REWARDER;
        // rewarders[1] = new address[](3);
        // rewarders[1][0] = HMX_PROTOCOL_REWARDER;
        // rewarders[1][1] = HMX_EMISSIONS_REWARDER;
        // rewarders[1][2] = HMX_DRAGONPOINTS_REWARDER;
        // /// @dev Claim rewards from HLP and HMX staking via the interface
        // /// @dev esHMX and DP rewards are staked automatically, USDC is transferred to contract
        // ICompounder(COMPOUNDER_ADDRESS).compound(
        //     pools,
        //     rewarders,
        //     HMX_TIMESTAMP,
        //     HMX_NUMBER,
        //     new uint256[](0)
        // );
        // /// @dev Emit event that rewards have been claimed
        // emit RewardsClaimed(pools, rewarders, block.timestamp);
    }

    /// @notice If the above claim function breaks in the future, use this function to claim specific rewards
    /// @param _pools The pools to claim rewards from
    /// @param _rewarders The rewarders to claim rewards from
    function claimRewardsManual(
        address[] memory _pools,
        address[][] memory _rewarders
    ) external {
        // /// @dev claim rewards from any staked token and any rewarder via interface
        // /// @dev esHMX and DP rewards are staked automatically, USDC or other reward tokens are transferred to Portal
        // ICompounder(COMPOUNDER_ADDRESS).compound(
        //     _pools,
        //     _rewarders,
        //     HMX_TIMESTAMP,
        //     HMX_NUMBER,
        //     new uint256[](0)
        // );
        // /// @dev Emit event that rewards have been claimed
        // emit RewardsClaimed(_pools, _rewarders, block.timestamp);
    }

    /// @notice View claimable yield from a specific rewarder contract of the yield source
    /// @dev This function shows the claimable yield from a specific rewarder contract of the yield source
    /// @param _rewarder The rewarder contract whose pending reward is to be viewed
    /// @return claimableReward The amount of claimable tokens from this rewarder
    function getPendingRewards(
        address _rewarder
    ) external view returns (uint256 claimableReward) {
        // claimableReward = IRewarder(_rewarder).pendingReward(address(this));
    }

    // ============================================
    // ==               INTERNAL LP              ==
    // ============================================
    /// @notice Users sell PSM into the Portal to top up portalEnergy balance of a recipient
    /// @dev This function allows users to sell PSM tokens to the contract to increase a recipient´s portalEnergy
    /// @dev Can only be called if the Portal is active
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
    ) external nonReentrant activePortalCheck {
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

        /// =======================
        /// THIS CHECK COULD BE REMOVED TO SAVE GAS
        /// =======================
        /// @dev Check that the user has enough PSM token to sell
        if (IERC20(PSM_ADDRESS).balanceOf(msg.sender) < _amountInput) {
            revert InsufficientBalance();
        }

        /// @dev Get the amount of portalEnergy received based on the amount of PSM tokens sold
        uint256 amountReceived = quoteBuyPortalEnergy(_amountInput);

        /// @dev Check that the amount of portalEnergy received is greater than or equal to the minimum expected output
        if (amountReceived < _minReceived) {
            revert InsufficientReceived();
        }

        /// @dev Increase the portalEnergy of the recipient by the amount of portalEnergy received
        accounts[_recipient].portalEnergy += amountReceived;

        /// @dev Transfer the PSM tokens from the caller to the contract
        IERC20(PSM_ADDRESS).transferFrom(
            msg.sender,
            address(this),
            _amountInput
        );

        /// @dev Emit the portalEnergyBuyExecuted event
        emit PortalEnergyBuyExecuted(msg.sender, _recipient, amountReceived);
    }

    /// @notice Users sell portalEnergy into the Portal to receive PSM to a recipient address
    /// @dev This function allows users to sell portalEnergy to the contract to increase a recipient´s PSM
    /// @dev Can only be called if the Portal is active
    /// @dev Get the correct price from the quote function
    /// @dev Reduce the portalEnergy balance of the caller by the amount of portalEnergy sold
    /// @dev Send PSM to the recipient
    /// @param _amountInput The amount of portalEnergy to sell
    /// @param _minReceived The minimum amount of PSM tokens to receive
    function sellPortalEnergy(
        address _recipient,
        uint256 _amountInput,
        uint256 _minReceived,
        uint256 _deadline
    ) external nonReentrant activePortalCheck {
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

        /// @dev Get the current status of the user´s stake
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

        /// @dev Calculate the caller´s post-trade Portal Energy balance
        portalEnergy -= _amountInput;

        /// @dev Update the user´s stake struct
        _updateAccount(user, stakedBalance, maxStakeDebt, portalEnergy);

        /// @dev Send the output token to the recipient
        IERC20(PSM_ADDRESS).transfer(_recipient, amountReceived);

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
        uint256 reserve0 = IERC20(PSM_ADDRESS).balanceOf(address(this)) -
            fundingRewardPool;

        /// @dev Calculate the reserve of portalEnergy (output)
        uint256 reserve1 = constantProduct / reserve0;

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
        uint256 reserve0 = IERC20(PSM_ADDRESS).balanceOf(address(this)) -
            fundingRewardPool;

        /// @dev Calculate the reserve of portalEnergy (input)
        /// @dev Avoid zero value to prevent theoretical drainer attack by donating PSM before selling 1 PE
        uint256 reserve1 = (reserve0 > constantProduct)
            ? 1
            : constantProduct / reserve0;

        /// @dev Calculate the amount of PSM tokens received based on the amount of portalEnergy sold
        amountReceived = (_amountInput * reserve0) / (_amountInput + reserve1);
    }

    // ============================================
    // ==              PSM CONVERTER             ==
    // ============================================
    /// @notice Handle the arbitrage conversion of tokens inside the contract for PSM tokens
    /// @dev This function handles the conversion of tokens inside the contract for PSM tokens
    /// @dev Collect rewards for funders and reallocate reward overflow to the internal LP (indirect)
    /// @dev Transfer the input (PSM) token from the caller to the contract
    /// @dev Transfer the specified output token from the contract to the caller
    /// @param _token The token to be obtained by the recipient
    /// @param _minReceived The minimum amount of tokens received
    function convert(
        address _token,
        address _recipient,
        uint256 _minReceived,
        uint256 _deadline
    ) external nonReentrant {
        /// @dev Check the validity of token and recipient addresses
        if (_token == PSM_ADDRESS || _recipient == address(0)) {
            revert InvalidAddress();
        }

        /// @dev Prevent zero value input
        if (_minReceived == 0) {
            revert InvalidAmount();
        }

        /// @dev Check that the deadline has not expired
        if (_deadline < block.timestamp) {
            revert DeadlineExpired();
        }

        /// @dev Get the contract balance of the specified token
        uint256 contractBalance;
        if (_token == address(0)) {
            contractBalance = address(this).balance;
        } else {
            contractBalance = IERC20(_token).balanceOf(address(this));
        }

        /// @dev Check that enough output tokens are available for frontrun protection
        if (contractBalance < _minReceived) {
            revert InsufficientReceived();
        }

        /// @dev Check for reward overflow and reallocate rewards to internal LP if necessary (passive)
        uint256 maxRewards = (bToken.totalSupply() *
            FUNDING_MAX_RETURN_PERCENT) / 100;
        if (fundingRewardPool > maxRewards) {
            fundingRewardPool = maxRewards;
        }

        /// @dev Collect rewards if there is outstanding debt to funders
        if (fundingRewardPool < maxRewards) {
            uint256 newRewards = (AMOUNT_TO_CONVERT * FUNDING_REWARD_SHARE) /
                100;
            fundingRewardPool += newRewards;
        }

        /// @dev Transfer the input token (PSM) from the user to the contract
        IERC20(PSM_ADDRESS).transferFrom(
            msg.sender,
            address(this),
            AMOUNT_TO_CONVERT
        );

        /// @dev Transfer the output token from the contract to the recipient
        if (_token == address(0)) {
            (bool sent, ) = payable(_recipient).call{value: contractBalance}(
                ""
            );
            if (!sent) {
                revert FailedToSendNativeToken();
            }
        } else {
            IERC20(_token).safeTransfer(_recipient, contractBalance);
        }

        emit ConvertExecuted(_token, msg.sender, _recipient, contractBalance);
    }

    // ============================================
    // ==                FUNDING                 ==
    // ============================================
    /// @notice End the funding phase and enable normal contract functionality
    /// @dev This function activates the portal and initializes the internal LP
    /// @dev Can only be called when the Portal is inactive
    /// @dev Calculate the constant product K, which is used to initialize the internal LP
    function activatePortal() external nonActivePortalCheck {
        /// @dev Check that the funding phase is over and enough funding has been contributed
        if (block.timestamp < CREATION_TIME + FUNDING_PHASE_DURATION) {
            revert FundingPhaseOngoing();
        }
        if (fundingBalance < FUNDING_MIN_AMOUNT) {
            revert FundingInsufficient();
        }

        /// @dev Check that the necessary child contracts have been deployed
        if (!bTokenCreated) {
            revert bTokenNotDeployed();
        }
        if (!portalEnergyTokenCreated) {
            revert PEtokenNotDeployed();
        }
        if (!PortalNFTcreated) {
            revert PortalNFTnotDeployed();
        }

        /// @dev Activate the portal
        isActivePortal = true;

        /// @dev Set the constant product K, which is used in the calculation of the amount of assets in the LP
        constantProduct = fundingBalance ** 2 / FUNDING_EXCHANGE_RATIO;

        /// @dev Emit the PortalActivated event with the address of the contract and the funding balance
        emit PortalActivated(address(this), fundingBalance);
    }

    /// @notice Allow users to deposit PSM to provide the initial upfront yield
    /// @dev This function allows users to deposit PSM tokens during the funding phase
    /// @dev The bToken must have been deployed via the contract in advance
    /// @dev Increase the fundingBalance tracker by the amount of PSM deposited
    /// @dev Transfer the PSM tokens from the user to the contract
    /// @dev Mint bTokens to the user
    /// @param _amount The amount of PSM to deposit
    function contributeFunding(uint256 _amount) external nonActivePortalCheck {
        /// @dev Prevent zero amount transaction
        if (_amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Calculate the amount of bTokens to be minted based on the maximum return
        uint256 mintableAmount = (_amount * FUNDING_MAX_RETURN_PERCENT) / 100;

        /// @dev Increase the funding tracker balance by the amount of PSM deposited
        fundingBalance += _amount;

        /// @dev Transfer the PSM tokens from the user to the contract
        IERC20(PSM_ADDRESS).transferFrom(msg.sender, address(this), _amount);

        /// @dev Mint bTokens to the user
        bToken.mint(msg.sender, mintableAmount);

        /// @dev Emit the FundingReceived event with the user's address and the mintable amount
        emit FundingReceived(msg.sender, mintableAmount);
    }

    /// @notice Allow users to burn bTokens to recover PSM funding before the Portal is activated
    /// @dev This function allows users to withdraw PSM tokens during the funding phase of the contract
    /// @dev The bToken must have been deployed via the contract in advance
    /// @dev Decrease the fundingBalance tracker by the amount of PSM withdrawn
    /// @dev Burn the appropriate amount of bTokens from the caller
    /// @dev Transfer the PSM tokens from the contract to the caller
    /// @param _amount The amount of bTokens burned to withdraw PSM
    function withdrawFunding(uint256 _amount) external nonActivePortalCheck {
        /// @dev Prevent zero amount transaction
        if (_amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Calculate the amount of PSM returned to the user
        uint256 withdrawAmount = (_amount * 100) / FUNDING_MAX_RETURN_PERCENT;

        /// @dev Decrease the fundingBalance tracker by the amount of PSM deposited
        fundingBalance -= withdrawAmount;

        /// @dev Transfer the PSM tokens from the contract to the user
        IERC20(PSM_ADDRESS).transfer(msg.sender, withdrawAmount);

        /// @dev Burn bTokens from the user
        bToken.burnFrom(msg.sender, _amount);

        /// @dev Emit the FundingReceived event with the user's address and the mintable amount
        emit FundingWithdrawn(msg.sender, withdrawAmount);
    }

    /// @notice Calculate the current burn value of bTokens
    /// @param _amount The amount of bTokens to burn
    /// @return burnValue The amount of PSM received when redeeming bTokens
    function getBurnValuePSM(
        uint256 _amount
    ) public view returns (uint256 burnValue) {
        /// @dev Calculate the minimum burn value
        uint256 minValue = (_amount * 100) / FUNDING_MAX_RETURN_PERCENT;

        /// @dev Calculate the time based burn value
        uint256 accruedValue = (_amount *
            (block.timestamp - CREATION_TIME) *
            FUNDING_APR) / (100 * SECONDS_PER_YEAR);

        uint256 maxValue = (_amount * FUNDING_MAX_RETURN_PERCENT) / 100;
        uint256 currentValue = minValue + accruedValue;

        burnValue = (currentValue < maxValue) ? currentValue : maxValue;
    }

    /// @notice Get the amount of bTokens that can be burned against the reward Pool
    /// @dev Calculate how many bTokens can be burned to redeem the full reward Pool
    /// @return amountBurnable The amount of bTokens that can be redeemed for rewards
    function getBurnableBtokenAmount()
        public
        view
        returns (uint256 amountBurnable)
    {
        /// @dev Calculate the burn value of 1 full bToken in PSM
        /// @dev Add 1 to handle potential rounding issue in the next step
        uint256 burnValueFullToken = getBurnValuePSM(1e18) + 1;

        /// @dev Calculate and return the amount of bTokens burnable
        amountBurnable = (fundingRewardPool * 1e18) / burnValueFullToken;
    }

    /// @notice Users redeem bTokens for PSM tokens
    /// @dev This function allows users to burn bTokens to receive PSM when the Portal is active
    /// @dev Reduce the funding reward pool by the amount of PSM payable to the user
    /// @dev Burn the bTokens from the user's wallet
    /// @dev Transfer the PSM tokens to the user
    /// @param _amount The amount of bTokens to burn
    function burnBtokens(uint256 _amount) external activePortalCheck {
        /// @dev Check that the burn amount is not zero
        if (_amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Check that the burn amount is not larger than what can be redeemed
        uint256 burnable = getBurnableBtokenAmount();
        if (_amount > burnable) {
            revert InvalidAmount();
        }

        /// @dev Calculate how many PSM the user receives based on the burn amount
        uint256 amountToReceive = getBurnValuePSM(_amount);

        /// @dev Check that there are enough PSM in the funding reward pool
        if (amountToReceive > fundingRewardPool) {
            revert InsufficientRewards();
        }

        /// @dev Reduce the funding reward pool by the amount of PSM payable to the user
        fundingRewardPool -= amountToReceive;

        /// @dev Burn the bTokens from the user's balance
        bToken.burnFrom(msg.sender, _amount);

        /// @dev Transfer the PSM to the user
        IERC20(PSM_ADDRESS).transfer(msg.sender, amountToReceive);

        /// @dev Event that informs about burn amount and received PSM by the caller
        emit RewardsRedeemed(msg.sender, _amount, amountToReceive);
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

    /// @notice Deploy the bToken of this Portal
    /// @dev Must be called before Portal is activated
    /// @dev Must be called before Portal is activated
    /// @dev Can only be called once
    function create_bToken() external nonActivePortalCheck {
        if (bTokenCreated) {
            revert TokenExists();
        }

        /// @dev Update the token creation flag to prevent future calls.
        bTokenCreated = true;

        /// @dev Build the token name and symbol based on the principal token of this Portal.
        string memory name = concatenate(
            "b",
            ERC20(PRINCIPAL_TOKEN_ADDRESS).name()
        );

        string memory symbol = concatenate(
            "b",
            ERC20(PRINCIPAL_TOKEN_ADDRESS).symbol()
        );

        /// @dev Deploy the token and update the related storage variable so that other functions can work.
        bToken = new MintBurnToken(address(this), name, symbol);

        emit bTokenDeployed(address(bToken));
    }

    /// @notice Deploy the Portal Energy Token of this Portal
    /// @dev This function deploys the PortalEnergyToken of this Portal and sets the Portal as owner
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
        portalEnergyToken = new MintBurnToken(address(this), name, symbol);

        emit PortalEnergyTokenDeployed(address(portalEnergyToken));
    }

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
        Account memory account = accounts[_user];

        /// @dev initialize helper variables
        uint256 portalEnergyEarned;
        uint256 portalEnergyIncrease;
        uint256 portalEnergyNetChange;
        uint256 portalEnergyAdjustment;

        /// @dev Check the user´s account status based on lastUpdateTime
        /// @dev If this variable is 0, the user never staked and could not earn PE
        if (account.lastUpdateTime != 0) {
            /// @dev Calculate the Portal Energy earned since the last update
            portalEnergyEarned = (account.stakedBalance *
                (block.timestamp - account.lastUpdateTime) *
                1e18);

            /// @dev Calculate the gain of Portal Energy from maxLockDuration increase
            portalEnergyIncrease = (account.stakedBalance *
                (maxLockDuration - account.lastMaxLockDuration) *
                1e18);

            /// @dev Summarize Portal Energy changes and divide by common denominator
            portalEnergyNetChange =
                (portalEnergyEarned + portalEnergyIncrease) /
                (SECONDS_PER_YEAR * DECIMALS_ADJUSTMENT);
        }

        /// @dev Calculate the adjustment of Portal Energy from balance change
        portalEnergyAdjustment =
            ((_amount * maxLockDuration) * 1e18) /
            (SECONDS_PER_YEAR * DECIMALS_ADJUSTMENT);

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
        lastMaxLockDuration = maxLockDuration;

        /// @dev Calculate the user's staked balance and consider stake or unstake
        stakedBalance = _isPositiveAmount
            ? account.stakedBalance + _amount
            : account.stakedBalance - _amount;

        /// @dev Update the user's max stake debt
        maxStakeDebt =
            (stakedBalance * maxLockDuration * 1e18) /
            (SECONDS_PER_YEAR * DECIMALS_ADJUSTMENT);

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

        /// =======================
        /// THIS CHECK COULD BE REMOVED TO SAVE GAS
        /// =======================
        /// @dev Check that the caller has sufficient tokens to burn
        if (portalEnergyToken.balanceOf(msg.sender) < _amount) {
            revert InsufficientBalance();
        }

        /// @dev Increase the portalEnergy of the recipient by the amount of portalEnergyToken burned
        accounts[_recipient].portalEnergy += _amount;

        /// @dev Burn portalEnergyToken from the caller's wallet
        portalEnergyToken.burnFrom(msg.sender, _amount);

        /// @dev Emit the event that the ERC20 representation has been burned and value accrued to recipient
        emit PortalEnergyBurned(msg.sender, _recipient, _amount);
    }

    // ==============================
    /// THIS FUNCTION COULD BE CONSOLIDATED WITH THE ABOVE - ADJUST forceUnstakeAll()
    // ==============================
    /// @notice Burn portalEnergyToken from user wallet and increase portalEnergy of user equally
    /// @dev This function is private and can only be called internally
    /// @param _user The address whose portalEnergy is to be increased
    /// @param _amount The amount of portalEnergyToken to burn
    function _burnPortalEnergyToken(address _user, uint256 _amount) private {
        /// @dev Check that the user has sufficient tokens to burn
        if (portalEnergyToken.balanceOf(address(_user)) < _amount) {
            revert InsufficientBalance();
        }

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

        /// @dev Get the current status of the user´s stake
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
