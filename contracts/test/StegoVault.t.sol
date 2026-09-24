// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Base} from "./Base.t.sol";
import {StegoVault} from "../src/StegoVault.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";

contract StegoVaultTest is Base {
    StegoVault vault;
    MockStrategy strategy;

    uint256 constant ENTRY_BPS = 10; // 0.10%
    uint256 constant THROTTLE_BPS = 100; // 1.00%

    function setUp() public override {
        super.setUp();
        vault = new StegoVault(IERC20(address(wokb)), "Stego Vault WOKB", "sgWOKB", registry, owner, ENTRY_BPS, THROTTLE_BPS, 1_000_000 ether);
        strategy = new MockStrategy(IERC20(address(wokb)), address(vault));
        vm.prank(owner);
        vault.setStrategy(strategy);

        for (uint256 i = 0; i < 2; i++) {
            address u = i == 0 ? alice : bob;
            wokb.mint(u, 10_000 ether);
            vm.prank(u);
            wokb.approve(address(vault), type(uint256).max);
        }
    }

    function _deposit(address who, uint256 amt) internal returns (uint256) {
        vm.prank(who);
        return vault.deposit(amt, who);
    }

    // ------------------------------------------------ fail-safe defaults

    function test_depositsFailClosedWithoutDrawdownPolicy() public {
        assertEq(vault.maxDeposit(alice), 0);
        vm.prank(alice);
        vm.expectRevert(); // ERC4626ExceededMaxDeposit
        vault.deposit(1 ether, alice);
    }

    function test_withdrawalsFailOpenWithoutWithdrawPolicy() public {
        _activateAll();
        _deposit(alice, 1000 ether);
        processor.tamper(withdrawId, hex""); // pull the WITHDRAW circuit out of service
        registry.reportTamper(withdrawId);

        uint256 all = vault.maxWithdraw(alice);
        assertApproxEqAbs(all, vault.totalAssets(), 1);
        vm.prank(alice);
        vault.withdraw(all, alice, alice); // full exit, no throttle, no halt
    }

    // ------------------------------------------------ entry fee -> policy authors

    function test_entryFeeStreamsToPolicyAuthors() public {
        _activateAll();
        _deposit(alice, 1000 ether);
        uint256 fee = uint256(1000 ether) * ENTRY_BPS / (10_000 + ENTRY_BPS) + 1;
        assertApproxEqAbs(wokb.balanceOf(address(registry)), fee, 1);
        assertApproxEqAbs(vault.totalAssets(), 1000 ether - fee, 1);
    }

    // ------------------------------------------------ WITHDRAW circuit

    function test_withdrawAllowThrottleHalt() public {
        _activateAll();
        _deposit(alice, 1000 ether);
        vm.warp(block.timestamp + 1 days); // new epoch: start assets ~999
        uint256 tvl = vault.totalAssets();

        // 5% -> ALLOW, no fee
        uint256 sharesBefore = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 burned = vault.withdraw(tvl * 5 / 100, alice, alice);
        assertApproxEqAbs(burned, vault.convertToShares(tvl * 5 / 100), 2);

        // +10% (15% total) -> THROTTLE, 1% fee stays in vault
        (uint8 v,,) = vault.withdrawVerdict(tvl * 10 / 100);
        assertEq(v, 1);
        uint256 assetsBefore = vault.totalAssets();
        vm.prank(alice);
        vault.withdraw(tvl * 10 / 100, alice, alice);
        uint256 kept = vault.totalAssets() - (assetsBefore - tvl * 10 / 100);
        assertApproxEqAbs(kept, 0, 1); // fee is not paid out...
        assertLt(vault.balanceOf(alice), sharesBefore - burned - vault.convertToShares(tvl * 10 / 100) + 2); // ...it is extra shares burned

        // +15% (30% total) -> HALT
        (v,,) = vault.withdrawVerdict(tvl * 15 / 100);
        assertEq(v, 2);
        uint256 max = vault.maxWithdraw(alice);
        assertLt(max, tvl * 15 / 100);
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(tvl * 15 / 100, alice, alice);

        // exactly the policy max still works
        vm.prank(alice);
        vault.withdraw(max, alice, alice);

        // next epoch resets the budget
        vm.warp(block.timestamp + 1 days);
        (v,,) = vault.withdrawVerdict(vault.totalAssets() / 20);
        assertEq(v, 0);
    }

    function test_redeemPathAppliesSamePolicy() public {
        _activateAll();
        _deposit(alice, 1000 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 shares = vault.balanceOf(alice);
        uint256 maxR = vault.maxRedeem(alice);
        assertLt(maxR, shares);
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(shares, alice, alice);
        vm.prank(alice);
        uint256 out = vault.redeem(maxR, alice, alice);
        assertGt(out, 0);
    }

    // ------------------------------------------------ DRAWDOWN circuit

    function test_drawdownHaltsDepositsAndForcesDeRisk() public {
        _activateAll();
        _deposit(alice, 1000 ether);
        vm.startPrank(owner);
        vault.rebalance(100 ether);
        vault.rebalance(200 ether);
        vm.stopPrank();

        // 5% loss -> THROTTLE: deposits ok, only de-risking rebalances
        strategy.loss(50 ether, address(0xdead));
        (uint8 v,,) = vault.drawdownVerdict();
        assertEq(v, 1);
        _deposit(bob, 10 ether);
        vm.prank(owner);
        vm.expectRevert(StegoVault.DeRiskOnly.selector);
        vault.rebalance(200 ether);
        vm.prank(owner);
        vault.rebalance(100 ether);

        // total drawdown > 10% -> HALT: deposits closed, withdrawals still open
        strategy.loss(60 ether, address(0xdead));
        (v,,) = vault.drawdownVerdict();
        assertEq(v, 2);
        assertEq(vault.maxDeposit(bob), 0);
        vm.prank(bob);
        vm.expectRevert();
        vault.deposit(1 ether, bob);
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(bobShares, bob, bob);
    }

    // ------------------------------------------------ ALLOCATION circuit

    function test_allocationBand() public {
        _activateAll();
        _deposit(alice, 1000 ether);

        vm.startPrank(owner);
        vm.expectRevert(); // 30% in one step > ~10%
        vault.rebalance(300 ether);

        for (uint256 i = 1; i <= 8; i++) vault.rebalance(i * 99 ether); // ~9.9% steps to ~79%
        vm.expectRevert(); // > 80% deployed
        vault.rebalance(850 ether);

        vault.emergencyUnwind(); // de-risking always allowed
        vm.stopPrank();
        assertEq(strategy.totalAssets(), 0);
    }

    function test_withdrawPullsFromStrategy() public {
        _activateAll();
        _deposit(alice, 1000 ether);
        vm.startPrank(owner);
        vault.rebalance(99 ether);
        vault.rebalance(198 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        uint256 max = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(max, alice, alice);
        assertEq(vault.totalAssets(), wokb.balanceOf(address(vault)) + strategy.totalAssets());
    }

    /// Regression (found by fuzzing): maxWithdraw must be fee-aware when the exit lands in THROTTLE.
    function test_maxWithdrawIsWithdrawableInThrottleBand() public {
        _activateAll();
        _deposit(alice, 1063 ether);
        _deposit(bob, 4999 ether); // alice owns ~17.5% of TVL -> her full exit is THROTTLE
        vm.warp(block.timestamp + 1 days);
        uint256 max = vault.maxWithdraw(alice);
        (uint8 v,,) = vault.withdrawVerdict(max);
        assertEq(v, 1);
        vm.prank(alice);
        vault.withdraw(max, alice, alice);
        assertLe(vault.balanceOf(alice), 1);
    }

    /// Regression (found by fuzzing): holder of just over 25% of TVL. Their full exit is HALT, the
    /// policy cap itself is THROTTLE, so maxWithdraw must leave room for the 1% fee.
    function test_maxWithdrawAtPolicyCapBoundary() public {
        _activateAll();
        _deposit(alice, 1679417497684112572404);
        _deposit(bob, 4999000000000000012626);
        vm.warp(block.timestamp + 1 days);
        uint256 max = vault.maxWithdraw(alice);
        assertLe(vault.previewWithdraw(max), vault.balanceOf(alice));
        vm.prank(alice);
        vault.withdraw(max, alice, alice);
    }

    /// Regression (found by UI testing on a mainnet fork): on the vault's first day the epoch opened
    /// with 0 assets, which used to disable the exit limit for that whole day.
    function test_exitLimitAppliesOnFirstDay() public {
        _activateAll();
        _deposit(alice, 1 ether); // same day the epoch opened empty
        (uint8 v,,) = vault.withdrawVerdict(0.8 ether);
        assertEq(v, 2, "80% exit must HALT even on day one");
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(0.8 ether, alice, alice);
        uint256 max = vault.maxWithdraw(alice);
        assertLt(max, 0.26 ether);
        vm.prank(alice);
        vault.withdraw(max, alice, alice);
    }

    // ------------------------------------------------ invariants-by-fuzz

    function testFuzz_sharePriceNeverDropsFromUserFlows(uint96 d1, uint96 d2, uint16 wPct) public {
        _activateAll();
        d1 = uint96(bound(d1, 1 ether, 5000 ether));
        d2 = uint96(bound(d2, 1 ether, 5000 ether));
        _deposit(alice, d1);
        uint256 p0 = vault.sharePrice();
        _deposit(bob, d2);
        vm.warp(block.timestamp + 1 days);
        uint256 w = vault.maxWithdraw(alice) * bound(wPct, 0, 10_000) / 10_000;
        assertLe(vault.previewWithdraw(vault.maxWithdraw(alice)), vault.balanceOf(alice), "maxWithdraw must be withdrawable");
        vm.prank(alice);
        vault.withdraw(w, alice, alice);
        assertGe(vault.sharePrice() + 1, p0);
    }
}
