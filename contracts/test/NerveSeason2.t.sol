// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {Base} from "./Base.t.sol";
import {NerveSeason2} from "../src/NerveSeason2.sol";
import {IProtocolFee} from "../src/NerveSeason.sol";
import {ITapeOutProcessor} from "../src/interfaces/ITapeOutProcessor.sol";
import {MockFactory} from "./mocks/MockTapeOut.sol";

contract NerveSeason2Test is Base {
    NerveSeason2 s2;
    MockFactory factory;
    uint256 constant STAKE = 0.05 ether;
    address[] crowd;

    function setUp() public override {
        super.setUp();
        factory = new MockFactory();
        s2 = new NerveSeason2(_params(2000));
        for (uint256 i = 0; i < 20; i++) {
            address p = makeAddr(string.concat("p2_", vm.toString(i)));
            vm.deal(p, 1 ether);
            crowd.push(p);
        }
        vm.deal(owner, 5 ether);
    }

    function _params(uint256 diamondBps) internal view returns (NerveSeason2.Params memory) {
        return NerveSeason2.Params({
            name: "Stego Nerve - Season 2",
            processor: ITapeOutProcessor(address(processor)),
            factory: IProtocolFee(address(factory)),
            beacon: IBeacon(address(beacon)),
            circuitId: withdrawId,
            ticketTransistors: 10,
            joinDeadline: uint64(block.timestamp + 1 days),
            seasonEnd: uint64(block.timestamp + 2 days),
            minDeposit: 0.001 ether,
            maxPerWallet: STAKE,
            seasonCap: 2 ether,
            baseFeeBps: 200,
            throttleFeeBps: 1000,
            designerCutBps: 1000,
            envelope: withdrawSpec,
            diamondBonusBps: diamondBps
        });
    }

    function _join(address p, uint256 stake) internal {
        uint256 cost = s2.hasTicket(p) ? 0 : s2.ticketCost();
        vm.prank(p);
        s2.join{value: stake + cost}();
    }

    function _fund(uint256 amt) internal {
        vm.prank(owner);
        s2.fund{value: amt}();
    }

    function test_diamondHandsEarnTheBonus() public {
        _fund(0.1 ether);
        _join(crowd[0], STAKE);
        _join(crowd[1], STAKE);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(crowd[1]);
        s2.exit(0.001 ether); // a tiny exit is enough to lose diamond status
        assertTrue(s2.exited(crowd[1]));
        assertFalse(s2.exited(crowd[0]));

        vm.warp(block.timestamp + 2 days);
        uint256 b0 = crowd[0].balance;
        uint256 b1 = crowd[1].balance;
        vm.prank(crowd[0]);
        s2.claim();
        vm.prank(crowd[1]);
        s2.claim();
        uint256 sh0 = crowd[0].balance - b0 - STAKE;
        uint256 sh1 = crowd[1].balance - b1 - (STAKE - 0.001 ether);
        // weights: diamond 1.2 * P vs non-diamond 0.98 * P
        assertApproxEqRel(sh0 * 98, sh1 * 120, 1e15, "diamond gets 1.2x the weight of an equal exited stake");
        vm.prank(author);
        s2.claimDesigner();
        assertLt(address(s2).balance, 1000, "players + designer paid in full");
    }

    function test_everyoneStaysSplitsEvenly() public {
        _fund(0.09 ether);
        for (uint256 i = 0; i < 3; i++) _join(crowd[i], STAKE);
        vm.warp(block.timestamp + 2 days);
        for (uint256 i = 0; i < 3; i++) {
            uint256 b = crowd[i].balance;
            vm.prank(crowd[i]);
            s2.claim();
            assertApproxEqAbs(crowd[i].balance - b - STAKE, 0.027 ether, 3, "0.081 OKB split three ways");
        }
    }

    function test_exitedPlayerStaysNonDiamondAfterTopUp() public {
        _join(crowd[0], 0.02 ether);
        vm.prank(crowd[0]);
        s2.exit(0.001 ether);
        _join(crowd[0], 0.01 ether);
        assertTrue(s2.exited(crowd[0]));
        assertEq(s2.weightOf(crowd[0]), s2.points(crowd[0]));
        assertEq(s2.diamondPoints(), 0);
        assertEq(s2.totalWeight(), s2.totalPoints());
    }

    function test_standingsAndPlayerList() public {
        _join(crowd[0], STAKE);
        _join(crowd[1], 0.02 ether);
        _join(crowd[2], 0.03 ether);
        vm.prank(crowd[1]);
        s2.exit(0.001 ether);
        assertEq(s2.playerCount(), 3);
        (address[] memory who, uint256[] memory dep, uint256[] memory w, bool[] memory dia) = s2.standings(0, 10);
        assertEq(who.length, 3);
        assertEq(who[1], crowd[1]);
        assertEq(dep[1], 0.019 ether);
        assertFalse(dia[1]);
        assertTrue(dia[0] && dia[2]);
        assertEq(w[0], s2.weightOf(crowd[0]));
        (who,,,) = s2.standings(2, 10);
        assertEq(who.length, 1);
        (who,,,) = s2.standings(5, 10);
        assertEq(who.length, 0);
    }

    function test_quotesMatchPayoutWithDiamondAndBoost() public {
        _fund(0.1 ether);
        _join(crowd[0], STAKE);
        (uint256 q,) = s2.joinQuote(crowd[1], STAKE);
        _join(crowd[1], STAKE);
        uint256 bc = s2.boostCost(4);
        (uint256 bq,) = s2.boostQuote(crowd[1], 4);
        (, uint256 before) = s2.projectedPayout(crowd[1]);
        vm.prank(crowd[1]);
        s2.boost{value: bc}(4);
        (, uint256 afterB) = s2.projectedPayout(crowd[1]);
        assertApproxEqAbs(afterB - before, bq, 1e9, "boost quote");
        assertApproxEqAbs(before, q, 1e9, "join quote");
        vm.warp(block.timestamp + 2 days);
        uint256 b = crowd[1].balance;
        vm.prank(crowd[1]);
        s2.claim();
        assertApproxEqAbs(crowd[1].balance - b - STAKE, afterB, 1e9, "projected = paid");
    }

    function test_rejectsExcessiveDiamondBonus() public {
        vm.expectRevert(NerveSeason2.BadParams.selector);
        new NerveSeason2(_params(6000));
    }

    function testFuzz_solventWithDiamondsExitsAndBoosts(uint8 n, uint64 seed) public {
        n = uint8(bound(n, 1, 20));
        _fund(0.05 ether);
        for (uint256 i = 0; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            _join(crowd[i], 0.001 ether + r % (STAKE - 0.001 ether));
            uint256 units = (r >> 64) % 11;
            if (units > 0) {
                uint256 c = s2.boostCost(units);
                vm.prank(crowd[i]);
                s2.boost{value: c}(units);
            }
        }
        for (uint256 step = 0; step < 3; step++) {
            vm.warp(block.timestamp + 6 hours);
            for (uint256 i = 0; i < n; i++) {
                if (uint256(keccak256(abi.encode(seed, step, i))) % 3 != 0) continue;
                uint256 m = s2.maxExit(crowd[i]);
                if (m == 0) continue;
                vm.prank(crowd[i]);
                s2.exit(m);
            }
        }
        assertEq(s2.totalWeight(), _sumWeights(n), "total weight = sum of player weights");
        vm.warp(block.timestamp + 2 days);
        for (uint256 i = 0; i < n; i++) {
            if (s2.principal(crowd[i]) == 0) continue;
            vm.prank(crowd[i]);
            s2.claim();
        }
        vm.prank(author);
        s2.claimDesigner();
        assertLt(address(s2).balance, 1000, "all paid out, only dust left");
    }

    function _sumWeights(uint256 n) internal view returns (uint256 sum) {
        uint256 raw;
        uint256 dia;
        for (uint256 i = 0; i < n; i++) {
            raw += s2.points(crowd[i]);
            if (!s2.exited(crowd[i])) dia += s2.points(crowd[i]);
        }
        sum = raw + dia * s2.diamondBonusBps() / 10_000;
    }
}
