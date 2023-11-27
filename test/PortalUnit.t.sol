// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {Portal} from "../src/Portal.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MintBurnToken} from "./mocks/MintToken.sol";

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//                                                Done by mahdiRostami
//                              I have availability for smart contract security audits and testing.
// Reach out to me on [Twitter](https://twitter.com/0xmahdirostami) or [GitHub](https://github.com/0xmahdirostami/audits).
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

contract PortalTest is Test {
    // addresses
    address private constant PSM_ADDRESS =
        0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5;
    address private constant PRINCIPAL_TOKEN_ADDRESS =
        0x4307fbDCD9Ec7AEA5a1c2958deCaa6f316952bAb;
    address private constant USDCe = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
    // Pools
    address payable private constant HLP_STAKING =
        payable(0xbE8f8AF5953869222eA8D39F1Be9d03766010B1C);
    address private constant HMX_STAKING =
        0x92E586B8D4Bf59f4001604209A292621c716539a;
    // rewarders
    address private constant HLP_PROTOCOL_REWARDER =
        0x665099B3e59367f02E5f9e039C3450E31c338788;
    address private constant HLP_EMISSIONS_REWARDER =
        0x6D2c18B559C5343CB0703bB55AADB5f22152cC32;
    address private constant HMX_PROTOCOL_REWARDER =
        0xB698829C4C187C85859AD2085B24f308fC1195D3;
    address private constant HMX_EMISSIONS_REWARDER =
        0x94c22459b145F012F1c6791F2D729F7a22c44764;
    address private constant HMX_DRAGONPOINTS_REWARDER =
        0xbEDd351c62111FB7216683C2A26319743a06F273;

    // constant values
    uint256 constant _FUNDING_PHASE_DURATION = 432000;
    uint256 constant _FUNDING_EXCHANGE_RATIO = 550;
    uint256 constant _FUNDING_REWARD_RATE = 10;
    uint256 constant _TERMINAL_MAX_LOCK_DURATION = 157680000;
    uint256 constant _AMOUNT_TO_CONVERT = 100000 * 1e18;
    uint256 private constant SECONDS_PER_YEAR = 31536000; // seconds in a 365 day year
    uint256 public maxLockDuration = 7776000; // 7776000 starting value for maximum allowed lock duration of user´s balance in seconds (90 days)
    uint256 private constant _DECIMALS = 1e18;
    uint256 private constant _TRADE_TIMELOCK = 60;

    // portal
    Portal public portal;

    // time
    uint256 timestamp;
    uint256 timeAfterActivating;

    // prank addresses
    address Alice = address(0x01);
    address Bob = address(0x02);
    address Karen = address(0x03);

    // tokens
    MintBurnToken bToken = new MintBurnToken("BT", "BT");
    MintBurnToken eToken = new MintBurnToken("ET", "ET");

    // ============================================
    // ==               CUSTOM EVENT             ==
    // ============================================

    // --- Events related to the funding phase ---
    event PortalActivated(address indexed, uint256 fundingBalance);
    event FundingReceived(address indexed, uint256 amount);
    event RewardsRedeemed(
        address indexed,
        uint256 amountBurned,
        uint256 amountReceived
    );

    // --- Events related to internal exchange PSM vs. portalEnergy ---
    event PortalEnergyBuyExecuted(address indexed, uint256 amount);
    event PortalEnergySellExecuted(address indexed, uint256 amount);

    // --- Events related to minting and burning portalEnergyToken ---
    event PortalEnergyMinted(
        address indexed,
        address recipient,
        uint256 amount
    );
    event PortalEnergyBurned(
        address indexed,
        address recipient,
        uint256 amount
    );

    // --- Events related to staking & unstaking ---
    event TokenStaked(address indexed user, uint256 amountStaked);
    event TokenUnstaked(address indexed user, uint256 amountUnstaked);
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
        uint256 portalEnergy,
        uint256 availableToWithdraw
    );

    // ============================================
    // ==          CUSTOM ERROR MESSAGES         ==
    // ============================================
    error DeadlineExpired();
    error PortalNotActive();
    error PortalAlreadyActive();
    error AccountDoesNotExist();
    error InsufficientToWithdraw();
    error InsufficientStake();
    error InsufficientPEtokens();
    error InsufficientBalance();
    error InvalidOutput();
    error InvalidInput();
    error InvalidToken();
    error FundingPhaseOngoing();
    error DurationLocked();
    error DurationCannotIncrease();
    error TradeTimelockActive();
    error FailedToSendNativeToken();

    function setUp() public {
        portal = new Portal(
            _FUNDING_PHASE_DURATION,
            _FUNDING_EXCHANGE_RATIO,
            _FUNDING_REWARD_RATE,
            PRINCIPAL_TOKEN_ADDRESS,
            _DECIMALS,
            PSM_ADDRESS,
            address(bToken),
            address(eToken),
            _TERMINAL_MAX_LOCK_DURATION,
            _AMOUNT_TO_CONVERT,
            _TRADE_TIMELOCK
        );

        // creation time
        timestamp = block.timestamp;
        timeAfterActivating = timestamp + _FUNDING_PHASE_DURATION;

        // bToken, ENERGY Token
        bToken.transferOwnership(address(portal));
        eToken.transferOwnership(address(portal));

        // PSM TOKEN, PT TOKEN
        deal(PSM_ADDRESS, Alice, 1e30, true);
        deal(PSM_ADDRESS, Bob, 1e30, true);
        deal(PSM_ADDRESS, address(this), 1e30, true);
        deal(PRINCIPAL_TOKEN_ADDRESS, Alice, 1e30, true);
        deal(PRINCIPAL_TOKEN_ADDRESS, Bob, 1e30, true);
        deal(PRINCIPAL_TOKEN_ADDRESS, address(this), 1e30, true);
        deal(USDCe, address(this), 1e30, true);
    }

    /////////////////////////////////////////////////////////// helper
    function help_fundAndActivate() internal {
        vm.startPrank(Alice);
        IERC20(PSM_ADDRESS).approve(address(portal), 1e18);
        portal.contributeFunding(1e18);
        vm.startPrank(Bob);
        IERC20(PSM_ADDRESS).approve(address(portal), 1e18);
        portal.contributeFunding(1e18);
        vm.warp(timeAfterActivating);
        portal.activatePortal();
        vm.stopPrank();
    }

    function help_stake() internal {
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        portal.stake(1e18);
        vm.startPrank(Bob);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        portal.stake(1e18);
        vm.stopPrank();
    }

    // ---------------------------------------------------
    // -----------------funding&burnBtokens---------------
    // ---------------------------------------------------

    // reverts
    function testRevert_funding0Amount() public {
        vm.startPrank(Alice);
        IERC20(PSM_ADDRESS).approve(address(portal), 1e5);
        vm.expectRevert(InvalidInput.selector);
        portal.contributeFunding(0);
    }

    function testRevert_fundingActivePortal() public {
        help_fundAndActivate();
        vm.expectRevert(PortalAlreadyActive.selector);
        portal.contributeFunding(1e5);
    }

    function testRevert_burnBtokensPortalNotActive() public {
        vm.expectRevert(PortalNotActive.selector);
        portal.burnBtokens(1e5);
    }

    function testRevert_burnBtokens0Amount() public {
        help_fundAndActivate();
        vm.expectRevert(InvalidInput.selector);
        portal.burnBtokens(0);
    }

    // events
    function testEvent_funding() public {
        vm.startPrank(Alice);
        IERC20(PSM_ADDRESS).approve(address(portal), 1e5);
        vm.expectEmit(address(portal));
        emit FundingReceived(address(Alice), 1e5 * 10);
        portal.contributeFunding(1e5);
    }

    function testEvent_burnBtokens() public {
        help_fundAndActivate();
        vm.startPrank(Alice);
        IERC20(bToken).approve(address(portal), 1e5);
        vm.expectEmit(address(portal));
        emit RewardsRedeemed(address(Alice), 1e5, 0);
        portal.burnBtokens(1e5);
    }

    // funding
    function test_funding() public {
        vm.startPrank(Alice);
        assertEq(portal.fundingBalance(), 0);
        assertEq(bToken.totalSupply(), 0);
        assertEq(bToken.balanceOf(address(Alice)), 0);
        IERC20(PSM_ADDRESS).approve(address(portal), 2e5);
        portal.contributeFunding(1e5);
        assertEq(portal.fundingBalance(), 1e5);
        assertEq(bToken.totalSupply(), 1e5 * 10);
        assertEq(bToken.balanceOf(address(Alice)), 1e5 * 10);
        portal.contributeFunding(1e5);
        assertEq(portal.fundingBalance(), 1e5 * 2);
        assertEq(bToken.totalSupply(), 1e5 * 2 * 10);
        assertEq(bToken.balanceOf(address(Alice)), 1e5 * 2 * 10);
    }

    // burning
    function test_burnBtokens() public {
        help_fundAndActivate();

        IERC20(USDCe).transfer(address(portal), 1);
        IERC20(PSM_ADDRESS).approve(address(portal), _AMOUNT_TO_CONVERT);
        portal.convert(USDCe, 0, timeAfterActivating + 61); // 1e22 funding balance

        vm.startPrank(Alice);
        IERC20(bToken).approve(address(portal), 1e19);

        uint256 portalPSMBalanceBefore = IERC20(PSM_ADDRESS).balanceOf(
            address(portal)
        );
        uint256 alicePSMBalanceBefore = IERC20(PSM_ADDRESS).balanceOf(Alice);
        uint256 totalSupplyBefore = IERC20(bToken).totalSupply();
        uint256 bTokenBalanceBefore = IERC20(bToken).balanceOf(Alice);

        portal.burnBtokens(1e19);

        uint256 fundingRewardPoolBalanceAfter = portal.fundingRewardPool();
        uint256 portalPSMBalanceAfter = IERC20(PSM_ADDRESS).balanceOf(
            address(portal)
        );
        uint256 alicePSMBalanceAfter = IERC20(PSM_ADDRESS).balanceOf(Alice);
        uint256 totalSupplyAfter = IERC20(bToken).totalSupply();
        uint256 bTokenBalanceAfter = IERC20(bToken).balanceOf(Alice);

        assertEq(fundingRewardPoolBalanceAfter, 5e21); // 1e19 * 1e22 / 2e19 = 5e21
        assertEq(portalPSMBalanceBefore - portalPSMBalanceAfter, 5e21);
        assertEq(alicePSMBalanceAfter - alicePSMBalanceBefore, 5e21);
        assertEq(totalSupplyBefore - totalSupplyAfter, 1e19);
        assertEq(bTokenBalanceBefore - bTokenBalanceAfter, 1e19);
    }

    // ---------------------------------------------------
    // --------------------activating---------------------
    // ---------------------------------------------------

    // reverts
    function testRevert_activatePortalTwice() public {
        vm.warp(timestamp + 432001);
        portal.activatePortal();
        vm.expectRevert(PortalAlreadyActive.selector);
        portal.activatePortal();
    }

    function testRevert_beforeFundingPhaseEnded() public {
        vm.expectRevert(FundingPhaseOngoing.selector);
        portal.activatePortal();
    }

    // events
    function testEvent_activateProtal() public {
        vm.warp(timestamp + 432001);
        vm.expectEmit(address(portal));
        emit PortalActivated(address(portal), 0);
        portal.activatePortal();
    }

    // activating
    function test_activating() public {
        vm.startPrank(Alice);
        IERC20(PSM_ADDRESS).approve(address(portal), 1e5);
        portal.contributeFunding(1e5);
        assertEq(portal.isActivePortal(), false);
        assertEq(portal.fundingMaxRewards(), 0);
        assertEq(portal.constantProduct(), 0);
        assertEq(portal.fundingBalance(), 1e5);
        vm.warp(timestamp + 432001);
        portal.activatePortal();
        assertEq(portal.isActivePortal(), true);
        assertEq(portal.fundingMaxRewards(), 1e5 * 10);
        assertEq(portal.constantProduct(), 18181818); //1e5*1e5/550
        assertEq(portal.fundingBalance(), 1e5);
    }

    // ---------------------------------------------------
    // ------------------maxlockduraion-------------------
    // ---------------------------------------------------

    // reverts
    function testRevert_newTimeLessThanMaxlockduraion() external {
        vm.warp(timestamp);
        vm.expectRevert(DurationCannotIncrease.selector);
        portal.updateMaxLockDuration();
    }

    function testRevert_lockDurationNotUpdateable() external {
        vm.warp(timestamp + 365 * 6 days);
        portal.updateMaxLockDuration();
        vm.expectRevert(DurationLocked.selector);
        portal.updateMaxLockDuration();
    }

    // updateMaxLockDuration
    function test_updateMaxLockDuration() external {
        assertEq(portal.maxLockDuration(), maxLockDuration);
        vm.warp(timestamp + maxLockDuration + 1);
        portal.updateMaxLockDuration();
        assertEq(
            portal.maxLockDuration(),
            2 * (timestamp + maxLockDuration + 1 - portal.CREATION_TIME())
        );
        vm.warp(timestamp + 31536000 * 10);
        portal.updateMaxLockDuration();
        assertEq(portal.maxLockDuration(), _TERMINAL_MAX_LOCK_DURATION);
    }

    // ---------------------------------------------------
    // ---------------PortalEnergyToken-------------------
    // ---------------------------------------------------

    // reverts
    function testRevert_mintPortalEnergyToken0Amount() external {
        vm.expectRevert(InvalidInput.selector);
        portal.mintPortalEnergyToken(Alice, 0);
    }

    function testRevert_mintPortalEnergyTokenFor0Address() external {
        vm.expectRevert(InvalidInput.selector);
        portal.mintPortalEnergyToken(address(0), 1);
    }

    function testRevert_mintPortalEnergyTokenAccountDoesNotExist() external {
        vm.expectRevert(AccountDoesNotExist.selector);
        portal.mintPortalEnergyToken(Karen, 1);
    }

    function testRevert_mintPortalEnergyTokenInsufficientBalance() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectRevert(InsufficientBalance.selector);
        portal.mintPortalEnergyToken(Alice, 1e18);
    }

    function testRevert_burnPrtalEnergyToken0Amount() external {
        vm.expectRevert(InvalidInput.selector);
        portal.burnPortalEnergyToken(Alice, 0);
    }

    function testRevert_burnPortalEnergyTokenForAccountDoesNotExist() external {
        vm.expectRevert(AccountDoesNotExist.selector);
        portal.burnPortalEnergyToken(Karen, 1);
    }

    function testRevert_burnPortalEnergyTokenInsufficientBalance() external {
        help_fundAndActivate();
        help_stake();
        vm.expectRevert(InsufficientBalance.selector);
        portal.burnPortalEnergyToken(Alice, 1e18);
    }

    // events
    function testEvent_mintPortalEnergyToken() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectEmit(address(portal));
        emit PortalEnergyMinted(Alice, Karen, 246575342465753424); //1e18*maxlock/year = 246,575,342,465,753,424
        portal.mintPortalEnergyToken(Karen, 246575342465753424);
    }

    function testEvent_burnPortalEnergyToken() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        portal.mintPortalEnergyToken(Karen, 246575342465753424);
        vm.startPrank(Karen);
        eToken.approve(address(portal), 246575342465753424);
        vm.expectEmit(address(portal));
        emit PortalEnergyBurned(Karen, Alice, 246575342465753424);
        portal.burnPortalEnergyToken(Alice, 246575342465753424);
    }

    // mintPortalEnergyToken
    function test_mintPortalEnergyToken() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        portal.mintPortalEnergyToken(Karen, 246575342465753424);
        assertEq(eToken.balanceOf(Karen), 246575342465753424);
        (, , , , , uint256 portalEnergy, ) = portal.getUpdateAccount(Alice, 0);
        assertEq(portalEnergy, 0);
    }

    // burnPortalEnergyToken
    function test_burnPortalEnergyToken() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        portal.mintPortalEnergyToken(Karen, 246575342465753424);
        vm.startPrank(Karen);
        eToken.approve(address(portal), 246575342465753424);
        portal.burnPortalEnergyToken(Alice, 246575342465753424);
        assertEq(eToken.balanceOf(Karen), 0);
        (, , , , , uint256 portalEnergy, ) = portal.getUpdateAccount(Alice, 0);
        assertEq(portalEnergy, 246575342465753424);
    }

    // ---------------------------------------------------
    // ---------------staking and unstaking---------------
    // ---------------------------------------------------

    // reverts
    function testRevert_stakePortalNotActive() external {
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        vm.expectRevert(PortalNotActive.selector);
        portal.stake(1e5);
    }

    function testRevert_stake0Amount() external {
        help_fundAndActivate();
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        vm.expectRevert(InvalidInput.selector);
        portal.stake(0);
    }

    function testRevert_unStakeExistingAccount() external {
        vm.startPrank(Alice);
        vm.expectRevert(AccountDoesNotExist.selector);
        portal.unstake(1e5);
    }

    function testRevert_unStake0Amount() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectRevert(InvalidInput.selector);
        portal.unstake(0);
    }

    function testRevert_unStakeMoreThanStaked() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectRevert(InsufficientToWithdraw.selector);
        portal.unstake(1e19);
    }

    function testRevert_forceunStakeExistingAccount() external {
        vm.startPrank(Alice);
        vm.expectRevert(AccountDoesNotExist.selector);
        portal.forceUnstakeAll();
    }

    // events
    function testEvent_stake() external {
        help_fundAndActivate();
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        vm.expectEmit(address(portal));
        emit StakePositionUpdated(
            address(Alice),
            block.timestamp,
            maxLockDuration,
            1e5,
            (1e5 * maxLockDuration) / SECONDS_PER_YEAR,
            (1e5 * maxLockDuration) / SECONDS_PER_YEAR,
            1e5
        );
        portal.stake(1e5);
    }

    function testEvent_reStake() external {
        help_fundAndActivate();
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        vm.expectEmit(address(portal));
        emit StakePositionUpdated(
            address(Alice),
            block.timestamp,
            maxLockDuration,
            1e5,
            (1e5 * maxLockDuration) / SECONDS_PER_YEAR, //100000*7776000/31536000=24657
            (1e5 * maxLockDuration) / SECONDS_PER_YEAR, //24657
            1e5
        );
        portal.stake(1e5);
        vm.expectEmit(address(portal));
        emit StakePositionUpdated(
            address(Alice),
            block.timestamp, //lastUpdateTime 1701103606
            maxLockDuration, //maxLockDuration 7776000
            1e5 * 2, //stakedBalance 200000
            (1e5 * 2 * maxLockDuration) / SECONDS_PER_YEAR, //maxStakeDebt 49315
            (1e5 * 2 * maxLockDuration) / SECONDS_PER_YEAR - 1, //portalEnergy 49314
            199995
        ); //availableToWithdraw 199995
        portal.stake(1e5);
    }

    function testEvent_unStake() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectEmit(address(portal));
        emit StakePositionUpdated(
            address(Alice),
            block.timestamp,
            maxLockDuration,
            0,
            0,
            0,
            0
        );
        portal.unstake(1e18);
    }

    function testEvent_unStakePartially() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectEmit(address(portal));
        emit StakePositionUpdated(
            address(Alice),
            block.timestamp,
            maxLockDuration,
            5e17,
            (5e17 * maxLockDuration) / SECONDS_PER_YEAR,
            (5e17 * maxLockDuration) / SECONDS_PER_YEAR,
            5e17
        );
        portal.unstake(5e17);
    }

    function testEvent_forceunStake() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectEmit(address(portal));
        emit StakePositionUpdated(
            address(Alice),
            block.timestamp,
            maxLockDuration,
            0,
            0,
            0,
            0
        );
        portal.forceUnstakeAll();
    }

    function testEvent_forceunStakeWithExtraEnergy() external {
        help_fundAndActivate();
        help_stake();
        vm.warp(timeAfterActivating + 60);
        vm.startPrank(Alice);
        vm.expectEmit(address(portal));
        emit StakePositionUpdated(
            address(Alice),
            block.timestamp,
            maxLockDuration,
            0,
            0, //
            1902587519025, //1902587519025 = 60 * 1e18 / 31536000
            0
        );
        portal.unstake(1e18);
    }

    // stake
    function test_stake() external {
        help_fundAndActivate();
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        portal.stake(1e5);
        (
            address user,
            uint256 lastUpdateTime,
            uint256 lastMaxLockDuration,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,
            uint256 availableToWithdraw
        ) = portal.getUpdateAccount(address(Alice), 0);
        assertEq(user, address(Alice));
        assertEq(lastUpdateTime, block.timestamp);
        assertEq(lastMaxLockDuration, maxLockDuration);
        assertEq(stakedBalance, 1e5);
        assertEq(
            maxStakeDebt,
            (1e5 * maxLockDuration * 1e18) / (SECONDS_PER_YEAR * _DECIMALS)
        );
        assertEq(
            portalEnergy,
            (1e5 * maxLockDuration * 1e18) / (SECONDS_PER_YEAR * _DECIMALS)
        );
        assertEq(availableToWithdraw, 1e5);
    }

    function test_reStake() external {
        help_fundAndActivate();
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        portal.stake(1e5);
        portal.stake(1e5);
        (
            address user,
            uint256 lastUpdateTime,
            uint256 lastMaxLockDuration,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,
            uint256 availableToWithdraw
        ) = portal.getUpdateAccount(address(Alice), 0);
        assertEq(user, address(Alice));
        assertEq(lastUpdateTime, block.timestamp);
        assertEq(lastMaxLockDuration, maxLockDuration);
        assertEq(stakedBalance, 2 * 1e5);
        assertEq(maxStakeDebt, (2 * 1e5 * maxLockDuration) / SECONDS_PER_YEAR);
        assertEq(
            portalEnergy,
            ((2 * 1e5 * maxLockDuration) / SECONDS_PER_YEAR) - 1
        ); // beacuse of there are two division for portal energy
        assertEq(availableToWithdraw, 199995); // beacuse of portalEnergy
    }

    function test_unStake() external {
        help_fundAndActivate();
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        portal.stake(1e5);
        portal.unstake(1e5);
        (
            address user,
            uint256 lastUpdateTime,
            uint256 lastMaxLockDuration,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,
            uint256 availableToWithdraw
        ) = portal.getUpdateAccount(address(Alice), 0);
        assertEq(user, address(Alice));
        assertEq(lastUpdateTime, block.timestamp);
        assertEq(lastMaxLockDuration, maxLockDuration);
        assertEq(stakedBalance, 0);
        assertEq(maxStakeDebt, 0);
        assertEq(portalEnergy, 0);
        assertEq(availableToWithdraw, 0);
    }

    function test_unStakeAvailableToWithdraw() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        portal.mintPortalEnergyToken(Alice, 10000000);
        (
            address user,
            uint256 lastUpdateTime,
            uint256 lastMaxLockDuration,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,
            uint256 availableToWithdraw
        ) = portal.getUpdateAccount(address(Alice), 0);
        portal.unstake(availableToWithdraw);
        (
            user,
            lastUpdateTime,
            lastMaxLockDuration,
            stakedBalance,
            maxStakeDebt,
            portalEnergy,
            availableToWithdraw
        ) = portal.getUpdateAccount(address(Alice), 0);
        assertEq(
            (stakedBalance * maxLockDuration) / SECONDS_PER_YEAR,
            maxStakeDebt
        );
        assertEq(portalEnergy, 0);
        assertEq(availableToWithdraw, 0);
    }

    function test_forceunStake() external {
        help_fundAndActivate();
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        portal.stake(1e5);
        portal.forceUnstakeAll();
        (
            address user,
            uint256 lastUpdateTime,
            uint256 lastMaxLockDuration,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,
            uint256 availableToWithdraw
        ) = portal.getUpdateAccount(address(Alice), 0);
        assertEq(user, address(Alice));
        assertEq(lastUpdateTime, block.timestamp);
        assertEq(lastMaxLockDuration, maxLockDuration);
        assertEq(stakedBalance, 0);
        assertEq(maxStakeDebt, 0);
        assertEq(portalEnergy, 0);
        assertEq(availableToWithdraw, 0);
    }

    function test_forceunStakeWithMintToken() external {
        help_fundAndActivate();
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        portal.stake(1e5);
        portal.mintPortalEnergyToken(Alice, 24657);
        IERC20(eToken).approve(address(portal), 24657);
        portal.forceUnstakeAll();
        (
            address user,
            uint256 lastUpdateTime,
            uint256 lastMaxLockDuration,
            uint256 stakedBalance,
            uint256 maxStakeDebt,
            uint256 portalEnergy,
            uint256 availableToWithdraw
        ) = portal.getUpdateAccount(address(Alice), 0);
        assertEq(user, address(Alice));
        assertEq(lastUpdateTime, block.timestamp);
        assertEq(lastMaxLockDuration, maxLockDuration);
        assertEq(stakedBalance, 0);
        assertEq(maxStakeDebt, 0);
        assertEq(portalEnergy, 0);
        assertEq(availableToWithdraw, 0);
    }

    // ---------------------------------------------------
    // ---------------buy and sell energy token-----------
    // ---------------------------------------------------

    // revert
    function testRevert_buyPortalEnergynotexitaccount() external {
        vm.expectRevert(AccountDoesNotExist.selector);
        portal.buyPortalEnergy(0, 0, 0);
    }

    function testRevert_buyPortalEnergy0Amount() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectRevert(InvalidInput.selector);
        portal.buyPortalEnergy(0, 0, 0);
    }

    function testRevert_buyPortalEnergy0MinReceived() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectRevert(InvalidInput.selector);
        portal.buyPortalEnergy(1, 0, 0);
    }

    function testRevert_buyPortalEnergyAfterDeadline() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectRevert(DeadlineExpired.selector);
        portal.buyPortalEnergy(1, 1, block.timestamp - 1);
    }

    function testRevert_buyPortalEnergyTradeTimelockActive() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        portal.sellPortalEnergy(1e10, 1e10, block.timestamp);
        IERC20(PSM_ADDRESS).approve(address(portal), 1e10);
        vm.expectRevert(TradeTimelockActive.selector);
        portal.buyPortalEnergy(1e10, 1, block.timestamp);
    }

    function testRevert_buyPortalEnergyAmountReceived() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        IERC20(PSM_ADDRESS).approve(address(portal), 1e10);
        vm.expectRevert(InvalidOutput.selector);
        portal.buyPortalEnergy(1e10, 1e18, block.timestamp);
    }

    function testRevert_sellPortalEnergynotexitaccount() external {
        vm.expectRevert(AccountDoesNotExist.selector);
        portal.sellPortalEnergy(0, 0, 0);
    }

    function testRevert_sellPortalEnergy0Amount() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectRevert(InvalidInput.selector);
        portal.sellPortalEnergy(0, 0, 0);
    }

    function testRevert_sellPortalEnergy0MinReceived() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectRevert(InvalidInput.selector);
        portal.sellPortalEnergy(1, 0, 0);
    }

    function testRevert_sellPortalEnergyAfterDeadline() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectRevert(DeadlineExpired.selector);
        portal.sellPortalEnergy(1, 1, block.timestamp - 1);
    }

    function testRevert_sellPortalEnergyTradeTimelockActive() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        IERC20(PSM_ADDRESS).approve(address(portal), 1e10);
        portal.buyPortalEnergy(1e10, 1, block.timestamp);
        vm.expectRevert(TradeTimelockActive.selector);
        portal.sellPortalEnergy(1e10, 1e10, block.timestamp);
    }

    function testRevert_sellPortalEnergyInsufficientBalance() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectRevert(InsufficientBalance.selector);
        portal.sellPortalEnergy(10e18, 1e18, block.timestamp);
    }

    function testRevert_sellPortalEnergyAmountReceived() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectRevert(InvalidOutput.selector);
        portal.sellPortalEnergy(1e10, 1e18, block.timestamp);
    }

    // event
    function testEvent_buyPortalEnergy() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        IERC20(PSM_ADDRESS).approve(address(portal), 1e15);
        vm.expectEmit(address(portal));
        emit PortalEnergyBuyExecuted(Alice, 1817273181591); //reserve 0 = 2e18 // reserve1= 2e18*2e18/550/2e18 = 7e33/2e18 = 3636363636363636 // amountReceived = 1e15 * 3636363636363636 / 1e15 + 2e18 = 1817273181591
        portal.buyPortalEnergy(1e15, 1e5, block.timestamp);
    }

    function testEvent_sellPortalEnergy() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectEmit(address(portal));
        emit PortalEnergySellExecuted(Alice, 1e15); //reserve 0 = 2e18 // reserve1= 2e18*2e18/550/2e18 = 7e33/2e18 = 3636363636363636 // amountReceived = 1e15 * 2e18 / 1e15 + 3636363636363636 = 431372549019607876
        portal.sellPortalEnergy(1e15, 1e5, block.timestamp);
    }

    // buy and sell
    function test_buyPortalEnergy() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        IERC20(PSM_ADDRESS).approve(address(portal), 1e15);
        (, , , , , uint256 portalEnergyBefore, ) = portal.getUpdateAccount(
            address(Alice),
            0
        );
        uint256 PSMBalanceAliceBefore = IERC20(PSM_ADDRESS).balanceOf(Alice);
        uint256 PSMBalancePortalBefore = IERC20(PSM_ADDRESS).balanceOf(
            address(portal)
        );
        //reserve 0 = 2e18 // reserve1= 2e18*2e18/550/2e18 = 7e33/2e18 = 3636363636363636 // amountReceived = 1e15 * 3636363636363636 / 1e15 + 2e18 = 1817273181591
        portal.buyPortalEnergy(1e15, 1e5, block.timestamp);
        (, , , , , uint256 portalEnergyAfter, ) = portal.getUpdateAccount(
            address(Alice),
            0
        );
        uint256 PSMBalanceAliceAfter = IERC20(PSM_ADDRESS).balanceOf(Alice);
        uint256 PSMBalancePortalAfter = IERC20(PSM_ADDRESS).balanceOf(
            address(portal)
        );
        assertEq(portalEnergyAfter - portalEnergyBefore, 1817273181591);
        assertEq(PSMBalanceAliceBefore - PSMBalanceAliceAfter, 1e15);
        assertEq(PSMBalancePortalAfter - PSMBalancePortalBefore, 1e15);
    }

    function test_sellPortalEnergy() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        (, , , , , uint256 portalEnergyBefore, ) = portal.getUpdateAccount(
            address(Alice),
            0
        );
        uint256 PSMBalanceAliceBefore = IERC20(PSM_ADDRESS).balanceOf(Alice);
        uint256 PSMBalancePortalBefore = IERC20(PSM_ADDRESS).balanceOf(
            address(portal)
        );
        //reserve 0 = 2e18 // reserve1= 2e18*2e18/550/2e18 = 7e33/2e18 = 3636363636363636 // amountReceived = 1e15 * 2e18 / 1e15 + 3636363636363636 = 431372549019607876
        portal.sellPortalEnergy(1e15, 1e5, block.timestamp);
        (, , , , , uint256 portalEnergyAfter, ) = portal.getUpdateAccount(
            address(Alice),
            0
        );
        uint256 PSMBalanceAliceAfter = IERC20(PSM_ADDRESS).balanceOf(Alice);
        uint256 PSMBalancePortalAfter = IERC20(PSM_ADDRESS).balanceOf(
            address(portal)
        );
        assertEq(portalEnergyBefore - portalEnergyAfter, 1e15);
        assertEq(
            PSMBalanceAliceAfter - PSMBalanceAliceBefore,
            431372549019607876
        );
        assertEq(
            PSMBalancePortalBefore - PSMBalancePortalAfter,
            431372549019607876
        );
    }

    // ---------------------------------------------------
    // --------------------compound-----------------------
    // ---------------------------------------------------

    // event
    function testEvent_compound() external {
        help_fundAndActivate();
        help_stake();

        address[] memory pools = new address[](2);
        pools[0] = HLP_STAKING;
        pools[1] = HMX_STAKING;
        address[][] memory rewarders = new address[][](2);
        rewarders[0] = new address[](2);
        rewarders[0][0] = HLP_PROTOCOL_REWARDER;
        rewarders[0][1] = HLP_EMISSIONS_REWARDER;
        rewarders[1] = new address[](3);
        rewarders[1][0] = HMX_PROTOCOL_REWARDER;
        rewarders[1][1] = HMX_EMISSIONS_REWARDER;
        rewarders[1][2] = HMX_DRAGONPOINTS_REWARDER;

        vm.expectEmit(address(portal));
        emit RewardsClaimed(pools, rewarders, timeAfterActivating);
        portal.claimRewardsHLPandHMX();
    }

    // compound
    function test_compound() external {
        help_fundAndActivate();
        help_stake();
        vm.warp(timeAfterActivating + 60);
        uint256 balanceBefore = IERC20(USDCe).balanceOf(address(portal));
        portal.claimRewardsHLPandHMX();
        uint256 balanceAfter = IERC20(USDCe).balanceOf(address(portal));
        assertGt(balanceAfter, balanceBefore);
    }

    function test_compoundManual() external {
        help_fundAndActivate();
        help_stake();
        vm.warp(timeAfterActivating + 60);
        uint256 balanceBefore = IERC20(USDCe).balanceOf(address(portal));

        address[] memory pools = new address[](2);
        pools[0] = HLP_STAKING;
        pools[1] = HMX_STAKING;
        address[][] memory rewarders = new address[][](2);
        rewarders[0] = new address[](2);
        rewarders[0][0] = HLP_PROTOCOL_REWARDER;
        rewarders[0][1] = HLP_EMISSIONS_REWARDER;
        rewarders[1] = new address[](3);
        rewarders[1][0] = HMX_PROTOCOL_REWARDER;
        rewarders[1][1] = HMX_EMISSIONS_REWARDER;
        rewarders[1][2] = HMX_DRAGONPOINTS_REWARDER;

        portal.claimRewardsManual(pools, rewarders);
        uint256 balanceAfter = IERC20(USDCe).balanceOf(address(portal));
        assertGt(balanceAfter, balanceBefore);
    }

    // ---------------------------------------------------
    // ---------------------convert-----------------------
    // ---------------------------------------------------

    // revert
    function testRevert_convertPSMToken() external {
        vm.expectRevert(InvalidToken.selector);
        portal.convert(PSM_ADDRESS, 0, 0);
    }

    function testRevert_convertAfterDeadLine() external {
        vm.expectRevert(DeadlineExpired.selector);
        portal.convert(USDCe, 0, block.timestamp - 1);
    }

    function testRevert_convertContractBalance0() external {
        vm.expectRevert(InvalidOutput.selector);
        portal.convert(USDCe, 0, block.timestamp);
    }

    function testRevert_convertContractBalanceFewerThanMinReceived() external {
        IERC20(USDCe).transfer(address(portal), 1);
        vm.expectRevert(InvalidOutput.selector);
        portal.convert(USDCe, 2, block.timestamp);
    }

    // convert
    function test_convertUCDCe() external {
        help_fundAndActivate();
        help_stake();
        vm.warp(timeAfterActivating + 60);
        portal.claimRewardsHLPandHMX();
        IERC20(PSM_ADDRESS).approve(address(portal), _AMOUNT_TO_CONVERT);

        uint256 balanceBeforePSM = IERC20(PSM_ADDRESS).balanceOf(
            address(portal)
        );
        uint256 balanceBeforeUSDCe = IERC20(USDCe).balanceOf(address(portal));
        uint256 fundingRewardPoolBefore = portal.fundingRewardPool();
        uint256 fundingRewardsCollectedBefore = portal
            .fundingRewardsCollected();

        portal.convert(address(USDCe), 0, timeAfterActivating + 61);

        uint256 balanceAfterPSM = IERC20(PSM_ADDRESS).balanceOf(
            address(portal)
        );
        uint256 balanceAfterUSDCe = IERC20(USDCe).balanceOf(address(portal));
        uint256 fundingRewardPoolAfter = portal.fundingRewardPool();
        uint256 fundingRewardsCollectedAfter = portal.fundingRewardsCollected();

        assertEq(balanceAfterPSM - balanceBeforePSM, _AMOUNT_TO_CONVERT);
        assertEq(balanceBeforeUSDCe - balanceAfterUSDCe, 1);
        assertEq(
            fundingRewardPoolAfter - fundingRewardPoolBefore,
            10000 * 1e18
        );
        assertEq(
            fundingRewardsCollectedAfter - fundingRewardsCollectedBefore,
            10000 * 1e18
        );
    }

    function test_convertUCDCeTotalSupply0() external {
        help_fundAndActivate();
        help_stake();
        vm.warp(timeAfterActivating + 60);
        portal.claimRewardsHLPandHMX();
        vm.startPrank(Alice);
        uint256 amount = bToken.balanceOf(address(Alice));
        bToken.approve(address(portal), amount);
        portal.burnBtokens(amount);
        vm.startPrank(Bob);
        amount = bToken.balanceOf(address(Bob));
        bToken.approve(address(portal), amount);
        portal.burnBtokens(amount);
        vm.stopPrank();

        assertEq(bToken.totalSupply(), 0);

        IERC20(PSM_ADDRESS).approve(address(portal), _AMOUNT_TO_CONVERT);

        uint256 fundingRewardPoolBefore = portal.fundingRewardPool();
        uint256 fundingRewardsCollectedBefore = portal
            .fundingRewardsCollected();

        portal.convert(address(USDCe), 0, timeAfterActivating + 61);

        uint256 fundingRewardPoolAfter = portal.fundingRewardPool();
        uint256 fundingRewardsCollectedAfter = portal.fundingRewardsCollected();

        assertEq(fundingRewardPoolAfter - fundingRewardPoolBefore, 0);
        assertEq(
            fundingRewardsCollectedAfter - fundingRewardsCollectedBefore,
            0
        );
    }

    function test_convertUCDCeFundingMaxRewards() external {
        help_fundAndActivate();
        help_stake();
        // funded 2e18 -> fundingMaxRewards = 2e19
        IERC20(PSM_ADDRESS).approve(address(portal), _AMOUNT_TO_CONVERT * 2);
        assertEq(portal.fundingRewardsCollected(), 0);
        assertEq(portal.fundingRewardPool(), 0);
        IERC20(USDCe).transfer(address(portal), 1);
        portal.convert(address(USDCe), 0, timeAfterActivating + 1);
        assertEq(portal.fundingRewardsCollected(), 10000 * 1e18);
        assertEq(portal.fundingRewardPool(), 10000 * 1e18);
        IERC20(USDCe).transfer(address(portal), 1);
        portal.convert(address(USDCe), 0, timeAfterActivating + 2);
        assertEq(portal.fundingRewardsCollected(), 10000 * 1e18);
        assertEq(portal.fundingRewardPool(), 10000 * 1e18);
    }

    function test_convertETH() external {
        help_fundAndActivate();
        help_stake();
        payable(address(portal)).transfer(1 ether);
        vm.startPrank(Alice);
        IERC20(PSM_ADDRESS).approve(address(portal), _AMOUNT_TO_CONVERT);
        uint256 balanceBeforeETH = address(portal).balance;
        uint256 balanceBeforePSM = IERC20(PSM_ADDRESS).balanceOf(
            address(portal)
        );
        portal.convert(address(0), 0, timeAfterActivating + 60);
        uint256 balanceAfterETH = address(portal).balance;
        uint256 balanceAfterPSM = IERC20(PSM_ADDRESS).balanceOf(
            address(portal)
        );
        assertEq(balanceBeforeETH - balanceAfterETH, 1 ether);
        assertEq(balanceAfterPSM - balanceBeforePSM, _AMOUNT_TO_CONVERT);
    }

    // ---------------------------------------------------
    // ---------------------accept ETH--------------------
    // ---------------------------------------------------
    function test_acceptETH() external {
        assertEq(address(portal).balance, 0);
        payable(address(portal)).transfer(1 ether);
        assertEq(address(portal).balance, 1 ether);
    }

    function test_acceptETHwithData() external {
        assertEq(address(portal).balance, 0);
        (bool sent, ) = address(portal).call{value: 1 ether}("0xPortal");
        require(sent);
        assertEq(address(portal).balance, 1 ether);
    }

    // ---------------------------------------------------
    // ---------------------view--------------------------
    // ---------------------------------------------------
    function test_quoteBuyPortalEnergy() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        uint256 amount = portal.quoteBuyPortalEnergy(1e15);
        assertEq(amount, 1817273181591);
    }

    function test_quoteSellPortalEnergy() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        uint256 amount = portal.quoteSellPortalEnergy(1e15);
        assertEq(amount, 431372549019607876);
    }

    function test_quoteforceUnstakeAll() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice); //246575342465753424
        portal.mintPortalEnergyToken(Alice, 123287671232876712); //123287671232876712
        uint256 amount = portal.quoteforceUnstakeAll(Alice);
        assertEq(amount, 123287671232876712);
    }

    function test_getBalanceOfToken() external {
        assertEq(portal.getBalanceOfToken(PSM_ADDRESS), 0);
        IERC20(PSM_ADDRESS).transfer(address(portal), 1e5);
        assertEq(portal.getBalanceOfToken(PSM_ADDRESS), 1e5);
    }

    function test_getPendingRewards() external {
        help_fundAndActivate();
        help_stake();
        vm.warp(timeAfterActivating + 60);
        assertGt(portal.getPendingRewards(HLP_PROTOCOL_REWARDER), 0);
        assertGt(portal.getPendingRewards(HLP_EMISSIONS_REWARDER), 0);
    }
}
