// SPDX-License-Identifier: GPL-2.0-only
pragma solidity =0.8.19;
import {MintBurnToken} from "./MintBurnToken.sol";
import {PortalNFT} from "./PortalNFT.sol";
import {IVirtualLP} from "./interfaces/IVirtualLP.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
interface IWETH {
    function deposit() external payable;}
error DeadlineExpired();
error DurationLocked();
error DurationTooLow();
error EmptyAccount();
error InactiveLP();
error InsufficientBalance();
error InsufficientReceived();
error InsufficientStakeBalance();
error InvalidAddress();
error InvalidAmount();
error InvalidConstructor();
error NativeTokenNotAllowed();
error TokenExists();
contract PortalV2MultiAsset is ReentrancyGuard {
    constructor(address _VIRTUAL_LP,uint256 _CONSTANT_PRODUCT,address _PRINCIPAL_TOKEN_ADDRESS,uint256 _DECIMALS,string memory _PRINCIPAL_NAME,string memory _PRINCIPAL_SYMBOL,string memory _META_DATA_URI) {
        if (_VIRTUAL_LP == address(0)) {
            revert InvalidConstructor();}
        if (_CONSTANT_PRODUCT < 1e25) {
            revert InvalidConstructor();}
        if (_DECIMALS == 0) {
            revert InvalidConstructor();}
        if (keccak256(bytes(_PRINCIPAL_NAME)) == keccak256(bytes(""))) {
            revert InvalidConstructor();}
        if (keccak256(bytes(_PRINCIPAL_SYMBOL)) == keccak256(bytes(""))) {
            revert InvalidConstructor();}
        if (keccak256(bytes(_META_DATA_URI)) == keccak256(bytes(""))) {
            revert InvalidConstructor();}
        VIRTUAL_LP = _VIRTUAL_LP;
        CONSTANT_PRODUCT = _CONSTANT_PRODUCT;
        PRINCIPAL_TOKEN_ADDRESS = _PRINCIPAL_TOKEN_ADDRESS;
        DECIMALS_ADJUSTMENT = 10 ** _DECIMALS;
        NFT_META_DATA = _META_DATA_URI;
        PRINCIPAL_NAME = _PRINCIPAL_NAME;
        PRINCIPAL_SYMBOL = _PRINCIPAL_SYMBOL;
        CREATION_TIME = block.timestamp;
        virtualLP = IVirtualLP(VIRTUAL_LP);
        DENOMINATOR = SECONDS_PER_YEAR * DECIMALS_ADJUSTMENT;}
    using SafeERC20 for IERC20;
    address constant WETH_ADDRESS = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant PSM_ADDRESS = 0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5; // address of PSM token
    uint256 constant TERMINAL_MAX_LOCK_DURATION = 157680000; // terminal maximum lock duration of a user stake in seconds (5y)
    uint256 constant SECONDS_PER_YEAR = 31536000; // seconds in a 365 day year
    string PRINCIPAL_NAME; // Name of the staking token
    string PRINCIPAL_SYMBOL; // Symbol of the staking token
    uint256 public immutable CREATION_TIME; // time stamp of deployment
    uint256 public immutable DECIMALS_ADJUSTMENT; // scaling factor to account for the decimals of the principal token
    uint256 public immutable DENOMINATOR; // used in calculations around earning Portal Energy
    MintBurnToken public portalEnergyToken; // the ERC20 representation of portalEnergy
    PortalNFT public portalNFT; // The NFT contract deployed by the Portal that can store accounts
    bool portalEnergyTokenCreated; // flag for PE token deployment
    bool portalNFTcreated; // flag for Portal NFT contract deployment
    address public immutable PRINCIPAL_TOKEN_ADDRESS; // address of the token accepted by the strategy as deposit
    string public NFT_META_DATA; // IPFS uri for Portal Position NFTs metadata
    uint256 public maxLockDuration = 7776000; // starting value for maximum allowed lock duration of user balance in seconds (90 days)
    uint256 public totalPrincipalStaked; // returns how much principal is staked by all users combined
    bool public lockDurationUpdateable = true; // flag to signal if the lock duration can still be updated
    IVirtualLP private virtualLP;
    uint256 public immutable CONSTANT_PRODUCT; // The constantProduct with which the Portal will be activated
    address public immutable VIRTUAL_LP; // Address of the collective, virtual LP
    uint256 public constant LP_PROTECTION_HURDLE = 1; // percent reduction of output amount when minting or buying PE
    struct Account {
        uint256 lastUpdateTime;
        uint256 lastMaxLockDuration;
        uint256 stakedBalance;
        uint256 maxStakeDebt;
        uint256 portalEnergy;}
    mapping(address => Account) public accounts; // Associate users with their stake position
    event maxLockDurationUpdated(uint256 newDuration);
    event PortalEnergyBuyExecuted(address indexed caller,address indexed recipient,uint256 amount);
    event PortalEnergySellExecuted(address indexed caller,address indexed recipient,uint256 amount);
    event PortalEnergyMinted(address indexed caller,address indexed recipient,uint256 amount);
    event PortalEnergyBurned(address indexed caller,address indexed recipient,uint256 amount);
    event PortalNFTminted(address indexed caller,address indexed recipient,uint256 nftID);
    event PortalNFTredeemed(address indexed caller,address indexed recipient,uint256 nftID);
    event PrincipalStaked(address indexed user, uint256 amountStaked);
    event PrincipalUnstaked(address indexed user, uint256 amountUnstaked);
    event StakePositionUpdated(address indexed user,uint256 lastUpdateTime,uint256 lastMaxLockDuration,uint256 stakedBalance,uint256 maxStakeDebt,uint256 portalEnergy);
    modifier activeLP() {
        if (!virtualLP.isActiveLP()) {
            revert InactiveLP();}
        _;}
    function getUpdateAccount(address _user,uint256 _amount,bool _isPositiveAmount)public view returns (uint256 lastUpdateTime,uint256 lastMaxLockDuration,uint256 stakedBalance,uint256 maxStakeDebt,uint256 portalEnergy,uint256 availableToWithdraw,uint256 portalEnergyTokensRequired){
        Account memory account = accounts[_user];
        uint256 amount = _amount; // to avoid stack too deep issue
        bool isPositive = _isPositiveAmount; // to avoid stack too deep issue
        uint256 portalEnergyNetChange;
        uint256 timePassed = block.timestamp - account.lastUpdateTime;
        uint256 maxLockDifference = maxLockDuration - account.lastMaxLockDuration;
        uint256 adjustedPE = amount * maxLockDuration * 1e18;
        stakedBalance = account.stakedBalance;
        if (!isPositive && amount > stakedBalance) {
            revert InsufficientStakeBalance();}
        if (account.lastUpdateTime > 0) {
            uint256 portalEnergyEarned = stakedBalance * timePassed;
            uint256 portalEnergyIncrease = stakedBalance * maxLockDifference;
            portalEnergyNetChange =((portalEnergyEarned + portalEnergyIncrease) * 1e18) /DENOMINATOR;}
        uint256 portalEnergyAdjustment = adjustedPE / DENOMINATOR;
        portalEnergyTokensRequired = !isPositive && portalEnergyAdjustment >(account.portalEnergy + portalEnergyNetChange) ? portalEnergyAdjustment -(account.portalEnergy + portalEnergyNetChange): 0;
        lastUpdateTime = block.timestamp;
        lastMaxLockDuration = maxLockDuration;
        stakedBalance = isPositive ? stakedBalance + amount : stakedBalance - amount;
        maxStakeDebt = (stakedBalance * maxLockDuration * 1e18) / DENOMINATOR;
        portalEnergy = isPositive? account.portalEnergy +portalEnergyNetChange +portalEnergyAdjustment: account.portalEnergy +portalEnergyTokensRequired +portalEnergyNetChange -portalEnergyAdjustment;
        availableToWithdraw = portalEnergy >= maxStakeDebt? stakedBalance: (stakedBalance * portalEnergy) / maxStakeDebt;}
    function _updateAccount(address _user,uint256 _stakedBalance,uint256 _maxStakeDebt,uint256 _portalEnergy) private {
        Account storage account = accounts[_user];
        account.lastUpdateTime = block.timestamp;
        account.lastMaxLockDuration = maxLockDuration;
        account.stakedBalance = _stakedBalance;
        account.maxStakeDebt = _maxStakeDebt;
        account.portalEnergy = _portalEnergy;
        emit StakePositionUpdated(_user,account.lastUpdateTime,account.lastMaxLockDuration,account.stakedBalance,account.maxStakeDebt,account.portalEnergy);}
    function stake(uint256 _amount) external payable activeLP nonReentrant {
        if (PRINCIPAL_TOKEN_ADDRESS == address(0)) {
            _amount = msg.value;
            IWETH(WETH_ADDRESS).deposit{value: _amount}();
            IERC20(WETH_ADDRESS).transfer(VIRTUAL_LP, _amount);
        } else {
            if (msg.value > 0) {
                revert NativeTokenNotAllowed();}
            IERC20(PRINCIPAL_TOKEN_ADDRESS).safeTransferFrom(msg.sender,VIRTUAL_LP,_amount);}
        if (_amount == 0) {
            revert InvalidAmount();}
        ( ,,uint256 stakedBalance,uint256 maxStakeDebt,uint256 portalEnergy,,) = getUpdateAccount(msg.sender, _amount, true);
        _updateAccount(msg.sender, stakedBalance, maxStakeDebt, portalEnergy);
        totalPrincipalStaked += _amount;
        virtualLP.depositToYieldSource(PRINCIPAL_TOKEN_ADDRESS, _amount);
        emit PrincipalStaked(msg.sender, _amount);}
    function unstake(uint256 _amount) external nonReentrant {
        if (_amount == 0) {
            revert InvalidAmount();}
        (,,uint256 stakedBalance,uint256 maxStakeDebt,uint256 portalEnergy,,uint256 portalEnergyTokensRequired) = getUpdateAccount(msg.sender, _amount, false);
        _updateAccount(msg.sender, stakedBalance, maxStakeDebt, portalEnergy);
        totalPrincipalStaked -= _amount;
        if (portalEnergyTokensRequired > 0) {
            portalEnergyToken.burnFrom(msg.sender, portalEnergyTokensRequired);}
        virtualLP.withdrawFromYieldSource(PRINCIPAL_TOKEN_ADDRESS,payable(msg.sender),_amount);
        emit PrincipalUnstaked(msg.sender, _amount);}
    function create_portalNFT() external {
        if (portalNFTcreated) {
            revert TokenExists();}
        portalNFTcreated = true;
        string memory name = concatenate("Portal-Position-", PRINCIPAL_NAME);
        string memory symbol = concatenate("P-", PRINCIPAL_SYMBOL);
        portalNFT = new PortalNFT(DECIMALS_ADJUSTMENT,name,symbol,NFT_META_DATA);}
    function mintNFTposition(address _recipient) external {
        if (_recipient == address(0)) {
            revert InvalidAddress();}
        (,uint256 lastMaxLockDuration,uint256 stakedBalance,,uint256 portalEnergy,,) = getUpdateAccount(msg.sender, 0, true);
        if (portalEnergy == 0 && stakedBalance == 0) {
            revert EmptyAccount();}
        delete accounts[msg.sender];
        uint256 nftID = portalNFT.mint(_recipient,lastMaxLockDuration,stakedBalance,portalEnergy);
        emit PortalNFTminted(msg.sender, _recipient, nftID);}
    function redeemNFTposition(uint256 _tokenId) external {
        (,,uint256 stakedBalance,uint256 maxStakeDebt,uint256 portalEnergy,,) = getUpdateAccount(msg.sender, 0, true);
        (uint256 stakedBalanceNFT, uint256 portalEnergyNFT) = portalNFT.redeem(msg.sender,_tokenId);
        stakedBalance += stakedBalanceNFT;
        portalEnergy += portalEnergyNFT;
        maxStakeDebt = (stakedBalance * maxLockDuration * 1e18) / DENOMINATOR;
        _updateAccount(msg.sender, stakedBalance, maxStakeDebt, portalEnergy);
        emit PortalNFTredeemed(msg.sender, msg.sender, _tokenId);}
    function buyPortalEnergy(address _recipient,uint256 _amountInputPSM,uint256 _minReceived,uint256 _deadline) external nonReentrant {
        if (_amountInputPSM == 0 || _minReceived == 0) {
            revert InvalidAmount();}
        if (_recipient == address(0)) {
            revert InvalidAddress();}
        if (_deadline < block.timestamp) {
            revert DeadlineExpired();}
        uint256 amountReceived = quoteBuyPortalEnergy(_amountInputPSM);
        if (amountReceived < _minReceived) {
            revert InsufficientReceived();}
        accounts[_recipient].portalEnergy += amountReceived;
        IERC20(PSM_ADDRESS).transferFrom(msg.sender,VIRTUAL_LP,_amountInputPSM);
        emit PortalEnergyBuyExecuted(msg.sender, _recipient, amountReceived);}
    function sellPortalEnergy(address _recipient,uint256 _amountInputPE,uint256 _minReceived,uint256 _deadline) external nonReentrant {
        if (_amountInputPE == 0 || _minReceived == 0) {
            revert InvalidAmount();}
        if (_recipient == address(0)) {
            revert InvalidAddress();}
        if (_deadline < block.timestamp) {
            revert DeadlineExpired();}
        (,,uint256 stakedBalance,uint256 maxStakeDebt,uint256 portalEnergy,,) = getUpdateAccount(msg.sender, 0, true);
        if (portalEnergy < _amountInputPE) {
            revert InsufficientBalance();}
        uint256 amountReceived = quoteSellPortalEnergy(_amountInputPE);
        if (amountReceived < _minReceived) {
            revert InsufficientReceived();}
        portalEnergy -= _amountInputPE;
        _updateAccount(msg.sender, stakedBalance, maxStakeDebt, portalEnergy);
        virtualLP.PSM_sendToPortalUser(_recipient, amountReceived);
        emit PortalEnergySellExecuted(msg.sender, _recipient, _amountInputPE);}
    function quoteBuyPortalEnergy(uint256 _amountInputPSM) public view activeLP returns (uint256 amountReceived) {
        uint256 reserve0 = IERC20(PSM_ADDRESS).balanceOf(VIRTUAL_LP) -virtualLP.fundingRewardPool();
        uint256 reserve1 = CONSTANT_PRODUCT / reserve0;
        _amountInputPSM =(_amountInputPSM * (100 - LP_PROTECTION_HURDLE)) /100;
        amountReceived =(_amountInputPSM * reserve1) /(_amountInputPSM + reserve0);}
    function quoteSellPortalEnergy(uint256 _amountInputPE) public view activeLP returns (uint256 amountReceived) {
        uint256 reserve0 = IERC20(PSM_ADDRESS).balanceOf(VIRTUAL_LP) -virtualLP.fundingRewardPool();
        uint256 reserve1 = (reserve0 > CONSTANT_PRODUCT)
            ? 1
            : CONSTANT_PRODUCT / reserve0;
        amountReceived =(_amountInputPE * reserve0) /(_amountInputPE + reserve1);}
    function concatenate(string memory a,string memory b) internal pure returns (string memory) {
        return string(abi.encodePacked(a, b));}
    function create_portalEnergyToken() external {
        if (portalEnergyTokenCreated) {
            revert TokenExists();}
        portalEnergyTokenCreated = true;
        string memory name = concatenate("PE-", PRINCIPAL_NAME);
        string memory symbol = concatenate("PE-", PRINCIPAL_SYMBOL);
        portalEnergyToken = new MintBurnToken(name, symbol);}
    function burnPortalEnergyToken(address _recipient,uint256 _amount) external {
        if (_amount == 0) {
            revert InvalidAmount();}
        if (_recipient == address(0)) {
            revert InvalidAddress();}
        accounts[_recipient].portalEnergy += _amount;
        portalEnergyToken.burnFrom(msg.sender, _amount);
        emit PortalEnergyBurned(msg.sender, _recipient, _amount);}
    function mintPortalEnergyToken(address _recipient,uint256 _amount) external {
        if (_amount == 0) {
            revert InvalidAmount();}
        if (_recipient == address(0)) {
            revert InvalidAddress();}
        (,,uint256 stakedBalance,uint256 maxStakeDebt,uint256 portalEnergy,,) = getUpdateAccount(msg.sender, 0, true);
        if (portalEnergy < _amount) {
            revert InsufficientBalance();}
        portalEnergy -= _amount;
        _updateAccount(msg.sender, stakedBalance, maxStakeDebt, portalEnergy);
        portalEnergyToken.mint(_recipient, _amount);
        emit PortalEnergyMinted(msg.sender, _recipient, _amount);}
    function updateMaxLockDuration() external {
        if (lockDurationUpdateable == false) {
            revert DurationLocked();}
        uint256 newValue = 2 * (block.timestamp - CREATION_TIME);
        if (newValue <= maxLockDuration) {
            revert DurationTooLow();}
        if (newValue >= TERMINAL_MAX_LOCK_DURATION) {
            maxLockDuration = TERMINAL_MAX_LOCK_DURATION;
            lockDurationUpdateable = false;
        } else if (newValue > maxLockDuration) {
            maxLockDuration = newValue;}
        emit maxLockDurationUpdated(maxLockDuration);}}