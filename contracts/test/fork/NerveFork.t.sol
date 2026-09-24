// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

import {NerveSeason, IProtocolFee} from "../../src/NerveSeason.sol";
import {ITapeOutProcessor} from "../../src/interfaces/ITapeOutProcessor.sol";
import {IPolicySpec} from "../../src/interfaces/IPolicySpec.sol";
import {WithdrawEnvelopeV1} from "../../src/specs/PolicySpecs.sol";

interface ITransistorsView is IERC1155 {
    function owed(address a) external view returns (uint256);
}

/// forge test --match-path "test/fork/NerveFork*" --fork-url https://xlayerrpc.okx.com -vv
/// Nerve Season on the LIVE Stego processor and its live circuit #1 (WITHDRAW_GUARD_V1).
contract NerveForkTest is Test {
    ITapeOutProcessor constant STEGO = ITapeOutProcessor(0x0d90BA20B57D63b8eEA92d674ef87284B2EB290C);
    IProtocolFee constant FACTORY = IProtocolFee(0x1f09DAeFA827f02CBb40967cc91b259763760761);
    IBeacon constant BEACON = IBeacon(0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C);
    address constant CREATOR = 0xC4AAaf5BD7e688F19F70E1e5067aF4c2d1307A74;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function test_nerveOnLiveStego() public {
        vm.skip(block.chainid != 196);
        NerveSeason nerve = new NerveSeason(
            NerveSeason.Params({
                name: "Stego Nerve - Season 1",
                processor: STEGO,
                factory: FACTORY,
                beacon: BEACON,
                circuitId: 1,
                ticketTransistors: 10,
                joinDeadline: uint64(block.timestamp + 3 days),
                seasonEnd: uint64(block.timestamp + 5 days),
                minDeposit: 0.001 ether,
                maxPerWallet: 0.05 ether,
                seasonCap: 2 ether,
                baseFeeBps: 200,
                throttleFeeBps: 1000,
                designerCutBps: 1000,
                envelope: IPolicySpec(address(new WithdrawEnvelopeV1()))
            })
        );
        assertEq(nerve.name(), "Stego Nerve - Season 1");
        ITransistorsView t = ITransistorsView(STEGO.transistors());
        uint256 owedBefore = t.owed(CREATOR);
        uint256 deadBefore = t.balanceOf(DEAD, 0);
        uint256 cost = nerve.ticketCost();
        console2.log("ticket cost (wei)", cost);

        address[] memory crowd = new address[](12);
        for (uint256 i = 0; i < crowd.length; i++) {
            crowd[i] = makeAddr(string.concat("p", vm.toString(i)));
            vm.deal(crowd[i], 1 ether);
            vm.prank(crowd[i]);
            nerve.join{value: 0.05 ether + cost}();
        }
        assertEq(t.balanceOf(DEAD, 0) - deadBefore, 120, "12 tickets x 10 STEGO burned");
        assertEq(t.owed(CREATOR) - owedBefore, 120 * 0.000066 ether, "ticket price goes to the STEGO creator");

        vm.warp(block.timestamp + 1 days);
        uint8 seen;
        for (uint256 i = 0; i < 6; i++) {
            (uint8 v,,,) = nerve.exitQuote(0.05 ether);
            seen |= uint8(1 << v);
            if (v == 2) break;
            vm.prank(crowd[i]);
            nerve.exit(0.05 ether);
        }
        assertEq(seen, 7, "live circuit produced ALLOW, THROTTLE and HALT");

        vm.warp(block.timestamp + 5 days);
        uint256 pot = nerve.pot();
        uint256 b = crowd[11].balance;
        vm.prank(crowd[11]);
        nerve.claim();
        console2.log("pot (wei)", pot);
        console2.log("stayer payout (wei)", crowd[11].balance - b);
        assertGt(crowd[11].balance - b, 0.05 ether, "stayer earns more than their deposit");

        uint256 cb = CREATOR.balance;
        vm.prank(CREATOR);
        nerve.claimDesigner();
        assertEq(CREATOR.balance - cb, pot / 10, "circuit #1 owner gets the designer cut");
    }
}
