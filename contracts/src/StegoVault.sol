// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PolicyRegistry} from "./PolicyRegistry.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/// @title StegoVault
/// @notice ERC-4626 vault whose risk rules are TapeOut circuits. Before every state change the vault
/// quantises its own accounting into two bytes, asks the slot's active circuit for a verdict via
/// processor.eval(), and obeys it:
///   WITHDRAW   (A = epoch outflow, B = request)        ALLOW / THROTTLE (fee stays with LPs) / HALT
///   DRAWDOWN   (A = price vs HWM, B = epoch-start vs HWM) ALLOW / THROTTLE (de-risk only) / HALT (no deposits)
///   ALLOCATION (A = deployed after, B = before)         ALLOW / HALT
/// No oracle: every input comes from the vault's own books.
/// Failure modes: exits fail open (missing or broken WITHDRAW policy never traps users);
/// deposits and strategy moves fail closed.
contract StegoVault is ERC4626, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    bytes32 public constant WITHDRAW = "WITHDRAW";
    bytes32 public constant DRAWDOWN = "DRAWDOWN";
    bytes32 public constant ALLOCATION = "ALLOCATION";

    uint8 public constant ALLOW = 0;
    uint8 public constant THROTTLE = 1;
    uint8 public constant HALT = 2;

    uint256 public constant EPOCH = 1 days;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_ENTRY_FEE_BPS = 50;
    uint256 public constant MAX_THROTTLE_FEE_BPS = 200;

    PolicyRegistry public immutable registry;
    uint256 public immutable entryFeeBps; // streamed to policy authors via the registry
    uint256 public immutable throttleFeeBps; // kept in the vault for remaining LPs

    IStrategy public strategy;
    address public strategist;
    uint256 public depositCap; // max totalAssets; experimental, unaudited

    struct EpochState {
        uint64 id;
        uint256 startAssets;
        uint256 outflow;
        uint256 startPrice;
        uint256 hwm;
    }

    EpochState internal _epoch;

    event Rebalanced(uint256 before, uint256 target, uint8 allocationVerdict, uint8 drawdownVerdict);
    event Throttled(address indexed owner, uint256 assets, uint256 fee);
    event StrategyChanged(address strategy);
    event StrategistChanged(address strategist);
    event DepositCapChanged(uint256 cap);
    event EmergencyUnwind(uint256 amount);

    error PolicyHalt(bytes32 slot, uint8 a, uint8 b);
    error DepositsHalted(uint8 a, uint8 b);
    error OnlyStrategist();
    error NoStrategy();
    error StrategyNotEmpty();
    error BadStrategy();
    error FeeTooHigh();
    error DeRiskOnly();

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        PolicyRegistry registry_,
        address owner_,
        uint256 entryFeeBps_,
        uint256 throttleFeeBps_,
        uint256 depositCap_
    ) ERC4626(asset_) ERC20(name_, symbol_) Ownable(owner_) {
        if (entryFeeBps_ > MAX_ENTRY_FEE_BPS || throttleFeeBps_ > MAX_THROTTLE_FEE_BPS) revert FeeTooHigh();
        registry = registry_;
        entryFeeBps = entryFeeBps_;
        throttleFeeBps = throttleFeeBps_;
        depositCap = depositCap_;
        strategist = owner_;
        asset_.forceApprove(address(registry_), type(uint256).max);
    }

    // ================================================================ accounting

    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        return address(strategy) == address(0) ? idle : idle + strategy.totalAssets();
    }

    function sharePrice() public view returns (uint256) {
        return convertToAssets(10 ** decimals());
    }

    function epochState() public view returns (EpochState memory e) {
        e = _epoch;
        uint64 id = uint64(block.timestamp / EPOCH);
        uint256 price = sharePrice();
        if (e.id != id) {
            e.id = id;
            e.startAssets = totalAssets();
            e.outflow = 0;
            e.startPrice = price;
        }
        if (price > e.hwm) e.hwm = price;
    }

    function _poke() internal {
        _epoch = epochState();
    }

    // ================================================================ policy inputs (public for dashboards)

    function withdrawInputs(uint256 assets) public view returns (uint8 a, uint8 b) {
        EpochState memory e = epochState();
        uint256 base = _exitBase(e);
        if (base == 0) return (0, 0);
        a = _q256(e.outflow, base, Math.Rounding.Floor);
        b = _q256(assets, base, Math.Rounding.Ceil);
    }

    function drawdownInputs() public view returns (uint8 a, uint8 b) {
        EpochState memory e = epochState();
        if (e.hwm == 0) return (255, 255);
        a = _q255(sharePrice(), e.hwm);
        b = _q255(e.startPrice, e.hwm);
    }

    function allocationInputs(uint256 targetDeployed) public view returns (uint8 a, uint8 b) {
        uint256 total = totalAssets();
        if (total == 0) return (0, 0);
        uint256 before = address(strategy) == address(0) ? 0 : strategy.totalAssets();
        // Same rounding on both sides so the step |A - B| is not inflated; Ceil keeps the level check conservative.
        a = uint8(Math.min(255, targetDeployed.mulDiv(255, total, Math.Rounding.Ceil)));
        b = uint8(Math.min(255, before.mulDiv(255, total, Math.Rounding.Ceil)));
    }

    function withdrawVerdict(uint256 assets) public view returns (uint8 v, uint8 a, uint8 b) {
        (a, b) = withdrawInputs(assets);
        if (_exitBase(epochState()) == 0) return (ALLOW, a, b);
        bool ok;
        (v, ok) = registry.verdict(WITHDRAW, a, b);
        if (!ok) v = ALLOW; // exits fail open
    }

    function drawdownVerdict() public view returns (uint8 v, uint8 a, uint8 b) {
        (a, b) = drawdownInputs();
        bool ok;
        (v, ok) = registry.verdict(DRAWDOWN, a, b);
        if (!ok) v = HALT; // risk-on fails closed
    }

    function allocationVerdict(uint256 targetDeployed) public view returns (uint8 v, uint8 a, uint8 b) {
        (a, b) = allocationInputs(targetDeployed);
        bool ok;
        (v, ok) = registry.verdict(ALLOCATION, a, b);
        if (!ok) v = HALT;
    }

    // ================================================================ ERC-4626 limits & previews

    function maxDeposit(address) public view override returns (uint256) {
        (uint8 v,,) = drawdownVerdict();
        if (v >= HALT) return 0;
        uint256 total = totalAssets();
        return total >= depositCap ? 0 : depositCap - total;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 assets = maxDeposit(receiver);
        return assets == 0 ? 0 : previewDeposit(assets);
    }

    /// @dev Fee-aware: the largest `assets` the owner can pass to withdraw() right now. Capped by the
    /// policy (no HALT), then, if that amount is THROTTLEd, reduced so assets + fee fits the owner's shares.
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 shares = balanceOf(owner);
        uint256 gross = _convertToAssets(shares, Math.Rounding.Floor);
        uint256 x = Math.min(gross, _policyMaxExit());
        (uint8 v,,) = withdrawVerdict(x);
        if (v == THROTTLE) x = Math.min(x, gross - _feeOnTotal(gross, throttleFeeBps));
        // absorb 1-2 wei of rounding in the share conversion
        for (uint256 i = 0; i < 3 && x != 0 && previewWithdraw(x) > shares; i++) x--;
        return x;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 cap = _policyMaxExit();
        uint256 bal = balanceOf(owner);
        if (cap == type(uint256).max) return bal;
        return Math.min(bal, _convertToShares(cap, Math.Rounding.Floor));
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return super.previewDeposit(assets - _feeOnTotal(assets, entryFeeBps));
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 assets = super.previewMint(shares);
        return assets + _feeOnRaw(assets, entryFeeBps);
    }

    /// @dev Throttle fee is added on top: the owner burns shares worth assets + fee, fee stays in the vault.
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        (uint8 v,,) = withdrawVerdict(assets);
        uint256 fee = v == THROTTLE ? _feeOnRaw(assets, throttleFeeBps) : 0;
        return super.previewWithdraw(assets + fee);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 gross = super.previewRedeem(shares);
        (uint8 v,,) = withdrawVerdict(gross);
        return v == THROTTLE ? gross - _feeOnTotal(gross, throttleFeeBps) : gross;
    }

    // ================================================================ ERC-4626 entry points

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        _poke();
        _requireDepositsOpen();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        _poke();
        _requireDepositsOpen();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256) {
        _poke();
        _requireExitAllowed(assets);
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        _poke();
        _requireExitAllowed(super.previewRedeem(shares));
        return super.redeem(shares, receiver, owner);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        uint256 fee = _feeOnTotal(assets, entryFeeBps);
        if (fee != 0) registry.notifyReward(fee);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        _ensureIdle(assets);
        _epoch.outflow += assets;
        uint256 gross = _convertToAssets(shares, Math.Rounding.Floor);
        if (gross > assets) emit Throttled(owner, assets, gross - assets);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ================================================================ strategy

    /// @notice Move the strategy's allocation to `targetDeployed`. Must pass the ALLOCATION circuit;
    /// while DRAWDOWN says THROTTLE or HALT, only de-risking moves are allowed.
    function rebalance(uint256 targetDeployed) external nonReentrant {
        if (msg.sender != strategist) revert OnlyStrategist();
        if (address(strategy) == address(0)) revert NoStrategy();
        _poke();

        uint256 before = strategy.totalAssets();
        (uint8 av, uint8 a, uint8 b) = allocationVerdict(targetDeployed);
        if (av != ALLOW) revert PolicyHalt(ALLOCATION, a, b);
        (uint8 dv,,) = drawdownVerdict();
        if (dv != ALLOW && targetDeployed > before) revert DeRiskOnly();

        if (targetDeployed > before) {
            uint256 amt = targetDeployed - before;
            IERC20(asset()).forceApprove(address(strategy), amt);
            strategy.deposit(amt);
        } else if (targetDeployed < before) {
            strategy.withdraw(before - targetDeployed);
        }
        emit Rebalanced(before, targetDeployed, av, dv);
    }

    /// @notice De-risking is always allowed: pull everything back from the strategy.
    function emergencyUnwind() external nonReentrant {
        if (msg.sender != owner() && msg.sender != strategist) revert OnlyStrategist();
        if (address(strategy) == address(0)) revert NoStrategy();
        uint256 amt = strategy.totalAssets();
        if (amt != 0) strategy.withdraw(amt);
        emit EmergencyUnwind(amt);
    }

    function setStrategy(IStrategy s) external onlyOwner {
        if (address(strategy) != address(0) && strategy.totalAssets() != 0) revert StrategyNotEmpty();
        if (address(s) != address(0) && (s.asset() != asset() || s.vault() != address(this))) revert BadStrategy();
        strategy = s;
        emit StrategyChanged(address(s));
    }

    function setStrategist(address s) external onlyOwner {
        strategist = s;
        emit StrategistChanged(s);
    }

    function setDepositCap(uint256 cap) external onlyOwner {
        depositCap = cap;
        emit DepositCapChanged(cap);
    }

    // ================================================================ internal

    function _requireDepositsOpen() internal view {
        (uint8 v, uint8 a, uint8 b) = drawdownVerdict();
        if (v >= HALT) revert DepositsHalted(a, b);
    }

    function _requireExitAllowed(uint256 assets) internal view {
        (uint8 v, uint8 a, uint8 b) = withdrawVerdict(assets);
        if (v >= HALT) revert PolicyHalt(WITHDRAW, a, b);
    }

    /// @dev Largest exit (in assets) the WITHDRAW circuit allows this epoch. Binary search over the
    /// request bucket, assuming the verdict is monotone in B (true for every spec shipped here).
    function _policyMaxExit() internal view returns (uint256) {
        EpochState memory e = epochState();
        uint256 base = _exitBase(e);
        if (base == 0) return type(uint256).max;
        uint8 a = _q256(e.outflow, base, Math.Rounding.Floor);
        (uint8 v0, bool ok) = registry.verdict(WITHDRAW, a, 0);
        if (!ok) return type(uint256).max;
        if (v0 >= HALT) return 0;
        uint256 lo = 0;
        uint256 hi = 255;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            (uint8 v,) = registry.verdict(WITHDRAW, a, uint8(mid));
            if (v < HALT) lo = mid;
            else hi = mid - 1;
        }
        return lo == 255 ? type(uint256).max : lo.mulDiv(base, 256, Math.Rounding.Floor);
    }

    /// @dev The daily exit allowance is measured against the larger of the epoch's opening assets and
    /// the current assets. Without this, a vault whose epoch opened empty (e.g. its first day) would
    /// have no exit limit at all that day.
    function _exitBase(EpochState memory e) internal view returns (uint256) {
        uint256 current = totalAssets();
        return e.startAssets > current ? e.startAssets : current;
    }

    function _ensureIdle(uint256 assets) internal {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets && address(strategy) != address(0)) strategy.withdraw(assets - idle);
    }

    function _q256(uint256 x, uint256 unit, Math.Rounding r) internal pure returns (uint8) {
        return uint8(Math.min(255, x.mulDiv(256, unit, r)));
    }

    function _q255(uint256 x, uint256 hwm) internal pure returns (uint8) {
        return uint8(Math.min(255, x.mulDiv(255, hwm, Math.Rounding.Floor)));
    }

    function _feeOnRaw(uint256 assets, uint256 bps) internal pure returns (uint256) {
        return assets.mulDiv(bps, BPS, Math.Rounding.Ceil);
    }

    function _feeOnTotal(uint256 assets, uint256 bps) internal pure returns (uint256) {
        return assets.mulDiv(bps, bps + BPS, Math.Rounding.Ceil);
    }
}
