// SPDX-License-Identifier: GPL-2.0-only
pragma solidity =0.8.19;

import {MintBurnToken} from "./MintBurnToken.sol";
import {IWater} from "./interfaces/IWater.sol";
import {ISingleStaking} from "./interfaces/ISingleStaking.sol";
import {IDualStaking} from "./interfaces/IDualStaking.sol";
import {IPortalV2MultiAsset} from "./interfaces/IPortalV2MultiAsset.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IWETH {
    function withdrawTo(address _account, uint256 _amount) external;
}

// ============================================
// ==              CUSTOM ERRORS             ==
// ============================================
error InactiveLP();
error ActiveLP();
error NotOwner();
error PortalNotRegistered();
error OwnerNotExpired();
error InsufficientReceived();
error InvalidConstructor();
error InvalidAddress();
error InvalidAmount();
error DeadlineExpired();
error FailedToSendNativeToken();
error FundingPhaseOngoing();
error FundingInsufficient();
error TokenExists();
error TimeLockActive();
error NoProfit();
error OwnerRevoked();

/// @title Portal V2 Virtual LP
/// @author Possum Labs
/** @notice This contract serves as the shared, virtual LP for multiple Portals
 * Each Portal must be registered by the owner
 * The contract is owned for a predetermined duration to enable registering more Portals
 * Registering more Portals must be permissioned because it can be malicious
 * Portals cannot be removed from the registry to guarantee Portal integrity
 * The full amount of PSM inside the LP is available to provide upfront yield for each Portal
 * Capital staked through the connected Portals is redirected and staked in an external yield source
 * The LP is refilled by convert() calls which exchanges ERC20 balances for PSM
 */
/// @dev Setup Process: 1. Deploy VirtualLP, 2. Deploy Portals, 3. Register Portals in VirtualLP 4. Activate LP
contract VirtualLP is ReentrancyGuard {
    constructor(
        address _owner,
        uint256 _AMOUNT_TO_CONVERT,
        uint256 _FUNDING_PHASE_DURATION,
        uint256 _FUNDING_MIN_AMOUNT
    ) {
        if (_owner == address(0)) {
            revert InvalidConstructor();
        }
        if (_AMOUNT_TO_CONVERT == 0) {
            revert InvalidConstructor();
        }
        if (
            _FUNDING_PHASE_DURATION < 259200 ||
            _FUNDING_PHASE_DURATION > 2592000
        ) {
            revert InvalidConstructor();
        }
        if (_FUNDING_MIN_AMOUNT == 0) {
            revert InvalidConstructor();
        }

        AMOUNT_TO_CONVERT = _AMOUNT_TO_CONVERT;
        FUNDING_PHASE_DURATION = _FUNDING_PHASE_DURATION;
        FUNDING_MIN_AMOUNT = _FUNDING_MIN_AMOUNT;

        owner = _owner;
        OWNER_EXPIRY_TIME = OWNER_DURATION + block.timestamp;

        CREATION_TIME = block.timestamp;
    }

    // ============================================
    // ==            GLOBAL VARIABLES            ==
    // ============================================
    using SafeERC20 for IERC20;

    MintBurnToken public bToken; // the receipt token for funding the LP
    address public bTokenAddress; // the address of the receipt token

    uint256 constant SECONDS_PER_YEAR = 31536000; // seconds in a 365 day year
    uint256 constant MAX_UINT =
        115792089237316195423570985008687907853269984665640564039457584007913129639935;

    address public owner;
    uint256 private constant OWNER_DURATION = 31536000; // 1 Year
    uint256 public immutable OWNER_EXPIRY_TIME; // Time required to pass before owner can be revoked
    uint256 public immutable AMOUNT_TO_CONVERT; // fixed amount of PSM tokens required to withdraw yield in the contract
    uint256 public immutable FUNDING_PHASE_DURATION; // seconds after deployment before Portal can be activated
    uint256 public immutable FUNDING_MIN_AMOUNT; // minimum funding required before Portal can be activated
    uint256 public immutable CREATION_TIME; // time stamp of deployment

    uint256 public constant FUNDING_APR = 36; // annual redemption value increase (APR) of bTokens
    uint256 public constant FUNDING_MAX_RETURN_PERCENT = 1000; // maximum redemption value percent of bTokens (must be >100)
    uint256 public constant FUNDING_REWARD_SHARE = 10; // 10% of yield goes to the funding pool until investors are paid back

    address constant WETH_ADDRESS = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant PSM_ADDRESS = 0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5; // address of PSM token

    address public constant SINGLE_STAKING =
        0x314223E2fA375F972E159002Eb72A96301E99e22;
    address public constant DUAL_STAKING =
        0x31Fa38A6381e9d1f4770C73AB14a0ced1528A65E;
    address public constant esVKA = 0x95b3F9797077DDCa971aB8524b439553a220EB2A;

    bool public isActiveLP; // Will be set to true when funding phase ends
    bool public bTokenCreated; // flag for bToken deployment
    uint256 public fundingBalance; // sum of all PSM funding contributions
    uint256 public fundingRewardPool; // amount of PSM available for redemption against bTokens

    mapping(address portal => bool isRegistered) public registeredPortals;
    mapping(address portal => mapping(address asset => address vault))
        public vaults;
    mapping(address portal => mapping(address asset => uint256 pid))
        public poolID;

    // ============================================
    // ==                EVENTS                  ==
    // ============================================
    event LP_Activated(address indexed, uint256 fundingBalance);
    event ConvertExecuted(
        address indexed token,
        address indexed caller,
        address indexed recipient,
        uint256 amount
    );

    event FundingReceived(address indexed, uint256 amount);
    event FundingWithdrawn(address indexed, uint256 amount);
    event RewardsRedeemed(
        address indexed,
        uint256 amountBurned,
        uint256 amountReceived
    );

    event RewardsClaimed(address indexed portal, uint256 timeStamp);

    // ============================================
    // ==               MODIFIERS                ==
    // ============================================
    modifier activeLP() {
        if (!isActiveLP) {
            revert InactiveLP();
        }
        _;
    }

    modifier inactiveLP() {
        if (isActiveLP) {
            revert ActiveLP();
        }
        _;
    }

    modifier registeredPortal() {
        if (!registeredPortals[msg.sender]) {
            revert PortalNotRegistered();
        }
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }

    // ============================================
    // ==             LP FUNCTIONS               ==
    // ============================================
    /// @notice This function transfers PSM to a recipient address
    /// @dev Transfer an amount of PSM to a recipient
    /// @dev Can only be called by a registered address (Portal)
    /// @dev All critical logic is handled by the Portal, hence no additional checks
    /// @param _recipient The address that recieves the PSM
    /// @param _amount The amount of PSM send to the recipient
    function PSM_sendToPortalUser(
        address _recipient,
        uint256 _amount
    ) external registeredPortal {
        /// @dev Transfer PSM to the recipient
        IERC20(PSM_ADDRESS).transfer(_recipient, _amount);
    }

    /// @notice Function to add new Portals to the registry
    /// @dev Add new Portals to the registry. Portals can only be added, never removed
    /// @dev Only callable by owner to prevent malicious interactions
    /// @dev Function can override existing registries to fix potential integration errors
    /// @param _portal The address of the Portal to register
    /// @param _asset The address of the principal token of the Portal
    /// @param _vault The address of the staking Vault used by the Portal in the external protocol
    /// @param _pid The pool identifier of the staking Vault, relevant for the SingleStaking contract
    function registerPortal(
        address _portal,
        address _asset,
        address _vault,
        uint256 _pid
    ) external onlyOwner {
        ///@dev register Portal so that it can call protected functions
        registeredPortals[_portal] = true;

        /// @dev update the Portal asset mappings
        vaults[_portal][_asset] = _vault;
        poolID[_portal][_asset] = _pid;
    }

    /// @notice This function disables the ownership access
    /// @dev Set the zero address as owner
    /// @dev Callable by anyone after duration passed
    function removeOwner() external {
        if (block.timestamp < OWNER_EXPIRY_TIME) {
            revert OwnerNotExpired();
        }
        if (owner == address(0)) {
            revert OwnerRevoked();
        }

        owner = address(0);
    }

    // ============================================
    // ==      EXTERNAL PROTOCOL INTEGRATION     ==
    // ============================================
    /// @notice Deposit principal into the yield source
    /// @dev This function deposits principal tokens from a connected Portal into the external protocol
    /// @dev Receive and transfer tokens from the Portal to the external protocol via interface
    /// @param _asset The address of the asset to deposit
    /// @param _amount The amount of asset to deposit
    function depositToYieldSource(
        address _asset,
        uint256 _amount
    ) external registeredPortal {
        /// @dev Check that the withdraw timeLock is zero to protect stakers from griefing attack
        if (IWater(vaults[msg.sender][_asset]).lockTime() > 0) {
            revert TimeLockActive();
        }

        /// @dev Deposit tokens into Vault to receive Shares (WATER)
        /// @dev Approval of token spending is handled with a separate function to save gas
        uint256 depositShares = IWater(vaults[msg.sender][_asset]).deposit(
            _amount,
            address(this)
        );

        /// @dev Stake the Vault Shares into the staking contract using the pool identifier (pid)
        /// @dev Approval of token spending is handled with a separate function to save gas
        ISingleStaking(SINGLE_STAKING).deposit(
            poolID[msg.sender][_asset],
            depositShares
        );
    }

    /// @notice Withdraw principal from the yield source to the user
    /// @dev This function withdraws principal tokens from the external protocol
    /// @dev Transfer the tokens from the external protocol to a Portal user via integration interface
    /// @param _asset The address of the asset to withdraw
    /// @param _user The address of the user that will receive the withdrawn assets
    /// @param _amount The amount of assets to withdraw
    function withdrawFromYieldSource(
        address _asset,
        address _user,
        uint256 _amount
    ) external registeredPortal {
        /// @dev Calculate number of Vault Shares that equal the withdraw amount
        uint256 withdrawShares = IWater(vaults[msg.sender][_asset])
            .convertToShares(_amount);

        /// @dev Get the withdrawable assets from burning Vault Shares (consider rounding)
        uint256 withdrawAssets = IWater(vaults[msg.sender][_asset])
            .convertToAssets(withdrawShares);

        /// @dev Initialize helper variables for withdraw amount sanity check
        uint256 balanceBefore;
        uint256 balanceAfter;

        /// @dev Withdraw Vault Shares from Single Staking Contract
        ISingleStaking(SINGLE_STAKING).withdraw(
            poolID[msg.sender][_asset],
            withdrawShares
        );

        /// @dev Check if handling ETH, withdraw as WETH
        address tokenAdr = (_asset == address(0)) ? WETH_ADDRESS : _asset;

        /// @dev Withdraw the staked assets from Vault
        balanceBefore = IERC20(tokenAdr).balanceOf(address(this));
        IWater(vaults[msg.sender][_asset]).withdraw(
            withdrawAssets,
            address(this),
            address(this)
        );
        balanceAfter = IERC20(tokenAdr).balanceOf(address(this));

        /// @dev Sanity check on obtained amount from Vault
        _amount = balanceAfter - balanceBefore;

        /// @dev Transfer the obtained assets to the user
        /// @dev Convert WETH to ETH before sending
        if (_asset == address(0)) {
            IWETH(WETH_ADDRESS).withdrawTo(_user, _amount);
        } else {
            IERC20(tokenAdr).safeTransfer(_user, _amount);
        }
    }

    /// @notice Claim pending esVKA and USDC rewards, then restake esVKA
    /// @dev Claim protocol rewards for a specific Portal and restake esVKA
    /// @param _portal The address of a registered Portal
    function claimProtocolRewards(address _portal) external {
        /// @dev Get the asset of the Portal
        address asset = IPortalV2MultiAsset(_portal).PRINCIPAL_TOKEN_ADDRESS();

        /// @dev Claim esVKA rewards from staking the Vault Shares
        ISingleStaking(SINGLE_STAKING).deposit(poolID[_portal][asset], 0);

        uint256 esVKABalance = IERC20(esVKA).balanceOf(address(this));

        /// @dev Stake esVKA into the Dual Staking contract
        /// @dev Approval of token spending is handled with a separate function to save gas
        if (esVKABalance > 0) {
            IDualStaking(DUAL_STAKING).stake(esVKABalance, esVKA);
        }

        /// @dev Claim esVKA and USDC from DualStaking, stake the esVKA reward and receive USDC to contract
        IDualStaking(DUAL_STAKING).compound();

        /// @dev Emit the event that rewards have been claimed
        emit RewardsClaimed(_portal, block.timestamp);
    }

    /// @notice Internal function to get Vault profit before withdrawal fees
    /// @dev Get the surplus assets in the Vault excluding withdrawal fee
    /// @param _portal The address of a registered Portal
    function _getProfitOfPortal(
        address _portal
    ) private view returns (uint256 profitAsset, uint256 profitShares) {
        /// @dev Get the asset of the Portal
        IPortalV2MultiAsset portal = IPortalV2MultiAsset(_portal);
        address asset = portal.PRINCIPAL_TOKEN_ADDRESS();

        /// @dev Get the Vault shares owned by Portal
        uint256 sharesOwned = ISingleStaking(SINGLE_STAKING).getUserAmount(
            poolID[_portal][asset],
            address(this)
        );

        /// @dev Calculate the shares to be reserved for user withdrawals
        uint256 sharesDebt = IWater(vaults[_portal][asset]).convertToShares(
            portal.totalPrincipalStaked()
        );

        /// @dev Calculate the surplus shares owned by the Portal
        profitShares = (sharesOwned > sharesDebt)
            ? sharesOwned - sharesDebt
            : 0;

        /// @dev Calculate the net profit in assets
        profitAsset = IWater(vaults[_portal][asset]).convertToAssets(
            profitShares
        );
    }

    /// @notice View current net profit of a Vault used by a specific Portal
    /// @dev Get surplus assets in the Vault after deducting withdrawal fees
    /// @param _portal The address of a registered Portal
    function getProfitOfPortal(
        address _portal
    ) external view returns (uint256 profitOfPortal) {
        /// @dev Get the asset of the Portal
        address asset = IPortalV2MultiAsset(_portal).PRINCIPAL_TOKEN_ADDRESS();

        /// @dev Get the gross profit of the Vault
        (uint256 profit, ) = _getProfitOfPortal(_portal);

        /// @dev Calculate the net profit after withdrawal fees
        uint256 denominator = IWater(vaults[_portal][asset]).DENOMINATOR();
        uint256 withdrawalFee = IWater(vaults[_portal][asset]).withdrawalFees();

        profitOfPortal = (profit * (denominator - withdrawalFee)) / denominator;
    }

    /// @notice Withdraw the asset surplus of a Vault used by a specific Portal
    /// @dev Withdraw the asset surplus from Vault to contract
    /// @param _portal The address of a registered Portal
    function collectProfitOfPortal(address _portal) public {
        /// @dev Get the asset of the Portal
        address asset = IPortalV2MultiAsset(_portal).PRINCIPAL_TOKEN_ADDRESS();

        (uint256 profit, uint256 shares) = _getProfitOfPortal(_portal);

        /// @dev Check if there is profit to withdraw
        if (profit == 0 || shares == 0) {
            revert NoProfit();
        }

        /// @dev Withdraw the surplus Vault Shares from Single Staking Contract
        ISingleStaking(SINGLE_STAKING).withdraw(poolID[_portal][asset], shares);

        /// @dev Withdraw the profit Assets from the Vault to contract (collect WETH from ETH Vault)
        IWater(vaults[_portal][asset]).withdraw(
            profit,
            address(this),
            address(this)
        );
    }

    /// @notice Read the pending USDC protocol rewards earned by the LP contract
    /// @dev Get current USDC rewards pending from protocol fees
    function getPendingRewardsUSDC() external view returns (uint256 rewards) {
        rewards = IDualStaking(DUAL_STAKING).pendingRewardsUSDC(address(this));
    }

    /// @notice Read the timelock value of a Vault used by a specific Portal
    /// @dev Get the timelock of a Vault used by a Portal
    /// @param _portal The address of a registered Portal
    function getPortalVaultLockTime(
        address _portal
    ) external view returns (uint256 lockTime) {
        /// @dev Get the asset of the Portal
        IPortalV2MultiAsset portal = IPortalV2MultiAsset(_portal);
        address asset = portal.PRINCIPAL_TOKEN_ADDRESS();

        lockTime = IWater(vaults[_portal][asset]).lockTime();
    }

    /// @notice This function allows to update the Boost Multiplier to earn more esVKA
    /// @dev Update the Boost Multiplier of a Vault used by a specific Portal
    /// @param _portal The address of a registered Portal
    function updatePortalBoostMultiplier(address _portal) public {
        /// @dev Get the asset of the Portal
        IPortalV2MultiAsset portal = IPortalV2MultiAsset(_portal);
        address asset = portal.PRINCIPAL_TOKEN_ADDRESS();

        ISingleStaking(SINGLE_STAKING).updateBoostMultiplier(
            address(this),
            poolID[_portal][asset]
        );
    }

    /// @notice This function increases spending allowance for staking assets by Vaults
    /// @dev Increase the token spending allowance of assets by a staking Vault of a specific Portal
    /// @param _portal The address of a registered Portal
    function increaseAllowanceVault(address _portal) public {
        /// @dev Get the asset of the Portal
        address asset = IPortalV2MultiAsset(_portal).PRINCIPAL_TOKEN_ADDRESS();

        /// @dev Get the principal token address, WETH for ETH
        address tokenAdr = (asset == address(0)) ? WETH_ADDRESS : asset;

        /// @dev For ERC20 that require allowance to be 0 before increasing (e.g. USDT) add the following:
        /// IERC20(tokenAdr).approve(vaults[_portal][asset], 0);

        /// @dev Allow spending of Assets by the associated Vault
        IERC20(tokenAdr).safeIncreaseAllowance(
            vaults[_portal][asset],
            MAX_UINT
        );
    }

    /// @notice This function increases spending allowance for Vault Shares by the SingleStaking contract
    /// @dev Increase the token spending allowance of Vault Shares by the Single Staking contract
    /// @param _portal The address of a registered Portal
    function increaseAllowanceSingleStaking(address _portal) public {
        /// @dev Get the asset of the Portal
        address asset = IPortalV2MultiAsset(_portal).PRINCIPAL_TOKEN_ADDRESS();

        /// @dev Allow spending of Vault Shares of a Portal by the single staking contract
        IERC20(vaults[_portal][asset]).safeIncreaseAllowance(
            SINGLE_STAKING,
            MAX_UINT
        );
    }

    /// @notice This function increases spending allowance for esVKA by the DualStaking contract
    /// @dev Increase the token spending allowance of esVKA by the DualStaking contract
    function increaseAllowanceDualStaking() public {
        IERC20(esVKA).safeIncreaseAllowance(DUAL_STAKING, MAX_UINT);
    }

    // ============================================
    // ==              PSM CONVERTER             ==
    // ============================================
    /// @notice Handle the arbitrage conversion of tokens inside the contract for PSM tokens
    /// @dev This function handles the conversion of tokens inside the contract for PSM tokens
    /// @dev Collect rewards for funders and reallocate reward overflow to the LP (indirect)
    /// @dev Transfer the input (PSM) token from the caller to the contract
    /// @dev Transfer the specified output token from the contract to the caller
    /// @param _token The token to be obtained by the recipient
    /// @param _minReceived The minimum amount of tokens received
    function convert(
        address _token,
        address _recipient,
        uint256 _minReceived,
        uint256 _deadline
    ) external nonReentrant activeLP {
        /// @dev Check the validity of token and recipient addresses
        if (_token == PSM_ADDRESS || _recipient == address(0)) {
            revert InvalidAddress();
        }

        /// @dev Prevent zero value
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

        /// @dev initialize helper variables
        uint256 maxRewards = bToken.totalSupply();
        uint256 newRewards = (AMOUNT_TO_CONVERT * FUNDING_REWARD_SHARE) / 100;

        /// @dev Check if rewards must be added, adjust reward pool accordingly
        if (fundingRewardPool + newRewards >= maxRewards) {
            fundingRewardPool = maxRewards;
        } else {
            fundingRewardPool += newRewards;
        }

        /// @dev transfer PSM to the LP
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
    /// @dev This function activates the Virtual LP
    /// @dev Can only be called when the Virtual LP is inactive
    function activateLP() external inactiveLP {
        /// @dev Check that the funding phase is over and enough funding has been contributed
        if (block.timestamp < CREATION_TIME + FUNDING_PHASE_DURATION) {
            revert FundingPhaseOngoing();
        }
        if (fundingBalance < FUNDING_MIN_AMOUNT) {
            revert FundingInsufficient();
        }

        /// @dev Activate the Virtual LP
        isActiveLP = true;

        /// @dev Emit the activation event with the address of the contract and the funding balance
        emit LP_Activated(address(this), fundingBalance);
    }

    /// @notice Allow users to deposit PSM to fund the Virtual LP
    /// @dev This function allows users to deposit PSM tokens during the funding phase
    /// @dev The bToken must have been deployed via the contract in advance
    /// @dev Increase the fundingBalance tracker by the amount of PSM deposited
    /// @dev Transfer the PSM tokens from the user to the contract
    /// @dev Mint bTokens to the user
    /// @param _amount The amount of PSM to deposit
    function contributeFunding(uint256 _amount) external inactiveLP {
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

        /// @dev Emit the FundingReceived event with the user address and the mintable amount
        emit FundingReceived(msg.sender, mintableAmount);
    }

    /// @notice Allow users to burn bTokens to recover PSM funding before the Virtual LP is activated
    /// @dev This function allows users to burn bTokens during the funding phase of the contract to get back PSM
    /// @dev The bToken must have been deployed via the contract in advance
    /// @dev Decrease the fundingBalance tracker by the amount of PSM withdrawn
    /// @dev Burn the appropriate amount of bTokens from the caller
    /// @dev Transfer the PSM tokens from the contract to the caller
    /// @param _amountBtoken The amount of bTokens burned to withdraw PSM
    function withdrawFunding(uint256 _amountBtoken) external inactiveLP {
        /// @dev Prevent zero amount transaction
        if (_amountBtoken == 0) {
            revert InvalidAmount();
        }

        /// @dev Calculate the amount of PSM returned to the user
        uint256 withdrawAmount = (_amountBtoken * 100) /
            FUNDING_MAX_RETURN_PERCENT;

        /// @dev Decrease the fundingBalance tracker by the amount of PSM withdrawn
        fundingBalance -= withdrawAmount;

        /// @dev Burn bTokens from the user
        bToken.burnFrom(msg.sender, _amountBtoken);

        /// @dev Transfer the PSM tokens from the contract to the user
        IERC20(PSM_ADDRESS).transfer(msg.sender, withdrawAmount);

        /// @dev Emit an event that the user has withdrawn an amount of funding
        emit FundingWithdrawn(msg.sender, withdrawAmount);
    }

    /// @notice Calculate the current burn value of bTokens
    /// @dev Get the current burn value of any amount of bTokens
    /// @param _amount The amount of bTokens to burn
    /// @return burnValue The amount of PSM received when redeeming bTokens
    function getBurnValuePSM(
        uint256 _amount
    ) public view activeLP returns (uint256 burnValue) {
        /// @dev Calculate the minimum burn value
        uint256 minValue = (_amount * 100) / FUNDING_MAX_RETURN_PERCENT;

        /// @dev Calculate the time based burn value
        uint256 accruedValue = (_amount *
            (block.timestamp - CREATION_TIME) *
            FUNDING_APR) / (100 * SECONDS_PER_YEAR);

        /// @dev Calculate the maximum and current burn value
        uint256 maxValue = _amount;
        uint256 currentValue = minValue + accruedValue;

        burnValue = (currentValue < maxValue) ? currentValue : maxValue;
    }

    /// @notice Get the amount of bTokens that can be burned against the reward Pool
    /// @dev Calculate how many bTokens can be burned to redeem the entire reward Pool
    /// @return amountBurnable The amount of bTokens that can be redeemed for rewards
    function getBurnableBtokenAmount()
        public
        view
        activeLP
        returns (uint256 amountBurnable)
    {
        /// @dev Calculate the burn value of 1 full bToken in PSM
        /// @dev Add 1 WEI to handle rounding issue in the next step
        uint256 burnValueFullToken = getBurnValuePSM(1e18) + 1;

        /// @dev Calculate and return the amount of bTokens burnable
        /// @dev This will slightly underestimate because of the 1 WEI for reliability reasons
        amountBurnable = (fundingRewardPool * 1e18) / burnValueFullToken;
    }

    /// @notice This function allows users to redeem bTokens for PSM tokens
    /// @dev Burn bTokens to receive PSM when the Portal is active
    /// @dev Reduce the funding reward pool by the amount of PSM payable to the user
    /// @dev Burn the bTokens from the user wallet
    /// @dev Transfer the PSM tokens to the user
    /// @param _amount The amount of bTokens to burn
    function burnBtokens(uint256 _amount) external {
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
    /// @notice Deploy the bToken of the Virtual LP
    /// @dev This function deploys the bToken of this contract and takes ownership
    /// @dev Must be called before the Virtual LP is activated
    /// @dev Can only be called once
    function create_bToken() external inactiveLP {
        if (bTokenCreated) {
            revert TokenExists();
        }

        /// @dev Update the token creation flag to prevent future calls.
        bTokenCreated = true;

        /// @dev Set the token name and symbol
        string memory name = "bVaultkaLending";
        string memory symbol = "bVKA-L";

        /// @dev Deploy the token and update the related storage variable so that other functions can work.
        bToken = new MintBurnToken(name, symbol);
        bTokenAddress = address(bToken);
    }

    receive() external payable {}

    fallback() external payable {}
}
