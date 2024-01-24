// SPDX-License-Identifier: GPL-2.0-only
pragma solidity =0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IWater} from "./interfaces/IWater.sol";
import {ISingleStaking} from "./interfaces/ISingleStaking.sol";
import {IDualStaking} from "./interfaces/IDualStaking.sol";

error InsufficientStakeBalance();

contract IntegrationTest is Ownable {
    constructor() {
        sharesAddresses[USDCE_ADDRESS] = USDCE_WATER;
        sharesAddresses[USDC_ADDRESS] = USDC_WATER;
        sharesAddresses[ARB_ADDRESS] = ARB_WATER;
        sharesAddresses[WBTC_ADDRESS] = WBTC_WATER;
        sharesAddresses[WETH_ADDRESS] = WETH_WATER;
        sharesAddresses[address(0)] = WETH_WATER;
        sharesAddresses[LINK_ADDRESS] = LINK_WATER;
    }

    // ==============================================
    // PARAMETERS
    // ==============================================
    using SafeERC20 for IERC20;

    address private constant USDCE_ADDRESS =
        0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
    address private constant USDC_ADDRESS =
        0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant ARB_ADDRESS =
        0x912CE59144191C1204E64559FE8253a0e49E6548;
    address private constant WBTC_ADDRESS =
        0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address private constant WETH_ADDRESS =
        0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address private constant LINK_ADDRESS =
        0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;

    address private constant esVKA = 0x95b3F9797077DDCa971aB8524b439553a220EB2A;

    address private constant SINGLE_STAKING =
        0x314223E2fA375F972E159002Eb72A96301E99e22;
    address private constant DUAL_STAKING =
        0x31Fa38A6381e9d1f4770C73AB14a0ced1528A65E;

    address private constant USDCE_WATER =
        0x806e8538FC05774Ea83d9428F778E423F6492475;
    address private constant USDC_WATER =
        0x9045ae36f963b7184861BDce205ea8B08913B48c;
    address private constant ARB_WATER =
        0x175995159ca4F833794C88f7873B3e7fB12Bb1b6;
    address private constant WBTC_WATER =
        0x4e9e41Bbf099fE0ef960017861d181a9aF6DDa07;
    address private constant WETH_WATER =
        0x8A98929750e6709Af765F976c6bddb5BfFE6C06c;
    address private constant LINK_WATER =
        0xFF614Dd6fC857e4daDa196d75DaC51D522a2ccf7;

    mapping(address asset => address vaultShare) public sharesAddresses;

    // ==============================================
    // Staking & Unstaking
    // ==============================================

    // Helper function to get the PID of a vault share token (WATER)
    function getPidOfAsset(address _asset) public view returns (uint256 pid) {
        address vaultShare = sharesAddresses[_asset];
        uint256 length = ISingleStaking(SINGLE_STAKING).poolLength();

        for (uint256 i = 0; i < length; ++i) {
            // Get the token address of the current pid
            address tokenCheck = ISingleStaking(SINGLE_STAKING)
                .getPoolTokenAddress(i);

            // save and return the pid of the input token
            if (tokenCheck == vaultShare) {
                pid = i;
            }
        }
    }

    // Deposit -- MUST ALLOW NATIVE ETH STAKING
    function deposit(address _token, uint256 _amount) public onlyOwner {
        // transfer token from user to contract
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        // Change the IWater interface dynamically according to input token
        address shareAddress = sharesAddresses[_token];

        // Allow spending token and deposit into Vault to receive Shares (WATER)
        IERC20(_token).safeIncreaseAllowance(shareAddress, _amount);
        uint256 depositShares = IWater(shareAddress).deposit(
            _amount,
            address(this)
        );

        // Allow spending of shares by the staking contract
        IERC20(shareAddress).safeIncreaseAllowance(
            SINGLE_STAKING,
            depositShares
        );

        // Stake the Vault Shares into the staking contract using the pool identifier (pid)
        uint256 pid = getPidOfAsset(_token);
        ISingleStaking(SINGLE_STAKING).deposit(pid, depositShares);

        // increase tracker of user and global stakes
    }

    // Withdrawal of asset token --> must allow for withdrawing native ETH
    function withdraw(address _token, uint256 _amount) public onlyOwner {
        // Change the IWater interface dynamically according to input token
        address shareAddress = sharesAddresses[_token];
        uint256 withdrawShares = IWater(shareAddress).convertToShares(_amount);

        uint256 pid = getPidOfAsset(_token);

        // Check if user has enough shares/assets to withdraw

        // Reduce tracker of user and global stakes

        // ISSUE: At this point, the contract will pay out less shares over time, perma-locking the remainders
        // The contract must know how many shares are principal and how many are profit
        // Track user´s debt in asset and total asset debt of all users
        // convert total debt of all users into shares on each call -> this is principal
        // rest of shares are profit
        // profit can be redeemed and arbitraged -> This changes the convert() function
        ISingleStaking(SINGLE_STAKING).withdraw(pid, withdrawShares);

        // Withdraw the staked assets and adjust for rounding errors from Vault
        uint256 balanceBefore = IERC20(_token).balanceOf(address(this));
        IWater(shareAddress).withdraw(_amount, address(this), address(this));
        uint256 balanceAfter = IERC20(_token).balanceOf(address(this));

        _amount = balanceAfter - balanceBefore;

        // Transfer the obtained assets to the user
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    // ==============================================
    // Claiming Rewards from esVKA Staking
    // ==============================================

    // Read current USDC.E rewards pending
    function getPendingRewardsUSDC() external view returns (uint256 rewards) {
        rewards = IDualStaking(DUAL_STAKING).pendingRewardsUSDC(address(this));
    }

    // WORKS
    function claimAll() public onlyOwner {
        ISingleStaking(SINGLE_STAKING).claimAll();

        uint256 esVKABalance = IERC20(esVKA).balanceOf(address(this));

        if (esVKABalance > 0) {
            IERC20(esVKA).safeIncreaseAllowance(DUAL_STAKING, esVKABalance);
            IDualStaking(DUAL_STAKING).stake(esVKABalance, esVKA);
        }

        IDualStaking(DUAL_STAKING).compound();
    }

    // WORKS
    function claimRewardsForAsset(address _asset) external onlyOwner {
        uint256 pid = getPidOfAsset(_asset);
        ISingleStaking(SINGLE_STAKING).deposit(pid, 0);

        uint256 esVKABalance = IERC20(esVKA).balanceOf(address(this));

        if (esVKABalance > 0) {
            IERC20(esVKA).safeIncreaseAllowance(DUAL_STAKING, esVKABalance);
            IDualStaking(DUAL_STAKING).stake(esVKABalance, esVKA);
        }

        IDualStaking(DUAL_STAKING).compound();
    }

    // ==============================================
    // EMERGENCY
    // ==============================================
    function rescueToken(address _token) public onlyOwner {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(msg.sender, balance);
    }
}
