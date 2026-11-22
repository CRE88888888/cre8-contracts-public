// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TestnetToken } from "../TestnetToken.sol";
import { MockLista } from "../yield/MockLista.sol";

/// @notice Chain-97-only USDT earn vault for Strategy Earn (#64, EARN_UX §B/§C): the `MockLista` ERC4626 vault
/// (simulated APR, partial liquidity, utilization) plus a simulated incentive APR on top, like a Lista vault's
/// reward emissions. Incentives accrue per share holder on the USD value of its shares and are paid in the
/// vault's asset (testnet USDT; this vault is already a USDT minter for its interest) only to that holder.
contract MockEarnVault is MockLista {
    uint16 public incentiveAprBps;
    mapping(address => uint256) public rewardAccrued;
    mapping(address => uint256) public rewardStamp;

    event SimulatedIncentiveSet(uint16 aprBps);
    event RewardClaimed(address indexed account, uint256 amount);

    constructor(TestnetToken asset_, address owner_, uint16 apr) MockLista(asset_, owner_, apr) { }

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
        TestnetToken(asset()).mint(account, amount);
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
        uint256 value = convertToAssets(balanceOf(account));
        return Math.mulDiv(value * incentiveAprBps, block.timestamp - last, 10_000 * 365 days);
    }
}
