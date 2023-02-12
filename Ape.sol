//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import "./Banana.sol";

contract Ape is ERC721Enumerable, Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    struct ApeInfo {
        uint256 tokenId;
        uint256 apeType;
    }

    // CONSTANTS

    uint256 public constant APES_PER_BANANA_MINT_LEVEL = 5000;

    uint256 public constant NUM_GEN0_APES = 10_000;
    uint256 public constant NUM_GEN1_APES = 10_000;

    uint256 public constant APE_TYPE = 1;
    uint256 public constant ALPHA_APE_TYPE = 2;

    uint256 public constant APE_YIELD = 1;
    uint256 public constant ALPHA_APE_YIELD = 3;

    uint256 public constant PROMOTIONAL_APES = 50;

    // VAR

    // external contracts
    Banana public banana;
    address public forestAddress;
    address public apeTypeOracleAddress;

    // metadata URI
    string public BASE_URI;

    // ape type definitions (normal or alpha?)
    mapping(uint256 => uint256) public tokenTypes; // maps tokenId to its type
    mapping(uint256 => uint256) public typeYields; // maps ape type to yield

    // mint tracking
    uint256 public apesMintedWithBnb;
    uint256 public apesMintedWithBanana;
    uint256 public apesMintedPromotional;
    uint256 public apesMinted = 50; // First 50 ids are reserved for the promotional apes

    // mint control timestamps
    uint256 public startTimeBnb;
    uint256 public startTimeBanana;

    // BANANA mint price tracking
    uint256 public currentBnbMintCost = 0.25 ether;
    uint256 public currentBananaMintCost = 30_000 * 1e18;

    // EVENTS

    event onApeCreated(uint256 tokenId);
    event onApeRevealed(uint256 tokenId, uint256 apeType);

    /**
     * requires banana, apeType oracle address
     * banana: for liquidity bootstrapping and spending on apes
     * apeTypeOracleAddress: external ape generator uses secure RNG
     */
    constructor(Banana _banana, address _apeTypeOracleAddress, string memory _BASE_URI) ERC721("Home of The Apes", "HOTA") {
        require(address(_banana) != address(0));
        require(_apeTypeOracleAddress != address(0));

        // set required contract references
        banana = _banana;
        apeTypeOracleAddress = _apeTypeOracleAddress;

        // set base uri
        BASE_URI = _BASE_URI;

        // initialize token yield values for each ape type
        typeYields[APE_TYPE] = APE_YIELD;
        typeYields[ALPHA_APE_TYPE] = ALPHA_APE_YIELD;
    }

    // VIEWS

    // minting status

    function mintingStartedBnb() public view returns (bool) {
        return startTimeBnb != 0 && block.timestamp >= startTimeBnb;
    }

    function mintingStartedBanana() public view returns (bool) {
        return startTimeBanana != 0 && block.timestamp >= startTimeBanana;
    }

    // metadata

    function _baseURI() internal view virtual override returns (string memory) {
        return BASE_URI;
    }

    function getYield(uint256 _tokenId) public view returns (uint256) {
        require (_exists(_tokenId), "token does not exist");
        return typeYields[tokenTypes[_tokenId]];
    }

    function getType(uint256 _tokenId) public view returns (uint256) {
        require (_exists(_tokenId), "token does not exist");
        return tokenTypes[_tokenId];
    }

    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require (_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");
        return string(abi.encodePacked(_baseURI(), "/", tokenId.toString()));
    }

    // override

    function isApprovedForAll(address _owner, address _operator) public view override returns (bool) {
        // forest must be able to stake and unstake
        if (forestAddress != address(0) && _operator == forestAddress) return true;
        return super.isApprovedForAll(_owner, _operator);
    }

    // ADMIN

    function setForestAddress(address _forestAddress) external onlyOwner {
        forestAddress = _forestAddress;
    }

    function setBanana(address _banana) external onlyOwner {
        banana = Banana(_banana);
    }

    function setApeTypeOracleAddress(address _apeTypeOracleAddress) external onlyOwner {
        apeTypeOracleAddress = _apeTypeOracleAddress;
    }

    function setStartTimeBnb(uint256 _startTime) external onlyOwner {
        require (_startTime >= block.timestamp, "startTime cannot be in the past");
        startTimeBnb = _startTime;
    }

    function setStartTimeBanana(uint256 _startTime) external onlyOwner {
        require (_startTime >= block.timestamp, "startTime cannot be in the past");
        startTimeBanana = _startTime;
    }

    function setBaseURI(string calldata _BASE_URI) external onlyOwner {
        BASE_URI = _BASE_URI;
    }

    /**
     * @dev allows owner to send ERC20s held by this contract to target
     */
    function forwardERC20s(IERC20 _token, uint256 _amount, address target) external onlyOwner {
        _token.safeTransfer(target, _amount);
    }

    /**
     * @dev allows owner to withdraw BNB
     */
    function withdrawBNB(uint256 _amount) external payable onlyOwner {
        require(address(this).balance >= _amount, "not enough bnb");
        address payable to = payable(_msgSender());
        (bool sent, ) = to.call{value: _amount}("");
        require(sent, "failed to send bnb");
    }

    // MINTING

    function _createApe(address to, uint256 tokenId) internal {
        require (apesMinted <= NUM_GEN0_APES + NUM_GEN1_APES, "cannot mint anymore apes");
        _safeMint(to, tokenId);

        emit onApeCreated(tokenId);
    }

    function _createApes(uint256 qty, address to) internal {
        for (uint256 i = 0; i < qty; i++) {
            apesMinted += 1;
            _createApe(to, apesMinted);
        }
    }

    /**
     * @dev as an anti cheat mechanism, an external automation will generate the NFT metadata and set the ape types via rng
     * - Using an external source of randomness ensures our mint cannot be cheated
     * - The external automation is open source and can be found on banana game's github
     * - Once the mint is finished, it is provable that this randomness was not tampered with by providing the seed
     * - Ape type can be set only once
     */
    function setApeType(uint256 tokenId, uint256 apeType) external {
        require(_msgSender() == apeTypeOracleAddress, "msgsender does not have permission");
        require(tokenTypes[tokenId] == 0, "that token's type has already been set");
        require(apeType == APE_TYPE || apeType == ALPHA_APE_TYPE, "invalid ape type");

        tokenTypes[tokenId] = apeType;
        emit onApeRevealed(tokenId, apeType);
    }

    /**
     * @dev Promotional GEN0 minting 
     * Can mint maximum of PROMOTIONAL_APES
     * All apes minted are from the same apeType
     */
    function mintPromotional(uint256 qty, uint256 apeType, address target) external onlyOwner {
        require (qty > 0, "quantity must be greater than 0");
        require ((apesMintedPromotional + qty) <= PROMOTIONAL_APES, "you can't mint that many right now");
        require(apeType == APE_TYPE || apeType == ALPHA_APE_TYPE, "invalid ape type");

        for (uint256 i = 0; i < qty; i++) {
            apesMintedPromotional += 1;
            require(tokenTypes[apesMintedPromotional] == 0, "that token's type has already been set");
            tokenTypes[apesMintedPromotional] = apeType;
            _createApe(target, apesMintedPromotional);
        }
    }

    /**
     * @dev GEN0 minting
     */
    function mintApeWithBnb(uint256 qty) external payable whenNotPaused {
        require (mintingStartedBnb(), "cannot mint right now");
        require (qty > 0 && qty <= 10, "quantity must be between 1 and 10");
        require ((apesMintedWithBnb + qty) <= (NUM_GEN0_APES - PROMOTIONAL_APES), "you can't mint that many right now");

        // calculate the transaction cost
        uint256 transactionCost = currentBnbMintCost * qty;
        require (msg.value >= transactionCost, "not enough bnb");

        apesMintedWithBnb += qty;

        // mint apes
        _createApes(qty, _msgSender());
    }

    /**
     * @dev GEN1 minting 
     */
    function mintApeWithBanana(uint256 qty) external whenNotPaused {
        require (mintingStartedBanana(), "cannot mint right now");
        require (qty > 0 && qty <= 10, "quantity must be between 1 and 10");
        require ((apesMintedWithBanana + qty) <= NUM_GEN1_APES, "you can't mint that many right now");

        // calculate transaction costs
        uint256 transactionCostBANANA = currentBananaMintCost * qty;
        require (banana.balanceOf(_msgSender()) >= transactionCostBANANA, "not enough banana");

        // raise the mint level and cost when this mint would place us in the next level
        // if you mint in the cost transition you get a discount =)
        if(apesMintedWithBanana <= APES_PER_BANANA_MINT_LEVEL && apesMintedWithBanana + qty > APES_PER_BANANA_MINT_LEVEL) {
            currentBananaMintCost = currentBananaMintCost * 2;
        }

        apesMintedWithBanana += qty;

        // spend banana
        banana.burn(_msgSender(), transactionCostBANANA);

        // mint apes
        _createApes(qty, _msgSender());
    }

    // Returns information for multiples apes
    function batchedApesOfOwner(address _owner, uint256 _offset, uint256 _maxSize) public view returns (ApeInfo[] memory) {
        if (_offset >= balanceOf(_owner)) {
            return new ApeInfo[](0);
        }

        uint256 outputSize = _maxSize;
        if (_offset + _maxSize >= balanceOf(_owner)) {
            outputSize = balanceOf(_owner) - _offset;
        }
        ApeInfo[] memory apes = new ApeInfo[](outputSize);

        for (uint256 i = 0; i < outputSize; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(_owner, _offset + i); // tokenOfOwnerByIndex comes from IERC721Enumerable

            apes[i] = ApeInfo({
                tokenId: tokenId,
                apeType: tokenTypes[tokenId]
            });
        }

        return apes;
    }
}
