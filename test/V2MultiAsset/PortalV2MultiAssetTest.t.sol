// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {PortalV2MultiAsset} from "src/V2MultiAsset/PortalV2MultiAsset.sol";
import {MintBurnToken} from "src/V2MultiAsset/MintBurnToken.sol";
import {VirtualLP} from "src/V2MultiAsset/VirtualLP.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PortalV2MultiAssetTest is Test {
    // External token addresses
    address constant WETH_ADDRESS = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
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

    // Portal Constructor values
    uint256 constant _TARGET_CONSTANT_USDC = 1101321585903080 * 1e18;
    uint256 constant _TARGET_CONSTANT_WETH = 423076988165 * 1e18;

    uint256 constant _FUNDING_PHASE_DURATION = 604800; // 7 days
    uint256 constant _FUNDING_MIN_AMOUNT = 5e25;

    address private constant _PRINCIPAL_TOKEN_ADDRESS_USDC =
        0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant _PRINCIPAL_TOKEN_ADDRESS_ETH = address(0);

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
    address payable Alice = payable(0x46340b20830761efd32832A74d7169B29FEB9758);
    address payable Bob = payable(0x58071967a168245cBAF2b59C67527E0FDeC6F919);
    address payable Karen = payable(0x3A30aaf1189E830b02416fb8C513373C659ed748);

    // Token Instances
    IERC20 psm = IERC20(PSM_ADDRESS);
    IERC20 usdc = IERC20(_PRINCIPAL_TOKEN_ADDRESS_USDC);
    IERC20 weth = IERC20(WETH_ADDRESS);

    // Portals & LP
    PortalV2MultiAsset public portal_USDC;
    PortalV2MultiAsset public portal_ETH;
    VirtualLP public virtualLP;

    // Simulated USDC distributor
    address usdcSender = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    // PSM Treasury
    address psmSender = 0xAb845D09933f52af5642FC87Dd8FBbf553fd7B33;

    ////////////// SETUP ////////////////////////
    function setUp() public {
        // Create Virtual LP instance
        virtualLP = new VirtualLP(
            address(this),
            _AMOUNT_TO_CONVERT,
            _FUNDING_PHASE_DURATION,
            _FUNDING_MIN_AMOUNT
        );
        address _VIRTUAL_LP = address(virtualLP);

        // Create Portal instances
        portal_USDC = new PortalV2MultiAsset(
            _VIRTUAL_LP,
            _TARGET_CONSTANT_USDC,
            _PRINCIPAL_TOKEN_ADDRESS_USDC,
            _DECIMALS_USDC,
            _META_DATA_URI
        );
        portal_ETH = new PortalV2MultiAsset(
            _VIRTUAL_LP,
            _TARGET_CONSTANT_WETH,
            _PRINCIPAL_TOKEN_ADDRESS_ETH,
            _DECIMALS,
            _META_DATA_URI
        );

        // creation time
        timestamp = block.timestamp;
        fundingPhase = timestamp + _FUNDING_PHASE_DURATION;

        // Deal tokens to addresses
        vm.deal(Alice, 1 ether);
        vm.prank(psmSender);
        psm.transfer(Alice, 1e25);
        vm.prank(usdcSender);
        usdc.transfer(Alice, 1e13);

        vm.deal(Bob, 1 ether);
        vm.prank(psmSender);
        psm.transfer(Bob, 1e25);
        vm.prank(usdcSender);
        usdc.transfer(Bob, 1e13);

        vm.deal(Karen, 1 ether);
        vm.prank(psmSender);
        psm.transfer(Karen, 1e25);
        vm.prank(usdcSender);
        usdc.transfer(Karen, 1e13);
    }

    ////////////// HELPER FUNCTIONS /////////////
    // Register USDC Portal
    function helper_registerPortalUSDC() public {
        address vaultAddress = virtualLP.vaults(
            address(portal_USDC),
            _PRINCIPAL_TOKEN_ADDRESS_USDC
        );
        uint256 pid = virtualLP.poolID(
            address(portal_USDC),
            _PRINCIPAL_TOKEN_ADDRESS_USDC
        );

        // register USDC Portal
        virtualLP.registerPortal(
            address(portal_USDC),
            _PRINCIPAL_TOKEN_ADDRESS_USDC,
            vaultAddress,
            pid
        );
    }

    // Register ETH Portal
    function helper_registerPortalETH() public {
        address vaultAddress = virtualLP.vaults(
            address(portal_ETH),
            _PRINCIPAL_TOKEN_ADDRESS_ETH
        );
        uint256 pid = virtualLP.poolID(
            address(portal_ETH),
            _PRINCIPAL_TOKEN_ADDRESS_ETH
        );

        // register Portal
        virtualLP.registerPortal(
            address(portal_ETH),
            _PRINCIPAL_TOKEN_ADDRESS_ETH,
            vaultAddress,
            pid
        );
    }

    // ===================================
    // ============= TESTS ===============
    // ===================================
    // Test Section 1: Virtual LP - Bootstrapping & Activation
    // Test Section 2: ETH Portal + USDC Portal - Isolated Interactions & Vaultka Integration
    // Test Section 3: Multi-Portal LP interaction

    // Test Section 1: Virtual LP - Bootstrapping & Activation
    // First: Test revert of functions that should revert before the LP is funded and activated
    /////////////// LP functions ///////////////
    function testRevert_removeOwner() public {
        vm.expectRevert(ErrorsLib.OwnerNotExpired.selector);
        virtualLP.removeOwner();
    }

    // getBurnValuePSM
    function testRevert_getBurnValuePSM() public {
        vm.startPrank(Alice);
        vm.expectRevert(ErrorsLib.InactiveLP.selector);
        virtualLP.getBurnValuePSM(1e18);
        vm.stopPrank();
    }

    // getBurnableBtokenAmount
    function testRevert_getBurnableBtokenAmount() public {
        vm.startPrank(Alice);
        vm.expectRevert(ErrorsLib.InactiveLP.selector);
        virtualLP.getBurnableBtokenAmount();
        vm.stopPrank();
    }

    // burnBtokens
    function testRevert_burnBtokens_I() public {
        vm.startPrank(Alice);
        vm.expectRevert(ErrorsLib.InactiveLP.selector);
        virtualLP.burnBtokens(100);
        vm.stopPrank();
    }

    // convert
    function testRevert_convert_I() public {
        vm.startPrank(Alice);
        vm.expectRevert(ErrorsLib.InactiveLP.selector);
        virtualLP.convert(
            _PRINCIPAL_TOKEN_ADDRESS_USDC,
            msg.sender,
            1,
            block.timestamp
        );
        vm.stopPrank();
    }

    // function testRevert_convert_II() public {
    //     // activate Portal

    //     vm.startPrank(Alice);
    //     vm.expectRevert(ErrorsLib.InvalidAddress.selector);
    //     virtualLP.convert(PSM_ADDRESS, msg.sender, 1, block.timestamp);
    //     vm.stopPrank();
    // }

    ///////////// Portal functions ///////////
    // getUpdateAccount
    function testRevert_getUpdateAccount() public {
        vm.startPrank(Alice);
        // Try to simulate a withdrawal greater than the stake balance
        vm.expectRevert(ErrorsLib.InsufficientToWithdraw.selector);
        portal_USDC.getUpdateAccount(Alice, 100, false);
        vm.stopPrank();
    }

    // mintNFTposition
    function testRevert_mintNFTposition() public {
        vm.startPrank(Alice);
        // Invalid recipient
        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        portal_USDC.mintNFTposition(address(0));

        // Empty Account
        vm.expectRevert(ErrorsLib.EmptyAccount.selector);
        portal_USDC.mintNFTposition(Alice);

        vm.stopPrank();
    }

    // quoteBuyPortalEnergy - LP not yet funded, i.e. Reserve0 == 0 -> math error
    function testRevert_quoteBuyPortalEnergy() public {
        vm.startPrank(Alice);
        vm.expectRevert();
        portal_USDC.quoteBuyPortalEnergy(123456);
        vm.stopPrank();
    }

    // quoteSellPortalEnergy - LP not yet funded, i.e. Reserve0 == 0 -> math error
    function testRevert_quoteSellPortalEnergy() public {
        vm.startPrank(Alice);
        vm.expectRevert();
        portal_USDC.quoteSellPortalEnergy(123456);
        vm.stopPrank();
    }

    // stake before Portal was registered
    function testRevert_stake_I() public {
        vm.startPrank(Alice);
        usdc.approve(address(portal_USDC), 1e55);
        // Portal is not registered with the Virtual LP yet
        vm.expectRevert(ErrorsLib.PortalNotRegistered.selector);
        portal_USDC.stake(23450);
        vm.stopPrank();
    }

    // stake after Portal was registered but not funded
    function testRevert_stake_II() public {
        helper_registerPortalUSDC();

        vm.startPrank(Alice);
        usdc.approve(address(portal_USDC), 1e55);

        // Trying to stake zero tokens
        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
        portal_USDC.stake(0);

        // Sending ether with the function call using the USDC Portal
        vm.expectRevert(ErrorsLib.NativeTokenNotAllowed.selector);
        portal_USDC.stake{value: 100}(100);
        vm.stopPrank();
    }

    // stake ETH with difference in input amount and message value
    function testRevert_stake_III() public {
        helper_registerPortalETH();

        vm.startPrank(Alice);
        // Sending zero ether value but positive input amount
        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
        portal_ETH.stake{value: 0}(100);
        vm.stopPrank();
    }

    // create_portalEnergyToken
    function testSuccess_create_portalEnergyToken() public {
        assertTrue(address(portal_USDC.portalEnergyToken()) == address(0));
        assertTrue(portal_USDC.portalEnergyTokenCreated() == false);

        portal_USDC.create_portalEnergyToken();

        assertTrue(address(portal_USDC.portalEnergyToken()) != address(0));
        assertTrue(portal_USDC.portalEnergyTokenCreated() == true);
    }

    // create_portalNFT
    function testSuccess_create_portalNFT() public {
        assertTrue(address(portal_USDC.portalNFT()) == address(0));
        assertTrue(portal_USDC.portalNFTcreated() == false);

        portal_USDC.create_portalNFT();

        assertTrue(address(portal_USDC.portalNFT()) != address(0));
        assertTrue(portal_USDC.portalNFTcreated() == true);
    }

    // -------- REVERTS ---------
    // create_portalEnergyToken if token has been deployed
    // create_portalNFT if token has been deployed

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

    // mintNFTposition -> delete user account, mint NFT to recipient address, check that NFT data is correct
    // redeemNFTposition -> burn NFT, update the user account and add NFT values
}
