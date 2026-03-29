// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IronToken.sol";

/**
 * @title IronStaking
 * @notice Stake IRON tokens to earn a separate reward token streamed over time.
 *         The emission rate and schedule are configurable by the protocol admin.
 * @dev Uses a Synthetix-style accumulated-reward-per-token approach.
 *      Rewards accrue continuously between `lastUpdateTimestamp` and
 *      `rewardEndTimestamp`. Emission schedules are set via {fundRewards} and
 *      the per-second rate can be adjusted at any time via {setRewardRate}.
 */
contract IronStaking {
    IronToken public stakeToken;
    IronToken public rewardToken;

    address public owner;

    // ─── Global ───
    uint256 public totalStaked;
    uint256 public rewardPerSecond;
    uint256 public lastUpdateTimestamp;
    uint256 public accRewardPerToken; // 1e18 precision
    uint256 public rewardEndTimestamp;

    // ─── Per user ───
    struct UserInfo {
        uint256 stakedAmount;
        uint256 rewardDebt; // accRewardPerToken at last user action
        uint256 pendingRewards;
    }
    mapping(address => UserInfo) public userInfo;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 reward);
    event RewardRateChanged(uint256 oldRate, uint256 newRate);

    modifier onlyOwner() {
        require(msg.sender == owner, "Staking: not owner");
        _;
    }

    constructor(address _stakeToken, address _rewardToken) {
        stakeToken = IronToken(_stakeToken);
        rewardToken = IronToken(_rewardToken);
        owner = msg.sender;
        lastUpdateTimestamp = block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════

    function fundRewards(uint256 amount, uint256 duration) external onlyOwner {
        _updateRewards(address(0));
        rewardToken.transferFrom(msg.sender, address(this), amount);
        rewardPerSecond = amount / duration;
        rewardEndTimestamp = block.timestamp + duration;
        lastUpdateTimestamp = block.timestamp;
    }

    /**
     * @notice Update the reward emission rate.
     * @dev Can only be called by the owner. Takes effect immediately for the
     *      current epoch. To start a fresh epoch with a new token budget,
     *      use {fundRewards} instead.
     * @param newRate New number of reward tokens emitted per second.
     */
    function setRewardRate(uint256 newRate) external onlyOwner {
        uint256 oldRate = rewardPerSecond;
        rewardPerSecond = newRate;
        emit RewardRateChanged(oldRate, newRate);
    }

    // ═══════════════════════════════════════════════════════════════
    // STAKING
    // ═══════════════════════════════════════════════════════════════

    function stake(uint256 amount) external {
        require(amount > 0, "Staking: zero amount");
        _updateRewards(msg.sender);

        stakeToken.transferFrom(msg.sender, address(this), amount);
        userInfo[msg.sender].stakedAmount += amount;
        totalStaked += amount;

        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external {
        require(amount > 0, "Staking: zero amount");
        UserInfo storage user = userInfo[msg.sender];
        require(user.stakedAmount >= amount, "Staking: insufficient stake");

        _updateRewards(msg.sender);

        user.stakedAmount -= amount;
        totalStaked -= amount;
        stakeToken.transfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    function claim() external {
        _updateRewards(msg.sender);

        UserInfo storage user = userInfo[msg.sender];
        uint256 reward = user.pendingRewards;
        if (reward > 0) {
            user.pendingRewards = 0;
            rewardToken.transfer(msg.sender, reward);
            emit Claimed(msg.sender, reward);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════

    function pendingReward(address account) external view returns (uint256) {
        UserInfo storage user = userInfo[account];
        uint256 currentAcc = accRewardPerToken;

        if (totalStaked > 0) {
            uint256 end = block.timestamp < rewardEndTimestamp ? block.timestamp : rewardEndTimestamp;
            if (end > lastUpdateTimestamp) {
                uint256 elapsed = end - lastUpdateTimestamp;
                currentAcc += (elapsed * rewardPerSecond * 1e18) / totalStaked;
            }
        }

        return user.pendingRewards + (user.stakedAmount * (currentAcc - user.rewardDebt)) / 1e18;
    }

    // ═══════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════

    function _updateRewards(address account) internal {
        uint256 end = block.timestamp < rewardEndTimestamp ? block.timestamp : rewardEndTimestamp;

        if (totalStaked > 0 && end > lastUpdateTimestamp) {
            uint256 elapsed = end - lastUpdateTimestamp;
            accRewardPerToken += (elapsed * rewardPerSecond * 1e18) / totalStaked;
        }
        lastUpdateTimestamp = end;

        if (account != address(0)) {
            UserInfo storage user = userInfo[account];
            user.pendingRewards += (user.stakedAmount * (accRewardPerToken - user.rewardDebt)) / 1e18;
            user.rewardDebt = accRewardPerToken;
        }
    }
}
