//SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @author Ulaş Erdoğan
/// @title Staking Contract with Weights for Multi Asset Gains
/// @dev Inspired by Synthetix by adding "multi asset rewards" and time weighting
contract PeraStaking is Ownable {
    /////////// Interfaces & Libraries ///////////

    // Using OpenZeppelin's EnumerableSet Util
    using EnumerableSet for EnumerableSet.UintSet;
    // Using OpenZeppelin's SafeERC20 Util
    using SafeERC20 for IERC20;

    /////////// Structs ///////////

    // Information of reward tokens
    struct TokenInfo {
        IERC20 tokenInstance; // ERC-20 interface of tokens
        uint256 rewardRate; // Distributing count per second
        uint256 rewardPerTokenStored; // Staking calculation helper
        uint256 deadline; // Deadline of reward distributing
        uint8 decimals; // Decimal count of token
    }

    // Information of users staking details
    struct UserInfo {
        uint256 userStaked; // Staked balance per user
        uint16 userWeights; // Staking coefficient per user
        uint48 stakedTimestamp; // Staking timestamp of the users
        uint48 userUnlockingTime; // Unlocking timestamp of the users
    }

    /////////// Type Declarations ///////////

    // All historical reward token data
    TokenInfo[] private tokenList;
    // List of actively distributing token data
    EnumerableSet.UintSet private activeRewards;

    // User Data

    // User data which contains personal variables
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
    address public penaltyAddress;
    // Staking - withdrawing availability
    bool public isStakeOpen;
    // Claiming availability
    bool public isClaimOpen;
    // Emergency withdraw availability
    bool public isEmergencyOpen;

    /////////// Events ///////////

    // User initially stakes token
    event Staked(address _user, uint256 _amount, uint256 _time);
    //User increases stake amount
    event IncreaseStaked(address _user, uint256 _amount);
    // User withdraws token before the unlock time
    event PunishedWithdraw(
        address _user,
        uint256 _burntAmount,
        uint256 _amount
    );
    // User withdraws token on time
    event Withdraw(address _user, uint256 _amount);
    // User claims rewards
    event Claimed(address _user);
    // New reward token added by owner
    event NewReward(address _tokenAddress, uint256 _id);
    // Staking status switched
    event StakeStatusChanged(bool _newStatus);
    // Claim status switched
    event ClaimStatusChanged(bool _newStatus);
    // Emergency status is active
    event EmergencyStatusChanged(bool _newStatus);
    // Lock deadline change
    event LockLimitChanged(uint256 _lockLimit);

    /////////// Functions ///////////

    /**
     * @notice Constructor function - takes the parameters of the competition
     * @param _mainTokenAddress address - Main staking asset of the contract
     * @param _penaltyAddress address - Destination address of the cutted tokens
     * @param _rewardRate uint256 - Main tokens distribution rate per second
     * @param _lockLimit uint256 - Deadline for stake locks
     */
    constructor(
        address _mainTokenAddress,
        address _penaltyAddress,
        uint256 _rewardRate,
        uint256 _lockLimit
    ) {
        require(
            _mainTokenAddress != address(0),
            "[] Address failure."
        );
        require(
            _penaltyAddress != address(0),
            "[] Address failure."
        );
        TokenInfo memory info = TokenInfo(
            IERC20(_mainTokenAddress),
            _rewardRate,
            0,
            0,
            18
        );
        tokenList.push(info);
        require(activeRewards.add(tokenList.length - 1));
        penaltyAddress = _penaltyAddress;
        lockLimit = _lockLimit;
    }

    /**
     * @notice Direct native coin transfers are closed
     */
    receive() external payable {
        revert();
    }

    /**
     * @notice Direct native coin transfers are closed
     */
    fallback() external {
        revert();
    }

    /**
     * @notice Initializing stake position for users
     * @dev The staking token need to be approved to the contract by the user
     * @dev Maximum staking duration is {lockLimit - block.timestamp}
     * @param _amount uint256 - initial staking amount
     * @param _time uint256 - staking duration of tokens
     */
    function initialStake(uint256 _amount, uint256 _time)
        external
        stakeOpen
        updateReward(msg.sender)
    {
        require(
            userData[msg.sender].userUnlockingTime == 0,
            "[initialStake] Already staked!"
        );
        require(_amount > 0, "[initialStake] Insufficient amount.");
        require(_time > 0, "[initialStake] Insufficient time.");
        require(
            block.timestamp + _time < lockLimit,
            "[initialStake] Lock limit exceeded!"
        );

        // Sets user data
        userData[msg.sender].userWeights = calcWeight(_time);
        userData[msg.sender].userUnlockingTime = uint48(
            block.timestamp + _time
        );
        userData[msg.sender].stakedTimestamp = uint48(block.timestamp);

        wTotalStaked += (userData[msg.sender].userWeights * _amount);
        emit Staked(msg.sender, _amount, _time);

        // Manages internal stake amounts
        _increase(_amount);
    }

    /**
     * @notice Increasing stake position for user
     * @dev The staking token need to be approved to the contract by the user
     * @param _amount uint256 - increasing stake amount
     */
    function additionalStake(uint256 _amount)
        external
        stakeOpen
        updateReward(msg.sender)
    {
        require(
            userData[msg.sender].userUnlockingTime != 0,
            "[additionalStake] Initial stake not found!"
        );
        require(_amount > 0, "[additionalStake] Insufficient amount.");
        require(
            userData[msg.sender].userUnlockingTime > block.timestamp,
            "[additionalStake] Reached unlocking time!"
        );

        // Re-calculating weights
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

        // Manages internal stake amounts
        _increase(_amount);
    }

    /**
     * @notice Withdraws staked position w/wo penalties
     * @dev User gets less token from 75% to 25% if the unlocking time has not reached
     */
    function withdraw() external updateReward(msg.sender) {
        require(
            userData[msg.sender].userStaked > 0,
            "[withdraw] No staked balance."
        );

        uint256 _penaltyRate = 0;
        if (
            block.timestamp >= uint256(userData[msg.sender].userUnlockingTime)
        ) {
            // Staking time is over - free withdrawing
            emit Withdraw(msg.sender, userData[msg.sender].userStaked);
        } else {
            // Early withdrawing with penalties
            _penaltyRate =
                25 +
                ((uint256(userData[msg.sender].userUnlockingTime) -
                    block.timestamp) * 50) /
                uint256(
                    userData[msg.sender].userUnlockingTime -
                        userData[msg.sender].stakedTimestamp
                );
            emit PunishedWithdraw(
                msg.sender,
                (userData[msg.sender].userStaked * _penaltyRate) / 100,
                (userData[msg.sender].userStaked * (100 - _penaltyRate)) /
                    100
            );
        }
        wTotalStaked -=
            uint256(userData[msg.sender].userWeights) *
            userData[msg.sender].userStaked;

        // Manages internal stake amounts
        _decrease(userData[msg.sender].userStaked, _penaltyRate);
    }

    /**
     * @notice Withdraws all staked position without penalties if emergency status is active
     * @dev Emergency status can be activated by owner
     */
    function emergencyWithdraw() external updateReward(msg.sender) {
        require(
            isEmergencyOpen,
            "[emergencyWithdraw] Not emergency status."
        );
        require(
            userData[msg.sender].userStaked > 0,
            "[emergencyWithdraw] No staked balance."
        );

        wTotalStaked -=
            uint256(userData[msg.sender].userWeights) *
            userData[msg.sender].userStaked;

        // Manages internal stake amounts
        _decrease(userData[msg.sender].userStaked, 0);
    }

    /**
     * @notice Claims actively distributing token rewards
     */
    function claimAllRewards() external claimOpen updateReward(msg.sender) {
        emit Claimed(msg.sender);
        // Iterates all active reward tokens
        for (uint256 i = 0; i < activeRewards.length(); i++) {
            uint256 _reward = tokenRewards[activeRewards.at(i)][msg.sender];
            if (_reward > 0) {
                if (i == 0) {
                    require(
                        (tokenList[0].tokenInstance.balanceOf(address(this)) -
                            _reward) >= totalStaked,
                        "[claimAllRewards] No claimable balance."
                    );
                }
                tokenRewards[activeRewards.at(i)][msg.sender] = 0;
                tokenList[activeRewards.at(i)].tokenInstance.safeTransfer(
                    msg.sender,
                    _reward
                );
            }
        }
    }

    /**
     * @notice Claims specified token rewards
     * @dev The tokens removed from actively distributing list can only be claimed by this funciton
     * @param _id uint256 - reward token id
     */
    function claimSingleReward(uint256 _id) external updateReward(msg.sender) {
        require(
            activeRewards.contains(_id),
            "[claimSingleReward] Not an active reward."
        );
        uint256 _reward = tokenRewards[_id][msg.sender];
        emit Claimed(msg.sender);
        if (_reward > 0) {
            if (_id == 0) {
                require(
                    (tokenList[0].tokenInstance.balanceOf(address(this)) -
                        _reward) >= totalStaked,
                    "[claimSingleReward] No claimable balance."
                );
            }
            tokenRewards[_id][msg.sender] = 0;
            tokenList[_id].tokenInstance.safeTransfer(msg.sender, _reward);
        }
    }

    /**
     * @notice New reward token round can be created by owner
     * @param _tokenAddress address - Address of the reward token
     * @param _rewardRate uint256 - Tokens distribution rate per second
     * @param _deadline uint256 - Tokens last distribution timestamp
     * @param _decimals uint8 - Tokens decimal count
     */
    function addNewRewardToken(
        address _tokenAddress,
        uint256 _rewardRate,
        uint256 _deadline,
        uint8 _decimals
    ) external onlyOwner updateReward(address(0)) {
        require(
            _tokenAddress != address(0),
            "[addNewRewardToken] Address failure."
        );

        // Creating reward token data
        TokenInfo memory info = TokenInfo(
            IERC20(_tokenAddress),
            _rewardRate,
            0,
            _deadline,
            _decimals
        );

        tokenList.push(info);
        require(activeRewards.add(tokenList.length - 1));

        emit NewReward(_tokenAddress, tokenList.length - 1);
    }

    /**
     * @notice Removes reward token from the actively distributing list
     * @dev Can only be called after the distribution deadline is over
     * @dev After this removal, the tokens can not be claimed by [claimAllRewards]
     * @param _id uint256 - reward token id
     */
    function delistRewardToken(uint256 _id)
        external
        onlyOwner
        updateReward(address(0))
    {
        require(
            tokenList[_id].deadline < block.timestamp,
            "[delistRewardToken] Distr time has not over."
        );
        require(_id != 0, "[delistRewardToken] Can not delist main token.");
        require(
            activeRewards.remove(_id),
            "[delistRewardToken] Delisting unsuccessful"
        );
    }

    /**
     * @notice Sets emergency status
     * @dev Only owners can deposit rewards
     * @dev The depositing token need to be approved to the contract by the user
     * @param _id uint256 - Reward token id
     * @param _amount uint256 - Depositing reward token amount
     */
    function depositRewardTokens(uint256 _id, uint256 _amount)
        external
        onlyOwner
    {
        require(
            activeRewards.contains(_id),
            "[depositRewardTokens] Not active reward distr."
        );

        tokenList[_id].tokenInstance.safeTransferFrom(
            msg.sender,
            address(this),
            _amount
        );
    }

    /**
     * @notice Allows owner to claim all tokens in stuck
     * @notice The tokens staked by users can not be withdrawn
     * @notice It only will be used for the tokens for completed claim periods
     * @param _tokenAddress address - Address of the reward token
     * @param _amount uint256 - Withdrawing token amount
     */
    function withdrawStuckTokens(address _tokenAddress, uint256 _amount)
        external
        onlyOwner
    {
        if (_tokenAddress == address(tokenList[0].tokenInstance)) {
            require(
                (tokenList[0].tokenInstance.balanceOf(address(this)) -
                    _amount) >= totalStaked,
                "[withdrawStuckTokens] Users stakings can not be withdrawn."
            );
        }
        IERC20(_tokenAddress).safeTransfer(msg.sender, _amount);
    }

    /**
     * @notice Stops staking by owner authorizaton
     */
    function changeStakeStatus() external onlyOwner {
        isStakeOpen = !isStakeOpen;
        emit StakeStatusChanged(isStakeOpen);
    }

    /**
     * @notice Stops staking by owner authorizaton
     */
    function changeClaimStatus() external onlyOwner {
        isClaimOpen = !isClaimOpen;
        emit ClaimStatusChanged(isClaimOpen);
    }

    /**
     * @notice Activates emergency status
     * @dev Allows users to withdraw all staked tokens wo penalties
     */
    function changeEmergencyStatus() external onlyOwner {
        isEmergencyOpen = !isEmergencyOpen;

        for (uint256 i = 0; i < activeRewards.length(); i++) {
            changeDeadline(activeRewards.at(i), block.timestamp);
        }

        emit EmergencyStatusChanged(isEmergencyOpen);
    }

    /**
     * @notice Changes the lock limit
     * @param _lockLimit uint256 - New lock limit timestamp
     */
    function setLockLimit(uint256 _lockLimit) external onlyOwner {
        lockLimit = _lockLimit;
        emit LockLimitChanged(_lockLimit);
    }

    /**
     * @notice Sets the penalty address
     * @param _newAddress address - Destination address of penalty tokens
     */
    function changePenaltyAddress(address _newAddress) external onlyOwner {
        require(
            _newAddress != address(0),
            "[changePenaltyAddress] Address failure."
        );
        penaltyAddress = _newAddress;
    }

    /**
     * @notice Calculates the APR of main token staking
     * @param _weight uint256 - User weight to observe APR
     * @dev Min-Max APR can be showed by giving [1000, 2000] as param
     */
    function calcMainAPR(uint256 _weight) external view returns (uint256) {
        return
            (tokenList[0].rewardRate * 31_556_926 * _weight * 1000) /
            wTotalStaked;
    }

    /**
     * @notice Allows owner to change the distribution deadline of the tokens
     * @param _id uint256 - Reward token id
     * @param _time uint256 - New deadline timestamp
     * @dev The deadline can only be set to a future timestamp or 0 for unlimited deadline
     * @dev If the distribution is over, it can not be advanced
     */
    function changeDeadline(uint256 _id, uint256 _time)
        public
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

    // This function returns staking coefficient in the base of 100 (equals 1 coefficient)
    /**
     * @notice Calculates user staking coefficient (weight) due to staking time
     * @param _time uint256 - Staking time in seconds
     * @dev The coefficient is calculated by the formula: [coefficient = (day-90)^2 / 275^2 + 1]
     * @dev The coefficient is returned by 1000 base (1000 for 1 .... 2000 for 2)
     */
    function calcWeight(uint256 _time) public pure returns (uint16) {
        uint256 _stakingDays = _time / 1 days;
        if (_stakingDays <= 90) {
            return 1000;
        } else if (_stakingDays >= 365) {
            return 2000;
        } else {
            return uint16(((1000 * (_stakingDays - 90)**2) / 75625) + 1000);
        }
    }

    /**
     * @notice Calculates users weighted stakin amounts
     * @param _user address - Stakers address
     */
    function calcWeightedStake(address _user) public view returns (uint256) {
        return (userData[_user].userWeights * userData[_user].userStaked);
    }

    /**
     * @notice Staking helper function
     * @param _rewardTokenIndex uint256 - Reward tokens id
     */
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

    /**
     * @notice Staking helper function
     * @param _user address - Stakers address
     * @param _rewardTokenIndex uint256 - Reward tokens id
     */
    function earned(address _user, uint256 _rewardTokenIndex)
        public
        view
        returns (uint256)
    {
        if (rewardPerToken(_rewardTokenIndex) == 0)
            return tokenRewards[_rewardTokenIndex][_user];
        return
            ((calcWeightedStake(_user) *
                (rewardPerToken(_rewardTokenIndex) -
                    userRewardsPerTokenPaid[_rewardTokenIndex][_user])) /
                10**tokenList[_rewardTokenIndex].decimals) +
            tokenRewards[_rewardTokenIndex][_user];
    }

    // Increses staking positions of the users - actually "stake" function of general contracts
    /**
     * @notice Internally manages stake positions of the users - deposits actual token amounts
     * @param _amount address - Deposited token amount
     */
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
    /**
     * @notice Internally manages stake positions of the users - withdraws actual token amounts
     * @param _amount address - Withdrawed token amount
     * @param _penaltyRate uint256 - Percentage penalty rate to be cutted
     */
    function _decrease(uint256 _amount, uint256 _penaltyRate) private {
        if (userData[msg.sender].userStaked == _amount) {
            // If all balance is withdrawn, then the user data is removed
            delete (userData[msg.sender]);
        } else {
            userData[msg.sender].userStaked -= _amount;
        }
        totalStaked -= _amount;

        // User's early withdraw penalty is cutted
        if (_penaltyRate > 0) {
            uint256 _penalty = (_amount * _penaltyRate) / 100;
            _amount = _amount - _penalty;
            tokenList[0].tokenInstance.safeTransfer(
                penaltyAddress,
                _penalty
            );
        }
        tokenList[0].tokenInstance.safeTransfer(msg.sender, _amount);
    }

    /////////// Modifiers ///////////

    /**
     * @notice Updates staking positions
     * @param _user address - Staker address
     * @dev If the function is called by non-staker, {_user} can be setted to [address(0)]
     */
    modifier updateReward(address _user) {
        // Iterates all active reward tokens
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

    /**
     * @notice Closes token initial and later token staking
     */
    modifier stakeOpen() {
        require(isStakeOpen, "Not an active staking period.");
        _;
    }

    /**
     * @notice Closes token claims
     */
    modifier claimOpen() {
        require(isClaimOpen, "Not an claiming period.");
        _;
    }
}
