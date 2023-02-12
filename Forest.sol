//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./Ape.sol";
import "./Upgrade.sol";
import "./Banana.sol";
import "./ForestProgression.sol";

contract Forest is ForestProgression, ReentrancyGuard {
    using SafeMath for uint256;

    // Constants
    uint256 public constant CLAIM_BANANA_CONTRIBUTION_PERCENTAGE = 10;
    uint256 public constant CLAIM_BANANA_BURN_PERCENTAGE = 10;
    uint256 public constant MAX_FATIGUE = 100000000000000;

    uint256 public yieldBPS = 16666666666666667; // banana per second per unit of yield

    uint256 public startTime;

    // Staking

    struct StakedApe {
        address owner;
        uint256 tokenId;
        uint256 startTimestamp;
        bool staked;
    }

    struct StakedApeInfo {
        uint256 apeId;
        uint256 upgradeId;
        uint256 apeBPM;
        uint256 upgradeBPM;
        uint256 banana;
        uint256 fatigue;
        uint256 timeUntilFatigued;
    }

    mapping(uint256 => StakedApe) public stakedApes; // tokenId => StakedApe
    mapping(address => mapping(uint256 => uint256)) private ownedApeStakes; // (address, index) => tokenid
    mapping(uint256 => uint256) private ownedApeStakesIndex; // tokenId => index in its owner's stake list
    mapping(address => uint256) public ownedApeStakesBalance; // address => stake count

    mapping(address => uint256) public fatiguePerMinute; // address => fatigue per minute in the forest
    mapping(uint256 => uint256) private apeFatigue; // tokenId => fatigue
    mapping(uint256 => uint256) private apeBanana; // tokenId => banana

    mapping(address => uint256[2]) private numberOfApes; // address => [number of regular apes, number of alpha apes]
    mapping(address => uint256) private totalBPM; // address => total BPM

    struct StakedUpgrade {
        address owner;
        uint256 tokenId;
        bool staked;
    }

    mapping(uint256 => StakedUpgrade) public stakedUpgrades; // tokenId => StakedUpgrade
    mapping(address => mapping(uint256 => uint256)) private ownedUpgradeStakes; // (address, index) => tokenid
    mapping(uint256 => uint256) private ownedUpgradeStakesIndex; // tokenId => index in its owner's stake list
    mapping(address => uint256) public ownedUpgradeStakesBalance; // address => stake count

    // Fatigue cooldowns

    struct RestingApe {
        address owner;
        uint256 tokenId;
        uint256 endTimestamp;
        bool present;
    }

    struct RestingApeInfo {
        uint256 tokenId;
        uint256 endTimestamp;
    }
    
    mapping(uint256 => RestingApe) public restingApes; // tokenId => RestingApe
    mapping(address => mapping(uint256 => uint256)) private ownedRestingApes; // (user, index) => resting ape id
    mapping(uint256 => uint256) private restingApesIndex; // tokenId => index in its owner's cooldown list
    mapping(address => uint256) public restingApesBalance; // address => cooldown count

    // Var

    Ape public ape;
    Upgrade public upgrade;
    Banana public banana;
    address public caveAddress;
    
    constructor(Ape _ape, Upgrade _upgrade, Banana _banana, Tree _tree, address _caveAddress) ForestProgression (_tree) {
        ape = _ape;
        upgrade = _upgrade;
        banana = _banana;
        caveAddress = _caveAddress;
    }

    // Views

    function _getUpgradeStakedForApe(address _owner, uint256 _apeId) internal view returns (uint256) {
        uint256 index = ownedApeStakesIndex[_apeId];
        return ownedUpgradeStakes[_owner][index];
    }

    function getFatiguePerMinuteWithModifier(address _owner) public view returns (uint256) {
        uint256 fatigueSkillModifier = getFatigueSkillModifier(_owner);
        return fatiguePerMinute[_owner].mul(fatigueSkillModifier).div(100);
    }

    function _getAlphaApeNumber(address _owner) internal view returns (uint256) {
        return numberOfApes[_owner][1];
    }

    /**
     * Returns the current ape's fatigue
     */
    function getFatigueAccruedForApe(uint256 _tokenId, bool checkOwnership) public view returns (uint256) {
        StakedApe memory stakedApe = stakedApes[_tokenId];
        require(stakedApe.staked, "this token isn't staked");
        if (checkOwnership) {
            require(stakedApe.owner == _msgSender(), "you don't own this token");
        }

        uint256 fatigue = (block.timestamp - stakedApe.startTimestamp) * getFatiguePerMinuteWithModifier(stakedApe.owner) / 60;
        fatigue += apeFatigue[_tokenId];
        if (fatigue > MAX_FATIGUE) {
            fatigue = MAX_FATIGUE;
        }
        return fatigue;
    }

    /**
     * Returns the timestamp of when the ape will be fatigued
     */
    function timeUntilFatiguedCalculation(uint256 _startTime, uint256 _fatigue, uint256 _fatiguePerMinute) public pure returns (uint256) {
        return _startTime + 60 * ( MAX_FATIGUE - _fatigue ) / _fatiguePerMinute;
    }

    function getTimeUntilFatigued(uint256 _tokenId, bool checkOwnership) public view returns (uint256) {
        StakedApe memory stakedApe = stakedApes[_tokenId];
        require(stakedApe.staked, "this token isn't staked");
        if (checkOwnership) {
            require(stakedApe.owner == _msgSender(), "you don't own this token");
        }
        return timeUntilFatiguedCalculation(stakedApe.startTimestamp, apeFatigue[_tokenId], getFatiguePerMinuteWithModifier(stakedApe.owner));
    }

    /**
     * Returns the timestamp of when the ape will be fully rested
     */
     function restingTimeCalculation(uint256 _apeType, uint256 _alphaApeType, uint256 _fatigue) public pure returns (uint256) {
        uint256 maxTime = 43200; //12*60*60
        if( _apeType == _alphaApeType){
            maxTime = maxTime / 2; // alpha apes rest half of the time of regular apes
        }

        if(_fatigue > MAX_FATIGUE / 2){
            return maxTime * _fatigue / MAX_FATIGUE;
        }

        return maxTime / 2; // minimum rest time is half of the maximum time
    }
    function getRestingTime(uint256 _tokenId, bool checkOwnership) public view returns (uint256) {
        StakedApe memory stakedApe = stakedApes[_tokenId];
        require(stakedApe.staked, "this token isn't staked");
        if (checkOwnership) {
            require(stakedApe.owner == _msgSender(), "you don't own this token");
        }

        return restingTimeCalculation(ape.getType(_tokenId), ape.ALPHA_APE_TYPE(), getFatigueAccruedForApe(_tokenId, false));
    }

    function getBananaAccruedForManyApes(uint256[] calldata _tokenIds) public view returns (uint256[] memory) {
        uint256[] memory output = new uint256[](_tokenIds.length);
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            output[i] = getBananaAccruedForApe(_tokenIds[i], false);
        }
        return output;
    }

    /**
     * Returns ape's banana from apeBanana mapping
     */
     function bananaAccruedCalculation(uint256 _initialBanana, uint256 _deltaTime, uint256 _bpm, uint256 _modifier, uint256 _fatigue, uint256 _fatiguePerMinute, uint256 _yieldBPS) public pure returns (uint256) {
        if(_fatigue >= MAX_FATIGUE){
            return _initialBanana;
        }

        uint256 a = _deltaTime * _bpm * _yieldBPS * _modifier * (MAX_FATIGUE - _fatigue) / ( 100 * MAX_FATIGUE);
        uint256 b = _deltaTime * _deltaTime * _bpm * _yieldBPS * _modifier * _fatiguePerMinute / (100 * 2 * 60 * MAX_FATIGUE);
        if(a > b){
            return _initialBanana + a - b;
        }

        return _initialBanana;
    }
    function getBananaAccruedForApe(uint256 _tokenId, bool checkOwnership) public view returns (uint256) {
        StakedApe memory stakedApe = stakedApes[_tokenId];
        address owner = stakedApe.owner;
        require(stakedApe.staked, "this token isn't staked");
        if (checkOwnership) {
            require(owner == _msgSender(), "you don't own this token");
        }

        // if apeFatigue = MAX_FATIGUE it means that apeBanana already has the correct value for the banana, since it didn't produce banana since last update
        uint256 apeFatigueLastUpdate = apeFatigue[_tokenId];
        if(apeFatigueLastUpdate == MAX_FATIGUE){
            return apeBanana[_tokenId];
        }

        uint256 timeUntilFatigued = getTimeUntilFatigued(_tokenId, false);

        uint256 endTimestamp;
        if(block.timestamp >= timeUntilFatigued){
            endTimestamp = timeUntilFatigued;
        } else {
            endTimestamp = block.timestamp;
        }

        uint256 bpm = ape.getYield(_tokenId);
        uint256 upgradeId = _getUpgradeStakedForApe(owner, _tokenId);

        if(upgradeId > 0){
            bpm += upgrade.getYield(upgradeId);
        }

        uint256 alphaApeSkillModifier = getAlphaApeSkillModifier(owner, _getAlphaApeNumber(owner));

        uint256 delta = endTimestamp - stakedApe.startTimestamp;

        return bananaAccruedCalculation(apeBanana[_tokenId], delta, bpm, alphaApeSkillModifier, apeFatigueLastUpdate, getFatiguePerMinuteWithModifier(owner), yieldBPS);
    }

    /**
     * Calculates the total BPM staked for a forest. 
     * This will also be used in the fatiguePerMinute calculation
     */
    function getTotalBPM(address _owner) public view returns (uint256) {
        return totalBPM[_owner];
    }

    function gameStarted() public view returns (bool) {
        return startTime != 0 && block.timestamp >= startTime;
    }

    function setStartTime(uint256 _startTime) external onlyOwner {
        require (_startTime >= block.timestamp, "startTime cannot be in the past");
        require(!gameStarted(), "game already started");
        startTime = _startTime;
    }

    /**
     * Updates the Fatigue per Minute
     * This function is called in _updateState
     */

    function fatiguePerMinuteCalculation(uint256 _bpm) public pure returns (uint256) {
        // NOTE: fatiguePerMinute[_owner] = 8610000000 + 166000000  * totalBPM[_owner] + -220833 * totalBPM[_owner]* totalBPM[_owner]  + 463 * totalBPM[_owner]*totalBPM[_owner]*totalBPM[_owner]; 
        uint256 a = 463;
        uint256 b = 220833;
        uint256 c = 166000000;
        uint256 d = 8610000000;
        if(_bpm == 0){
            return d;
        }
        return d + c * _bpm + a * _bpm * _bpm * _bpm - b * _bpm * _bpm;
    }

    function _updatefatiguePerMinute(address _owner) internal {
        fatiguePerMinute[_owner] = fatiguePerMinuteCalculation(totalBPM[_owner]);
    }

    /**
     * This function updates apeBanana and apeFatigue mappings
     * Calls _updatefatiguePerMinute
     * Also updates startTimestamp for apes
     * It should be used whenever the BPM changes
     */
    function _updateState(address _owner) internal {
        uint256 apeBalance = ownedApeStakesBalance[_owner];
        for (uint256 i = 0; i < apeBalance; i++) {
            uint256 tokenId = ownedApeStakes[_owner][i];
            StakedApe storage stakedApe = stakedApes[tokenId];
            if (stakedApe.staked && block.timestamp > stakedApe.startTimestamp) {
                apeBanana[tokenId] = getBananaAccruedForApe(tokenId, false);

                apeFatigue[tokenId] = getFatigueAccruedForApe(tokenId, false);

                stakedApe.startTimestamp = block.timestamp;
            }
        }
        _updatefatiguePerMinute(_owner);
    }

    //Claim
    function _claimBanana(address _owner) internal {
        uint256 totalClaimed = 0;

        uint256 caveSkillModifier = getCaveSkillModifier(_owner);
        uint256 burnSkillModifier = getBurnSkillModifier(_owner);

        uint256 apeBalance = ownedApeStakesBalance[_owner];

        for (uint256 i = 0; i < apeBalance; i++) {
            uint256 apeId = ownedApeStakes[_owner][i];

            totalClaimed += getBananaAccruedForApe(apeId, true); // also checks that msg.sender owns this token

            delete apeBanana[apeId];

            apeFatigue[apeId] = getFatigueAccruedForApe(apeId, false); // bug fix for fatigue

            stakedApes[apeId].startTimestamp = block.timestamp;
        }

        uint256 taxAmountCave = totalClaimed * (CLAIM_BANANA_CONTRIBUTION_PERCENTAGE - caveSkillModifier) / 100;
        uint256 taxAmountBurn = totalClaimed * (CLAIM_BANANA_BURN_PERCENTAGE - burnSkillModifier) / 100;

        totalClaimed = totalClaimed - taxAmountCave - taxAmountBurn;

        banana.mint(_msgSender(), totalClaimed);
        banana.mint(caveAddress, taxAmountCave);
    }

    function claimBanana() public nonReentrant whenNotPaused {
        address owner = _msgSender();
        _claimBanana(owner);
    }

    function unstakeApesAndUpgrades(uint256[] calldata _apeIds, uint256[] calldata _upgradeIds) public nonReentrant whenNotPaused {
        address owner = _msgSender();
        // Check 1:1 correspondency between ape and upgrade
        require(ownedApeStakesBalance[owner] - _apeIds.length >= ownedUpgradeStakesBalance[owner] - _upgradeIds.length, "needs at least ape for each tool");

        _claimBanana(owner);
        
        for (uint256 i = 0; i < _upgradeIds.length; i++) { //unstake upgrades
            uint256 upgradeId = _upgradeIds[i];

            require(stakedUpgrades[upgradeId].owner == owner, "you don't own this tool");
            require(stakedUpgrades[upgradeId].staked, "tool needs to be staked");

            totalBPM[owner] -= upgrade.getYield(upgradeId);
            upgrade.transferFrom(address(this), owner, upgradeId);

            _removeUpgrade(upgradeId);
        }

        for (uint256 i = 0; i < _apeIds.length; i++) { //unstake apes
            uint256 apeId = _apeIds[i];

            require(stakedApes[apeId].owner == owner, "you don't own this token");
            require(stakedApes[apeId].staked, "ape needs to be staked");

            if(ape.getType(apeId) == ape.ALPHA_APE_TYPE()){
                numberOfApes[owner][1]--; 
            } else {
                numberOfApes[owner][0]--; 
            }

            totalBPM[owner] -= ape.getYield(apeId);

            _moveApeToCooldown(apeId);
        }

        _updateState(owner);
    }

    // Stake

     /**
     * This function updates stake apes and upgrades
     * The upgrades are paired with the ape the upgrade will be applied
     */
    function stakeMany(uint256[] calldata _apeIds, uint256[] calldata _upgradeIds) public nonReentrant whenNotPaused {
        require(gameStarted(), "the game has not started");

        address owner = _msgSender();

        uint256 maxNumberApes = getMaxNumberApes(owner);
        uint256 apesAfterStaking = _apeIds.length + numberOfApes[owner][0] + numberOfApes[owner][1];
        require(maxNumberApes >= apesAfterStaking, "you can't stake that many apes");

        // Check 1:1 correspondency between ape and upgrade
        require(ownedApeStakesBalance[owner] + _apeIds.length >= ownedUpgradeStakesBalance[owner] + _upgradeIds.length, "needs at least ape for each tool");

        _claimBanana(owner); // Fix bug for incorrect time for upgrades

        for (uint256 i = 0; i < _apeIds.length; i++) { //stakes ape
            uint256 apeId = _apeIds[i];

            require(ape.ownerOf(apeId) == owner, "you don't own this token");
            require(ape.getType(apeId) > 0, "ape not yet revealed");
            require(!stakedApes[apeId].staked, "ape is already staked");

            _addApeToForest(apeId, owner);

            if(ape.getType(apeId) == ape.ALPHA_APE_TYPE()){
                numberOfApes[owner][1]++; 
            } else {
                numberOfApes[owner][0]++; 
            }

            totalBPM[owner] += ape.getYield(apeId);

            ape.transferFrom(owner, address(this), apeId);
        }
        uint256 maxLevelUpgrade = getMaxLevelUpgrade(owner);
        for (uint256 i = 0; i < _upgradeIds.length; i++) { //stakes upgrades
            uint256 upgradeId = _upgradeIds[i];

            require(upgrade.ownerOf(upgradeId) == owner, "you don't own this tool");
            require(!stakedUpgrades[upgradeId].staked, "tool is already staked");
            require(upgrade.getLevel(upgradeId) <= maxLevelUpgrade, "you can't equip that tool");

            upgrade.transferFrom(owner, address(this), upgradeId);
            totalBPM[owner] += upgrade.getYield(upgradeId);

             _addUpgradeToForest(upgradeId, owner);
        }
        _updateState(owner);
    }

    function _addApeToForest(uint256 _tokenId, address _owner) internal {
        stakedApes[_tokenId] = StakedApe({
            owner: _owner,
            tokenId: _tokenId,
            startTimestamp: block.timestamp,
            staked: true
        });
        _addStakeToOwnerEnumeration(_owner, _tokenId);
    }

    function _addUpgradeToForest(uint256 _tokenId, address _owner) internal {
        stakedUpgrades[_tokenId] = StakedUpgrade({
            owner: _owner,
            tokenId: _tokenId,
            staked: true
        });
        _addUpgradeToOwnerEnumeration(_owner, _tokenId);
    }


    function _addStakeToOwnerEnumeration(address _owner, uint256 _tokenId) internal {
        uint256 length = ownedApeStakesBalance[_owner];
        ownedApeStakes[_owner][length] = _tokenId;
        ownedApeStakesIndex[_tokenId] = length;
        ownedApeStakesBalance[_owner]++;
    }

    function _addUpgradeToOwnerEnumeration(address _owner, uint256 _tokenId) internal {
        uint256 length = ownedUpgradeStakesBalance[_owner];
        ownedUpgradeStakes[_owner][length] = _tokenId;
        ownedUpgradeStakesIndex[_tokenId] = length;
        ownedUpgradeStakesBalance[_owner]++;
    }

    function _moveApeToCooldown(uint256 _apeId) internal {
        address owner = stakedApes[_apeId].owner;

        uint256 endTimestamp = block.timestamp + getRestingTime(_apeId, false);
        restingApes[_apeId] = RestingApe({
            owner: owner,
            tokenId: _apeId,
            endTimestamp: endTimestamp,
            present: true
        });

        delete apeFatigue[_apeId];
        delete stakedApes[_apeId];
        _removeStakeFromOwnerEnumeration(owner, _apeId);
        _addCooldownToOwnerEnumeration(owner, _apeId);
    }

    // Cooldown
    function _removeUpgrade(uint256 _upgradeId) internal {
        address owner = stakedUpgrades[_upgradeId].owner;

        delete stakedUpgrades[_upgradeId];

        _removeUpgradeFromOwnerEnumeration(owner, _upgradeId);
    }

    function withdrawApes(uint256[] calldata _apeIds) public nonReentrant whenNotPaused {
        for (uint256 i = 0; i < _apeIds.length; i++) {
            uint256 _apeId = _apeIds[i];
            RestingApe memory resting = restingApes[_apeId];

            require(resting.present, "ape is not resting");
            require(resting.owner == _msgSender(), "you don't own this ape");
            require(block.timestamp >= resting.endTimestamp, "ape is still resting");

            _removeApeFromCooldown(_apeId);
            ape.transferFrom(address(this), _msgSender(), _apeId);
        }
    }

    function restakeRestedApes(uint256[] calldata _apeIds) public nonReentrant whenNotPaused {
        address owner = _msgSender();

        uint256 maxNumberApes = getMaxNumberApes(owner);
        uint256 apesAfterStaking = _apeIds.length + numberOfApes[owner][0] + numberOfApes[owner][1];
        require(maxNumberApes >= apesAfterStaking, "you can't stake that many apes");

        for (uint256 i = 0; i < _apeIds.length; i++) { //stakes ape
            uint256 _apeId = _apeIds[i];

            RestingApe memory resting = restingApes[_apeId];

            require(resting.present, "ape is not resting");
            require(resting.owner == owner, "you don't own this ape");
            require(block.timestamp >= resting.endTimestamp, "ape is still resting");

            _removeApeFromCooldown(_apeId);

            _addApeToForest(_apeId, owner);

            if(ape.getType(_apeId) == ape.ALPHA_APE_TYPE()){
                numberOfApes[owner][1]++; 
            } else {
                numberOfApes[owner][0]++; 
            }

            totalBPM[owner] += ape.getYield(_apeId);
        }
        _updateState(owner);
    }

    function _addCooldownToOwnerEnumeration(address _owner, uint256 _tokenId) internal {
        uint256 length = restingApesBalance[_owner];
        ownedRestingApes[_owner][length] = _tokenId;
        restingApesIndex[_tokenId] = length;
        restingApesBalance[_owner]++;
    }

    function _removeStakeFromOwnerEnumeration(address _owner, uint256 _tokenId) internal {
        uint256 lastTokenIndex = ownedApeStakesBalance[_owner] - 1;
        uint256 tokenIndex = ownedApeStakesIndex[_tokenId];

        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = ownedApeStakes[_owner][lastTokenIndex];

            ownedApeStakes[_owner][tokenIndex] = lastTokenId;
            ownedApeStakesIndex[lastTokenId] = tokenIndex;
        }

        delete ownedApeStakesIndex[_tokenId];
        delete ownedApeStakes[_owner][lastTokenIndex];
        ownedApeStakesBalance[_owner]--;
    }

    function _removeUpgradeFromOwnerEnumeration(address _owner, uint256 _tokenId) internal {
        uint256 lastTokenIndex = ownedUpgradeStakesBalance[_owner] - 1;
        uint256 tokenIndex = ownedUpgradeStakesIndex[_tokenId];

        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = ownedUpgradeStakes[_owner][lastTokenIndex];

            ownedUpgradeStakes[_owner][tokenIndex] = lastTokenId;
            ownedUpgradeStakesIndex[lastTokenId] = tokenIndex;
        }

        delete ownedUpgradeStakesIndex[_tokenId];
        delete ownedUpgradeStakes[_owner][lastTokenIndex];
        ownedUpgradeStakesBalance[_owner]--;
    }

    function _removeApeFromCooldown(uint256 _apeId) internal {
        address owner = restingApes[_apeId].owner;
        delete restingApes[_apeId];
        _removeCooldownFromOwnerEnumeration(owner, _apeId);
    }

    function _removeCooldownFromOwnerEnumeration(address _owner, uint256 _tokenId) internal {
        uint256 lastTokenIndex = restingApesBalance[_owner] - 1;
        uint256 tokenIndex = restingApesIndex[_tokenId];

        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = ownedRestingApes[_owner][lastTokenIndex];
            ownedRestingApes[_owner][tokenIndex] = lastTokenId;
            restingApesIndex[lastTokenId] = tokenIndex;
        }

        delete restingApesIndex[_tokenId];
        delete ownedRestingApes[_owner][lastTokenIndex];
        restingApesBalance[_owner]--;
    }

    function stakeOfOwnerByIndex(address _owner, uint256 _index) public view returns (uint256) {
        require(_index < ownedApeStakesBalance[_owner], "owner index out of bounds");
        return ownedApeStakes[_owner][_index];
    }

    function batchedStakesOfOwner(
        address _owner,
        uint256 _offset,
        uint256 _maxSize
    ) public view returns (StakedApeInfo[] memory) {
        if (_offset >= ownedApeStakesBalance[_owner]) {
            return new StakedApeInfo[](0);
        }

        uint256 outputSize = _maxSize;
        if (_offset + _maxSize >= ownedApeStakesBalance[_owner]) {
            outputSize = ownedApeStakesBalance[_owner] - _offset;
        }
        StakedApeInfo[] memory outputs = new StakedApeInfo[](outputSize);

        for (uint256 i = 0; i < outputSize; i++) {
            uint256 apeId = stakeOfOwnerByIndex(_owner, _offset + i);
            uint256 upgradeId = _getUpgradeStakedForApe(_owner, apeId);
            uint256 apeBPM = ape.getYield(apeId);
            uint256 upgradeBPM;
            if(upgradeId > 0){
                upgradeBPM = upgrade.getYield(upgradeId);
            }

            outputs[i] = StakedApeInfo({
                apeId: apeId,
                upgradeId: upgradeId,
                apeBPM: apeBPM,
                upgradeBPM: upgradeBPM, 
                banana: getBananaAccruedForApe(apeId, false),
                fatigue: getFatigueAccruedForApe(apeId, false),
                timeUntilFatigued: getTimeUntilFatigued(apeId, false)
            });
        }

        return outputs;
    }


    function cooldownOfOwnerByIndex(address _owner, uint256 _index) public view returns (uint256) {
        require(_index < restingApesBalance[_owner], "owner index out of bounds");
        return ownedRestingApes[_owner][_index];
    }

    function batchedCooldownsOfOwner(
        address _owner,
        uint256 _offset,
        uint256 _maxSize
    ) public view returns (RestingApeInfo[] memory) {
        if (_offset >= restingApesBalance[_owner]) {
            return new RestingApeInfo[](0);
        }

        uint256 outputSize = _maxSize;
        if (_offset + _maxSize >= restingApesBalance[_owner]) {
            outputSize = restingApesBalance[_owner] - _offset;
        }
        RestingApeInfo[] memory outputs = new RestingApeInfo[](outputSize);

        for (uint256 i = 0; i < outputSize; i++) {
            uint256 tokenId = cooldownOfOwnerByIndex(_owner, _offset + i);

            outputs[i] = RestingApeInfo({
                tokenId: tokenId,
                endTimestamp: restingApes[tokenId].endTimestamp
            });
        }

        return outputs;
    }
    
    /**
     * enables owner to pause / unpause minting
     */
    function setPaused(bool _paused) external onlyOwner {
        if (_paused) _pause();
        else _unpause();
    }


    // ForestV3
    function setBanana(Banana _banana) external onlyOwner {
        banana = _banana;
    }
    function setCaveAddress(address _caveAddress) external onlyOwner {
        caveAddress = _caveAddress;
    }
    function setApe(Ape _ape) external onlyOwner {
        ape = _ape;
    }
    function setUpgrade(Upgrade _upgrade) external onlyOwner {
        upgrade = _upgrade;
    }
    function setYieldBPS(uint256 _yieldBPS) external onlyOwner {
        yieldBPS = _yieldBPS;
    }
}