pragma solidity ^0.5.16;

import "openzeppelin-solidity-2.3.0/contracts/math/Math.sol";
import "openzeppelin-solidity-2.3.0/contracts/math/SafeMath.sol";
import "openzeppelin-solidity-2.3.0/contracts/token/ERC20/ERC20Detailed.sol";
import "openzeppelin-solidity-2.3.0/contracts/token/ERC20/SafeERC20.sol";
import "openzeppelin-solidity-2.3.0/contracts/utils/ReentrancyGuard.sol";

// Inheritance
import "./interfaces/IStakingRewards.sol";
import "./RewardsDistributionRecipient.sol";

/**
 * 用户挖矿奖励的计算：用户stake时 存储当时每token奖励的数额 , 到用户withdraw时，此时的每token奖励的数额 - stake时存储当时每token奖励的数额  == token奖励数额的增量 * 质押token数量 + 未领取的挖矿奖励数额  == 最终总挖矿奖励数量
 */

/**
 * 本合约质押的时间是有限制，然后在通过总的奖励数额reward因此才可以获取每秒的奖励数额是多少rewardRate
 */

contract StakingRewards is IStakingRewards, RewardsDistributionRecipient, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */
    //奖励代币，即 UNI 代币
    IERC20 public rewardsToken;
    IERC20 public stakingToken;
    //质押挖矿结束的时间，默认时为 0
    uint256 public periodFinish = 0;
    //挖矿速率，即每秒挖矿奖励的数量
    uint256 public rewardRate = 0;
    //挖矿时长，默认设置为 60 天
    uint256 public rewardsDuration = 60 days;
    //最近一次更新时间
    uint256 public lastUpdateTime;
    //每单位 token 奖励数量
    uint256 public rewardPerTokenStored;

    //用户的每单位 token 奖励数量
    mapping(address => uint256) public userRewardPerTokenPaid;
    //用户的奖励数量
    mapping(address => uint256) public rewards;

    //总质押量
    uint256 private _totalSupply;
    //用户的质押余额
    mapping(address => uint256) private _balances;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _rewardsDistribution,
        address _rewardsToken,
        address _stakingToken
    ) public {
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
        //奖励分配地址
        rewardsDistribution = _rewardsDistribution;
    }

    /* ========== VIEWS ========== */

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }
    
    //有奖励的最近区块数
    function lastTimeRewardApplicable() public view returns (uint256) {
        //从当前区块时间和挖矿结束时间两者中返回最小值。因此，当挖矿未结束时返回的就是当前区块时间，而挖矿结束后则返回挖矿结束时间。也因此，挖矿结束后，lastUpdateTime 也会一直等于挖矿结束时间，这点很关键
        return Math.min(block.timestamp, periodFinish);
    }

    //每单位 Token 奖励数量
    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        //lastTimeRewardApplicable挖矿未结束前都是当前时间
        //获取 （当前时间 - 上一次更新时间）* 每秒的挖矿奖励数量 / 总质押量 == 此刻每个token获取的奖励数额
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply)
            );
    }

    //用户已赚但未提取的奖励数量
    //计算出增量的每单位质押代币的挖矿奖励，再乘以用户的质押余额得到增量的总挖矿奖励，再加上之前已存储的挖矿奖励，就得到当前总的挖矿奖励。
    function earned(address account) public view returns (uint256) {
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    //挖矿奖励总量  rewardsDuration = 60 days
    function getRewardForDuration() external view returns (uint256) {
        return rewardRate.mul(rewardsDuration);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stakeWithPermit(uint256 amount, uint deadline, uint8 v, bytes32 r, bytes32 s) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);

        // permit
        IUniswapV2ERC20(address(stakingToken)).permit(msg.sender, address(this), amount, deadline, v, r, s);

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function notifyRewardAmount(uint256 reward) external onlyRewardsDistribution updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            //将从工厂合约转过来的挖矿奖励总量除以挖矿奖励时长，得到挖矿速率 rewardRate，即每秒的挖矿数量
            rewardRate = reward.div(rewardsDuration);
        } else {
            //else 分支是执行不到的，除非以后工厂合约升级为可以多次触发执行该函数
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint balance = rewardsToken.balanceOf(address(this));
        //读取 balance 并校验下 rewardRate，可以保证收取到的挖矿奖励余额也是充足的，rewardRate 就不会虚高
        require(rewardRate <= balance.div(rewardsDuration), "Provided reward too high");

        lastUpdateTime = block.timestamp;
        //当前区块时间上加上挖矿时长，就得到了挖矿结束的时间。
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        //每个token的奖励数额
        rewardPerTokenStored = rewardPerToken();
        ////从当前区块时间和挖矿结束时间两者中返回最小值。因此，当挖矿未结束时返回的就是当前区块时间，而挖矿结束后则返回挖矿结束时间。也因此，挖矿结束后，lastUpdateTime 也会一直等于挖矿结束时间，这点很关键
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
}

interface IUniswapV2ERC20 {
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
}
