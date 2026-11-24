// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TestnetToken } from "../TestnetToken.sol";
import { MockLista } from "../yield/MockLista.sol";

/// @notice Chain-97-only earn vault for Strategy Earn routing v2: the `MockLista` ERC4626 vault (simulated APR,
/// partial liquidity) for any loan token, with a simulated incentive paid in a separate reward token, the way a
/// Lista vault's LISTA emissions are. Incentives accrue per share holder on the USD value of its shares
/// (the vault's asset and the reward token both count as 1 USD per whole token) and are minted only to that
/// holder; anyone may trigger the claim. In routing v2 the holder is the account's strategy box, and
/// `collectRewards` moves the reward into the portfolio account.
/// @dev Differs from `MockEarnVault` (v1), whose incentive is paid in the vault's own asset: a loan token
/// arriving in a strategy box is strategy money, not a reward. This vault must be a minter of `rewardToken`.
contract MockRewardEarnVault is MockLista {
    TestnetToken public immutable rewardToken;
    uint256 internal immutable assetScale;
    uint16 public incentiveAprBps;
    mapping(address => uint256) public rewardAccrued;
    mapping(address => uint256) public rewardStamp;

    event SimulatedIncentiveSet(uint16 aprBps);
    event RewardClaimed(address indexed account, uint256 amount);

    constructor(TestnetToken asset_, address owner_, uint16 apr, TestnetToken rewardToken_)
        MockLista(asset_, owner_, apr)
    {
        require(
            address(rewardToken_).code.length != 0 && address(rewardToken_) != address(asset_)
                && rewardToken_.decimals() == 18 && asset_.decimals() <= 18,
            "yield mock: reward"
        );
        rewardToken = rewardToken_;
        assetScale = 10 ** (18 - asset_.decimals());
    }

    function setIncentiveAprBps(uint16 apr) external {
        require(msg.sender == owner, "yield mock: owner only");
        require(apr <= 10_000, "incentive cap");
        incentiveAprBps = apr;
        emit SimulatedIncentiveSet(apr);
    }

    function rewardOf(address account) external view returns (uint256) {
        return rewardAccrued[account] + _pendingReward(account);
    }

    /// @notice Anyone may trigger; rewards always go to `account`, the share holder.
    function claimReward(address account) external returns (uint256 amount) {
        _accrueReward(account);
        amount = rewardAccrued[account];
        if (amount == 0) return 0;
        rewardAccrued[account] = 0;
        rewardToken.mint(account, amount);
        emit RewardClaimed(account, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) _accrueReward(from);
        if (to != address(0)) _accrueReward(to);
        super._update(from, to, value);
    }

    function _accrueReward(address account) private {
        rewardAccrued[account] += _pendingReward(account);
        rewardStamp[account] = block.timestamp;
    }

    function _pendingReward(address account) private view returns (uint256) {
        uint256 last = rewardStamp[account];
        if (last == 0 || last >= block.timestamp || incentiveAprBps == 0) return 0;
        uint256 value = convertToAssets(balanceOf(account)) * assetScale;
        return Math.mulDiv(value * incentiveAprBps, block.timestamp - last, 10_000 * 365 days);
    }
}
