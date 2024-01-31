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
error NotOwner();

contract IntegrationTest {
    constructor() {
        OWNER = msg.sender;
    }

    // ==============================================
    // PARAMETERS
    // ==============================================
    using SafeERC20 for IERC20;
    uint256 private constant MAX_UINT =
        115792089237316195423570985008687907853269984665640564039457584007913129639935;
    address public immutable OWNER;
    uint256 public acceptedTimeLock = 1000; // THIS MUST BE SET TO 0 IN REAL USE
    address private constant WETH_ADDRESS =
        0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // in case native ETH is handled

    address private constant USDCE_ADDRESS =
        0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
    address private constant USDCE_WATER =
        0x806e8538FC05774Ea83d9428F778E423F6492475;
    uint256 public constant POOL_ID = 4;

    address private constant SINGLE_STAKING =
        0x314223E2fA375F972E159002Eb72A96301E99e22;
    address private constant DUAL_STAKING =
        0x31Fa38A6381e9d1f4770C73AB14a0ced1528A65E;

    address private constant esVKA = 0x95b3F9797077DDCa971aB8524b439553a220EB2A;

    uint256 public assetsStaked;

    // ==============================================
    // MODIFIERS
    // ==============================================
    modifier onlyOwner() {
        if (msg.sender != OWNER) {
            revert NotOwner();
        }
        _;
    }

    // ==============================================
    // Staking & Unstaking
    // ==============================================
    // Deposit
    function deposit(address _token, uint256 _amount) public payable onlyOwner {
        // Check if timeLock is zero to protect from griefing attack
        if (IWater(USDCE_WATER).lockTime() > acceptedTimeLock) {
            revert TimeLockActive();
        }

        // Convert native ETH to WETH for contract
        if (_token == address(0)) {
            // Deposit ETH into WETH
            _amount = msg.value;
            IWETH(WETH_ADDRESS).deposit{value: _amount}();
        }

        // Transfer ERC20 token to contract
        if (_token != address(0)) {
            // transfer token from user to contract
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        }

        // increase tracker of staked assets
        assetsStaked += _amount;

        // Allow spending token and deposit into Vault to receive Shares (WATER)
        // Approval of token spending is handled with separate function to save gas
        uint256 depositShares = IWater(USDCE_WATER).deposit(
            _amount,
            address(this)
        );

        // Stake the Vault Shares into the staking contract using the pool identifier (pid)
        // Approval of token spending is handled with separate function to save gas
        ISingleStaking(SINGLE_STAKING).deposit(POOL_ID, depositShares);
    }

    // Withdrawing user assets
    function withdraw(address _token, uint256 _amount) public onlyOwner {
        // Calculate number of Vault Shares that equal the withdraw amount
        uint256 withdrawShares = IWater(USDCE_WATER).convertToShares(_amount);

        // Withdraw Vault Shares from Single Staking Contract
        ISingleStaking(SINGLE_STAKING).withdraw(POOL_ID, withdrawShares);

        // Get the withdrawable assets from burning Vault Shares (avoid rounding issue)
        uint256 withdrawAssets = IWater(USDCE_WATER).convertToAssets(
            withdrawShares
        );

        // Reduce tracker of user and global stakes
        assetsStaked -= _amount;

        // ISSUE: At this point, the contract will pay out less shares over time, perma-locking the remainders
        // The contract must know how many shares are principal and how many are profit
        // Track user´s debt in asset and total asset debt of all users
        // convert total debt of all users into shares on each call -> this is principal
        // rest of shares are profit
        // profit can be redeemed and arbitraged -> This changes the convert() function

        // helper variables for withdraw amount sanity check
        uint256 balanceBefore;
        uint256 balanceAfter;

        // Check if handling native ETH
        if (_token == address(0)) {
            // Withdraw the staked ETH from Vault
            balanceBefore = address(this).balance;
            IWater(USDCE_WATER).withdrawETH(withdrawAssets);
            balanceAfter = address(this).balance;

            // Sanity check on obtained amount from Vault
            _amount = balanceAfter - balanceBefore;

            // Transfer the obtained ETH to the user
            (bool sent, ) = payable(msg.sender).call{value: _amount}("");
            if (!sent) {
                revert FailedToSendNativeToken();
            }
        }

        // Check if handling ERC20 tokens
        if (_token != address(0)) {
            // Withdraw the staked assets from Vault
            balanceBefore = IERC20(_token).balanceOf(address(this));
            IWater(USDCE_WATER).withdraw(
                withdrawAssets,
                address(this),
                address(this)
            );
            balanceAfter = IERC20(_token).balanceOf(address(this));

            // Sanity check on obtained amount from Vault
            _amount = balanceAfter - balanceBefore;

            // Transfer the obtained assets to the user
            IERC20(_token).safeTransfer(msg.sender, _amount);
        }
    }

    // ==============================================
    // Claiming Rewards from esVKA Staking
    // ==============================================

    // Read current USDC.E rewards pending
    function getPendingRewardsUSDC() external view returns (uint256 rewards) {
        rewards = IDualStaking(DUAL_STAKING).pendingRewardsUSDC(address(this));
    }

    // Claim pending esVKA and USDC rewards
    function claimRewards() external onlyOwner {
        // Claim esVKA rewards from staking the asset
        ISingleStaking(SINGLE_STAKING).deposit(POOL_ID, 0);

        uint256 esVKABalance = IERC20(esVKA).balanceOf(address(this));

        // Increase allowance and stake esVKA
        if (esVKABalance > 0) {
            IDualStaking(DUAL_STAKING).stake(esVKABalance, esVKA);
        }

        // Claim esVKA and USDC from DualStaking, stake the esVKA reward and send USDC to contract
        IDualStaking(DUAL_STAKING).compound();
    }

    // ==============================================
    // HELPER FUNCTIONS
    // ==============================================
    function getVaultLockTime() public view returns (uint256 lockTime) {
        lockTime = IWater(USDCE_WATER).lockTime();
    }

    // Increase the token spending allowance of Assets by the associated Vault (WATER)
    function increaseAllowanceVault() public {
        // Allow spending of Assets by the associated Vault
        IERC20(USDCE_ADDRESS).safeIncreaseAllowance(USDCE_WATER, MAX_UINT);
    }

    // Increase the token spending allowance of Vault Shares by the Single Staking contract
    function increaseAllowanceSingleStaking() public {
        // Allow spending of Vault shares of an asset by the single staking contract
        IERC20(USDCE_WATER).safeIncreaseAllowance(SINGLE_STAKING, MAX_UINT);
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
