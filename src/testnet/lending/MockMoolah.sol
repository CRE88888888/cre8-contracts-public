// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { MoolahParams, MoolahMarket } from "../../atp/yield/YieldInterfaces.sol";

interface IMockMintable {
    function mint(address to, uint256 amount) external;
}

interface IPeekOracle {
    function peek(address asset) external view returns (uint256);
}

/// @notice Chain-97-only Lista Moolah core (#64), Morpho Blue ABI: isolated markets keyed by
/// `keccak256(abi.encode(params))`, lender `supply`/`withdraw`, borrower `supplyCollateral`/`borrow`/`repay`/
/// `withdrawCollateral`, `liquidate`, `setAuthorization`. Shares use Morpho's virtual 1e6 shares / 1 asset.
/// Health uses Lista's oracle `peek` (USD, 8 decimals) and the market LLTV; the liquidation incentive is
/// Morpho's `min(1.15, 1 / (1 - 0.3 * (1 - lltv)))`. The IRM is this contract: a fixed, owner-adjustable borrow
/// APR per market (simple interest per second). Callbacks (`data`) are not supported and must be empty.
contract MockMoolah {
    using SafeERC20 for IERC20;

    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;
    uint256 internal constant MAX_LIF = 1.15e18;
    uint256 internal constant LIF_CURSOR = 0.3e18;

    struct Position {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    address public immutable owner;
    bool public paused;
    mapping(bytes32 => MoolahParams) internal _params;
    mapping(bytes32 => MoolahMarket) internal _market;
    mapping(bytes32 => mapping(address => Position)) internal _position;
    mapping(address => mapping(address => bool)) public isAuthorized;
    mapping(bytes32 => uint16) public borrowAprBps;

    /// @notice Simulated incentives per market (bps of USD value per year), like Lista's daily bStock-collateral
    /// reward pool and borrow rebates (a borrow incentive above the borrow APR makes the net rate negative).
    /// Paid in `rewardToken` (testnet USDT: 1 raw unit per 1e-18 USD) only to the position's own account.
    address public rewardToken;
    mapping(bytes32 => uint16) public collateralIncentiveAprBps;
    mapping(bytes32 => uint16) public borrowIncentiveAprBps;
    mapping(bytes32 => mapping(address => uint256)) public rewardAccrued;
    mapping(bytes32 => mapping(address => uint256)) public rewardStamp;

    event CreateMarket(bytes32 indexed id, MoolahParams params);
    event Supply(
        bytes32 indexed id, address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares
    );
    event Withdraw(
        bytes32 indexed id, address caller, address indexed onBehalf, address indexed receiver, uint256 assets
    );
    event SupplyCollateral(
        bytes32 indexed id, address indexed caller, address indexed onBehalf, uint256 assets
    );
    event WithdrawCollateral(
        bytes32 indexed id, address caller, address indexed onBehalf, address indexed receiver, uint256 assets
    );
    event Borrow(
        bytes32 indexed id,
        address caller,
        address indexed onBehalf,
        address indexed receiver,
        uint256 assets,
        uint256 shares
    );
    event Repay(
        bytes32 indexed id, address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares
    );
    event Liquidate(
        bytes32 indexed id,
        address indexed caller,
        address indexed borrower,
        uint256 repaidAssets,
        uint256 seizedAssets
    );
    event SetAuthorization(address indexed authorizer, address indexed authorized, bool newIsAuthorized);
    event SimulatedBorrowAprSet(bytes32 indexed id, uint16 aprBps);
    event PausedSet(bool paused);
    event SimulatedIncentivesSet(bytes32 indexed id, uint16 collateralAprBps, uint16 borrowAprBps);
    event RewardClaimed(bytes32 indexed id, address indexed account, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "lending mock: owner only");
        _;
    }

    constructor(address owner_) {
        require(block.chainid == 97, "lending mock: chain 97 only");
        require(owner_ != address(0), "lending mock: config");
        owner = owner_;
    }

    function isTestnetLendingMock() external pure returns (bool) {
        return true;
    }

    function marketId(MoolahParams memory p) public pure returns (bytes32) {
        return keccak256(abi.encode(p));
    }

    // ---- admin ----

    function createMarket(MoolahParams memory p, uint16 aprBps) external onlyOwner returns (bytes32 id) {
        id = marketId(p);
        require(_market[id].lastUpdate == 0, "market already created");
        require(p.lltv != 0 && p.lltv < 1e18, "lltv");
        require(p.irm == address(this), "irm");
        require(p.loanToken.code.length != 0 && p.collateralToken.code.length != 0, "tokens");
        require(p.oracle.code.length != 0, "oracle");
        require(aprBps <= 10_000, "APR cap");
        _params[id] = p;
        _market[id].lastUpdate = uint128(block.timestamp);
        borrowAprBps[id] = aprBps;
        emit CreateMarket(id, p);
        emit SimulatedBorrowAprSet(id, aprBps);
    }

    function setBorrowAprBps(bytes32 id, uint16 aprBps) external onlyOwner {
        require(aprBps <= 10_000, "APR cap");
        _accrue(id);
        borrowAprBps[id] = aprBps;
        emit SimulatedBorrowAprSet(id, aprBps);
    }

    function setRewardToken(address token) external onlyOwner {
        rewardToken = token;
    }

    function setIncentives(bytes32 id, uint16 collateralAprBps, uint16 borrowAprBps_) external onlyOwner {
        require(_market[id].lastUpdate != 0, "market not created");
        require(collateralAprBps <= 10_000 && borrowAprBps_ <= 10_000, "incentive cap");
        _accrue(id);
        collateralIncentiveAprBps[id] = collateralAprBps;
        borrowIncentiveAprBps[id] = borrowAprBps_;
        emit SimulatedIncentivesSet(id, collateralAprBps, borrowAprBps_);
    }

    function rewardOf(bytes32 id, address account) external view returns (uint256) {
        return rewardAccrued[id][account] + _pendingReward(id, account);
    }

    /// @notice Anyone may trigger; rewards always go to `account`, the position holder.
    function claimReward(bytes32 id, address account) external returns (uint256 amount) {
        require(_market[id].lastUpdate != 0, "market not created");
        _accrue(id);
        _accrueReward(id, account);
        amount = rewardAccrued[id][account];
        if (amount == 0) return 0;
        rewardAccrued[id][account] = 0;
        IMockMintable(rewardToken).mint(account, amount);
        emit RewardClaimed(id, account, amount);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    // ---- reads ----

    function idToMarketParams(bytes32 id) external view returns (MoolahParams memory) {
        return _params[id];
    }

    function market(bytes32 id) external view returns (MoolahMarket memory) {
        return _market[id];
    }

    function position(bytes32 id, address user) external view returns (uint256, uint128, uint128) {
        Position memory p = _position[id][user];
        return (p.supplyShares, p.borrowShares, p.collateral);
    }

    function isHealthy(MoolahParams memory p, address borrower) external view returns (bool) {
        return _isHealthy(p, marketId(p), borrower);
    }

    /// @notice Morpho IRM read: this mock is every market's IRM; borrow rate per second, 18 decimals.
    function borrowRateView(MoolahParams memory p, MoolahMarket memory) external view returns (uint256) {
        return uint256(borrowAprBps[marketId(p)]) * 1e18 / (10_000 * 365 days);
    }

    // ---- authorization ----

    function setAuthorization(address authorized, bool newIsAuthorized) external {
        isAuthorized[msg.sender][authorized] = newIsAuthorized;
        emit SetAuthorization(msg.sender, authorized, newIsAuthorized);
    }

    // ---- lenders ----

    function supply(
        MoolahParams memory p,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256) {
        bytes32 id = _live(p, data);
        require((assets == 0) != (shares == 0), "inconsistent input");
        require(onBehalf != address(0), "zero address");
        _accrue(id);
        MoolahMarket storage s = _market[id];
        if (assets > 0) shares = _toSharesDown(assets, s.totalSupplyAssets, s.totalSupplyShares);
        else assets = _toAssetsUp(shares, s.totalSupplyAssets, s.totalSupplyShares);
        _position[id][onBehalf].supplyShares += shares;
        s.totalSupplyShares += uint128(shares);
        s.totalSupplyAssets += uint128(assets);
        IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        emit Supply(id, msg.sender, onBehalf, assets, shares);
        return (assets, shares);
    }

    function withdraw(
        MoolahParams memory p,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        bytes32 id = marketId(p);
        require(_market[id].lastUpdate != 0, "market not created");
        require((assets == 0) != (shares == 0), "inconsistent input");
        _authorized(onBehalf);
        _accrue(id);
        MoolahMarket storage s = _market[id];
        if (assets > 0) shares = _toSharesUp(assets, s.totalSupplyAssets, s.totalSupplyShares);
        else assets = _toAssetsDown(shares, s.totalSupplyAssets, s.totalSupplyShares);
        _position[id][onBehalf].supplyShares -= shares;
        s.totalSupplyShares -= uint128(shares);
        s.totalSupplyAssets -= uint128(assets);
        require(s.totalBorrowAssets <= s.totalSupplyAssets, "insufficient liquidity");
        IERC20(p.loanToken).safeTransfer(receiver, assets);
        emit Withdraw(id, msg.sender, onBehalf, receiver, assets);
        return (assets, shares);
    }

    // ---- borrowers ----

    function supplyCollateral(MoolahParams memory p, uint256 assets, address onBehalf, bytes calldata data)
        external
    {
        bytes32 id = _live(p, data);
        require(assets != 0, "zero assets");
        require(onBehalf != address(0), "zero address");
        _accrueReward(id, onBehalf);
        _position[id][onBehalf].collateral += uint128(assets);
        IERC20(p.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
        emit SupplyCollateral(id, msg.sender, onBehalf, assets);
    }

    function withdrawCollateral(MoolahParams memory p, uint256 assets, address onBehalf, address receiver)
        external
    {
        bytes32 id = marketId(p);
        require(_market[id].lastUpdate != 0, "market not created");
        require(assets != 0, "zero assets");
        require(receiver != address(0), "zero address");
        _authorized(onBehalf);
        _accrue(id);
        _accrueReward(id, onBehalf);
        _position[id][onBehalf].collateral -= uint128(assets);
        require(_isHealthy(p, id, onBehalf), "insufficient collateral");
        IERC20(p.collateralToken).safeTransfer(receiver, assets);
        emit WithdrawCollateral(id, msg.sender, onBehalf, receiver, assets);
    }

    function borrow(MoolahParams memory p, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256)
    {
        bytes32 id = _live(p, "");
        require((assets == 0) != (shares == 0), "inconsistent input");
        require(receiver != address(0), "zero address");
        _authorized(onBehalf);
        _accrue(id);
        MoolahMarket storage s = _market[id];
        if (assets > 0) shares = _toSharesUp(assets, s.totalBorrowAssets, s.totalBorrowShares);
        else assets = _toAssetsDown(shares, s.totalBorrowAssets, s.totalBorrowShares);
        _accrueReward(id, onBehalf);
        _position[id][onBehalf].borrowShares += uint128(shares);
        s.totalBorrowShares += uint128(shares);
        s.totalBorrowAssets += uint128(assets);
        require(_isHealthy(p, id, onBehalf), "insufficient collateral");
        require(s.totalBorrowAssets <= s.totalSupplyAssets, "insufficient liquidity");
        IERC20(p.loanToken).safeTransfer(receiver, assets);
        emit Borrow(id, msg.sender, onBehalf, receiver, assets, shares);
        return (assets, shares);
    }

    /// @notice Repay is open while paused, like Lista.
    function repay(
        MoolahParams memory p,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256) {
        bytes32 id = marketId(p);
        require(_market[id].lastUpdate != 0, "market not created");
        require(data.length == 0, "callbacks unsupported");
        require((assets == 0) != (shares == 0), "inconsistent input");
        require(onBehalf != address(0), "zero address");
        _accrue(id);
        MoolahMarket storage s = _market[id];
        if (assets > 0) shares = _toSharesDown(assets, s.totalBorrowAssets, s.totalBorrowShares);
        else assets = _toAssetsUp(shares, s.totalBorrowAssets, s.totalBorrowShares);
        _accrueReward(id, onBehalf);
        _position[id][onBehalf].borrowShares -= uint128(shares);
        s.totalBorrowShares -= uint128(shares);
        s.totalBorrowAssets = uint128(_zeroFloorSub(s.totalBorrowAssets, assets));
        IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        emit Repay(id, msg.sender, onBehalf, assets, shares);
        return (assets, shares);
    }

    /// @notice Repay an unhealthy borrower's debt and take collateral at the incentive. Exactly one of
    /// `seizedAssets` / `repaidShares` is non-zero. Bad debt left with no collateral is socialized to lenders.
    function liquidate(
        MoolahParams memory p,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external returns (uint256, uint256) {
        bytes32 id = _live(p, data);
        require((seizedAssets == 0) != (repaidShares == 0), "inconsistent input");
        _accrue(id);
        require(!_isHealthy(p, id, borrower), "healthy position");
        MoolahMarket storage s = _market[id];
        uint256 incentive =
            Math.min(MAX_LIF, Math.mulDiv(1e18, 1e18, 1e18 - Math.mulDiv(LIF_CURSOR, 1e18 - p.lltv, 1e18)));
        // collateral raw per loan raw, scaled 1e36: loanPrice * 10^collDec / (collPrice * 10^loanDec)
        uint256 collPrice = IPeekOracle(p.oracle).peek(p.collateralToken);
        uint256 loanPrice = IPeekOracle(p.oracle).peek(p.loanToken);
        uint256 collUnit = 10 ** IERC20Metadata(p.collateralToken).decimals();
        uint256 loanUnit = 10 ** IERC20Metadata(p.loanToken).decimals();
        uint256 repaidAssets;
        if (seizedAssets > 0) {
            // value(seized) / incentive, in loan raw
            uint256 seizedValue = Math.mulDiv(seizedAssets, collPrice, collUnit);
            repaidAssets = Math.mulDiv(
                Math.mulDiv(seizedValue, loanUnit, loanPrice, Math.Rounding.Ceil),
                1e18,
                incentive,
                Math.Rounding.Ceil
            );
            repaidShares = _toSharesDown(repaidAssets, s.totalBorrowAssets, s.totalBorrowShares);
        } else {
            repaidAssets = _toAssetsUp(repaidShares, s.totalBorrowAssets, s.totalBorrowShares);
            uint256 repaidValue = Math.mulDiv(repaidAssets, loanPrice, loanUnit);
            seizedAssets = Math.mulDiv(Math.mulDiv(repaidValue, incentive, 1e18), collUnit, collPrice);
        }
        _accrueReward(id, borrower);
        Position storage pos = _position[id][borrower];
        pos.borrowShares -= uint128(repaidShares);
        s.totalBorrowShares -= uint128(repaidShares);
        s.totalBorrowAssets = uint128(_zeroFloorSub(s.totalBorrowAssets, repaidAssets));
        pos.collateral -= uint128(seizedAssets);
        if (pos.collateral == 0 && pos.borrowShares != 0) {
            uint256 badShares = pos.borrowShares;
            uint256 badDebt = Math.min(
                s.totalBorrowAssets, _toAssetsUp(badShares, s.totalBorrowAssets, s.totalBorrowShares)
            );
            s.totalBorrowAssets -= uint128(badDebt);
            s.totalSupplyAssets -= uint128(badDebt);
            s.totalBorrowShares -= uint128(badShares);
            pos.borrowShares = 0;
        }
        IERC20(p.collateralToken).safeTransfer(msg.sender, seizedAssets);
        IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), repaidAssets);
        emit Liquidate(id, msg.sender, borrower, repaidAssets, seizedAssets);
        return (seizedAssets, repaidAssets);
    }

    function accrueInterest(MoolahParams memory p) external {
        bytes32 id = marketId(p);
        require(_market[id].lastUpdate != 0, "market not created");
        _accrue(id);
    }

    // ---- internals ----

    function _live(MoolahParams memory p, bytes memory data) private view returns (bytes32 id) {
        require(!paused, "paused");
        require(data.length == 0, "callbacks unsupported");
        id = marketId(p);
        require(_market[id].lastUpdate != 0, "market not created");
    }

    function _authorized(address onBehalf) private view {
        require(msg.sender == onBehalf || isAuthorized[onBehalf][msg.sender], "unauthorized");
    }

    function _accrue(bytes32 id) private {
        MoolahMarket storage s = _market[id];
        uint256 elapsed = block.timestamp - s.lastUpdate;
        if (elapsed == 0) return;
        s.lastUpdate = uint128(block.timestamp);
        uint256 interest =
            Math.mulDiv(s.totalBorrowAssets, uint256(borrowAprBps[id]) * elapsed, 10_000 * 365 days);
        s.totalBorrowAssets += uint128(interest);
        s.totalSupplyAssets += uint128(interest);
    }

    function _isHealthy(MoolahParams memory p, bytes32 id, address borrower) private view returns (bool) {
        Position memory pos = _position[id][borrower];
        if (pos.borrowShares == 0) return true;
        MoolahMarket memory s = _market[id];
        uint256 borrowed = _toAssetsUp(pos.borrowShares, s.totalBorrowAssets, s.totalBorrowShares);
        uint256 debtValue = Math.mulDiv(
            borrowed, IPeekOracle(p.oracle).peek(p.loanToken), 10 ** IERC20Metadata(p.loanToken).decimals()
        );
        uint256 collateralValue = Math.mulDiv(
            pos.collateral,
            IPeekOracle(p.oracle).peek(p.collateralToken),
            10 ** IERC20Metadata(p.collateralToken).decimals()
        );
        return debtValue <= Math.mulDiv(collateralValue, p.lltv, 1e18);
    }

    function _toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares)
        private
        pure
        returns (uint256)
    {
        return Math.mulDiv(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    function _toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares)
        private
        pure
        returns (uint256)
    {
        return Math.mulDiv(
            assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS, Math.Rounding.Ceil
        );
    }

    function _toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares)
        private
        pure
        returns (uint256)
    {
        return Math.mulDiv(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    function _toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares)
        private
        pure
        returns (uint256)
    {
        return Math.mulDiv(
            shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES, Math.Rounding.Ceil
        );
    }

    function _zeroFloorSub(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    function _accrueReward(bytes32 id, address account) private {
        rewardAccrued[id][account] += _pendingReward(id, account);
        rewardStamp[id][account] = block.timestamp;
    }

    function _pendingReward(bytes32 id, address account) private view returns (uint256) {
        uint256 last = rewardStamp[id][account];
        if (last == 0 || last >= block.timestamp) return 0;
        if (collateralIncentiveAprBps[id] == 0 && borrowIncentiveAprBps[id] == 0) return 0;
        MoolahParams memory p = _params[id];
        Position memory pos = _position[id][account];
        MoolahMarket memory s = _market[id];
        uint256 collateralValue = Math.mulDiv(
            uint256(pos.collateral) * 1e10,
            IPeekOracle(p.oracle).peek(p.collateralToken),
            10 ** IERC20Metadata(p.collateralToken).decimals()
        );
        uint256 debtValue = Math.mulDiv(
            _toAssetsUp(pos.borrowShares, s.totalBorrowAssets, s.totalBorrowShares) * 1e10,
            IPeekOracle(p.oracle).peek(p.loanToken),
            10 ** IERC20Metadata(p.loanToken).decimals()
        );
        uint256 weighted =
            collateralValue * collateralIncentiveAprBps[id] + debtValue * borrowIncentiveAprBps[id];
        return Math.mulDiv(weighted, block.timestamp - last, 10_000 * 365 days);
    }
}
