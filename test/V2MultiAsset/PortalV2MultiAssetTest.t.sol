// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {PortalV2MultiAsset} from "src/V2MultiAsset/PortalV2MultiAsset.sol";
import {MintBurnToken} from "./mocks/MockToken.sol";
import {VirtualLP} from "./mocks/VirtualLP.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PortalV2MultiAssetTest is Test {
    // External token addresses
    address public constant PSM_ADDRESS =
        0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5;
    address private constant esVKA = 0x95b3F9797077DDCa971aB8524b439553a220EB2A;

    // Vaultka staking contracts
    address private constant SINGLE_STAKING =
        0x314223E2fA375F972E159002Eb72A96301E99e22;
    address private constant DUAL_STAKING =
        0x31Fa38A6381e9d1f4770C73AB14a0ced1528A65E;

    // General constants
    uint256 constant _TERMINAL_MAX_LOCK_DURATION = 157680000;
    uint256 private constant SECONDS_PER_YEAR = 31536000; // seconds in a 365 day year
    uint256 public maxLockDuration = 7776000; // 7776000 starting value for maximum allowed lock duration of user´s balance in seconds (90 days)

    // portal instances
    PortalV2MultiAsset public portal_USDC;
    PortalV2MultiAsset public portal_WETH;

    // Shared virtual LP
    VirtualLP public virtualLP;

    // Portal Constructor values
    address _VAULT_ADDRESS = address(0);

    uint256 constant _TARGET_CONSTANT_USDC = 1101321585903080 * 1e18;
    uint256 constant _TARGET_CONSTANT_WETH = 423076988165 * 1e18;

    uint256 constant _FUNDING_PHASE_DURATION = 604800; // 7 days
    uint256 constant _FUNDING_MIN_AMOUNT = 5e25;

    address private constant _PRINCIPAL_TOKEN_ADDRESS_USDC =
        0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant _PRINCIPAL_TOKEN_ADDRESS_WETH =
        0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    address private constant USDC_WATER =
        0x9045ae36f963b7184861BDce205ea8B08913B48c;
    address private constant WETH_WATER =
        0x8A98929750e6709Af765F976c6bddb5BfFE6C06c;

    uint256 constant _POOL_ID_USDC = 5;
    uint256 constant _POOL_ID_WETH = 10;

    uint256 constant _DECIMALS = 18;
    uint256 constant _DECIMALS_USDC = 6;

    uint256 constant _AMOUNT_TO_CONVERT = 100000 * 1e18;

    string _META_DATA_URI = "abcd";

    // time
    uint256 timestamp;
    uint256 fundingPhase;

    // prank addresses
    address Alice = address(0x01);
    address Bob = address(0x02);
    address Karen = address(0x03);

    // ============================================
    // ==                EVENTS                  ==
    // ============================================
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
    // ==              CUSTOM ERRORS             ==
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
    error NativeTokenNotAllowed();
    error NoProfit();
    error PEtokenNotDeployed();
    error PortalNFTnotDeployed();
    error PortalNotActive();
    error PortalAlreadyActive();
    error TimeLockActive();
    error TokenExists();

    function setUp() public {
        // Create Shared LP
        virtualLP = new VirtualLP(msg.sender);
        address _VIRTUAL_LP = address(virtualLP);

        // Create new Portals
        portal_USDC = new PortalV2MultiAsset(
            _VIRTUAL_LP,
            _TARGET_CONSTANT_USDC,
            _PRINCIPAL_TOKEN_ADDRESS_USDC,
            _DECIMALS_USDC,
            _META_DATA_URI
        );
        portal_WETH = new PortalV2MultiAsset(
            _VIRTUAL_LP,
            _TARGET_CONSTANT_WETH,
            _PRINCIPAL_TOKEN_ADDRESS_WETH,
            _DECIMALS,
            _META_DATA_URI
        );

        // creation time
        timestamp = block.timestamp;
        fundingPhase = timestamp + _FUNDING_PHASE_DURATION;

        // Deal tokens to addresses
        deal(PSM_ADDRESS, Alice, 1e30, true);
        deal(_PRINCIPAL_TOKEN_ADDRESS_USDC, Alice, 1e30, true);
        deal(_PRINCIPAL_TOKEN_ADDRESS_WETH, Alice, 1e30, true);

        deal(PSM_ADDRESS, Bob, 1e30, true);
        deal(_PRINCIPAL_TOKEN_ADDRESS_USDC, Bob, 1e30, true);
        deal(_PRINCIPAL_TOKEN_ADDRESS_WETH, Bob, 1e30, true);

        deal(PSM_ADDRESS, Karen, 1e30, true);
        deal(_PRINCIPAL_TOKEN_ADDRESS_USDC, Karen, 1e30, true);
        deal(_PRINCIPAL_TOKEN_ADDRESS_WETH, Karen, 1e30, true);
    }

    // Multi-Portal LP interaction
    //

    // -------------------- Funding phase:
    // stake
    function testRevert_stake() public {
        vm.startPrank(Alice);
        IERC20(PSM_ADDRESS).approve(address(portal_USDC), 1e55);
        vm.expectRevert(PortalNotActive.selector);
        portal_USDC.stake(123456);
    }

    // getUpdateAccount
    function testRevert_getUpdateAccount() public {
        vm.startPrank(Alice);
        vm.expectRevert(PortalNotActive.selector);
        portal_USDC.getUpdateAccount(Alice, 0, true);
    }

    // mintNFTposition
    function testRevert_mintNFTposition() public {
        vm.startPrank(Alice);
        vm.expectRevert(PortalNotActive.selector);
        portal_USDC.mintNFTposition(Alice);
    }

    // quoteBuyPortalEnergy
    function testRevert_quoteBuyPortalEnergy() public {
        vm.startPrank(Alice);
        vm.expectRevert(PortalNotActive.selector);
        portal_USDC.quoteBuyPortalEnergy(123456);
    }

    // quoteSellPortalEnergy
    function testRevert_quoteSellPortalEnergy() public {
        vm.startPrank(Alice);
        vm.expectRevert(PortalNotActive.selector);
        portal_USDC.quoteSellPortalEnergy(123456);
    }

    // convert
    function testRevert_convert() public {
        vm.startPrank(Alice);
        vm.expectRevert(PortalNotActive.selector);
        portal_USDC.convert(
            _PRINCIPAL_TOKEN_ADDRESS_WETH,
            Alice,
            123456,
            fundingPhase + 60
        );
    }

    // create_bToken
    // update parameters, create new contract
    function testSuccess_create_bToken() public {
        assertTrue(address(portal_USDC.bToken()) == address(0));
        assertTrue(portal_USDC.bTokenCreated() == false);

        portal_USDC.create_bToken();

        assertTrue(address(portal_USDC.bToken()) != address(0));
        assertTrue(portal_USDC.bTokenCreated() == true);
    }

    // create_portalEnergyToken
    // update parameters, create new contract
    function testSuccess_create_portalEnergyToken() public {
        assertTrue(address(portal_USDC.portalEnergyToken()) == address(0));
        assertTrue(portal_USDC.portalEnergyTokenCreated() == false);

        portal_USDC.create_portalEnergyToken();

        assertTrue(address(portal_USDC.portalEnergyToken()) != address(0));
        assertTrue(portal_USDC.portalEnergyTokenCreated() == true);
    }

    // create_portalNFT
    // update parameters, create new contract
    function testSuccess_create_portalNFT() public {
        assertTrue(address(portal_USDC.portalNFT()) == address(0));
        assertTrue(portal_USDC.portalNFTcreated() == false);

        portal_USDC.create_portalNFT();

        assertTrue(address(portal_USDC.portalNFT()) != address(0));
        assertTrue(portal_USDC.portalNFTcreated() == true);
    }

    // activate Portal
    // Funding phase has not passed
    // Funding phase has passed but insufficient funding was provided
    // bToken, PE token and NFT contract have not been deployed yet
    function testRevert_activatePortal() public {
        vm.expectRevert(FundingPhaseOngoing.selector);
        portal_USDC.activatePortal();

        // pass time
        vm.warp(fundingPhase + 60);

        vm.expectRevert(FundingInsufficient.selector);
        portal_USDC.activatePortal();

        // add funding
        testSuccess_contributeFunding();

        vm.expectRevert(bTokenNotDeployed.selector);
        portal_USDC.activatePortal();

        // deploy bToken
        testSuccess_create_bToken();

        vm.expectRevert(PEtokenNotDeployed.selector);
        portal_USDC.activatePortal();

        // deploy PE token
        testSuccess_create_portalEnergyToken();

        vm.expectRevert(PortalNFTnotDeployed.selector);
        portal_USDC.activatePortal();
    }

    // contributeFunding
    // amount is 0
    // bToken is not deployed
    function testRevert_contributeFunding() public {
        vm.startPrank(Alice);
        IERC20(PSM_ADDRESS).approve(address(portal_USDC), 1e55);

        vm.expectRevert(InvalidAmount.selector);
        portal_USDC.contributeFunding(0);

        vm.expectRevert();
        portal_USDC.contributeFunding(1e18);

        vm.stopPrank();
    }

    // contributeFunding
    // setup (create bToken)
    // transfer PSM to Portal, mint bToken to user, check amount minted is correct
    function testSuccess_contributeFunding() public {
        // deploy bToken
        testSuccess_create_bToken();

        vm.startPrank(Alice);
        IERC20(PSM_ADDRESS).approve(address(portal_USDC), 1e55);

        portal_USDC.contributeFunding(1e22);
        vm.stopPrank();

        assertEq(IERC20(PSM_ADDRESS).balanceOf(address(portal_USDC)), 1e22);
        assertEq(IERC20(PSM_ADDRESS).balanceOf(Alice), 1e30 - 1e22);
        assertEq(
            IERC20(address(portal_USDC.bToken())).balanceOf(Alice),
            (1e22 * portal_USDC.FUNDING_MAX_RETURN_PERCENT()) / 100
        );
    }

    // withdrawFunding
    // setup (contribute)
    // amount is 0
    // amount larger than user balance
    function testRevert_withdrawFunding() public {
        testSuccess_contributeFunding();

        vm.startPrank(Alice);
        IERC20(PSM_ADDRESS).approve(address(portal_USDC), 1e55);

        vm.expectRevert(InvalidAmount.selector);
        portal_USDC.withdrawFunding(0);

        vm.expectRevert();
        portal_USDC.contributeFunding(1e23);

        vm.stopPrank();
    }

    // withdrawFunding
    // setup (contribute funding)
    // transfer PSM to user, burn bTokens from user, check amount burned is correct
    function testSuccess_withdrawFunding() public {
        testSuccess_contributeFunding();

        vm.startPrank(Alice);
        IERC20(address(portal_USDC.bToken())).approve(
            address(portal_USDC),
            1e55
        );
        portal_USDC.withdrawFunding(1e20);
        vm.stopPrank();

        assertEq(
            IERC20(PSM_ADDRESS).balanceOf(address(portal_USDC)),
            1e22 - 1e20
        );
        assertEq(IERC20(PSM_ADDRESS).balanceOf(Alice), 1e30 - 1e22 + 1e20);
        assertEq(
            IERC20(address(portal_USDC.bToken())).balanceOf(Alice),
            ((1e22 - 1e20) * portal_USDC.FUNDING_MAX_RETURN_PERCENT()) / 100
        );
    }

    // activatePortal -> update parameters, send PSM to LP, emit event
    // vm.warp(timeAfterActivating + 60);

    // -------- REVERTS ---------
    // getBurnValuePSM
    // getBurnableBtokenAmount
    // create_bToken if token has been deployed
    // create_portalEnergyToken if token has been deployed
    // create_portalNFT if token has been deployed

    // ====================== Active Phase:
    // =========== Negatives:
    // activate Portal
    // contributeFunding
    // withdrawFunding
    // stake ERC20: amount 0
    // stake ERC20: send native ETH with call (msg.value) when principal is ERC20
    // stake ETH: amount > 0 + msg.value = 0
    // unstake: amount 0
    // unstake: amount > user available to withdraw

    // mintPortalEnergyToken: amount 0
    // mintPortalEnergyToken: recipient address(0)
    // mintPortalEnergyToken: caller has not enough portal energy to mint amount
    // forceUnstakeAll: user did not give spending approval
    // forceUnstakeAll: user has more debt than PE tokens

    // buyPortalEnergy: amount 0
    // buyPortalEnergy: minReceived 0
    // buyPortalEnergy: recipient address(0)
    // buyPortalEnergy: deadline expired
    // buyPortalEnergy: received amount < minReceived
    // sellPortalEnergy: amount 0
    // sellPortalEnergy: minReceived 0
    // sellPortalEnergy: recipient address(0)
    // sellPortalEnergy: deadline expired
    // sellPortalEnergy: caller has not enough portalEnergy balance
    // sellPortalEnergy: received amount < minReceived

    // convert: token address = PSM
    // convert: recipient address(0)
    // convert: minReceived 0
    // convert: deadline expired
    // convert: contract balance < minReceived

    // burnBtokens: amount 0
    // burnBtokens: amount greater than what can be redeemed
    // burnPortalEnergyToken: amount 0
    // burnPortalEnergyToken: recipient address(0)

    // mintNFTposition: recipient = address(0)
    // mintNFTposition: user with empty account (no PE & no stake)
    // redeemNFTposition: try redeem an ID that does not exist
    // redeemNFTposition: try redeem and ID that is not owned by the caller

    // =========== Positives:
    // stake ERC20 -> update stake of user + global, send tokens to external protocol
    // ---> change _depositToYieldSource for this test -> simple deposit
    // stake ETH -> update stake of user + global, send tokens to external protocol
    // ---> change _depositToYieldSource for this test -> simple deposit
    // unstake -> update stake of user + global, withdraw tokens from external protocol + send to user
    // ---> change _withdrawFromYieldSource for this test -> simple withdrawal with user as target

    // burnPortalEnergyToken -> increase recipient portalEnergy, burn PE tokens from caller
    // mintPortalEnergyToken -> reduce caller PE, mint PE tokens minus LP protection to recipient
    // quoteForceUnstakeAll -> return correct number
    // forceUnstakeAll ERC20 only -> burn PE tokens, update stake of user + global, withdraw from external protocol + send to user

    // quoteBuyPortalEnergy -> return the correct number
    // quoteSellPortalEnergy -> return the correct number
    // buyPortalEnergy -> increase the PortalEnergy of recipient, transfer PSM from user to Portal
    // sellPortalEnergy -> decrease the PortalEnergy of caller, transfer PSM from Portal to recipient

    // convert -> three scenarios:
    // If rewards are blow max rewards -> split PSM between Portal & LP, update rewards parameter, send token to user
    // If rewards are equal to max rewards -> send PSM only to LP, send token to user
    // If rewards are above max rewards -> calculate overflow and send to LP, update global parameter, send token to user

    // getBurnValuePSM -> return the correct number
    // getBurnableBtokenAmount -> return the correct number
    // burnBtokens -> reduce the fundingRewardPool, burn bTokens from user, transfer PSM from Portal to user
    // mintNFTposition -> delete user account, mint NFT to recipient address, check that NFT data is correct
    // redeemNFTposition -> burn NFT, update the user account and add NFT values
}
