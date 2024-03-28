// SPDX-License-Identifier: GPL-2.0-only
pragma solidity =0.8.19;
import {MintBurnToken} from "./MintBurnToken.sol";
import {IWater} from "./interfaces/IWater.sol";
import {IPortalV2MultiAsset} from "./interfaces/IPortalV2MultiAsset.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
interface IWETH {
    function withdrawTo(address payable _account, uint256 _amount) external;}
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
contract VirtualLP is ReentrancyGuard {
    constructor(address _owner,uint256 _AMOUNT_TO_CONVERT,uint256 _FUNDING_PHASE_DURATION,uint256 _FUNDING_MIN_AMOUNT) {
        if (_owner == address(0)) {
            revert InvalidConstructor();}
        if (_AMOUNT_TO_CONVERT == 0) {
            revert InvalidConstructor();}
        if (_FUNDING_PHASE_DURATION < 259200 ||_FUNDING_PHASE_DURATION > 2592000) {
            revert InvalidConstructor();}
        if (_FUNDING_MIN_AMOUNT == 0) {
            revert InvalidConstructor();}
        AMOUNT_TO_CONVERT = _AMOUNT_TO_CONVERT;
        FUNDING_PHASE_DURATION = _FUNDING_PHASE_DURATION;
        FUNDING_MIN_AMOUNT = _FUNDING_MIN_AMOUNT;
        FUNDING_REWARD = _AMOUNT_TO_CONVERT * FUNDING_REWARD_SHARE;
        owner = _owner;
        OWNER_EXPIRY_TIME = OWNER_DURATION + block.timestamp;
        CREATION_TIME = block.timestamp;}
    using SafeERC20 for IERC20;
    MintBurnToken public bToken; // the receipt token for funding the LP
    address public bTokenAddress; // the address of the receipt token
    uint256 constant SECONDS_PER_YEAR = 31536000; // seconds in a 365 day year
    uint256 constant MAX_UINT =115792089237316195423570985008687907853269984665640564039457584007913129639935;
    address public owner;
    uint256 private constant OWNER_DURATION = 172800; // 172800 = 2 days // 777600 = 9 days
    uint256 public immutable OWNER_EXPIRY_TIME; // Time required to pass before owner can be revoked
    uint256 public immutable AMOUNT_TO_CONVERT; // fixed amount of PSM tokens required to withdraw yield in the contract
    uint256 public immutable FUNDING_PHASE_DURATION; // seconds after deployment before Portal can be activated
    uint256 public immutable FUNDING_MIN_AMOUNT; // minimum funding required before Portal can be activated
    uint256 public immutable CREATION_TIME; // time stamp of deployment
    uint256 public constant FUNDING_APR = 48; // annual redemption value increase (APR) of bTokens
    uint256 public constant FUNDING_MAX_RETURN_PERCENT = 1000; // maximum redemption value percent of bTokens (must be >100)
    uint256 public constant FUNDING_REWARD_SHARE = 10; // 10% of yield goes to the funding pool until funders are paid back
    uint256 immutable FUNDING_REWARD; // The token amount transferred to the reward Pool when calling convert
    address constant WETH_ADDRESS = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant PSM_ADDRESS = 0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5; // address of PSM token
    address constant USDCE_WATER = 0x806e8538FC05774Ea83d9428F778E423F6492475;
    address constant USDC_WATER = 0x9045ae36f963b7184861BDce205ea8B08913B48c;
    address constant ARB_WATER = 0x175995159ca4F833794C88f7873B3e7fB12Bb1b6;
    address constant WBTC_WATER = 0x4e9e41Bbf099fE0ef960017861d181a9aF6DDa07;
    address constant WETH_WATER = 0x8A98929750e6709Af765F976c6bddb5BfFE6C06c;
    address constant LINK_WATER = 0xFF614Dd6fC857e4daDa196d75DaC51D522a2ccf7;
    bool public isActiveLP; // Will be set to true when funding phase ends
    bool public bTokenCreated; // flag for bToken deployment
    uint256 public fundingBalance; // sum of all PSM funding contributions
    uint256 public fundingRewardPool; // amount of PSM available for redemption against bTokens
    mapping(address portal => bool isRegistered) public registeredPortals;
    mapping(address portal => mapping(address asset => address vault)) public vaults;
    event LP_Activated(address indexed, uint256 fundingBalance);
    event ConvertExecuted(address indexed token,address indexed caller,address indexed recipient,uint256 amount);
    event FundingReceived(address indexed, uint256 amount);
    event FundingWithdrawn(address indexed, uint256 amount);
    event RewardsRedeemed(address indexed,uint256 amountBurned,uint256 amountReceived);
    modifier activeLP() {
        if (!isActiveLP) {
            revert InactiveLP();}
        _;}
    modifier inactiveLP() {
        if (isActiveLP) {
            revert ActiveLP();}
        _;}
    modifier registeredPortal() {
        if (!registeredPortals[msg.sender]) {
            revert PortalNotRegistered();}
        _;}
    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();}
        _;}
    function PSM_sendToPortalUser(address _recipient,uint256 _amount) external registeredPortal {
        IERC20(PSM_ADDRESS).transfer(_recipient, _amount);}
    function registerPortal(address _portal,address _asset,address _vault) external onlyOwner {
        registeredPortals[_portal] = true;
        vaults[_portal][_asset] = _vault;}
    function removeOwner() external {
        if (block.timestamp < OWNER_EXPIRY_TIME) {
            revert OwnerNotExpired();}
        if (owner == address(0)) {
            revert OwnerRevoked();}
        owner = address(0);}
    function depositToYieldSource(address _asset,uint256 _amount) external registeredPortal {
        if (IWater(vaults[msg.sender][_asset]).lockTime() > 0) {
            revert TimeLockActive();}
        IWater(vaults[msg.sender][_asset]).deposit(_amount, address(this));}
    function withdrawFromYieldSource(address _asset,address payable _user,uint256 _amount) external registeredPortal {
        uint256 withdrawShares = IWater(vaults[msg.sender][_asset]).convertToShares(_amount);
        uint256 withdrawAssets = IWater(vaults[msg.sender][_asset]).convertToAssets(withdrawShares);
        uint256 balanceBefore;
        uint256 balanceAfter;
        address tokenAdr = (_asset == address(0)) 
        ? WETH_ADDRESS 
        : _asset;
        balanceBefore = IERC20(tokenAdr).balanceOf(address(this));
        IWater(vaults[msg.sender][_asset]).withdraw(withdrawAssets,address(this),address(this));
        balanceAfter = IERC20(tokenAdr).balanceOf(address(this));
        _amount = balanceAfter - balanceBefore;
        if (_asset == address(0)) {
            IWETH(WETH_ADDRESS).withdrawTo(_user, _amount);
        } else {
            IERC20(tokenAdr).safeTransfer(_user, _amount);}}
    function _getProfitOfPortal(address _portal) private view returns (uint256 profitAsset, uint256 profitShares) {
        IPortalV2MultiAsset portal = IPortalV2MultiAsset(_portal);
        address asset = portal.PRINCIPAL_TOKEN_ADDRESS();
        uint256 sharesOwned = IERC20(vaults[_portal][asset]).balanceOf(address(this));
        uint256 sharesDebt = IWater(vaults[_portal][asset]).convertToShares(portal.totalPrincipalStaked());
        profitShares = (sharesOwned > sharesDebt)
            ? sharesOwned - sharesDebt
            : 0;
        profitAsset = IWater(vaults[_portal][asset]).convertToAssets(profitShares);}
    function getProfitOfPortal(address _portal) external view returns (uint256 profitOfPortal) {
        address asset = IPortalV2MultiAsset(_portal).PRINCIPAL_TOKEN_ADDRESS();
        (uint256 profit, ) = _getProfitOfPortal(_portal);
        uint256 denominator = IWater(vaults[_portal][asset]).DENOMINATOR();
        uint256 withdrawalFee = IWater(vaults[_portal][asset]).withdrawalFees();
        profitOfPortal = (profit * (denominator - withdrawalFee)) / denominator;}
    function collectProfitOfPortal(address _portal) public {
        address asset = IPortalV2MultiAsset(_portal).PRINCIPAL_TOKEN_ADDRESS();
        (uint256 profit, uint256 shares) = _getProfitOfPortal(_portal);
        if (profit == 0 || shares == 0) {
            revert NoProfit();}
        IWater(vaults[_portal][asset]).withdraw(profit,address(this),address(this));}
    function increaseAllowanceVault(address _portal) public {
        address asset = IPortalV2MultiAsset(_portal).PRINCIPAL_TOKEN_ADDRESS();
        address tokenAdr = (asset == address(0)) ? WETH_ADDRESS : asset;
        IERC20(tokenAdr).safeIncreaseAllowance(vaults[_portal][asset],MAX_UINT);}
    function convert(address _token,address _recipient,uint256 _minReceived,uint256 _deadline) external nonReentrant activeLP {
        if (_token == PSM_ADDRESS ||_token == USDCE_WATER ||_token == USDC_WATER || _token == ARB_WATER ||_token == WBTC_WATER ||_token == WETH_WATER || _token == LINK_WATER || _recipient == address(0)) {
            revert InvalidAddress();}
        if (_minReceived == 0) {
            revert InvalidAmount();}
        if (_deadline < block.timestamp) {
            revert DeadlineExpired();}
        uint256 contractBalance;
        if (_token == address(0)) {
            contractBalance = address(this).balance;
        } else {
            contractBalance = IERC20(_token).balanceOf(address(this));}
        if (contractBalance < _minReceived) {
            revert InsufficientReceived();}
        uint256 maxRewards = bToken.totalSupply();
        if (fundingRewardPool + FUNDING_REWARD >= maxRewards) {
            fundingRewardPool = maxRewards;
        } else {
            fundingRewardPool += FUNDING_REWARD;}
        IERC20(PSM_ADDRESS).transferFrom(msg.sender,address(this),AMOUNT_TO_CONVERT);
        if (_token == address(0)) {
            (bool sent, ) = payable(_recipient).call{value: contractBalance}("");
            if (!sent) {
                revert FailedToSendNativeToken();}
        } else {
            IERC20(_token).safeTransfer(_recipient, contractBalance);}
        emit ConvertExecuted(_token, msg.sender, _recipient, contractBalance);}
    function activateLP() external inactiveLP {
        if (block.timestamp < CREATION_TIME + FUNDING_PHASE_DURATION) {
            revert FundingPhaseOngoing();}
        if (fundingBalance < FUNDING_MIN_AMOUNT) {
            revert FundingInsufficient();}
        isActiveLP = true;
        emit LP_Activated(address(this), fundingBalance);}
    function contributeFunding(uint256 _amount) external inactiveLP {
        if (_amount == 0) {
            revert InvalidAmount();}
        uint256 mintableAmount = (_amount * FUNDING_MAX_RETURN_PERCENT) / 100;
        fundingBalance += _amount;
        IERC20(PSM_ADDRESS).transferFrom(msg.sender, address(this), _amount);
        bToken.mint(msg.sender, mintableAmount);
        emit FundingReceived(msg.sender, mintableAmount);}
    function withdrawFunding(uint256 _amountBtoken) external inactiveLP {
        if (_amountBtoken == 0) {
            revert InvalidAmount();}
        uint256 withdrawAmount = (_amountBtoken * 100) /FUNDING_MAX_RETURN_PERCENT;
        fundingBalance -= withdrawAmount;
        bToken.burnFrom(msg.sender, _amountBtoken);
        IERC20(PSM_ADDRESS).transfer(msg.sender, withdrawAmount);
        emit FundingWithdrawn(msg.sender, withdrawAmount);}
    function getBurnValuePSM(uint256 _amount) public view activeLP returns (uint256 burnValue) {
        uint256 minValue = (_amount * 100) / FUNDING_MAX_RETURN_PERCENT;
        uint256 accruedValue = (_amount *(block.timestamp - CREATION_TIME) *FUNDING_APR) / (100 * SECONDS_PER_YEAR);
        uint256 maxValue = _amount;
        uint256 currentValue = minValue + accruedValue;
        burnValue = (currentValue < maxValue) ? currentValue : maxValue;}
    function getBurnableBtokenAmount()public view activeLP returns (uint256 amountBurnable){
        uint256 burnValueFullToken = getBurnValuePSM(1e18) + 1;
        amountBurnable = (fundingRewardPool * 1e18) / burnValueFullToken;}
    function burnBtokens(uint256 _amount) external {
        if (_amount == 0) {
            revert InvalidAmount();}
        uint256 burnable = getBurnableBtokenAmount();
        if (_amount > burnable) {
            revert InvalidAmount();}
        uint256 amountToReceive = getBurnValuePSM(_amount);
        fundingRewardPool -= amountToReceive;
        bToken.burnFrom(msg.sender, _amount);
        IERC20(PSM_ADDRESS).transfer(msg.sender, amountToReceive);
        emit RewardsRedeemed(msg.sender, _amount, amountToReceive);}
    function create_bToken() external inactiveLP {
        if (bTokenCreated) {
            revert TokenExists();}
        bTokenCreated = true;
        string memory name = "bVaultkaLending";
        string memory symbol = "bVKA-L";
        bToken = new MintBurnToken(name, symbol);
        bTokenAddress = address(bToken);}
    receive() external payable {}
    fallback() external payable {}}