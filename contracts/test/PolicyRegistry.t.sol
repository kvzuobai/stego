// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {PolicyRegistry} from "../src/PolicyRegistry.sol";

contract PolicyRegistryTest is Base {
    // ------------------------------------------------ shipped circuits stay inside their envelopes

    function testFuzz_withdrawCircuitInsideEnvelope(uint8 a, uint8 b) public view {
        assertTrue(withdrawSpec.allowed(a, b, _eval(withdrawId, a, b)));
    }

    function testFuzz_drawdownCircuitInsideEnvelope(uint8 a, uint8 b) public view {
        assertTrue(drawdownSpec.allowed(a, b, _eval(drawdownId, a, b)));
    }

    function testFuzz_allocationCircuitInsideEnvelope(uint8 a, uint8 b) public view {
        assertTrue(allocationSpec.allowed(a, b, _eval(allocationId, a, b)));
    }

    function testFuzz_withdrawCircuitMonotone(uint8 a, uint8 b, uint8 da, uint8 db) public view {
        uint8 a2 = uint8(bound(uint256(a) + da, a, 255));
        uint8 b2 = uint8(bound(uint256(b) + db, b, 255));
        assertGe(_eval(withdrawId, a2, b2), _eval(withdrawId, a, b));
    }

    // ------------------------------------------------ lifecycle & curation

    function test_proposeBondsApproveTimelockActivate() public {
        vm.prank(author);
        registry.propose(WITHDRAW, withdrawId);
        assertEq(transistors.balanceOf(address(registry), 0), BOND);

        vm.warp(block.timestamp + TIMELOCK);
        vm.expectRevert(PolicyRegistry.NotApproved.selector);
        registry.activate(WITHDRAW);

        vm.prank(alice);
        vm.expectRevert(); // only the curator approves
        registry.approve(withdrawId);

        vm.prank(owner);
        registry.approve(withdrawId);
        registry.activate(WITHDRAW);
        assertEq(registry.activeCircuit(WITHDRAW), withdrawId);

        (uint8 v, bool ok) = registry.verdict(WITHDRAW, 30, 30);
        assertTrue(ok);
        assertEq(v, 1);
    }

    function test_timelockStillAppliesAfterApproval() public {
        vm.prank(author);
        registry.propose(WITHDRAW, withdrawId);
        vm.prank(owner);
        registry.approve(withdrawId);
        vm.expectRevert(PolicyRegistry.TooEarly.selector);
        registry.activate(WITHDRAW);
    }

    function test_curatorCanRejectPendingDesign() public {
        vm.prank(author);
        registry.propose(WITHDRAW, withdrawId);
        vm.prank(owner);
        registry.cancel(WITHDRAW);
        vm.prank(author);
        registry.withdrawBond(withdrawId);
        assertEq(transistors.balanceOf(address(registry), 0), 0);
    }

    function test_proposeRequiresCircuitOwner() public {
        vm.prank(alice);
        vm.expectRevert(PolicyRegistry.NotCircuitOwner.selector);
        registry.propose(WITHDRAW, withdrawId);
    }

    function test_proposeRejectsCircuitThatFailsSlotProbes() public {
        vm.prank(author);
        vm.expectPartialRevert(PolicyRegistry.ProbeFailed.selector);
        registry.propose(ALLOCATION, withdrawId); // right pinout, wrong behaviour for this slot
    }

    function test_proposeRejectsUnknownSlot() public {
        vm.prank(author);
        vm.expectRevert(PolicyRegistry.UnknownSlot.selector);
        registry.propose("NOPE", withdrawId);
    }

    function test_slotsAreAppendOnly() public {
        vm.prank(owner);
        vm.expectRevert(PolicyRegistry.SlotExists.selector);
        registry.addSlot(WITHDRAW, drawdownSpec);
    }

    /// Different designs can compete inside one envelope: a stricter author replaces V1.
    function test_differentDesignReplacesActiveAndReleasesBond() public {
        _activateAll();
        vm.prank(author);
        uint256 strict = _tapeout("WITHDRAW_GUARD_STRICT.json");
        _goLive(WITHDRAW, strict);

        assertEq(registry.activeCircuit(WITHDRAW), strict);
        (uint8 v,) = registry.verdict(WITHDRAW, 20, 0); // V1 would ALLOW ~7.8%, STRICT throttles it
        assertEq(v, 1);

        uint256 before = transistors.balanceOf(author, 0);
        vm.prank(author);
        registry.withdrawBond(withdrawId);
        assertEq(transistors.balanceOf(author, 0), before + BOND);
    }

    // ------------------------------------------------ counterexamples

    function test_pointChallengeSlashesBuggyCircuit() public {
        vm.prank(author);
        uint256 buggy = _tapeout("fixtures/WITHDRAW_GUARD_BUGGY.json");
        _goLive(WITHDRAW, buggy); // passes the probes and even curator review

        vm.prank(challenger);
        vm.expectRevert(PolicyRegistry.NotACounterexample.selector);
        registry.challenge(buggy, 10, 10);

        vm.prank(challenger);
        registry.challenge(buggy, 200, 7); // ALLOWs an ~81% exit

        assertEq(registry.activeCircuit(WITHDRAW), 0);
        assertEq(transistors.balanceOf(challenger, 0), BOND);
        (,, PolicyRegistry.Status st,,,,) = registry.candidates(buggy);
        assertEq(uint8(st), uint8(PolicyRegistry.Status.Slashed));

        vm.prank(author);
        vm.expectRevert(PolicyRegistry.NotRetired.selector);
        registry.withdrawBond(buggy);
    }

    function test_monotoneChallengeCatchesWhatPointChecksMiss() public {
        vm.prank(author);
        uint256 nm = _tapeout("fixtures/WITHDRAW_GUARD_NONMONO.json");
        _goLive(WITHDRAW, nm);

        // every single point is inside the envelope...
        for (uint8 s = 0; s < 100; s++) {
            vm.expectRevert(PolicyRegistry.NotACounterexample.selector);
            registry.challenge(nm, s, 0);
        }
        // ...a riskier pair must be properly ordered...
        vm.expectRevert(PolicyRegistry.NotAnOrderedPair.selector);
        registry.challengeMonotone(nm, 51, 0, 45, 0);
        // ...but a 51-unit exit gets THROTTLE while a 45-unit exit gets HALT
        vm.prank(challenger);
        registry.challengeMonotone(nm, 45, 0, 51, 0);
        assertEq(registry.activeCircuit(WITHDRAW), 0);
        assertEq(transistors.balanceOf(challenger, 0), BOND);
    }

    function test_challengeCannotSlashCompliantCircuit(uint8 a, uint8 b) public {
        _activateAll();
        vm.expectRevert(PolicyRegistry.NotACounterexample.selector);
        registry.challenge(drawdownId, a, b);
    }

    function test_monotoneChallengeCannotSlashCompliantCircuit(uint8 a1, uint8 b1, uint8 da, uint8 db) public {
        _activateAll();
        uint8 a2 = uint8(bound(uint256(a1) + da, a1, 255));
        uint8 b2 = uint8(bound(uint256(b1) + db, b1, 255));
        vm.assume(a2 != a1 || b2 != b1);
        vm.expectRevert(PolicyRegistry.NotACounterexample.selector);
        registry.challengeMonotone(withdrawId, a1, b1, a2, b2);
    }

    // ------------------------------------------------ TapeOut upgrade protection

    function test_processorUpgradeFreezesSlashingAndVerdicts() public {
        vm.prank(author);
        uint256 buggy = _tapeout("fixtures/WITHDRAW_GUARD_BUGGY.json");
        _goLive(WITHDRAW, buggy);

        beacon.upgrade(address(0x2222)); // TapeOut ships new processor code
        assertTrue(registry.processorUpgraded());

        // nobody can be slashed for behaviour that may be TapeOut's change, not the author's
        vm.prank(challenger);
        vm.expectRevert(PolicyRegistry.ProcessorUpgraded.selector);
        registry.challenge(buggy, 200, 7);

        // vaults stop trusting verdicts: exits fail open, deposits fail closed
        (, bool ok) = registry.verdict(WITHDRAW, 1, 1);
        assertFalse(ok);

        // after review the curator re-pins and everything resumes
        vm.prank(owner);
        registry.repin();
        (, ok) = registry.verdict(WITHDRAW, 1, 1);
        assertTrue(ok);
        vm.prank(challenger);
        registry.challenge(buggy, 200, 7);
    }

    function test_tamperPullsCircuitWithoutSlashing() public {
        _activateAll();
        vm.expectRevert(PolicyRegistry.NotTampered.selector);
        registry.reportTamper(withdrawId);

        processor.tamper(withdrawId, processor.netlist(drawdownId));
        registry.reportTamper(withdrawId);
        assertEq(registry.activeCircuit(WITHDRAW), 0);

        vm.prank(author);
        registry.withdrawBond(withdrawId);
    }

    // ------------------------------------------------ rewards

    function test_rewardsSplitAcrossLiveSlots() public {
        wokb.mint(address(this), 90 ether);
        wokb.approve(address(registry), type(uint256).max);

        registry.notifyReward(30 ether); // nobody live yet -> parked
        assertEq(registry.unallocatedRewards(), 30 ether);

        _activateAll();
        registry.notifyReward(60 ether); // 90 across 3 slots
        assertEq(registry.notifiedBy(address(this)), 90 ether, "cumulative commitment is auditable on-chain");
        (,,,,,, uint256 r) = registry.candidates(withdrawId);
        assertEq(r, 30 ether);

        vm.prank(author);
        registry.claimRewards(withdrawId);
        assertEq(wokb.balanceOf(author), 30 ether);
    }

    function test_slashedRewardsGoToChallenger() public {
        vm.prank(author);
        uint256 buggy = _tapeout("fixtures/WITHDRAW_GUARD_BUGGY.json");
        _goLive(WITHDRAW, buggy);

        wokb.mint(address(this), 10 ether);
        wokb.approve(address(registry), type(uint256).max);
        registry.notifyReward(10 ether);

        vm.prank(challenger);
        registry.challenge(buggy, 200, 7);
        assertEq(wokb.balanceOf(challenger), 10 ether);
    }
}
