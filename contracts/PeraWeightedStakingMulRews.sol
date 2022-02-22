//SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract PeraWeightedStakingMulRews is Ownable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    struct RewardTokensInfo {
        IERC20 tokenInstance;
        uint256 rewardRate;
        uint256 rewardPerTokenStored;
        uint256 deadline;
        uint8 decimals;
    }

    address public punishmentAddress;

    RewardTokensInfo[] private rewardTokens; // TODO: can be removed and change by a mapping
    EnumerableSet.UintSet private activeRewards;
    mapping(uint256 => mapping(address => uint256))
        private userRewardsPerTokenPaid;
    mapping(uint256 => mapping(address => uint256)) private tokenRewards;
    mapping(address => uint256) private stakedTimestamp;

    uint256 public lastUpdateTime; //

    uint256 public totalStaked; // _totalSupply
    // Total weighted staking amount of the users
    uint256 public wTotalStaked;

    bool public isStakeOpen;
    // TODO: implement emergency mode: bool public isEmergency;

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
    event Claimed(address _user);
    event NewReward(address _tokenAddress, uint256 _id);
    event StakeStatusChanged(bool _newStatus);

    constructor(
        address _peraAddress,
        address _punishmentAddress,
        uint256 _rewardRate
    ) {
        require(
            _peraAddress != address(0),
            "Token address can not be 0 address."
        );
        RewardTokensInfo memory info = RewardTokensInfo(
            IERC20(_peraAddress),
            _rewardRate,
            0,
            0,
            18
        );
        rewardTokens.push(info);
        activeRewards.add(rewardTokens.length - 1);
        punishmentAddress = _punishmentAddress;
    }

    // Starts users stake positions
    function initialStake(uint256 _amount, uint256 _time)
        external
        stakeOpen
        updateReward(msg.sender)
    {
        require(userUnlockingTime[msg.sender] == 0, "Initial stake found!");
        require(_amount > 0, "Insufficient stake amount.");
        require(_time > 0, "Insufficient stake time.");

        userWeights[msg.sender] = calcWeight(_time);
        userUnlockingTime[msg.sender] = block.timestamp + _time;
        stakedTimestamp[msg.sender] = block.timestamp;
        wTotalStaked += (userWeights[msg.sender] * _amount);
        emit Staked(msg.sender, _amount, _time);
        _increase(_amount);
    }

    // Edits users stake positions and allow if it's possible
    function additionalStake(uint256 _amount)
        external
        stakeOpen
        updateReward(msg.sender)
    {
        require(userUnlockingTime[msg.sender] != 0, "Initial stake not found!");
        require(_amount > 0, "Insufficient stake amount.");
        wTotalStaked += (userWeights[msg.sender] * _amount);
        emit IncreaseStaked(msg.sender, _amount);
        _increase(_amount);
    }

    // Unstakes users tokens if the staking period is over or punishes users
    function withdraw(uint256 _amount)
        external
        stakeOpen /** TODO: Should we limit withdrawing when we stop staking */
        updateReward(msg.sender)
    {
        require(
            userStaked[msg.sender] >= _amount && _amount > 0,
            "Insufficient withdraw amount."
        );
        uint256 _punishmentRate;
        // if staking time is over - free withdrawing
        if (block.timestamp >= userUnlockingTime[msg.sender]) {
            emit Withdraw(msg.sender, _amount);
            // early withdrawing with punishments
        } else {
            _punishmentRate =
                25 +
                ((userUnlockingTime[msg.sender] - block.timestamp) * 50) /
                (userUnlockingTime[msg.sender] - stakedTimestamp[msg.sender]);
            emit PunishedWithdraw(
                msg.sender,
                (_amount * _punishmentRate) / 100,
                (_amount * (100 - _punishmentRate)) / 100
            );
        }
        wTotalStaked -= userWeights[msg.sender] * _amount;
        userWeights[msg.sender] -= userWeights[msg.sender] * _amount;

        if (userStaked[msg.sender] == _amount) {
            userWeights[msg.sender] = 0;
            delete stakedTimestamp[msg.sender];
            delete (userUnlockingTime[msg.sender]);
        }

        _decrease(_amount, _punishmentRate);
    }

    // Claims users rewards externally or by the other functions before reorganizations
    function claimReward() external updateReward(msg.sender) {
        for (uint256 i = 0; i < activeRewards.length(); i++) {
            uint256 _reward = tokenRewards[activeRewards.at(i)][msg.sender];
            if (_reward > 0) {
                tokenRewards[activeRewards.at(i)][msg.sender] = 0;
                rewardTokens[activeRewards.at(i)].tokenInstance.safeTransfer(
                    msg.sender,
                    _reward
                );
            }
        }

        emit Claimed(msg.sender);
    }

    function addNewRewardToken(
        address _tokenAddress,
        uint256 _rewardRate,
        uint256 _deadline,
        uint8 _decimals
    ) external onlyOwner updateReward(address(0)) {
        require(
            _tokenAddress != address(0),
            "Token address can not be 0 address."
        );
        RewardTokensInfo memory info = RewardTokensInfo(
            IERC20(_tokenAddress),
            _rewardRate,
            0,
            _deadline,
            _decimals
        );

        rewardTokens.push(info);
        activeRewards.add(rewardTokens.length - 1);

        emit NewReward(_tokenAddress, rewardTokens.length - 1);
    }

    function delistRewardToken(uint256 _id) external onlyOwner {
        require(
            rewardTokens[_id].deadline < block.timestamp,
            "The distribution timeline has not over."
        );
        require(activeRewards.remove(_id), "Delisting unsuccessful");
    }

    function depositRewardTokens(uint256 _id, uint256 _amount)
        external
        onlyOwner
    {
        require(
            activeRewards.contains(_id),
            "Not an active reward distribution."
        );

        rewardTokens[_id].tokenInstance.safeTransferFrom(
            msg.sender,
            address(this),
            _amount
        );
    }

    function changeStakeStatus() external onlyOwner {
        isStakeOpen = !isStakeOpen;
        emit StakeStatusChanged(isStakeOpen);
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

    function rewardPerToken(uint256 _rewardTokenIndex)
        public
        view
        returns (uint256)
    {
        if (wTotalStaked == 0) return 0;

        uint256 deadline = rewardTokens[_rewardTokenIndex].deadline;

        if (deadline == 0 || block.timestamp < deadline) {
            deadline = block.timestamp;
        }

        uint256 time;
        (deadline > lastUpdateTime)
            ? time = deadline - lastUpdateTime
            : time = 0;

        return
            rewardTokens[_rewardTokenIndex].rewardPerTokenStored +
            ((time *
                rewardTokens[_rewardTokenIndex].rewardRate *
                10**rewardTokens[_rewardTokenIndex].decimals) / wTotalStaked);
    }

    function earned(address _user, uint256 _rewardTokenIndex)
        public
        view
        returns (uint256)
    {
        return
            ((calcWeightedStake(_user) *
                (rewardPerToken(_rewardTokenIndex) -
                    userRewardsPerTokenPaid[_rewardTokenIndex][_user])) /
                10**rewardTokens[_rewardTokenIndex].decimals) +
            tokenRewards[_rewardTokenIndex][_user];
    }

    /** 
        These two functions are the actual functions that manages staking positions on back side
        They will manage users staking amounts with the messages coming from the public ones
    */

    // Increses staking positions of the users - actually "stake" function of general contracts
    function _increase(uint256 _amount) private {
        totalStaked += _amount;
        userStaked[msg.sender] += _amount;
        rewardTokens[0].tokenInstance.safeTransferFrom(
            msg.sender,
            address(this),
            _amount
        );
    }

    // Decreases staking positions of the users - actually "unstake/withdraw" function of general contracts
    function _decrease(uint256 _amount, uint256 _punishmentRate) private {
        totalStaked -= _amount;
        userStaked[msg.sender] -= _amount;
        if (_punishmentRate > 0) {
            uint256 _punishment = (_amount * _punishmentRate) / 100;
            _amount = _amount - _punishment;
            rewardTokens[0].tokenInstance.safeTransfer(
                punishmentAddress,
                _punishment
            );
        }
        rewardTokens[0].tokenInstance.safeTransfer(msg.sender, _amount);
    }

    modifier updateReward(address _user) {
        for (uint256 i = 0; i < activeRewards.length(); i++) {
            uint256 _lastUpdateTime = lastUpdateTime;
            rewardTokens[activeRewards.at(i)]
                .rewardPerTokenStored = rewardPerToken(activeRewards.at(i));
            lastUpdateTime = block.timestamp;

            if (_user != address(0)) {
                tokenRewards[activeRewards.at(i)][_user] = earned(
                    _user,
                    activeRewards.at(i)
                );
                userRewardsPerTokenPaid[activeRewards.at(i)][
                    _user
                ] = rewardTokens[activeRewards.at(i)].rewardPerTokenStored;
            }
            if (i != activeRewards.length() - 1)
                lastUpdateTime = _lastUpdateTime;
        }
        _;
    }

    modifier stakeOpen() {
        require(isStakeOpen, "Not an active staking period.");
        _;
    }
}
