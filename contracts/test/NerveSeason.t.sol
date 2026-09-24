// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {Base} from "./Base.t.sol";
import {NerveSeason, IProtocolFee} from "../src/NerveSeason.sol";
import {ITapeOutProcessor} from "../src/interfaces/ITapeOutProcessor.sol";
import {MockFactory} from "./mocks/MockTapeOut.sol";

contract NerveSeasonTest is Base {
    NerveSeason nerve;
    MockFactory factory;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant STAKE = 0.05 ether;
    address[] crowd;

    function setUp() public override {
        super.setUp();
        factory = new MockFactory();
        nerve = new NerveSeason(_params(withdrawId));
        for (uint256 i = 0; i < 20; i++) {
            address p = makeAddr(string.concat("player", vm.toString(i)));
            vm.deal(p, 1 ether);
            crowd.push(p);
        }
    }

    function _params(uint256 id) internal view returns (NerveSeason.Params memory) {
        return NerveSeason.Params({
            name: "Stego Nerve - Test Season",
            processor: ITapeOutProcessor(address(processor)),
            factory: IProtocolFee(address(factory)),
            beacon: IBeacon(address(beacon)),
            circuitId: id,
            ticketTransistors: 10,
            joinDeadline: uint64(block.timestamp + 3 days),
            seasonEnd: uint64(block.timestamp + 5 days),
            minDeposit: 0.001 ether,
            maxPerWallet: STAKE,
            seasonCap: 2 ether,
            baseFeeBps: 200,
            throttleFeeBps: 1000,
            designerCutBps: 1000,
            envelope: withdrawSpec
        });
    }

    function _join(address p, uint256 stake) internal {
        uint256 cost = nerve.hasTicket(p) ? 0 : nerve.ticketCost();
        vm.prank(p);
        nerve.join{value: stake + cost}();
    }

    function _fillCrowd() internal {
        for (uint256 i = 0; i < crowd.length; i++) _join(crowd[i], STAKE);
        vm.warp(block.timestamp + 1 days); // new day: exit budget based on the full 1 OKB pool
    }

    // ------------------------------------------------ joining

    function test_joinMintsAndBurnsTicketInOneTx() public {
        uint256 cost = nerve.ticketCost();
        assertEq(cost, 10 * 0.000066 ether + 0.00066 ether);
        assertEq(nerve.name(), "Stego Nerve - Test Season");
        _join(alice = crowd[0], STAKE);
        assertEq(nerve.principal(alice), STAKE);
        assertEq(transistors.balanceOf(DEAD, 0), 10, "ticket burned");
        assertEq(transistors.balanceOf(address(nerve), 0), 0);
        assertEq(nerve.players(), 1);
        assertEq(nerve.ticketsBurned(), 10);
        assertEq(transistors.proceeds(), 10 * 0.000066 ether, "ticket price goes to the STEGO creator");

        // topping up does not need a second ticket
        vm.prank(alice);
        vm.expectRevert(NerveSeason.WalletCap.selector);
        nerve.join{value: 1 wei}();
    }

    function test_joinLimits() public {
        vm.deal(bob, 10 ether);
        uint256 cost = nerve.ticketCost();
        vm.startPrank(bob);
        vm.expectRevert(NerveSeason.TooSmall.selector);
        nerve.join{value: cost}();
        vm.expectRevert(NerveSeason.TooSmall.selector);
        nerve.join{value: cost + 0.0005 ether}();
        vm.expectRevert(NerveSeason.WalletCap.selector);
        nerve.join{value: cost + STAKE + 1}();
        vm.stopPrank();

        vm.warp(block.timestamp + 3 days);
        vm.prank(bob);
        vm.expectRevert(NerveSeason.JoinClosed.selector);
        nerve.join{value: cost + 0.01 ether}();
    }

    // ------------------------------------------------ the circuit prices every exit

    function test_exitAllowThrottleHalt() public {
        _fillCrowd(); // 1 OKB pool

        // 1 player leaves 0.03 (3% of pool) -> ALLOW, 2% nerve tax
        (uint8 v, uint256 fee,,) = nerve.exitQuote(0.03 ether);
        assertEq(v, 0);
        assertEq(fee, 0.0006 ether);
        uint256 before = crowd[0].balance;
        vm.prank(crowd[0]);
        nerve.exit(0.03 ether);
        assertEq(crowd[0].balance - before, 0.0294 ether);
        assertEq(nerve.pot(), 0.0006 ether);

        // more leave: cumulative ~13% -> THROTTLE, 10%
        for (uint256 i = 1; i <= 2; i++) {
            vm.prank(crowd[i]);
            nerve.exit(STAKE);
        }
        (v, fee,,) = nerve.exitQuote(0.02 ether);
        assertEq(v, 1);
        assertEq(fee, 0.002 ether);

        // push the day's outflow past ~25% -> HALT
        for (uint256 i = 3; i <= 4; i++) {
            vm.prank(crowd[i]);
            nerve.exit(STAKE);
        }
        (v,,,) = nerve.exitQuote(STAKE);
        assertEq(v, 2);
        vm.prank(crowd[5]);
        vm.expectPartialRevert(NerveSeason.ExitHalted.selector);
        nerve.exit(STAKE);

        // maxExit is exactly withdrawable
        uint256 m = nerve.maxExit(crowd[5]);
        assertGt(m, 0);
        assertLt(m, STAKE);
        vm.prank(crowd[5]);
        nerve.exit(m);

        // tomorrow the budget resets
        vm.warp(block.timestamp + 1 days);
        (v,,,) = nerve.exitQuote(0.01 ether);
        assertEq(v, 0);
    }

    // ------------------------------------------------ the pot rewards nerve

    function test_stayersSplitThePotDesignerGetsCut() public {
        _fillCrowd();
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(crowd[i]);
            nerve.exit(STAKE); // paper hands pay into the pot
        }
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        nerve.fund{value: 0.1 ether}(); // e.g. the creator's 25% commitment

        uint256 pot = nerve.pot();
        vm.warp(block.timestamp + 5 days);

        uint256 before = crowd[10].balance;
        vm.prank(crowd[10]);
        nerve.claim();
        uint256 potAfterCut = pot - pot / 10;
        assertEq(crowd[10].balance - before, STAKE + potAfterCut * STAKE / (16 * STAKE));

        // designer = owner of circuit #1 (the author) takes 10%
        uint256 ab = author.balance;
        vm.prank(author);
        nerve.claimDesigner();
        assertEq(author.balance - ab, pot / 10);

        vm.prank(alice);
        vm.expectRevert(NerveSeason.NothingToClaim.selector);
        nerve.claim();

        for (uint256 i = 4; i < 20; i++) {
            if (i == 10) continue;
            vm.prank(crowd[i]);
            nerve.claim();
        }
        assertLt(address(nerve).balance, 100, "only rounding dust left");
    }

    /// Early joiners earn a larger pot share for the same deposit (points = OKB x time committed).
    function test_earlyJoinerEarnsMore() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        nerve.fund{value: 0.1 ether}();

        _join(crowd[0], STAKE); // day 0
        (uint256 quoteShare,) = nerve.joinQuote(crowd[1], STAKE);
        vm.warp(block.timestamp + 2 days);
        _join(crowd[1], STAKE); // day 2: 3 of 5 days left
        vm.warp(block.timestamp + 3 days);

        uint256 b0 = crowd[0].balance;
        uint256 b1 = crowd[1].balance;
        vm.prank(crowd[0]);
        nerve.claim();
        vm.prank(crowd[1]);
        nerve.claim();
        uint256 s0 = crowd[0].balance - b0 - STAKE;
        uint256 s1 = crowd[1].balance - b1 - STAKE;
        assertGt(s0, s1, "early joiner earns more");
        assertApproxEqRel(s0 * 3, s1 * 5, 1e15, "shares are in the ratio of time committed (5:3)");
        assertGt(quoteShare, s1, "a day-0 quote promised more than joining on day 2 earns");
    }

    function test_joinQuoteMatchesPayoutWhenEveryoneStays() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        nerve.fund{value: 0.09 ether}();
        _join(crowd[0], STAKE);
        (uint256 q, uint256 ticket) = nerve.joinQuote(crowd[1], STAKE);
        assertEq(ticket, nerve.ticketCost());
        _join(crowd[1], STAKE);
        vm.warp(block.timestamp + 5 days);
        uint256 b = crowd[1].balance;
        vm.prank(crowd[1]);
        nerve.claim();
        assertApproxEqAbs(crowd[1].balance - b - STAKE, q, 1e9, "quote = real payout if everyone stays");
    }

    function test_partialExitRemovesProportionalPoints() public {
        _join(crowd[0], STAKE);
        uint256 p0 = nerve.points(crowd[0]);
        vm.warp(block.timestamp + 1 days);
        vm.prank(crowd[0]);
        nerve.exit(STAKE / 5); // a small exit (budget allows) removes 20% of points
        assertApproxEqAbs(nerve.points(crowd[0]), p0 * 4 / 5, 1);
        assertEq(nerve.totalPoints(), nerve.points(crowd[0]));
    }

    function test_noExitsAfterSeasonEnd() public {
        _fillCrowd();
        vm.warp(block.timestamp + 5 days);
        vm.prank(crowd[0]);
        vm.expectRevert(NerveSeason.SeasonOver.selector);
        nerve.exit(0.01 ether);
    }

    function test_everyoneLeavesDesignerTakesPot() public {
        _join(crowd[0], STAKE);
        _join(crowd[1], STAKE);
        vm.warp(block.timestamp + 1 days);
        for (uint256 d = 0; d < 3 && nerve.totalPrincipal() > 0; d++) {
            for (uint256 i = 0; i < 2; i++) {
                uint256 m = nerve.maxExit(crowd[i]);
                if (m > 0) {
                    vm.prank(crowd[i]);
                    nerve.exit(m);
                }
            }
            vm.warp(block.timestamp + 1 days);
        }
        if (nerve.totalPrincipal() == 0) {
            vm.warp(block.timestamp + 5 days);
            nerve.settle();
            assertEq(nerve.designerOwed(), nerve.pot());
        }
    }

    // ------------------------------------------------ players can never be trapped by TapeOut

    function test_processorUpgradeFailsOpen() public {
        _fillCrowd();
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(crowd[i]);
            nerve.exit(STAKE);
        }
        (uint8 v,,,) = nerve.exitQuote(STAKE);
        assertEq(v, 2);

        beacon.upgrade(address(0xBEEF));
        (v,,,) = nerve.exitQuote(STAKE);
        assertEq(v, 0, "fails open: base fee, no halt");
        vm.prank(crowd[5]);
        nerve.exit(STAKE);
    }

    function test_rejectsBadRuleCircuit() public {
        NerveSeason.Params memory p = _params(withdrawId);
        p.throttleFeeBps = 5000;
        vm.expectRevert(NerveSeason.BadParams.selector);
        new NerveSeason(p);
    }

    // ------------------------------------------------ solvency

    function testFuzz_alwaysSolvent(uint8 n, uint64 seed) public {
        n = uint8(bound(n, 1, 20));
        for (uint256 i = 0; i < n; i++) _join(crowd[i], 0.001 ether + (uint256(keccak256(abi.encode(seed, i))) % (STAKE - 0.001 ether)));
        for (uint256 d = 0; d < 4; d++) {
            vm.warp(block.timestamp + 1 days);
            for (uint256 i = 0; i < n; i++) {
                if (uint256(keccak256(abi.encode(seed, d, i))) % 3 != 0) continue;
                uint256 m = nerve.maxExit(crowd[i]);
                if (m == 0) continue;
                vm.prank(crowd[i]);
                nerve.exit(m);
                assertGe(address(nerve).balance, nerve.totalPrincipal() + nerve.pot());
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
        assertLt(address(nerve).balance, 1000);
    }
}
