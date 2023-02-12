//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "./Tree.sol";

contract ForestProgression is Context, Ownable, Pausable {

    // Constants
    uint256[20] public TREE_LEVELS = [0, 50 * 1e18, 110 * 1e18, 185 * 1e18, 280 * 1e18, 400 * 1e18, 550 * 1e18, 735 * 1e18, 960 * 1e18, 1230 * 1e18, 1550 * 1e18, 1925 * 1e18, 2360 * 1e18, 2860 * 1e18, 3430 * 1e18, 4075 * 1e18, 4800 * 1e18, 5610 * 1e18, 6510 * 1e18, 7510 * 1e18];
    uint256 public MAX_TREE_AMOUNT = TREE_LEVELS[TREE_LEVELS.length - 1];
    uint256 public constant BURN_ID = 0;
    uint256 public constant FATIGUE_ID = 1;
    uint256 public constant CAVE_ID = 2;
    uint256 public constant ALPHAAPE_ID = 3;
    uint256 public constant UPGRADES_ID = 4;
    uint256 public constant APES_ID = 5;
    uint256[6] public MAX_SKILL_LEVEL = [3, 3, 2, 2, 5, 5];

    uint256 public baseCostReset = 25 * 1e18;


    Tree public tree;

    uint256 public levelTime;

    mapping(address => uint256) public treeDeposited; // address => total amount of tree deposited
    mapping(address => uint256) public skillPoints; // address => skill points available
    mapping(address => uint256[6]) public skillsLearned; // address => skill learned.

    constructor(Tree _tree) {
        tree = _tree;
    }

    // EVENTS

    event receivedSkillPoints(address owner, uint256 skillPoints);
    event skillLearned(address owner, uint256 skillGroup, uint256 skillLevel);
    event reset(address owner, uint256 level);

    // Views

    /**
    * Returns the level based on the total tree deposited
    */
    function _getLevel(address _owner) internal view returns (uint256) {
        uint256 totalTree = treeDeposited[_owner];

        for (uint256 i = 0; i < TREE_LEVELS.length - 1; i++) {
            if (totalTree < TREE_LEVELS[i+1]) {
                    return i+1;
            }
        }
        return TREE_LEVELS.length;
    }

    /**
    * Returns a value representing the % of fatigue after reducing
    */
    function getFatigueSkillModifier(address _owner) public view returns (uint256) {
        uint256 fatigueSkill = skillsLearned[_owner][FATIGUE_ID];

        if(fatigueSkill == 3){
            return 80;
        } else if (fatigueSkill == 2){
            return 85;
        } else if (fatigueSkill == 1){
            return 92;
        } else {
            return 100;
        }
    }

    /**
    * Returns a value representing the % that will be reduced from the claim burn
    */
    function getBurnSkillModifier(address _owner) public view returns (uint256) {
        uint256 burnSkill = skillsLearned[_owner][BURN_ID];

        if(burnSkill == 3){
            return 8;
        } else if (burnSkill == 2){
            return 6;
        } else if (burnSkill == 1){
            return 3;
        } else {
            return 0;
        }
    }

    /**
    * Returns a value representing the % that will be reduced from the cave share of the claim
    */
    function getCaveSkillModifier(address _owner) public view returns (uint256) {
        uint256 caveSkill = skillsLearned[_owner][CAVE_ID];

        if(caveSkill == 2){
            return 9;
        } else if (caveSkill == 1){
            return 4;
        } else {
            return 0;
        }
    }

    /**
    * Returns the multiplier for $BANANA production based on the number of alpha apes and the skill points spent
    */
    function getAlphaApeSkillModifier(address _owner, uint256 _alphaApeNumber) public view returns (uint256) {
        uint256 alphaApeSkill = skillsLearned[_owner][ALPHAAPE_ID];

        if(alphaApeSkill == 2 && _alphaApeNumber >= 5){
            return 110;
        } else if (alphaApeSkill >= 1 && _alphaApeNumber >= 2){
            return 103;
        } else {
            return 100;
        }
    }

    /**
    * Returns the max level upgrade that can be staked based on the skill points spent
    */
    function getMaxLevelUpgrade(address _owner) public view returns (uint256) {
        uint256 upgradesSkill = skillsLearned[_owner][UPGRADES_ID];

        if(upgradesSkill == 0){
            return 1; //level id starts at 0, so here are first and second tiers
        } else if (upgradesSkill == 1){
            return 4;
        } else if (upgradesSkill == 2){
            return 6;
        } else if (upgradesSkill == 3){
            return 8;
        } else if (upgradesSkill == 4){
            return 11;
        } else {
            return 100;
        }
    }

    /**
    * Returns the max number of apes that can be staked based on the skill points spent
    */
    function getMaxNumberApes(address _owner) public view returns (uint256) {
        uint256 apesSkill = skillsLearned[_owner][APES_ID];

        if(apesSkill == 0){
            return 10;
        } else if (apesSkill == 1){
            return 15;
        } else if (apesSkill == 2){
            return 20;
        } else if (apesSkill == 3){
            return 30;
        } else if (apesSkill == 4){
            return 50;
        } else {
            return 20000;
        }
    }

    // Public views

    /**
    * Returns the Forest level
    */
    function getLevel(address _owner) public view returns (uint256) {
        return _getLevel(_owner);
    }

    /**
    * Returns the $TREE deposited in the current level
    */
    function getTreeDeposited(address _owner) public view returns (uint256) {
        uint256 level = _getLevel(_owner);
        uint256 totalTree = treeDeposited[_owner];
        if(level == TREE_LEVELS.length){
            return 0;
        }

        return totalTree - TREE_LEVELS[level-1];
    }

    /**
    * Returns the amount of tree required to level up
    */
    function getTreeToNextLevel(address _owner) public view returns (uint256) {
        uint256 level = _getLevel(_owner);
        if(level == TREE_LEVELS.length){
            return 0;
        }
        return TREE_LEVELS[level] - TREE_LEVELS[level-1];
    }

    /**
    * Returns the amount of skills points available to be spent
    */
    function getSkillPoints(address _owner) public view returns (uint256) {
        return skillPoints[_owner];
    }

    /**
    * Returns the current skills levels for each skill group
    */
    function getSkillsLearned(address _owner) public view returns (
        uint256 burn,
        uint256 fatigue,
        uint256 cave,
        uint256 alphaape,
        uint256 upgrades,
        uint256 apes       
    ) {
        uint256[6] memory skills = skillsLearned[_owner];

        burn = skills[BURN_ID];
        fatigue = skills[FATIGUE_ID]; 
        cave = skills[CAVE_ID]; 
        alphaape = skills[ALPHAAPE_ID]; 
        upgrades = skills[UPGRADES_ID];
        apes = skills[APES_ID]; 
    }

    // External

    /**
    * Burns deposited $TREE and add skill point if level up.
    */
    function depositTree(uint256 _amount) external whenNotPaused {
        require(levelStarted(), "you can't level yet");
        require (_getLevel(_msgSender()) < TREE_LEVELS.length, "already at max level");
        require (tree.balanceOf(_msgSender()) >= _amount, "not enough tree");

        if(_amount + treeDeposited[_msgSender()] > MAX_TREE_AMOUNT){
            _amount = MAX_TREE_AMOUNT - treeDeposited[_msgSender()];
        }

        uint256 levelBefore = _getLevel(_msgSender());
        treeDeposited[_msgSender()] += _amount;
        uint256 levelAfter = _getLevel(_msgSender());
        skillPoints[_msgSender()] += levelAfter - levelBefore;

        if(levelAfter == TREE_LEVELS.length){
            skillPoints[_msgSender()] += 1;
        }

        emit receivedSkillPoints(_msgSender(), levelAfter - levelBefore);

        tree.burn(_msgSender(), _amount);
    }

    /**
    *  Spend skill point based on the skill group and skill level. Can only spend 1 point at a time.
    */
    function spendSkillPoints(uint256 _skillGroup, uint256 _skillLevel) external whenNotPaused {
        require(skillPoints[_msgSender()] > 0, "not enough skill points");
        require (_skillGroup <= 5, "invalid skill group");
        require(_skillLevel >= 1 && _skillLevel <= MAX_SKILL_LEVEL[_skillGroup], "invalid skill level");
        
        uint256 currentSkillLevel = skillsLearned[_msgSender()][_skillGroup];
        require(_skillLevel == currentSkillLevel + 1, "invalid skill level jump"); //can only level up 1 point at a time

        skillsLearned[_msgSender()][_skillGroup] = _skillLevel;
        skillPoints[_msgSender()]--;

        emit skillLearned(_msgSender(), _skillGroup, _skillLevel);
    }

    /**
    *  Resets skills learned for a fee
    */
    function resetSkills() external whenNotPaused {
        uint256 level = _getLevel(_msgSender());
        uint256 costToReset = level * baseCostReset;
        require (level > 1, "you are still at level 1");
        require (tree.balanceOf(_msgSender()) >= costToReset, "not enough tree");

        skillsLearned[_msgSender()][BURN_ID] = 0;
        skillsLearned[_msgSender()][FATIGUE_ID] = 0;
        skillsLearned[_msgSender()][CAVE_ID] = 0;
        skillsLearned[_msgSender()][ALPHAAPE_ID] = 0;
        skillsLearned[_msgSender()][UPGRADES_ID] = 0;
        skillsLearned[_msgSender()][APES_ID] = 0;

        skillPoints[_msgSender()] = level - 1;

        if(level == 20){
            skillPoints[_msgSender()]++;
        }

        tree.burn(_msgSender(), costToReset);

        emit reset(_msgSender(), level);

    }

    // Admin

    function levelStarted() public view returns (bool) {
        return levelTime != 0 && block.timestamp >= levelTime;
    }

    function setLevelStartTime(uint256 _startTime) external onlyOwner {
        require (_startTime >= block.timestamp, "startTime cannot be in the past");
        require(!levelStarted(), "leveling already started");
        levelTime = _startTime;
    }

    // ForestProgressionV3
    function setTree(Tree _tree) external onlyOwner {
        tree = _tree;
    }

    function setBaseCostReset(uint256 _baseCostReset) external onlyOwner {
        baseCostReset = _baseCostReset;
    }

    function setTreeLevels(uint256 _index, uint256 _newValue) external onlyOwner {
        require (_index < TREE_LEVELS.length, "invalid index");
        TREE_LEVELS[_index] = _newValue;

        if(_index == (TREE_LEVELS.length - 1)){
            MAX_TREE_AMOUNT = TREE_LEVELS[TREE_LEVELS.length - 1];
        }
    }

    // In case we rebalance the leveling costs this fixes the skill points to correct players
    function fixSkillPoints(address _player) public {
        uint256 level = _getLevel(_player);
        uint256 currentSkillPoints = skillPoints[_player];
        uint256 totalSkillsLearned = skillsLearned[_player][BURN_ID] + skillsLearned[_player][FATIGUE_ID] + skillsLearned[_player][CAVE_ID] + skillsLearned[_player][ALPHAAPE_ID] + skillsLearned[_player][UPGRADES_ID] + skillsLearned[_player][APES_ID];

        uint256 correctSkillPoints = level - 1;
        if(level == TREE_LEVELS.length){ // last level has 2 skill points
            correctSkillPoints++;
        }
        if(correctSkillPoints > currentSkillPoints + totalSkillsLearned){
            skillPoints[_player] += correctSkillPoints - currentSkillPoints - totalSkillsLearned;
        }
    }

}
