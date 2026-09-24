// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import {PolicyRegistry} from "../../src/PolicyRegistry.sol";
import {StegoVault} from "../../src/StegoVault.sol";
import {ITapeOutProcessor} from "../../src/interfaces/ITapeOutProcessor.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {WithdrawEnvelopeV1, DrawdownEnvelopeV1, AllocationEnvelopeV1} from "../../src/specs/PolicySpecs.sol";

interface ITapeOutFactory {
    function createCPU(string calldata name, string calldata symbol, string calldata story, uint256 supply, uint256 mintPrice)
        external
        payable
        returns (address transistors, address circuits);
    function deployFee() external view returns (uint256);
    function protocolFee() external view returns (uint256);
    function isCPU(address) external view returns (bool);
}

interface IWOKBFork {
    function deposit() external payable;
}

interface ITransistors is IERC1155 {
    function owed(address a) external view returns (uint256);
    function withdraw() external;
    function mint(uint256 id, uint256 amount) external payable;
    function mintPrice() external view returns (uint256);
    function supplyCap() external view returns (uint256);
    function minted() external view returns (uint256);
}

interface IProcessorFull is ITapeOutProcessor {
    function tapeout(bytes calldata nl, uint32 nIn, uint32 nOut) external payable returns (uint256);
    function TAPEOUT_FEE() external view returns (uint256);
}

/// forge test --match-path test/fork/* --fork-url https://xlayerrpc.okx.com -vv
/// Runs the whole flow against the real TapeOut factory/processor implementation on an X Layer fork.
contract XLayerForkTest is Test {
    ITapeOutFactory constant FACTORY = ITapeOutFactory(0x1f09DAeFA827f02CBb40967cc91b259763760761);
    IERC20 constant WOKB = IERC20(0xe538905cf8410324e03A5A23C1c177a474D59b2b);
    IBeacon constant BEACON = IBeacon(0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C);

    address dev = makeAddr("dev");
    address alice = makeAddr("alice");

    function test_fullFlowOnRealTapeOut() public {
        vm.skip(block.chainid != 196);
        vm.deal(dev, 10 ether);
        vm.startPrank(dev);

        (address t, address c) = FACTORY.createCPU{value: FACTORY.deployFee()}(
            "Stego", "STEGO", "fork test", 262_144, 0.00005 ether
        );
        assertTrue(FACTORY.isCPU(c));
        ITransistors transistors = ITransistors(t);
        IProcessorFull processor = IProcessorFull(c);
        assertEq(processor.transistors(), t);
        console2.log("supplyCap", transistors.supplyCap());

        uint256 need = 112 + 161 + 246 + 300; // three circuits + bonds
        transistors.mint{value: transistors.mintPrice() * need + FACTORY.protocolFee()}(0, need);
        assertEq(transistors.balanceOf(dev, 0), need);

        uint256[3] memory ids;
        string[3] memory files = ["WITHDRAW_GUARD_V1.json", "DRAWDOWN_BREAKER_V1.json", "ALLOCATION_BAND_V1.json"];
        for (uint256 i = 0; i < 3; i++) {
            string memory json = vm.readFile(string.concat("../circuits/out/", files[i]));
            uint256 before = transistors.balanceOf(dev, 0);
            ids[i] = processor.tapeout{value: processor.TAPEOUT_FEE()}(
                vm.parseJsonBytes(json, ".netlist"), 16, 2
            );
            (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates) = processor.circuitInfo(ids[i]);
            assertEq(nIn, 16);
            assertEq(nOut, 2);
            assertEq(nState, 0);
            assertEq(gates, vm.parseJsonUint(json, ".gateCount"));
            assertEq(before - transistors.balanceOf(dev, 0), gates, "one transistor burned per gate");
            assertEq(keccak256(processor.netlist(ids[i])), vm.parseJsonBytes32(json, ".netlistHash"));
            assertEq(processor.ownerOf(ids[i]), dev);
            console2.log("circuit id / gates", ids[i], gates);
        }

        WithdrawEnvelopeV1 ws = new WithdrawEnvelopeV1();
        DrawdownEnvelopeV1 ds = new DrawdownEnvelopeV1();
        AllocationEnvelopeV1 as_ = new AllocationEnvelopeV1();

        // real eval() stays inside each slot's envelope on a spread of inputs
        for (uint256 k = 0; k < 64; k++) {
            uint8 a = uint8(uint256(keccak256(abi.encode(k, "a"))));
            uint8 b = uint8(uint256(keccak256(abi.encode(k, "b"))));
            assertTrue(ws.allowed(a, b, uint8(processor.eval(ids[0], abi.encodePacked(a, b))[0]) & 3));
            assertTrue(ds.allowed(a, b, uint8(processor.eval(ids[1], abi.encodePacked(a, b))[0]) & 3));
            assertTrue(as_.allowed(a, b, uint8(processor.eval(ids[2], abi.encodePacked(a, b))[0]) & 3));
        }

        PolicyRegistry registry = new PolicyRegistry(dev, processor, BEACON, WOKB, 100, 1 hours);
        registry.addSlot("WITHDRAW", ws);
        registry.addSlot("DRAWDOWN", ds);
        registry.addSlot("ALLOCATION", as_);
        transistors.setApprovalForAll(address(registry), true);
        registry.propose("WITHDRAW", ids[0]);
        registry.propose("DRAWDOWN", ids[1]);
        registry.propose("ALLOCATION", ids[2]);
        assertEq(transistors.balanceOf(address(registry), 0), 300);
        assertFalse(registry.processorUpgraded());
        registry.approve(ids[0]);
        registry.approve(ids[1]);
        registry.approve(ids[2]);
        vm.warp(block.timestamp + 1 hours);
        registry.activate("WITHDRAW");
        registry.activate("DRAWDOWN");
        registry.activate("ALLOCATION");

        StegoVault vault = new StegoVault(WOKB, "Stego Vault WOKB", "sgWOKB", registry, dev, 10, 100, 100 ether);
        vm.stopPrank();

        deal(address(WOKB), alice, 10 ether);
        vm.startPrank(alice);
        WOKB.approve(address(vault), type(uint256).max);
        uint256 g = gasleft();
        vault.deposit(10 ether, alice);
        console2.log("deposit gas (1 circuit eval)", g - gasleft());
        vm.warp(block.timestamp + 1 days);
        uint256 max = vault.maxWithdraw(alice);
        g = gasleft();
        vault.withdraw(max, alice, alice);
        console2.log("withdraw gas", g - gasleft());
        vm.expectRevert();
        vault.withdraw(1 ether, alice, alice); // over this epoch's budget -> HALT
        vm.stopPrank();
        console2.log("entry fees streamed to policy authors (WOKB wei)", WOKB.balanceOf(address(registry)));

        _shareProceeds(transistors, registry, ids[0]);
    }

    /// 25% mint-proceeds commitment (same steps as script ShareProceeds).
    function _shareProceeds(ITransistors transistors, PolicyRegistry registry, uint256 circuitId) internal {
        address minter = makeAddr("outsideMinter");
        vm.deal(minter, 1 ether);
        uint256 owedBefore = transistors.owed(dev);
        uint256 cost = transistors.mintPrice() * 1000 + FACTORY.protocolFee();
        vm.prank(minter);
        transistors.mint{value: cost}(0, 1000);
        uint256 owed = transistors.owed(dev);
        assertEq(owed - owedBefore, transistors.mintPrice() * 1000, "creator earns the full mint price");

        (,,,,,, uint256 rewardsBefore) = registry.candidates(circuitId);
        uint256 balBefore = dev.balance;
        vm.startPrank(dev);
        transistors.withdraw();
        assertEq(dev.balance - balBefore, owed, "withdraw pays native OKB");
        uint256 share = owed * 2500 / 10_000;
        IWOKBFork(address(WOKB)).deposit{value: share}();
        WOKB.approve(address(registry), share);
        registry.notifyReward(share);
        vm.stopPrank();
        (,,,,,, uint256 rewardsAfter) = registry.candidates(circuitId);
        assertApproxEqAbs(rewardsAfter - rewardsBefore, share / 3, 2, "split across 3 live policies");
        console2.log("proceeds withdrawn / 25% streamed", owed, share);
    }
}
