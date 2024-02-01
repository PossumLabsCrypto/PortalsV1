// SPDX-License-Identifier: GPL-2.0-only
pragma solidity =0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWater} from "./interfaces/IWater.sol";
import {ISingleStaking} from "./interfaces/ISingleStaking.sol";
import {IDualStaking} from "./interfaces/IDualStaking.sol";

interface IWETH {
    function deposit() external payable;

    function withdraw(uint256) external;
}

error InsufficientStakeBalance();
error IncorrectAmountNativeETH();
error FailedToSendNativeToken();
error TimeLockActive();
error InvalidAmount();
error NoProfit();
error NativeTokenNotAllowed();

contract SingleIntegrationTest {
    constructor() {}

    // ==============================================
    // PARAMETERS
    // ==============================================
    using SafeERC20 for IERC20;
    uint256 private constant MAX_UINT =
        115792089237316195423570985008687907853269984665640564039457584007913129639935;

    // CHANGE THIS PER ASSET -> CONSTRUCTOR
    address public constant PRINCIPAL_TOKEN_ADDRESS =
        0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant VAULT_ADDRESS =
        0x9045ae36f963b7184861BDce205ea8B08913B48c;
    uint256 public constant POOL_ID = 5;
    // ------------------------------------

    address public constant WETH_ADDRESS =
        0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    address private constant SINGLE_STAKING =
        0x314223E2fA375F972E159002Eb72A96301E99e22;
    address private constant DUAL_STAKING =
        0x31Fa38A6381e9d1f4770C73AB14a0ced1528A65E;
    address private constant esVKA = 0x95b3F9797077DDCa971aB8524b439553a220EB2A;

    uint256 public totalPrincipalStaked;

    // ==============================================
    // Staking & Unstaking
    // ==============================================
    /// @dev Stake user assets
    function stake(uint256 _amount) public payable {
        /// @dev Check that the unstaked amount is greater than zero
        if (_amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Convert native ETH to WETH for contract
        /// @dev This section must sit before using _amount elsewhere
        if (PRINCIPAL_TOKEN_ADDRESS == address(0)) {
            /// @dev Wrap ETH into WETH
            _amount = msg.value;
            IWETH(WETH_ADDRESS).deposit{value: _amount}();
        }

        /// @dev If not native ETH, transfer ERC20 token to contract
        if (PRINCIPAL_TOKEN_ADDRESS != address(0)) {
            /// @dev Prevent contract from receiving ETH when using ERC20 token
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

        /// @dev Increase tracker of staked principal
        totalPrincipalStaked += _amount;

        _depositToYieldSource(_amount);
    }

    /// @notice Deposit principal into the yield source
    /// @dev This function deposits principal tokens from the Portal into the external protocol
    /// @dev Approve the amount of tokens to be transferred
    /// @dev Transfer the tokens from the Portal to the external protocol via interface
    function _depositToYieldSource(uint256 _amount) private {
        /// @dev Check that timeLock is zero to protect from griefing attack
        if (IWater(VAULT_ADDRESS).lockTime() > 0) {
            revert TimeLockActive();
        }

        /// @dev Deposit Token into Vault to receive Shares (WATER)
        // Approval of token spending is handled with separate function to save gas
        uint256 depositShares = IWater(VAULT_ADDRESS).deposit(
            _amount,
            address(this)
        );

        /// @dev Stake the Vault Shares into the staking contract using the pool identifier (pid)
        /// @dev Approval of token spending is handled with separate function to save gas
        ISingleStaking(SINGLE_STAKING).deposit(POOL_ID, depositShares);
    }

    //.........
    // ........
    // .......
    // Withdrawing user assets
    function unstake(uint256 _amount) public {
        /// @dev Require that the unstaked amount is greater than zero
        if (_amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Update the global tracker of staked principal
        totalPrincipalStaked -= _amount;

        /// @dev Withdraw the assets from external Protocol and send to user
        _withdrawFromYieldSource(msg.sender, _amount);
    }

    function _withdrawFromYieldSource(address _user, uint256 _amount) private {
        /// @dev Calculate number of Vault Shares that equal the withdraw amount
        uint256 withdrawShares = IWater(VAULT_ADDRESS).convertToShares(_amount);

        /// @dev Get the withdrawable assets from burning Vault Shares (consider rounding)
        uint256 withdrawAssets = IWater(VAULT_ADDRESS).convertToAssets(
            withdrawShares
        );

        /// @dev Initialize helper variables for withdraw amount sanity check
        uint256 balanceBefore;
        uint256 balanceAfter;

        /// @dev Withdraw Vault Shares from Single Staking Contract
        ISingleStaking(SINGLE_STAKING).withdraw(POOL_ID, withdrawShares);

        /// @dev Check if handling native ETH
        if (PRINCIPAL_TOKEN_ADDRESS == address(0)) {
            /// @dev Withdraw the staked ETH from Vault
            balanceBefore = address(this).balance;
            IWater(VAULT_ADDRESS).withdrawETH(withdrawAssets);
            balanceAfter = address(this).balance;

            /// @dev Sanity check on obtained amount from Vault
            _amount = balanceAfter - balanceBefore;

            /// @dev Transfer the obtained ETH to the user
            (bool sent, ) = payable(_user).call{value: _amount}("");
            if (!sent) {
                revert FailedToSendNativeToken();
            }
        }

        /// @dev Check if handling ERC20 token
        if (PRINCIPAL_TOKEN_ADDRESS != address(0)) {
            /// @dev Withdraw the staked assets from Vault
            balanceBefore = IERC20(PRINCIPAL_TOKEN_ADDRESS).balanceOf(
                address(this)
            );
            IWater(VAULT_ADDRESS).withdraw(
                withdrawAssets,
                address(this),
                address(this)
            );
            balanceAfter = IERC20(PRINCIPAL_TOKEN_ADDRESS).balanceOf(
                address(this)
            );

            /// @dev Sanity check on obtained amount from Vault
            _amount = balanceAfter - balanceBefore;

            /// @dev Transfer the obtained assets to the user
            IERC20(PRINCIPAL_TOKEN_ADDRESS).safeTransfer(_user, _amount);
        }
    }

    // ==============================================
    // Claiming Rewards from esVKA Staking & Water
    // ==============================================
    /// @dev Claim pending esVKA and USDC rewards, restake esVKA
    function claimRewards() external {
        // Claim esVKA rewards from staking the asset
        ISingleStaking(SINGLE_STAKING).deposit(POOL_ID, 0);

        uint256 esVKABalance = IERC20(esVKA).balanceOf(address(this));

        // Stake esVKA
        // Approval of token spending is handled with separate function to save gas
        if (esVKABalance > 0) {
            IDualStaking(DUAL_STAKING).stake(esVKABalance, esVKA);
        }

        // Claim esVKA and USDC from DualStaking, stake the esVKA reward and send USDC to contract
        IDualStaking(DUAL_STAKING).compound();
    }

    /// @dev Withdraws the asset surplus from Vault to Portal
    function collectProfitOfAssetVault() public {
        (uint256 profit, uint256 shares) = _getProfitOfAssetVault();

        /// @dev Check if there is profit to withdraw
        if (profit == 0 || shares == 0) {
            revert NoProfit();
        }

        /// @dev Withdraw the surplus Vault Shares from Single Staking Contract
        ISingleStaking(SINGLE_STAKING).withdraw(POOL_ID, shares);

        /// @dev Withdraw the profit Assets from the Vault to contract (collects WETH from ETH Vault)
        IWater(VAULT_ADDRESS).withdraw(profit, address(this), address(this));
    }

    /// @dev Get current USDC rewards pending from protocol fees
    function getPendingRewardsUSDC() external view returns (uint256 rewards) {
        rewards = IDualStaking(DUAL_STAKING).pendingRewardsUSDC(address(this));
    }

    /// @dev Get the surplus assets in the Vault excluding withdrawal fee for internal use
    function _getProfitOfAssetVault()
        private
        view
        returns (uint256 profitAsset, uint256 profitShares)
    {
        /// @dev Get the Vault shares owned by Portal
        uint256 sharesOwned = ISingleStaking(SINGLE_STAKING).getUserAmount(
            POOL_ID,
            address(this)
        );

        /// @dev Calculate the shares to be reserved for user withdrawals
        uint256 sharesDebt = IWater(VAULT_ADDRESS).convertToShares(
            totalPrincipalStaked
        );

        /// @dev Calculate the surplus shares owned by the Portal
        profitShares = (sharesOwned > sharesDebt)
            ? sharesOwned - sharesDebt
            : 0;

        /// @dev Calculate the net profit in assets
        profitAsset = IWater(VAULT_ADDRESS).convertToAssets(profitShares);
    }

    /// @dev Show the surplus assets in the Vault after deducting withdrawal fees
    function getProfitOfAssetVault()
        external
        view
        returns (uint256 profitAsset)
    {
        (uint256 profit, ) = _getProfitOfAssetVault();

        uint256 denominator = IWater(VAULT_ADDRESS).DENOMINATOR();
        uint256 withdrawalFee = IWater(VAULT_ADDRESS).withdrawalFees();

        profitAsset = (profit * (denominator - withdrawalFee)) / denominator;
    }

    // ==============================================
    // HELPER FUNCTIONS
    // ==============================================
    function getVaultLockTime() public view returns (uint256 lockTime) {
        lockTime = IWater(VAULT_ADDRESS).lockTime();
    }

    // Increase the token spending allowance of Assets by the associated Vault (WATER)
    function increaseAllowanceVault() public {
        // Allow spending of Assets by the associated Vault
        address tokenAdr = (PRINCIPAL_TOKEN_ADDRESS == address(0))
            ? WETH_ADDRESS
            : PRINCIPAL_TOKEN_ADDRESS;
        IERC20(tokenAdr).safeIncreaseAllowance(VAULT_ADDRESS, MAX_UINT);
    }

    // Increase the token spending allowance of Vault Shares by the Single Staking contract
    function increaseAllowanceSingleStaking() public {
        // Allow spending of Vault shares of an asset by the single staking contract
        IERC20(VAULT_ADDRESS).safeIncreaseAllowance(SINGLE_STAKING, MAX_UINT);
    }

    // Increase the token spending allowance of esVKA by the Dual Staking contract
    function increaseAllowanceDualStaking() public {
        // Allow spending of esVKA by the Dual Staking contract
        IERC20(esVKA).safeIncreaseAllowance(DUAL_STAKING, MAX_UINT);
    }

    function updateBoostMultiplier() public {
        ISingleStaking(SINGLE_STAKING).updateBoostMultiplier(
            address(this),
            POOL_ID
        );
    }

    receive() external payable {}

    fallback() external payable {}
}
