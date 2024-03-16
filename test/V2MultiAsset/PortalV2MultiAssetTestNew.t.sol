// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {PortalV2MultiAsset} from "src/V2MultiAsset/PortalV2MultiAsset.sol";
import {MintBurnToken} from "src/V2MultiAsset/MintBurnToken.sol";
import {VirtualLP} from "src/V2MultiAsset/VirtualLP.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWater} from "src/V2MultiAsset/interfaces/IWater.sol";
import {ISingleStaking} from "src/V2MultiAsset/interfaces/ISingleStaking.sol";
import {IDualStaking} from "src/V2MultiAsset/interfaces/IDualStaking.sol";
import {IPortalV2MultiAsset} from "src/V2MultiAsset/interfaces/IPortalV2MultiAsset.sol";

contract PortalV2MultiAssetTest is Test {
    // External token addresses
    address constant WETH_ADDRESS = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public constant PSM_ADDRESS =
        0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5;
    address constant esVKA = 0x95b3F9797077DDCa971aB8524b439553a220EB2A;

    // Vaultka staking contracts
    address constant SINGLE_STAKING =
        0x314223E2fA375F972E159002Eb72A96301E99e22;
    address constant DUAL_STAKING = 0x31Fa38A6381e9d1f4770C73AB14a0ced1528A65E;

    uint256 constant _POOL_ID_USDC = 5;
    uint256 constant _POOL_ID_WETH = 10;

    address private constant USDC_WATER =
        0x9045ae36f963b7184861BDce205ea8B08913B48c;
    address private constant WETH_WATER =
        0x8A98929750e6709Af765F976c6bddb5BfFE6C06c;

    address private constant _PRINCIPAL_TOKEN_ADDRESS_USDC =
        0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant _PRINCIPAL_TOKEN_ADDRESS_ETH = address(0);

    // General constants
    uint256 constant _TERMINAL_MAX_LOCK_DURATION = 157680000;
    uint256 private constant SECONDS_PER_YEAR = 31536000; // seconds in a 365 day year
    uint256 public maxLockDuration = 7776000; // 7776000 starting value for maximum allowed lock duration of user´s balance in seconds (90 days)
    uint256 private constant OWNER_DURATION = 31536000; // 1 Year

    // Portal Constructor values
    uint256 constant _TARGET_CONSTANT_USDC = 440528634361 * 1e36;
    uint256 constant _TARGET_CONSTANT_WETH = 125714213 * 1e36;

    uint256 constant _FUNDING_PHASE_DURATION = 604800; // 7 days
    uint256 constant _FUNDING_MIN_AMOUNT = 1e25; // 10M PSM

    uint256 constant _DECIMALS = 18;
    uint256 constant _DECIMALS_USDC = 6;

    uint256 constant _AMOUNT_TO_CONVERT = 100000 * 1e18;

    string _META_DATA_URI = "abcd";

    // time
    uint256 timestamp;
    uint256 fundingPhase;
    uint256 ownerExpiry;
    uint256 hundredYearsLater;

    // prank addresses
    address payable Alice = payable(0x46340b20830761efd32832A74d7169B29FEB9758);
    address payable Bob = payable(0xDD56CFdDB0002f4d7f8CC0563FD489971899cb79);
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

    // starting token amounts
    uint256 usdcAmount = 1e12; // 1M USDC
    uint256 psmAmount = 1e25; // 10M PSM
    uint256 usdcSendAmount = 1e9; // 1k USDC

    ////////////// SETUP ////////////////////////
    function setUp() public {
        // Create Virtual LP instance
        virtualLP = new VirtualLP(
            psmSender,
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
            "USD Coin",
            "USDC",
            _META_DATA_URI
        );
        portal_ETH = new PortalV2MultiAsset(
            _VIRTUAL_LP,
            _TARGET_CONSTANT_WETH,
            _PRINCIPAL_TOKEN_ADDRESS_ETH,
            _DECIMALS,
            "ETHER",
            "ETH",
            _META_DATA_URI
        );

        // creation time
        timestamp = block.timestamp;
        fundingPhase = timestamp + _FUNDING_PHASE_DURATION;
        ownerExpiry = timestamp + OWNER_DURATION;
        hundredYearsLater = timestamp + 100 * SECONDS_PER_YEAR;

        // Deal tokens to addresses
        vm.deal(Alice, 1 ether);
        vm.prank(psmSender);
        psm.transfer(Alice, psmAmount);
        vm.prank(usdcSender);
        usdc.transfer(Alice, usdcAmount);

        vm.deal(Bob, 1 ether);
        vm.prank(psmSender);
        psm.transfer(Bob, psmAmount);
        vm.prank(usdcSender);
        usdc.transfer(Bob, usdcAmount);

        vm.deal(Karen, 1 ether);
        vm.prank(psmSender);
        psm.transfer(Karen, psmAmount);
        vm.prank(usdcSender);
        usdc.transfer(Karen, usdcAmount);
    }

    ////////////// HELPER FUNCTIONS /////////////
    // create the bToken token
    function helper_create_bToken() public {
        virtualLP.create_bToken();
    }

    // fund the Virtual LP
    function helper_fundLP() public {
        vm.startPrank(psmSender);

        psm.approve(address(virtualLP), 1e55);
        virtualLP.contributeFunding(_FUNDING_MIN_AMOUNT);

        vm.stopPrank();
    }

    // Register USDC Portal
    function helper_registerPortalUSDC() public {
        vm.prank(psmSender);
        virtualLP.registerPortal(
            address(portal_USDC),
            _PRINCIPAL_TOKEN_ADDRESS_USDC,
            USDC_WATER,
            _POOL_ID_USDC
        );
    }

    // Register ETH Portal
    function helper_registerPortalETH() public {
        vm.prank(psmSender);
        virtualLP.registerPortal(
            address(portal_ETH),
            _PRINCIPAL_TOKEN_ADDRESS_ETH,
            WETH_WATER,
            _POOL_ID_WETH
        );
    }

    // activate the Virtual LP
    function helper_activateLP() public {
        vm.warp(fundingPhase);
        virtualLP.activateLP();
    }

    // fund and activate the LP and register both Portals
    function helper_prepareSystem() public {
        helper_create_bToken();
        helper_fundLP();
        helper_registerPortalETH();
        helper_registerPortalUSDC();
        helper_activateLP();
    }

    // Deploy the NFT contract
    function helper_createNFT() public {
        portal_USDC.create_portalNFT();
    }

    // Deploy the ERC20 contract for mintable Portal Energy
    function helper_createPortalEnergyToken() public {
        portal_USDC.create_portalEnergyToken();
    }

    // Increase allowance of tokens used by the USDC Portal
    function helper_setApprovalsInLP_USDC() public {
        virtualLP.increaseAllowanceDualStaking();
        virtualLP.increaseAllowanceSingleStaking(address(portal_USDC));
        virtualLP.increaseAllowanceVault(address(portal_USDC));
    }

    // Increase allowance of tokens used by the ETH Portal
    function helper_setApprovalsInLP_ETH() public {
        virtualLP.increaseAllowanceDualStaking();
        virtualLP.increaseAllowanceSingleStaking(address(portal_ETH));
        virtualLP.increaseAllowanceVault(address(portal_ETH));
    }

    // send USDC to LP when balance is required
    function helper_sendUSDCtoLP() public {
        vm.prank(usdcSender);
        usdc.transfer(address(virtualLP), usdcSendAmount); // Send 1k USDC to LP
    }

    // simulate a full convert() cycle
    function helper_executeConvert() public {
        helper_sendUSDCtoLP();
        vm.startPrank(psmSender);
        psm.approve(address(virtualLP), 1e55);
        virtualLP.convert(
            _PRINCIPAL_TOKEN_ADDRESS_USDC,
            msg.sender,
            1,
            block.timestamp
        );
        vm.stopPrank();
    }

    ////////////////////////////////////////////
    /////////////// LP functions ///////////////
    ////////////////////////////////////////////

    function testSuccess_burnPortalEnergyToken_Unintended() public {
        uint256 alicePE;

        vm.prank(Alice);
        portal_USDC.burnPortalEnergyToken(Alice, 1e10);

        (, , , , alicePE) = portal_USDC.accounts(Alice);
        console2.log(alicePE);
    }
}
