// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {PortalV2MultiAsset} from "src/V2MultiAsset/PortalV2MultiAsset.sol";
import {MintBurnToken} from "./mocks/MockToken.sol";
import {VirtualLP} from "./mocks/VirtualLP.sol";

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
    uint256 private constant _TRADE_TIMELOCK = 60;

    // portal instances
    PortalV2MultiAsset public portal_USDCE;
    PortalV2MultiAsset public portal_USDC;
    PortalV2MultiAsset public portal_WETH;
    PortalV2MultiAsset public portal_ARB;
    PortalV2MultiAsset public portal_WBTC;
    PortalV2MultiAsset public portal_LINK;

    // Shared virtual LP
    VirtualLP public virtualLP;

    // Portal Constructor values
    address _VAULT_ADDRESS = address(0);

    uint256 constant _TARGET_CONSTANT_USDC = 1101321585903080 * 1e18;
    uint256 constant _TARGET_CONSTANT_WETH = 423076988165 * 1e18;
    uint256 constant _TARGET_CONSTANT_ARB = 500000000000000 * 1e18;
    uint256 constant _TARGET_CONSTANT_WBTC = 25581396062 * 1e18;
    uint256 constant _TARGET_CONSTANT_LINK = 61109753116597 * 1e18;

    uint256 constant _FUNDING_PHASE_DURATION = 604800; // 7 days
    uint256 constant _FUNDING_MIN_AMOUNT = 5e25;

    address private constant _PRINCIPAL_TOKEN_ADDRESS_USDCE =
        0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
    address private constant _PRINCIPAL_TOKEN_ADDRESS_USDC =
        0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant _PRINCIPAL_TOKEN_ADDRESS_WETH =
        0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address private constant _PRINCIPAL_TOKEN_ADDRESS_ARB =
        0x912CE59144191C1204E64559FE8253a0e49E6548;
    address private constant _PRINCIPAL_TOKEN_ADDRESS_WBTC =
        0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address private constant _PRINCIPAL_TOKEN_ADDRESS_LINK =
        0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;

    address private constant USDCE_WATER =
        0x806e8538FC05774Ea83d9428F778E423F6492475;
    address private constant USDC_WATER =
        0x9045ae36f963b7184861BDce205ea8B08913B48c;
    address private constant WETH_WATER =
        0x8A98929750e6709Af765F976c6bddb5BfFE6C06c;
    address private constant ARB_WATER =
        0x175995159ca4F833794C88f7873B3e7fB12Bb1b6;
    address private constant WBTC_WATER =
        0x4e9e41Bbf099fE0ef960017861d181a9aF6DDa07;
    address private constant LINK_WATER =
        0xFF614Dd6fC857e4daDa196d75DaC51D522a2ccf7;

    uint256 constant _POOL_ID_USDCE = 4;
    uint256 constant _POOL_ID_USDC = 5;
    uint256 constant _POOL_ID_WETH = 10;
    uint256 constant _POOL_ID_ARB = 11;
    uint256 constant _POOL_ID_WBTC = 12;
    uint256 constant _POOL_ID_LINK = 16;

    uint256 constant _DECIMALS = 18;
    uint256 constant _DECIMALS_USDC = 6;
    uint256 constant _DECIMALS_WBTC = 8;

    uint256 constant _AMOUNT_TO_CONVERT = 100000 * 1e18;

    string _META_DATA_URI = "abcd";

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
        portal_USDCE = new PortalV2MultiAsset(
            _VIRTUAL_LP,
            _TARGET_CONSTANT_USDC,
            _FUNDING_PHASE_DURATION,
            _FUNDING_MIN_AMOUNT,
            _PRINCIPAL_TOKEN_ADDRESS_USDCE,
            _VAULT_ADDRESS,
            _POOL_ID_USDCE,
            _DECIMALS_USDC,
            _AMOUNT_TO_CONVERT,
            _META_DATA_URI
        );
        portal_USDC = new PortalV2MultiAsset(
            _VIRTUAL_LP,
            _TARGET_CONSTANT_USDC,
            _FUNDING_PHASE_DURATION,
            _FUNDING_MIN_AMOUNT,
            _PRINCIPAL_TOKEN_ADDRESS_USDC,
            _VAULT_ADDRESS,
            _POOL_ID_USDC,
            _DECIMALS_USDC,
            _AMOUNT_TO_CONVERT,
            _META_DATA_URI
        );
        portal_WETH = new PortalV2MultiAsset(
            _VIRTUAL_LP,
            _TARGET_CONSTANT_WETH,
            _FUNDING_PHASE_DURATION,
            _FUNDING_MIN_AMOUNT,
            _PRINCIPAL_TOKEN_ADDRESS_WETH,
            _VAULT_ADDRESS,
            _POOL_ID_WETH,
            _DECIMALS,
            _AMOUNT_TO_CONVERT,
            _META_DATA_URI
        );
        portal_ARB = new PortalV2MultiAsset(
            _VIRTUAL_LP,
            _TARGET_CONSTANT_ARB,
            _FUNDING_PHASE_DURATION,
            _FUNDING_MIN_AMOUNT,
            _PRINCIPAL_TOKEN_ADDRESS_ARB,
            _VAULT_ADDRESS,
            _POOL_ID_ARB,
            _DECIMALS,
            _AMOUNT_TO_CONVERT,
            _META_DATA_URI
        );
        portal_WBTC = new PortalV2MultiAsset(
            _VIRTUAL_LP,
            _TARGET_CONSTANT_WBTC,
            _FUNDING_PHASE_DURATION,
            _FUNDING_MIN_AMOUNT,
            _PRINCIPAL_TOKEN_ADDRESS_WBTC,
            _VAULT_ADDRESS,
            _POOL_ID_WBTC,
            _DECIMALS_WBTC,
            _AMOUNT_TO_CONVERT,
            _META_DATA_URI
        );
        portal_LINK = new PortalV2MultiAsset(
            _VIRTUAL_LP,
            _TARGET_CONSTANT_USDC,
            _FUNDING_PHASE_DURATION,
            _FUNDING_MIN_AMOUNT,
            _PRINCIPAL_TOKEN_ADDRESS_USDC,
            _VAULT_ADDRESS,
            _POOL_ID_USDC,
            _DECIMALS_USDC,
            _AMOUNT_TO_CONVERT,
            _META_DATA_URI
        );

        // creation time
        timestamp = block.timestamp;
        timeAfterActivating = timestamp + _FUNDING_PHASE_DURATION;
    }

    // -------------------- Funding phase:
    // ----------- Negatives:
    // stake

    // getUpdateAccount

    // mintNFTposition

    // quoteBuyPortalEnergy

    // quoteSellPortalEnergy

    // convert

    // activate Portal before time passed
    // activate Portal after time passed but before sufficient funding was provided
    // activate Portal before bToken, PE token and NFT contract have been deployed

    // contributeFunding if amount is 0
    // contributeFunding if bToken is not deployed

    // withdrawFunding if amount is 0
    // withdrawFunding if amount is larger than user balance

    // getBurnValuePSM
    // getBurnableBtokenAmount

    // create_bToken if token has been deployed
    // create_portalEnergyToken if token has been deployed
    // create_portalNFT if token has been deployed

    // ----------- Positives:
    // activatePortal -> update parameters, send PSM to LP, emit event

    // contributeFunding -> transfer PSM to Portal, mint bToken to user, check amount minted is correct

    // withdrawFunding -> transfer PSM to user, burn bTokens from user, check amount burned is correct

    // create_bToken -> update parameters, create new contract

    // create_portalEnergyToken -> update parameters, create new contract

    // create_portalNFT -> update parameters, create new contract

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

    // forceUnstakeAll: user did not give spending approval
    // forceUnstakeAll: user has more debt than PE tokens

    // mintNFTposition: recipient = address(0)
    // mintNFTposition: user with empty account (no PE & no stake)

    // redeemNFTposition: try redeem an ID that does not exist
    // redeemNFTposition: try redeem and ID that is not owned by the caller

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

    // mintPortalEnergyToken: amount 0
    // mintPortalEnergyToken: recipient address(0)
    // mintPortalEnergyToken: caller has not enough portal energy to mint amount

    // =========== Positives:
    // stake ERC20 -> update stake of user + global, send tokens to external protocol
    // ---> change _depositToYieldSource for this test -> simple deposit
    // stake ETH -> update stake of user + global, send tokens to external protocol
    // ---> change _depositToYieldSource for this test -> simple deposit

    // unstake -> update stake of user + global, withdraw tokens from external protocol + send to user
    // ---> change _withdrawFromYieldSource for this test -> simple withdrawal with user as target

    // forceUnstakeAll ERC20 only -> burn PE tokens, update stake of user + global, withdraw from external protocol + send to user

    // quoteForceUnstakeAll -> return correct number

    // mintNFTposition -> delete user account, mint NFT to recipient address, check that NFT data is correct

    // redeemNFTposition -> burn NFT, update the user account and add NFT values

    // buyPortalEnergy -> increase the PortalEnergy of recipient, transfer PSM from user to Portal

    // sellPortalEnergy -> decrease the PortalEnergy of caller, transfer PSM from Portal to recipient

    // quoteBuyPortalEnergy -> return the correct number
    // quoteSellPortalEnergy -> return the correct number

    // convert -> three scenarios:
    // If rewards are blow max rewards -> split PSM between Portal & LP, update rewards parameter, send token to user
    // If rewards are equal to max rewards -> send PSM only to LP, send token to user
    // If rewards are above max rewards -> calculate overflow and send to LP, update global parameter, send token to user

    // getBurnValuePSM -> return the correct number
    // getBurnableBtokenAmount -> return the correct number

    // burnBtokens -> reduce the fundingRewardPool, burn bTokens from user, transfer PSM from Portal to user

    // burnPortalEnergyToken -> increase recipient portalEnergy, burn PE tokens from caller

    // mintPortalEnergyToken -> reduce caller PE, mint PE tokens minus LP protection to recipient
}
