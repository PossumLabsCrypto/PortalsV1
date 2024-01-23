// SPDX-License-Identifier: GPL-2.0-only
pragma solidity =0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IWater} from "./interfaces/IWater.sol";
import {ISingleStaking} from "./interfaces/ISingleStaking.sol";
import {IDualStaking} from "./interfaces/IDualStaking.sol";

contract IntegrationTest is Ownable {
    constructor() {}

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

    mapping(uint256 pid => uint256 staked) stakeBalance;

    // ==============================================
    // Staking & Unstaking
    // ==============================================

    // Helper function to get the PID of a staking token
    function getPidOfVaultShare(
        address _token
    ) public view returns (uint256 pid) {
        uint256 length = ISingleStaking(SINGLE_STAKING).poolLength();

        for (uint256 i = 0; i < length; ++i) {
            // Get the token address of the current pid
            address tokenCheck = ISingleStaking(SINGLE_STAKING)
                .getPoolTokenAddress(i);

            // save and return the pid of the input token
            if (tokenCheck == _token) {
                pid = i;
            }
        }
    }

    // Deposit
    function deposit(address _token, uint256 _amount) public onlyOwner {
        // transfer token from user to contract
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        // TO DO change the IWater interface dynamically according to input token
        IERC20(_token).safeIncreaseAllowance(USDCE_WATER, _amount);
        uint256 depositShares = IWater(USDCE_WATER).deposit(
            _amount,
            address(this)
        );

        uint256 pid = getPidOfVaultShare(USDCE_WATER);

        IERC20(USDCE_WATER).safeIncreaseAllowance(
            SINGLE_STAKING,
            depositShares
        );
        ISingleStaking(SINGLE_STAKING).deposit(pid, depositShares);

        stakeBalance[pid] += depositShares;
    }

    // Withdrawal
    function withdraw(address _token, uint256 _amount) public onlyOwner {
        // Require that the amount of withdrawn assets is less or equal to user´s staked assets
        // IWater(USDCE_WATER).convertToShares(_amount);

        // TO DO change the interface input dynamically
        // AT THIS POINT THE USDCE_WATER IS NOT IN CONTRACT
        uint256 withdrawShares = IWater(USDCE_WATER).withdraw(
            _amount,
            msg.sender,
            address(this)
        );

        // NOTICE: At this point, the contract will pay out less shares over time, perma-locking the other shares.
        // The contract must know how many shares it can withdraw as profit so that it can be arbitraged

        uint256 pid = getPidOfVaultShare(_token);

        ISingleStaking(SINGLE_STAKING).withdraw(pid, withdrawShares);

        stakeBalance[pid] -= withdrawShares;
    }

    // ==============================================
    // Claiming Rewards
    // ==============================================

    function claimAll() public onlyOwner {
        ISingleStaking(SINGLE_STAKING).claimAll();

        uint256 esVKABalance = IERC20(esVKA).balanceOf(address(this));

        if (esVKABalance > 0) {
            IERC20(esVKA).safeIncreaseAllowance(DUAL_STAKING, esVKABalance);
            IDualStaking(DUAL_STAKING).stake(esVKABalance, esVKA);
        }

        IDualStaking(DUAL_STAKING).compound();
    }

    function claimRewardsForStakePid(uint256 _pid) external onlyOwner {
        ISingleStaking(SINGLE_STAKING).deposit(_pid, 0);

        uint256 esVKABalance = IERC20(esVKA).balanceOf(address(this));

        if (esVKABalance > 0) {
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
