//SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract PeraStaking is Ownable {
    /////////// Interfaces & Libraries ///////////

    // Using OpenZeppelin's EnumerableSet Util
    using EnumerableSet for EnumerableSet.UintSet;
    // Using OpenZeppelin's SafeERC20 Util
    using SafeERC20 for IERC20;

    /////////// Structs ///////////

    struct TokenInfo {
        IERC20 tokenInstance; // Token interface of tokens
        uint256 rewardRate; // Distributing token count per second
        uint256 rewardPerTokenStored;
        uint256 deadline; // Deadline of reward distributing
        uint8 decimals; // Decimal count of token
    }

    struct UserInfo {
        uint256 userStaked; // User staked balance
        uint16 userWeights; // User staking coefficient
        uint48 stakedTimestamp; // Staking timestamp of the users
        uint48 userUnlockingTime; // Unlocking timestamp of the users
    }

    /////////// Type Declarations ///////////

    // All historical reward token data
    TokenInfo[] private tokenList;
    // List of actively distributing token data
    EnumerableSet.UintSet private activeRewards;

    // User Data
    // User variables
    mapping(address => UserInfo) public userData;
    // rewardPerTokenPaid data for each reward tokens
    mapping(uint256 => mapping(address => uint256))
        private userRewardsPerTokenPaid;
    // Reward data for each reward token
    mapping(uint256 => mapping(address => uint256)) private tokenRewards;

    /////////// State Variables ///////////

    // Deadline to locked stakings - after which date the token cannot be locked
    uint256 public lockLimit;
    // Last stake operations
    uint256 public lastUpdateTime;
    // Total staked token amount
    uint256 public totalStaked;
    // Total weighted staked amount
    uint256 public wTotalStaked;
    // Cutted tokens destination address
    address public punishmentAddress;
    // Staking - withdrawing availability
    bool public isStakeOpen;
    // Emergency withdraw availability
    bool public isEmergencyOpen;

    /////////// Events ///////////

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
    event EmergencyStatusChanged(bool _newStatus);

    /////////// Functions ///////////

    constructor(
        address _mainTokenAddress,
        address _punishmentAddress,
        uint256 _rewardRate,
        uint256 _lockLimit
    ) {
        require(
            _mainTokenAddress != address(0),
            "Token address can not be 0 address."
        );
        require(
            _punishmentAddress != address(0),
            "Receiver address can not be 0 address."
        );
        TokenInfo memory info = TokenInfo(
            IERC20(_mainTokenAddress),
            _rewardRate,
            0,
            0,
            18
        );
        tokenList.push(info);
        activeRewards.add(tokenList.length - 1);
        punishmentAddress = _punishmentAddress;
        lockLimit = _lockLimit;
    }

    // Starts users stake positions
    function initialStake(uint256 _amount, uint256 _time)
        external
        stakeOpen
        updateReward(msg.sender)
    {
        require(
            userData[msg.sender].userUnlockingTime == 0,
            "Initial stake found!"
        );
        require(_amount > 0, "Insufficient stake amount.");
        require(_time > 0, "Insufficient stake time.");
        require(block.timestamp + _time < lockLimit, "Lock limit exceeded!");

        userData[msg.sender].userWeights = calcWeight(_time);
        userData[msg.sender].userUnlockingTime = uint48(
            block.timestamp + _time
        );
        userData[msg.sender].stakedTimestamp = uint48(block.timestamp);
        wTotalStaked += (userData[msg.sender].userWeights * _amount);
        emit Staked(msg.sender, _amount, _time);
        _increase(_amount);
    }

    // Edits users stake positions and allow if it's possible
    function additionalStake(uint256 _amount)
        external
        stakeOpen
        updateReward(msg.sender)
    {
        require(
            userData[msg.sender].userUnlockingTime != 0,
            "Initial stake not found!"
        );
        require(_amount > 0, "Insufficient stake amount.");
        uint16 _additionWeight = calcWeight(
            uint256(userData[msg.sender].userUnlockingTime) - block.timestamp
        );
        userData[msg.sender].userWeights = uint16(
            (calcWeightedStake(msg.sender) +
                (_amount * uint256(_additionWeight))) /
                (userData[msg.sender].userStaked + _amount)
        );
        wTotalStaked += uint256(_additionWeight) * _amount;
        emit IncreaseStaked(msg.sender, _amount);
        _increase(_amount);
    }

    // Unstakes users tokens if the staking period is over or punishes users
    function withdraw(uint256 _amount) external updateReward(msg.sender) {
        require(
            userData[msg.sender].userStaked >= _amount && _amount > 0,
            "Insufficient withdraw amount."
        );
        uint256 _punishmentRate = 0;
        // if staking time is over - free withdrawing
        if (
            block.timestamp >= uint256(userData[msg.sender].userUnlockingTime)
        ) {
            emit Withdraw(msg.sender, _amount);
            // early withdrawing with punishments
        } else {
            _punishmentRate =
                25 +
                ((uint256(userData[msg.sender].userUnlockingTime) -
                    block.timestamp) * 50) /
                uint256(
                    userData[msg.sender].userUnlockingTime -
                        userData[msg.sender].stakedTimestamp
                );
            emit PunishedWithdraw(
                msg.sender,
                (_amount * _punishmentRate) / 100,
                (_amount * (100 - _punishmentRate)) / 100
            );
        }
        wTotalStaked -= uint256(userData[msg.sender].userWeights) * _amount;

        if (userData[msg.sender].userStaked == _amount) {
            delete (userData[msg.sender]);
        }

        _decrease(_amount, _punishmentRate);
    }

    function emergencyWithdraw() external {
        require(isEmergencyOpen, "Not an emergency status.");
        require(
            userData[msg.sender].userStaked > 0,
            "No staked balance found ."
        );

        wTotalStaked -=
            uint256(userData[msg.sender].userWeights) *
            userData[msg.sender].userStaked;
        delete (userData[msg.sender]);
        _decrease(userData[msg.sender].userStaked, 0);
    }

    // Claims users rewards externally or by the other functions before reorganizations
    function claimAllRewards() external updateReward(msg.sender) {
        for (uint256 i = 0; i < activeRewards.length(); i++) {
            uint256 _reward = tokenRewards[activeRewards.at(i)][msg.sender];
            if (_reward > 0) {
                tokenRewards[activeRewards.at(i)][msg.sender] = 0;
                tokenList[activeRewards.at(i)].tokenInstance.safeTransfer(
                    msg.sender,
                    _reward
                );
            }
        }

        emit Claimed(msg.sender);
    }

    function claimSingleReward(uint256 _id) external updateReward(msg.sender) {
        uint256 _reward = tokenRewards[_id][msg.sender];
        if (_reward > 0) {
            tokenRewards[_id][msg.sender] = 0;
            tokenList[_id].tokenInstance.safeTransfer(msg.sender, _reward);
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
        TokenInfo memory info = TokenInfo(
            IERC20(_tokenAddress),
            _rewardRate,
            0,
            _deadline,
            _decimals
        );

        tokenList.push(info);
        activeRewards.add(tokenList.length - 1);

        emit NewReward(_tokenAddress, tokenList.length - 1);
    }

    function delistRewardToken(uint256 _id) external onlyOwner {
        require(
            tokenList[_id].deadline < block.timestamp,
            "The distribution timeline has not over."
        );
        require(_id != 0, "Can not delist main token.");
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

        tokenList[_id].tokenInstance.safeTransferFrom(
            msg.sender,
            address(this),
            _amount
        );
    }

    function changeDeadline(uint256 _id, uint256 _time)
        external
        updateReward(address(0))
        onlyOwner
    {
        require(
            _time >= block.timestamp || _time == 0,
            "Inappropriate timestamp."
        );
        require(
            tokenList[_id].deadline > block.timestamp,
            "The distribution has over."
        );
        tokenList[_id].deadline = _time;
    }

    function changeStakeStatus() external onlyOwner {
        isStakeOpen = !isStakeOpen;
        emit StakeStatusChanged(isStakeOpen);
    }

    function changeEmergencyStatus() external onlyOwner {
        isEmergencyOpen = !isEmergencyOpen;
        emit EmergencyStatusChanged(isEmergencyOpen);
    }

    function setLockLimit(uint256 _lockLimit) external onlyOwner {
        lockLimit = _lockLimit;
    }

    function changePunishmentAddress(address _newAddress) external onlyOwner {
        require(
            _newAddress != address(0),
            "Receiver address can not be 0 address."
        );
        punishmentAddress = _newAddress;
    }

    // This function returns staking coefficient in the base of 100 (equals 1 coefficient)
    function calcWeight(uint256 _time) public pure returns (uint16) {
        uint256 _stakingDays = _time / 1 days;
        if (_stakingDays <= 90) {
            return 100;
        } else if (_stakingDays >= 365) {
            return 200;
        } else {
            return uint16(((100 * (_stakingDays - 90)**2) / 75625) + 100);
        }
    }

    // This function calculates users weighted stakin amounts
    function calcWeightedStake(address _user) public view returns (uint256) {
        return (userData[_user].userWeights * userData[_user].userStaked);
    }

    function rewardPerToken(uint256 _rewardTokenIndex)
        public
        view
        returns (uint256)
    {
        if (wTotalStaked == 0) return 0;

        uint256 deadline = tokenList[_rewardTokenIndex].deadline;

        if (deadline == 0 || block.timestamp < deadline) {
            deadline = block.timestamp;
        }

        uint256 time;
        (deadline > lastUpdateTime)
            ? time = deadline - lastUpdateTime
            : time = 0;

        return
            tokenList[_rewardTokenIndex].rewardPerTokenStored +
            ((time *
                tokenList[_rewardTokenIndex].rewardRate *
                10**tokenList[_rewardTokenIndex].decimals) / wTotalStaked);
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
                10**tokenList[_rewardTokenIndex].decimals) +
            tokenRewards[_rewardTokenIndex][_user];
    }

    /** 
        These two functions are the actual functions that manages staking positions on back side
        They will manage users staking amounts with the messages coming from the public ones
    */

    // Increses staking positions of the users - actually "stake" function of general contracts
    function _increase(uint256 _amount) private {
        totalStaked += _amount;
        userData[msg.sender].userStaked += _amount;
        tokenList[0].tokenInstance.safeTransferFrom(
            msg.sender,
            address(this),
            _amount
        );
    }

    // Decreases staking positions of the users - actually "unstake/withdraw" function of general contracts
    function _decrease(uint256 _amount, uint256 _punishmentRate) private {
        totalStaked -= _amount;
        userData[msg.sender].userStaked -= _amount;
        if (_punishmentRate > 0) {
            uint256 _punishment = (_amount * _punishmentRate) / 100;
            _amount = _amount - _punishment;
            tokenList[0].tokenInstance.safeTransfer(
                punishmentAddress,
                _punishment
            );
        }
        tokenList[0].tokenInstance.safeTransfer(msg.sender, _amount);
    }

    /////////// Modifiers ///////////

    modifier updateReward(address _user) {
        for (uint256 i = 0; i < activeRewards.length(); i++) {
            uint256 _lastUpdateTime = lastUpdateTime;
            tokenList[activeRewards.at(i)]
                .rewardPerTokenStored = rewardPerToken(activeRewards.at(i));
            lastUpdateTime = block.timestamp;

            if (_user != address(0)) {
                tokenRewards[activeRewards.at(i)][_user] = earned(
                    _user,
                    activeRewards.at(i)
                );
                userRewardsPerTokenPaid[activeRewards.at(i)][_user] = tokenList[
                    activeRewards.at(i)
                ].rewardPerTokenStored;
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
