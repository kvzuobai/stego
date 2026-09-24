// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NerveSeasonTest} from "./NerveSeason.t.sol";
import {NerveSeason} from "../src/NerveSeason.sol";

/// STEGO Boost and designer seasons.
contract NerveBoostTest is NerveSeasonTest {
    function _boost(address p, uint256 units) internal {
        uint256 cost = nerve.boostCost(units);
        vm.prank(p);
        nerve.boost{value: cost}(units);
    }

    function test_boostCostsBurnsAndRaisesWeight() public {
        _join(crowd[0], STAKE);
        uint256 p0 = nerve.points(crowd[0]);
        assertEq(nerve.boostCost(10), 100 * 0.000066 ether + 0.00066 ether);
        uint256 deadBefore = transistors.balanceOf(DEAD, 0);

        _boost(crowd[0], 4); // +20%
        assertEq(nerve.boostBps(crowd[0]), 2000);
        assertEq(nerve.points(crowd[0]), p0 * 12 / 10);
        _boost(crowd[0], 6); // +50% total
        assertEq(nerve.points(crowd[0]), p0 * 15 / 10);
        assertEq(transistors.balanceOf(DEAD, 0) - deadBefore, 100, "100 STEGO burned");
        assertEq(nerve.boostBurned(), 100);
        assertEq(nerve.totalPoints(), nerve.points(crowd[0]));

        uint256 c = nerve.boostCost(1);
        vm.prank(crowd[0]);
        vm.expectRevert(NerveSeason.BoostCap.selector);
        nerve.boost{value: c}(1);
    }

    function test_boostRules() public {
        uint256 c = nerve.boostCost(1);
        vm.prank(crowd[0]);
        vm.expectRevert(NerveSeason.NotPlaying.selector);
        nerve.boost{value: c}(1);

        _join(crowd[0], STAKE);
        vm.prank(crowd[0]);
        vm.expectPartialRevert(NerveSeason.WrongValue.selector);
        nerve.boost{value: c - 1}(1);

        vm.warp(block.timestamp + 3 days); // joins closed
        vm.prank(crowd[0]);
        vm.expectRevert(NerveSeason.JoinClosed.selector);
        nerve.boost{value: c}(1);
    }

    function test_boostedPlayerEarnsOneAndAHalfTimes() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        nerve.fund{value: 0.1 ether}();
        _join(crowd[0], STAKE);
        _join(crowd[1], STAKE);
        (uint256 quoted,) = nerve.boostQuote(crowd[0], 10);
        _boost(crowd[0], 10);
        (, uint256 s0p) = nerve.projectedPayout(crowd[0]);
        (, uint256 s1p) = nerve.projectedPayout(crowd[1]);
        assertApproxEqAbs(s0p * 2, s1p * 3, 10, "1.5 : 1");

        vm.warp(block.timestamp + 5 days);
        uint256 b0 = crowd[0].balance;
        uint256 b1 = crowd[1].balance;
        vm.prank(crowd[0]);
        nerve.claim();
        vm.prank(crowd[1]);
        nerve.claim();
        uint256 s0 = crowd[0].balance - b0 - STAKE;
        uint256 s1 = crowd[1].balance - b1 - STAKE;
        assertApproxEqAbs(s0 * 2, s1 * 3, 10);
        // boostQuote = extra share over the unboosted even split
        assertApproxEqAbs(s0 - 0.045 ether, quoted, 1e9);
    }

    function test_boostThenPartialExitKeepsMultiplier() public {
        _join(crowd[0], STAKE);
        _join(crowd[1], STAKE);
        _boost(crowd[0], 10);
        vm.warp(block.timestamp + 1 days);
        uint256 before = nerve.points(crowd[0]);
        vm.prank(crowd[0]);
        nerve.exit(STAKE / 10);
        assertApproxEqAbs(nerve.points(crowd[0]), before * 9 / 10, 1);
    }

    // ------------------------------------------------ designer seasons

    function test_designerSeasonRejectsRuleOutsideEnvelope() public {
        NerveSeason.Params memory p = _params(drawdownId); // a drawdown circuit is not a safe exit rule
        vm.expectPartialRevert(NerveSeason.BadRule.selector);
        new NerveSeason(p);
    }

    function test_designerSeasonPaysCommunityDesigner() public {
        address designer = makeAddr("designer");
        transistors.mint(designer, 0, 1000);
        vm.prank(designer);
        uint256 id = _tapeout("WITHDRAW_GUARD_STRICT.json"); // a different, valid design
        NerveSeason s2 = new NerveSeason(_params(id));

        uint256 cost = s2.ticketCost();
        vm.prank(crowd[0]);
        s2.join{value: STAKE + cost}();
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        s2.fund{value: 0.1 ether}();
        vm.warp(block.timestamp + 5 days);

        uint256 b = designer.balance;
        vm.prank(designer);
        s2.claimDesigner();
        assertEq(designer.balance - b, 0.01 ether, "10% of the pot to the circuit's designer");
    }

    // ------------------------------------------------ solvency with boosts

    function testFuzz_solventWithBoosts(uint8 n, uint64 seed) public {
        n = uint8(bound(n, 1, 20));
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        nerve.fund{value: 0.05 ether}();
        for (uint256 i = 0; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            _join(crowd[i], 0.001 ether + r % (STAKE - 0.001 ether));
            uint256 units = (r >> 64) % 11;
            if (units > 0) _boost(crowd[i], units);
        }
        for (uint256 d = 0; d < 4; d++) {
            vm.warp(block.timestamp + 1 days);
            for (uint256 i = 0; i < n; i++) {
                if (uint256(keccak256(abi.encode(seed, d, i))) % 3 != 0) continue;
                uint256 m = nerve.maxExit(crowd[i]);
                if (m == 0) continue;
                vm.prank(crowd[i]);
                nerve.exit(m);
            }
        }
        vm.warp(block.timestamp + 5 days);
        for (uint256 i = 0; i < n; i++) {
            if (nerve.principal(crowd[i]) == 0) continue;
            vm.prank(crowd[i]);
            nerve.claim();
        }
        vm.prank(author);
        nerve.claimDesigner();
        assertLt(address(nerve).balance, 1000, "everything paid out, only dust left");
    }
}
