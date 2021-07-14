// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

// import "hardhat/console.sol";

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol"; // OZ contracts v4
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol"; // OZ contracts v4
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol"; // OZ contracts v4

contract PolsStake is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    event Claimed(address indexed wallet, address indexed rewardToken, uint256 amount);
    event Rewarded(address indexed rewardToken, uint256 amount, uint256 totalStaked, uint256 date);
    event Stake(address indexed wallet, uint256 amount, uint256 date);
    event Withdraw(address indexed wallet, uint256 amount, uint256 date);
    event Log(uint256 data);

    struct User {
        uint32 stakeTime; // we will have a problem after 03:14:07 UTC on 19 January 2038
        uint112 stakeAmount; // limit ~ 5 * 10^15 token
        uint112 accumulatedRewards; // limit ~ 5 * 10^15 => ~ 2 years * 82,000,000 token staked
    }

    mapping(address => User) public userMap;

    uint256 public tokenTotalStaked; // sum of all staked token

    address public stakingToken; // address of token which can be staked into this contract
    address public rewardToken; // address of reward token
    address public tokenSaleContract; // the address of the token sale contract which is allowed to stake user's tokens directly

    /**
     * Using block.timestamp instead of block.number for reward calculation
     * 1) Easier to handle for users
     * 2) Should result in same rewards across different chain with different block times
     * 3) "The current block timestamp must be strictly larger than the timestamp of the last block, ...
     *     but the only guarantee is that it will be somewhere between the timestamps ...
     *     of two consecutive blocks in the canonical chain."
     *    https://docs.soliditylang.org/en/v0.7.6/cheatsheet.html?highlight=block.timestamp#global-variables
     */

    uint32 public lockTimePeriod; // time in seconds a user has to wait after calling unlock until staked token can be withdrawn
    uint32 public stakeRewardEndTime; // unix time in seconds after which no rewards will be paid out
    uint256 public stakeRewardFactor; // time in seconds * amount of staked token to receive 1 reward token

    constructor(address _stakingToken, uint32 _lockTimePeriod) {
        require(_stakingToken != address(0));
        // require(_rewardToken != address(0));  // _rewardToken can be 0, will disable claim/mint
        stakingToken = _stakingToken;
        // rewardToken = _rewardToken;
        lockTimePeriod = _lockTimePeriod;
        stakeRewardFactor = 1000 * 7 days; // default : a user has to stake 1000 token for 7 days to receive 1 reward token * decimals
        stakeRewardEndTime = uint32(block.timestamp + 366 days); // default : reward scheme ends in 1 year
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * based on OpenZeppelin SafeCast v4.1
     * https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.1/contracts/utils/math/SafeCast.sol
     */

    function toUint32(uint256 value) internal pure returns (uint32) {
        require(value < 2**32, "value doesn't fit in 32 bits");
        return uint32(value);
    }

    function toUint112(uint256 value) internal pure returns (uint112) {
        require(value < 2**112, "value doesn't fit in 112 bits");
        return uint112(value);
    }

    function stakeTime(address _staker) public view returns (uint256) {
        return userMap[_staker].stakeTime;
    }

    function stakeAmount(address _staker) public view returns (uint256) {
        return userMap[_staker].stakeAmount;
    }

    function userAccumulatedRewards(address _staker) public view returns (uint256) {
        return userMap[_staker].accumulatedRewards;
    }

    // onlyOwner / DEFAULT_ADMIN_ROLE functions --------------------------------------------------

    /**
     * @notice setting _rewardToken to 0 disables claim/mint
     * @param _rewardToken address
     */
    function setRewardToken(address _rewardToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        rewardToken = _rewardToken;
    }

    /**
     * @notice set a user has to wait after calling unlock until staked token can be withdrawn
     * @param _lockTimePeriod time in seconds
     */
    function setLockTimePeriod(uint32 _lockTimePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        lockTimePeriod = _lockTimePeriod;
    }

    /**
     * @notice set a user has to wait after calling unlock until staked token can be withdrawn
     * @notice see calculateUserClaimableReward() docs
     * @dev requires that reward token has the same decimals as stake token
     * @param _stakeRewardFactor time in seconds * amount of staked token to receive 1 reward token
     */
    function setStakeRewardFactor(uint256 _stakeRewardFactor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        stakeRewardFactor = _stakeRewardFactor;
    }

    /**
     * @notice set block number when stake reward scheme will end
     * @param _stakeRewardEndTime unix time in seconds
     */
    function setStakeRewardEndTime(uint32 _stakeRewardEndTime) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(stakeRewardEndTime > block.timestamp, "time has to be in the future");
        stakeRewardEndTime = _stakeRewardEndTime;
    }

    function setTokenSaleContract(address _tokenSaleContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tokenSaleContract = _tokenSaleContract;
    }

    /**
     * Burner role functions (will be the external lottery token sale contract)
     */
    function burnRewards(address _staker, uint256 _amount) public onlyRole(BURNER_ROLE) {
        User storage user = userMap[_staker];
        user.accumulatedRewards = toUint112(user.accumulatedRewards + userClaimableRewards(_staker));
        user.stakeTime = toUint32(block.timestamp);
        if (_amount <= user.accumulatedRewards) {
            user.accumulatedRewards = uint112(user.accumulatedRewards - _amount); // safe
        } else {
            user.accumulatedRewards = 0; // burn at least all what's there
        }
    }

    /** msg.sender external view convenience functions *********************************/

    function stakeAmount_msgSender() external view returns (uint256) {
        return userMap[msg.sender].stakeAmount;
    }

    function stakeTime_msgSender() external view returns (uint256) {
        return userMap[msg.sender].stakeTime;
    }

    function userStakedTokenUnlockTime_msgSender() external view returns (uint256 unlockTime) {
        return userStakedTokenUnlockTime(msg.sender);
    }

    function userClaimableRewards_msgSender() external view returns (uint256) {
        return userClaimableRewards(msg.sender);
    }

    function userAccumulatedRewards_msgSender() external view returns (uint256) {
        return userMap[msg.sender].accumulatedRewards;
    }

    function userTotalRewards_msgSender() external view returns (uint256) {
        return userTotalRewards(msg.sender);
    }

    function userClaimableRewardTokens_msgSender() external view returns (uint256) {
        return userClaimableRewardTokens(msg.sender);
    }

    /** public external view functions (also used internally) **************************/

    /**
     * calculates unclaimed rewards
     * unclaimed rewards = expired time since last stake/unstake transaction * current staked amount
     *
     * We have to cover 6 cases here :
     * 1) block time < stake time < end time   : should never happen => error
     * 2) block time < end time   < stake time : should never happen => error
     * 3) end time   < block time < stake time : should never happen => error
     * 4) end time   < stake time < block time : staked after reward period is over => no rewards
     * 5) stake time < block time < end time   : end time in the future
     * 6) stake time < end time   < block time : end time in the past & staked before
     * @param _staker address
     * @return claimableRewards = timePeriod * stakeAmount
     */
    function userClaimableRewards(address _staker) public view returns (uint256) {
        User storage user = userMap[_staker];
        // case 1) 2) 3)
        // stake time in the future - should never happen - actually an (internal ?) error
        if (block.timestamp < user.stakeTime) return 0;

        // case 4)
        // staked after reward period is over => no rewards
        // end time < stake time < block time
        if (stakeRewardEndTime < user.stakeTime) return 0;

        uint256 timePeriod;

        // case 5
        // we have not reached the end of the reward period
        // stake time < block time < end time
        if (block.timestamp <= stakeRewardEndTime) {
            timePeriod = block.timestamp - user.stakeTime; // covered by case 1) 2) 3) 'if'
        } else {
            // case 6
            // user staked before end of reward period , but that is in the past now
            // stake time < end time < block time
            timePeriod = stakeRewardEndTime - user.stakeTime; // covered case 4)
        }

        return timePeriod * user.stakeAmount;
    }

    function userTotalRewards(address _staker) public view returns (uint256) {
        return userClaimableRewards(_staker) + userMap[_staker].accumulatedRewards;
    }

    function userClaimableRewardTokens(address _staker) public view returns (uint256 claimableRewardTokens) {
        if (address(rewardToken) == address(0)) {
            return 0;
        } else {
            return userTotalRewards(_staker) / stakeRewardFactor;
        }
    }

    /**
     * @dev return unix epoch time when staked token will be unlocked
     * @dev return 0 if user has no token staked
     * @return unlockTime unix epoch time in seconds
     */
    function userStakedTokenUnlockTime(address _staker) public view returns (uint256 unlockTime) {
        return userMap[_staker].stakeAmount > 0 ? (lockTimePeriod + userMap[_staker].stakeTime) : 0;
    }

    /**
     *  @dev whenver the staked balance changes do for msg.sender :
     *
     *  @dev calculate userClaimableRewards = previous staked amount * (current time - last stake time)
     *  @dev add userClaimableRewards to userAccumulatedRewards
     *  @dev reset userClaimableRewards to 0 by setting stakeTime to current time
     *  @dev not used as doing it inline, local, within a function consumes less gas
     */
    /*
    function _updateRewards(address _staker) internal {
        // calculate reward credits using previous staking amount and previous time period
        // add new reward credits to already accumulated reward credits
        User storage user = userMap[_staker];
        user.accumulatedRewards = toUint112(user.accumulatedRewards + userClaimableRewards(_staker));

        // update stake Time to current time (start new reward period)
        // will also reset userClaimableRewards()
        user.stakeTime = toUint32(block.timestamp);
    }
    */

    /**
     * token sale contract can transfer tokens on behalf of the user (token owner)
     * directly from the token sale contract to this staking contract
     */
    function stakeTransfer(uint256 _amount, address _account) external nonReentrant returns (uint256) {
        require(tokenSaleContract != address(0), "tokenSaleContract is not set");
        require(tokenSaleContract == msg.sender, "msg.sender is not tokenSaleContract");
        return _stake(_amount, msg.sender, _account);
    }

    /**
     * add stake token to staking pool
     * @dev requires the token to be approved for transfer
     * @param _amount of token to be staked
     * @param _sourceAccount address of token source account/contract
     * @param _beneficiaryAccount address of beneficiary account
     */
    function _stake(
        uint256 _amount,
        address _sourceAccount,
        address _beneficiaryAccount
    ) internal returns (uint256) {
        require(_amount > 0, "amount to be staked must be >0");

        User storage user = userMap[_beneficiaryAccount];

        user.accumulatedRewards = toUint112(user.accumulatedRewards + userClaimableRewards(_beneficiaryAccount));
        user.stakeTime = toUint32(block.timestamp);

        user.stakeAmount = toUint112(user.stakeAmount + _amount);
        tokenTotalStaked += _amount;

        // using SafeERC20 for IERC20 => will revert in case of error
        IERC20(stakingToken).safeTransferFrom(_sourceAccount, address(this), _amount);

        emit Stake(_sourceAccount, _amount, user.stakeTime);
        return _amount;
    }

    /**
     * withdraw staked token, ...
     * do not claim (mint) rewards token (it might not be worth the gas)
     * @return _amount of token will be reurned to user's account
     */
    function _withdraw() internal returns (uint256) {
        User storage user = userMap[msg.sender];
        require(user.stakeAmount > 0, "no staked token to withdraw");
        require(block.timestamp > lockTimePeriod + user.stakeTime, "staked token are still locked");

        // _updateRewards(msg.sender);
        user.accumulatedRewards = toUint112(user.accumulatedRewards + userClaimableRewards(msg.sender));
        user.stakeTime = toUint32(block.timestamp);

        uint256 amount = user.stakeAmount;
        user.stakeAmount = 0;
        tokenTotalStaked -= amount;

        // using SafeERC20 for IERC20 => will revert in case of error
        IERC20(stakingToken).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount, user.stakeTime);
        return amount;
    }

    function getRewardTokenBalance() public view returns (uint256 balance) {
        balance = IERC20(rewardToken).balanceOf(address(this));
        if (stakingToken == rewardToken) {
            balance -= tokenTotalStaked;
        }
    }

    /**
     * claim & mint reward tokens for accumulated reward credits ...
     * but do not unstake staked token
     */
    function _claim() internal returns (uint256) {
        require(rewardToken != address(0), "no reward token contract");
        uint256 claimableRewardTokenAmount = userClaimableRewardTokens(msg.sender);
        require(claimableRewardTokenAmount > 0, "no tokens to claim");

        // reset all rewards to 0
        User storage user = userMap[msg.sender];
        user.accumulatedRewards = 0;
        user.stakeTime = toUint32(block.timestamp); // results in claimableRewardTokenAmount = 0
        // user.stakeAmount = unchanged

        // this contract must have MINTER_ROLE in order to be able to mint reward tokens
        // IERC20Mintable(rewardToken).mint(msg.sender, claimableRewardTokenAmount);

        require(claimableRewardTokenAmount <= getRewardTokenBalance(), "not enough reward tokens");
        IERC20(rewardToken).safeTransfer(msg.sender, claimableRewardTokenAmount);

        emit Claimed(msg.sender, rewardToken, claimableRewardTokenAmount);
        return claimableRewardTokenAmount;
    }

    function stake(uint256 _amount) external nonReentrant returns (uint256) {
        return _stake(_amount, msg.sender, msg.sender);
    }

    function claim() external nonReentrant returns (uint256) {
        return _claim();
    }

    function withdraw() external nonReentrant returns (uint256) {
        return _withdraw();
    }
}
