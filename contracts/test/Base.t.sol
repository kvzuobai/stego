// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PolicyRegistry} from "../src/PolicyRegistry.sol";
import {StegoVault} from "../src/StegoVault.sol";
import {ITapeOutProcessor} from "../src/interfaces/ITapeOutProcessor.sol";
import {IPolicySpec} from "../src/interfaces/IPolicySpec.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {WithdrawEnvelopeV1, DrawdownEnvelopeV1, AllocationEnvelopeV1} from "../src/specs/PolicySpecs.sol";
import {MockProcessor, MockTransistors, MockWOKB, MockBeacon} from "./mocks/MockTapeOut.sol";

/// @dev Deploys the full system against a MockProcessor loaded with the real netlists from
/// circuits/out (the exact bytes that will be taped out).
abstract contract Base is Test {
    bytes32 constant WITHDRAW = "WITHDRAW";
    bytes32 constant DRAWDOWN = "DRAWDOWN";
    bytes32 constant ALLOCATION = "ALLOCATION";

    uint256 constant BOND = 100;
    uint64 constant TIMELOCK = 1 hours;

    address owner = makeAddr("owner");
    address author = makeAddr("author");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address challenger = makeAddr("challenger");

    MockTransistors transistors;
    MockProcessor processor;
    MockWOKB wokb;
    MockBeacon beacon;
    PolicyRegistry registry;
    WithdrawEnvelopeV1 withdrawSpec;
    DrawdownEnvelopeV1 drawdownSpec;
    AllocationEnvelopeV1 allocationSpec;

    uint256 withdrawId;
    uint256 drawdownId;
    uint256 allocationId;

    function setUp() public virtual {
        transistors = new MockTransistors();
        processor = new MockProcessor(transistors);
        wokb = new MockWOKB();
        beacon = new MockBeacon();

        transistors.mint(author, 0, 10_000);
        vm.startPrank(author);
        withdrawId = _tapeout("WITHDRAW_GUARD_V1.json");
        drawdownId = _tapeout("DRAWDOWN_BREAKER_V1.json");
        allocationId = _tapeout("ALLOCATION_BAND_V1.json");
        vm.stopPrank();

        registry = new PolicyRegistry(owner, ITapeOutProcessor(address(processor)), IBeacon(address(beacon)), IERC20(address(wokb)), BOND, TIMELOCK);
        withdrawSpec = new WithdrawEnvelopeV1();
        drawdownSpec = new DrawdownEnvelopeV1();
        allocationSpec = new AllocationEnvelopeV1();
        vm.startPrank(owner);
        registry.addSlot(WITHDRAW, withdrawSpec);
        registry.addSlot(DRAWDOWN, drawdownSpec);
        registry.addSlot(ALLOCATION, allocationSpec);
        vm.stopPrank();

        vm.prank(author);
        transistors.setApprovalForAll(address(registry), true);
    }

    function _tapeout(string memory file) internal returns (uint256) {
        string memory json = vm.readFile(string.concat("../circuits/out/", file));
        bytes memory nl = vm.parseJsonBytes(json, ".netlist");
        uint32 nIn = uint32(vm.parseJsonUint(json, ".nIn"));
        uint32 nOut = uint32(vm.parseJsonUint(json, ".nOut"));
        return processor.tapeout(nl, nIn, nOut);
    }

    function _activateAll() internal {
        vm.startPrank(author);
        registry.propose(WITHDRAW, withdrawId);
        registry.propose(DRAWDOWN, drawdownId);
        registry.propose(ALLOCATION, allocationId);
        vm.stopPrank();
        vm.startPrank(owner);
        registry.approve(withdrawId);
        registry.approve(drawdownId);
        registry.approve(allocationId);
        vm.stopPrank();
        vm.warp(block.timestamp + TIMELOCK);
        registry.activate(WITHDRAW);
        registry.activate(DRAWDOWN);
        registry.activate(ALLOCATION);
    }

    /// Propose + curator approval + timelock + activate for one circuit.
    function _goLive(bytes32 slot, uint256 id) internal {
        vm.prank(author);
        registry.propose(slot, id);
        vm.prank(owner);
        registry.approve(id);
        vm.warp(block.timestamp + TIMELOCK);
        registry.activate(slot);
    }

    function _eval(uint256 id, uint8 a, uint8 b) internal view returns (uint8 v) {
        v = uint8(processor.eval(id, abi.encodePacked(a, b))[0]) & 3;
        if (v > 2) v = 2;
    }
}
