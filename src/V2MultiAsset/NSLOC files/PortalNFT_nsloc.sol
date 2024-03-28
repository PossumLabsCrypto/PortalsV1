// SPDX-License-Identifier: GPL-2.0-only
pragma solidity =0.8.19;
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {IPortalV2MultiAsset} from "./interfaces/IPortalV2MultiAsset.sol";
error NotOwner();
error NotOwnerOfNFT();
contract PortalNFT is ERC721URIStorage {
    constructor(uint256 _decimalsAdjustment,string memory _name,string memory _symbol,string memory _metadataURI
    ) ERC721(_name, _symbol) {
        OWNER = msg.sender;DECIMALS_ADJUSTMENT = _decimalsAdjustment;metadataURI = _metadataURI;portal = IPortalV2MultiAsset(msg.sender);}
    IPortalV2MultiAsset public portal;
    address private immutable OWNER;
    struct AccountNFT {
        uint256 mintTime;
        uint256 lastMaxLockDuration;
        uint256 stakedBalance;
        uint256 portalEnergy;}
    mapping(uint256 tokenID => AccountNFT) public accounts;
    uint256 public totalSupply;
    uint256 private constant SECONDS_PER_YEAR = 31536000;
    uint256 private immutable DECIMALS_ADJUSTMENT;
    string private metadataURI; // Metadata URI for all NFTs of this Portal
    modifier onlyOwner() {
        if (msg.sender != OWNER) {
            revert NotOwner();}
        _;}
    function getAccount(
        uint256 _tokenId
    ) public view returns (uint256 stakedBalance, uint256 portalEnergy) {
        _requireMinted(_tokenId);
        AccountNFT memory account = accounts[_tokenId];
        uint256 portalEnergyEarned = (account.stakedBalance *(block.timestamp - account.mintTime) * 1e18);
        uint256 portalEnergyIncrease = (account.stakedBalance *(portal.maxLockDuration() - account.lastMaxLockDuration) * 1e18);
        account.portalEnergy += (portalEnergyEarned + portalEnergyIncrease) / (SECONDS_PER_YEAR * DECIMALS_ADJUSTMENT);
        stakedBalance = account.stakedBalance;
        portalEnergy = account.portalEnergy;}
    function mint(
        address _recipient,
        uint256 _lastMaxLockDuration,
        uint256 _stakedBalance,
        uint256 _portalEnergy
    ) external onlyOwner returns (uint256 nftID) {
        totalSupply++;
        _safeMint(_recipient, totalSupply);
        _setTokenURI(totalSupply, metadataURI);
        AccountNFT memory account;
        account.mintTime = block.timestamp;
        account.lastMaxLockDuration = _lastMaxLockDuration;
        account.stakedBalance = _stakedBalance;
        account.portalEnergy = _portalEnergy;
        accounts[totalSupply] = account;
        nftID = totalSupply;}
    function redeem(
        address ownerOfNFT,
        uint256 _tokenId
    ) external onlyOwner returns (uint256 stakedBalance, uint256 portalEnergy) {
        if (ownerOfNFT != _ownerOf(_tokenId)) {
            revert NotOwnerOfNFT();}
        (stakedBalance, portalEnergy) = getAccount(_tokenId);
        _burn(_tokenId);
        delete accounts[_tokenId];}}