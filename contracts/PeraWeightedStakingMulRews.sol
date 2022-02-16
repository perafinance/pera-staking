//SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

    // IERC20 tokenInstance;
    // uint256 rewardRate;
    // uint256 rewardPerTokenStored;
    // mapping(address => uint256) userRewardPerTokenPaid;
    // mapping(address => uint256) rewards;

contract PeraWeightedStakingMulRews is Ownable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    struct RewardTokensInfo {
        IERC20 tokenInstance;
        uint256 rewardRate;
        uint256 rewardPerTokenStored;
    }

    // $PERA instance
    address public punishmentAddress;

    EnumerableSet.UintSet private activeRewards;
    RewardTokensInfo[] private rewardTokens;
    mapping(uint256 => mapping(address => uint256)) private userRewardsPerTokenPaid;
    mapping(uint256 => mapping(address => uint256)) private tokenRewards;


    uint256 public lastUpdateTime; //

    uint256 public totalStaked; // _totalSupply
    // Total weighted staking amount of the users
    uint256 public wTotalStaked;

    mapping(address => uint256) public userStaked; // _balances

    // Users staking coefficient
    mapping(address => uint256) public userWeights;
    // Unlocking timestamp of the users
    mapping(address => uint256) public userUnlockingTime;

    event Staked(address _user, uint256 _amount, uint256 _time);
    event IncreaseStaked(address _user, uint256 _amount);
    event PunishedWithdraw(
        address _user,
        uint256 _burntAmount,
        uint256 _amount
    );
    event Withdraw(address _user, uint256 _amount);
    event Claimed(address _user, uint256 _amount);

    constructor(
        address _peraAddress,
        address _punishmentAddress,
        uint256 _rewardRate
    ) {
        RewardTokensInfo memory info = RewardTokensInfo(IERC20(_peraAddress), _rewardRate, 0);
        rewardTokens.push(info);
        punishmentAddress = _punishmentAddress;
    }

    // Starts users stake positions
    function initialStake(uint256 _amount, uint256 _time)
        external
        updateReward(msg.sender)
    {
        require(userUnlockingTime[msg.sender] == 0, "Initial stake found!");
        require(_amount > 0, "Insufficient stake amount.");
        require(_time > 0, "Insufficient stake time.");

        userWeights[msg.sender] = calcWeight(_time);
        userUnlockingTime[msg.sender] = block.timestamp + _time;
        wTotalStaked += (userWeights[msg.sender] * _amount);
        emit Staked(msg.sender, _amount, _time);
        _increase(_amount);
    }

    // Edits users stake positions and allow if it's possible
    function additionalStake(uint256 _amount)
        external
        updateReward(msg.sender)
    {
        require(userUnlockingTime[msg.sender] != 0, "Initial stake not found!");
        require(_amount > 0, "Insufficient stake amount.");
        wTotalStaked += (userWeights[msg.sender] * _amount);
        emit IncreaseStaked(msg.sender, _amount);
        _increase(_amount);
    }

    // Unstakes users tokens if the staking period is over or punishes users
    function withdraw(uint256 _amount) external updateReward(msg.sender) {
        require(
            userStaked[msg.sender] >= _amount && _amount > 0,
            "Insufficient withdraw amount."
        );

        // if staking time is over - free withdrawing
        if (block.timestamp >= userUnlockingTime[msg.sender]) {
            if (userStaked[msg.sender] == _amount) {
                wTotalStaked -= calcWeightedStake(msg.sender);
                userWeights[msg.sender] = 0;
                delete (userUnlockingTime[msg.sender]);
            } else {
                wTotalStaked -= userWeights[msg.sender] * _amount;
                userWeights[msg.sender] -= userWeights[msg.sender] * _amount;
            }
            emit Withdraw(msg.sender, _amount);
            _decrease(_amount, 0);
            // early withdrawing with punishments
        } else {
            // TODO: Implement unstaking with punishment - i made a mock version with 50% cut
            uint256 _punishmentRate = 50;
            emit PunishedWithdraw(
                msg.sender,
                (_amount * _punishmentRate) / 100,
                (_amount * (100 - _punishmentRate)) / 100
            );
            _decrease(_amount, _punishmentRate);
        }
    }

    // Claims users rewards externally or by the other functions before reorganizations
    function claimReward() external updateReward(msg.sender) {
        uint256 _reward = tokenRewards[0][msg.sender];
        tokenRewards[0][msg.sender] = 0;
        emit Claimed(msg.sender, _reward);
        rewardTokens[0].tokenInstance.safeTransfer(msg.sender, _reward);
    }

    function depositRewardTokens(uint256 _amount) external onlyOwner {
        rewardTokens[0].tokenInstance.safeTransferFrom(msg.sender, address(this), _amount);
    }

    // This function returns staking coefficient in the base of 1000 (equals 1 coefficient)
    function calcWeight(uint256 _time) public pure returns (uint256) {
        // TODO: implement coefficient function on the base of 100
        // 150 is returned as a mock variable aka coef: 1.5

        if ((_time / 1 weeks) < 12) {
            return 150;
        } else {
            return 200;
        }
    }

    // This function calculates users weighted stakin amounts
    function calcWeightedStake(address _user) public view returns (uint256) {
        return (userWeights[_user] * userStaked[_user]);
    }

    function rewardPerToken() public view returns (uint256) {
        if (wTotalStaked == 0) return 0;

        return
            rewardTokens[0].rewardPerTokenStored +
            (((block.timestamp - lastUpdateTime) * rewardTokens[0].rewardRate * 1e18) /
                wTotalStaked);
    }

    function earned(address _user) public view returns (uint256) {
        return
            ((calcWeightedStake(_user) *
                (rewardPerToken() - userRewardsPerTokenPaid[0][_user])) / 1e18) +
            tokenRewards[0][_user];
    }

    /** 
        These two functions are the actual functions that manages staking positions on back side
        They will manage users staking amounts with the messages coming from the public ones
    */

    // Increses staking positions of the users - actually "stake" function of general contracts
    function _increase(uint256 _amount) private {
        totalStaked += _amount;
        userStaked[msg.sender] += _amount;
        rewardTokens[0].tokenInstance.safeTransferFrom(msg.sender, address(this), _amount);
    }

    // Decreases staking positions of the users - actually "unstake/withdraw" function of general contracts
    function _decrease(uint256 _amount, uint256 _punishmentRate) private {
        totalStaked -= _amount;
        userStaked[msg.sender] -= _amount;
        if (_punishmentRate > 0) {
            uint256 _punishment = (_amount * _punishmentRate) / 100;
            _amount = _amount - _punishment;
            rewardTokens[0].tokenInstance.safeTransfer(punishmentAddress, _punishment);
        }
        rewardTokens[0].tokenInstance.safeTransfer(msg.sender, _amount);
    }

    modifier updateReward(address _user) {
        rewardTokens[0].rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;

        tokenRewards[0][_user] = earned(_user);
        userRewardsPerTokenPaid[0][_user] = rewardTokens[0].rewardPerTokenStored;
        _;
    }
}
