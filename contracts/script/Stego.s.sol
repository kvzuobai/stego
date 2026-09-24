// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import {PolicyRegistry} from "../src/PolicyRegistry.sol";
import {StegoVault} from "../src/StegoVault.sol";
import {NerveSeason, IProtocolFee} from "../src/NerveSeason.sol";
import {ITapeOutProcessor} from "../src/interfaces/ITapeOutProcessor.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {WithdrawEnvelopeV1, DrawdownEnvelopeV1, AllocationEnvelopeV1} from "../src/specs/PolicySpecs.sol";
import {IPolicySpec} from "../src/interfaces/IPolicySpec.sol";

interface ITapeOutFactory {
    function createCPU(string calldata name, string calldata symbol, string calldata story, uint256 supply, uint256 mintPrice)
        external
        payable
        returns (address transistors, address circuits);
    function deployFee() external view returns (uint256);
    function protocolFee() external view returns (uint256);
    function isCPU(address) external view returns (bool);
}

interface ITransistors is IERC1155 {
    function mint(uint256 id, uint256 amount) external payable;
    function mintPrice() external view returns (uint256);
    function owed(address a) external view returns (uint256);
    function withdraw() external;
    function minted() external view returns (uint256);
}

interface IWOKB {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IProcessorFull is ITapeOutProcessor {
    function tapeout(bytes calldata nl, uint32 nIn, uint32 nOut) external payable returns (uint256);
    function TAPEOUT_FEE() external view returns (uint256);
}

abstract contract StegoScript is Script {
    ITapeOutFactory constant FACTORY = ITapeOutFactory(0x1f09DAeFA827f02CBb40967cc91b259763760761);
    IERC20 constant WOKB = IERC20(0xe538905cf8410324e03A5A23C1c177a474D59b2b);
    /// TapeOut's processor beacon on X Layer (embedded in every processor clone's bytecode)
    IBeacon constant BEACON = IBeacon(0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C);

    /// The Stego deployment wallet: creator of the processor, owner of circuit #1, curator.
    address constant CREATOR = 0xC4AAaf5BD7e688F19F70E1e5067aF4c2d1307A74;

    function _requireXLayer() internal view {
        require(block.chainid == 196, "not X Layer mainnet (196)");
    }

    /// Refuses to run (before anything is sent) unless the signing wallet is the deployment wallet.
    function _requireCreator() internal view {
        _requireXLayer();
        require(msg.sender == CREATOR, "wrong wallet: sign with the Stego deployment wallet 0xC4AA...7A74");
    }
}

/// Step 1: create the processor through the TapeOut factory. Supply and price are immutable.
/// NAME, SYMBOL, STORY, SUPPLY, PRICE_WEI from env.
contract CreateProcessor is StegoScript {
    function run() external {
        _requireXLayer();
        string memory name = vm.envString("NAME");
        string memory symbol = vm.envString("SYMBOL");
        string memory story = vm.envString("STORY");
        uint256 supply = vm.envUint("SUPPLY");
        uint256 price = vm.envUint("PRICE_WEI");
        require(supply >= 10_000 && price >= 66e12, "below TapeOut X Layer quality minimums");

        vm.startBroadcast();
        (address t, address c) = FACTORY.createCPU{value: FACTORY.deployFee()}(name, symbol, story, supply, price);
        vm.stopBroadcast();

        require(FACTORY.isCPU(c), "factory does not recognise processor");
        console2.log("PROCESSOR  =", c);
        console2.log("TRANSISTORS=", t);
    }
}

/// Step 2: mint exactly the transistors needed and tape out the three policy circuits.
/// PROCESSOR, BOND from env. Mints gates + 3 * BOND so step 3 can bond all three.
contract TapeOutPolicies is StegoScript {
    function run() external {
        _requireXLayer();
        IProcessorFull processor = IProcessorFull(vm.envAddress("PROCESSOR"));
        require(FACTORY.isCPU(address(processor)), "not a factory processor");
        ITransistors transistors = ITransistors(processor.transistors());
        uint256 bond = vm.envUint("BOND");

        string[3] memory files = ["WITHDRAW_GUARD_V1.json", "DRAWDOWN_BREAKER_V1.json", "ALLOCATION_BAND_V1.json"];
        bytes[3] memory nls;
        uint256 gates;
        for (uint256 i = 0; i < 3; i++) {
            string memory json = vm.readFile(string.concat("../circuits/out/", files[i]));
            nls[i] = vm.parseJsonBytes(json, ".netlist");
            gates += vm.parseJsonUint(json, ".gateCount");
        }
        uint256 have = transistors.balanceOf(msg.sender, 0);
        uint256 need = gates + 3 * bond;

        vm.startBroadcast();
        if (have < need) {
            uint256 n = need - have;
            transistors.mint{value: transistors.mintPrice() * n + FACTORY.protocolFee()}(0, n);
        }
        for (uint256 i = 0; i < 3; i++) {
            uint256 id = processor.tapeout{value: processor.TAPEOUT_FEE()}(nls[i], 16, 2);
            console2.log(files[i], "-> circuit id", id);
        }
        vm.stopBroadcast();
    }
}

/// Low-budget alternative to step 2 for the creator wallet: tapes out ONE circuit (FILE, default the
/// 112-gate WITHDRAW_GUARD_V1) with very little OKB. The creator's own mint payments are credited back
/// as creator proceeds, so it mints in small batches and withdraws after each one. Only protocol and
/// tape-out fees are really spent. PROCESSOR from env; optional FILE.
contract BootstrapCircuit is StegoScript {
    function run() external {
        _requireXLayer();
        IProcessorFull processor = IProcessorFull(vm.envAddress("PROCESSOR"));
        require(FACTORY.isCPU(address(processor)), "not a factory processor");
        ITransistors transistors = ITransistors(processor.transistors());
        string memory file = vm.envOr("FILE", string("WITHDRAW_GUARD_V1.json"));
        string memory json = vm.readFile(string.concat("../circuits/out/", file));
        bytes memory nl = vm.parseJsonBytes(json, ".netlist");
        uint256 gates = vm.parseJsonUint(json, ".gateCount");

        uint256 price = transistors.mintPrice();
        uint256 fee = FACTORY.protocolFee();
        uint256 tapeFee = processor.TAPEOUT_FEE();
        uint256 reserve = tapeFee + 0.0003 ether; // tape-out fee + gas headroom
        address me = msg.sender;

        vm.startBroadcast();
        uint256 rounds;
        while (transistors.balanceOf(me, 0) < gates) {
            uint256 missing = gates - transistors.balanceOf(me, 0);
            require(me.balance > reserve + fee + price, "not enough OKB for another mint round");
            uint256 n = (me.balance - reserve - fee) / price;
            if (n > missing) n = missing;
            transistors.mint{value: price * n + fee}(0, n);
            if (transistors.owed(me) != 0) transistors.withdraw();
            require(++rounds <= 8, "too many rounds; top up the wallet");
        }
        uint256 id = processor.tapeout{value: tapeFee}(nl, 16, 2);
        vm.stopBroadcast();

        console2.log(file, "-> circuit id", id);
        console2.log("mint rounds", rounds);
        console2.log("OKB left (wei)", me.balance);
    }
}

/// Step 3: deploy specs + registry + vault and propose the three circuits (starts the timelock).
/// PROCESSOR, WITHDRAW_ID, DRAWDOWN_ID, ALLOCATION_ID, BOND, TIMELOCK_SECONDS,
/// ENTRY_FEE_BPS, THROTTLE_FEE_BPS, DEPOSIT_CAP_WEI from env.
contract DeployStego is StegoScript {
    function run() external {
        _requireCreator();
        ITapeOutProcessor processor = ITapeOutProcessor(vm.envAddress("PROCESSOR"));
        require(FACTORY.isCPU(address(processor)), "not a factory processor");

        vm.startBroadcast();
        address me = msg.sender;
        WithdrawEnvelopeV1 ws = new WithdrawEnvelopeV1();
        DrawdownEnvelopeV1 ds = new DrawdownEnvelopeV1();
        AllocationEnvelopeV1 as_ = new AllocationEnvelopeV1();

        PolicyRegistry registry = new PolicyRegistry(
            me, processor, BEACON, WOKB, vm.envUint("BOND"), uint64(vm.envUint("TIMELOCK_SECONDS"))
        );
        registry.addSlot("WITHDRAW", ws);
        registry.addSlot("DRAWDOWN", ds);
        registry.addSlot("ALLOCATION", as_);

        IERC1155(processor.transistors()).setApprovalForAll(address(registry), true);
        registry.propose("WITHDRAW", vm.envUint("WITHDRAW_ID"));
        registry.propose("DRAWDOWN", vm.envUint("DRAWDOWN_ID"));
        registry.propose("ALLOCATION", vm.envUint("ALLOCATION_ID"));
        // the deployer is also the initial curator and approves its own reviewed designs
        registry.approve(vm.envUint("WITHDRAW_ID"));
        registry.approve(vm.envUint("DRAWDOWN_ID"));
        registry.approve(vm.envUint("ALLOCATION_ID"));

        StegoVault vault = new StegoVault(
            WOKB,
            "Stego Vault WOKB",
            "sgWOKB",
            registry,
            me,
            vm.envUint("ENTRY_FEE_BPS"),
            vm.envUint("THROTTLE_FEE_BPS"),
            vm.envUint("DEPOSIT_CAP_WEI")
        );
        vm.stopBroadcast();

        console2.log("WITHDRAW_SPEC  =", address(ws));
        console2.log("DRAWDOWN_SPEC  =", address(ds));
        console2.log("ALLOCATION_SPEC=", address(as_));
        console2.log("REGISTRY       =", address(registry));
        console2.log("VAULT          =", address(vault));
    }
}

/// Recurring: honour the public 25% commitment, cumulatively and auditably.
/// Every STEGO ever minted paid the creator mintPrice, so all proceeds ever = minted() * mintPrice().
/// Due = SHARE_BPS of that; already paid = registry.notifiedBy(creator), recorded on-chain. The script
/// withdraws any owed proceeds and streams the shortfall as WOKB to the active policy authors.
/// With a small wallet it streams in chunks: after each chunk it claims back whatever this wallet
/// earned as a policy author (CLAIM_BACK, default true) and continues, until the commitment is met or
/// no more OKB is available. Every chunk is a real, public RewardNotified payment.
/// PROCESSOR, REGISTRY from env; optional SHARE_BPS (2500), CLAIM_BACK (true), MAX_CHUNKS (10).
contract HonourCommitment is StegoScript {
    uint256 constant GAS_RESERVE = 0.002 ether;

    function run() external {
        _requireCreator();
        ITransistors transistors = ITransistors(ITapeOutProcessor(vm.envAddress("PROCESSOR")).transistors());
        PolicyRegistry registry = PolicyRegistry(vm.envAddress("REGISTRY"));
        uint256 shareBps = vm.envOr("SHARE_BPS", uint256(2500));
        require(shareBps >= 2500 && shareBps <= 10_000, "commitment is at least 25%");
        bool claimBack = vm.envOr("CLAIM_BACK", true);
        uint256 maxChunks = vm.envOr("MAX_CHUNKS", uint256(10));
        address me = msg.sender;

        uint256 due = transistors.minted() * transistors.mintPrice() * shareBps / 10_000;
        console2.log("committed share due (wei)", due);
        console2.log("already streamed (wei)   ", registry.notifiedBy(me));

        vm.startBroadcast();
        if (transistors.owed(me) != 0) transistors.withdraw();
        for (uint256 i = 0; i < maxChunks; i++) {
            uint256 paid = registry.notifiedBy(me);
            if (paid >= due) break;
            uint256 avail = me.balance > GAS_RESERVE ? me.balance - GAS_RESERVE : 0;
            uint256 chunk = due - paid;
            if (chunk > avail) chunk = avail;
            if (chunk == 0) break;
            IWOKB(address(WOKB)).deposit{value: chunk}();
            IWOKB(address(WOKB)).approve(address(registry), chunk);
            registry.notifyReward(chunk);
            console2.log("streamed chunk (wei)", chunk);
            if (!claimBack) break;
            _claimMine(registry, me);
        }
        vm.stopBroadcast();

        uint256 paidNow = registry.notifiedBy(me);
        console2.log("streamed in total (wei)  ", paidNow);
        if (paidNow >= due) console2.log("commitment is fully honoured");
        else console2.log("still owed (wei) - top up and run again:", due - paidNow);
    }

    /// @dev Claim this wallet's author rewards on circuits 1..32 and unwrap them back to OKB.
    function _claimMine(PolicyRegistry registry, address me) internal {
        uint256 before = WOKB.balanceOf(me);
        for (uint256 id = 1; id <= 32; id++) {
            (, address author, PolicyRegistry.Status st,,,, uint256 rewards) = registry.candidates(id);
            if (author == me && rewards != 0 && st != PolicyRegistry.Status.Slashed) registry.claimRewards(id);
        }
        uint256 gained = WOKB.balanceOf(me) - before;
        if (gained != 0) IWOKB(address(WOKB)).withdraw(gained);
    }
}

/// Claim policy-author rewards for every circuit this wallet authored, optionally unwrapping WOKB to OKB.
/// REGISTRY from env; optional UNWRAP (true), MAX_ID (32).
contract ClaimAuthorRewards is StegoScript {
    function run() external {
        _requireCreator();
        PolicyRegistry registry = PolicyRegistry(vm.envAddress("REGISTRY"));
        uint256 maxId = vm.envOr("MAX_ID", uint256(32));
        address me = msg.sender;
        uint256 before = WOKB.balanceOf(me);

        vm.startBroadcast();
        for (uint256 id = 1; id <= maxId; id++) {
            (, address author, PolicyRegistry.Status st,,,, uint256 rewards) = registry.candidates(id);
            if (author != me || rewards == 0 || st == PolicyRegistry.Status.Slashed) continue;
            registry.claimRewards(id);
            console2.log("claimed for circuit", id, rewards);
        }
        uint256 gained = WOKB.balanceOf(me) - before;
        if (gained != 0 && vm.envOr("UNWRAP", true)) IWOKB(address(WOKB)).withdraw(gained);
        vm.stopBroadcast();
        console2.log("total claimed (wei)", gained);
    }
}

/// Phase 2: tape out DRAWDOWN_BREAKER_V1 + ALLOCATION_BAND_V1 and hold 3 * BOND STEGO for the registry
/// bonds. Mints in as few rounds as the wallet allows (one round by default, since every mint pays
/// TapeOut's fixed protocol fee), withdrawing the creator proceeds right after each mint and checking
/// nothing is left unclaimed. Set ROUND_WEI to cap OKB per round if the wallet is short. Resumable:
/// circuits already taped out by this wallet (same netlist) are detected and skipped.
/// PROCESSOR, BOND from env; optional ROUND_WEI (unlimited), MAX_ROUNDS (40).
contract Phase2Safe is StegoScript {
    function run() external {
        _requireCreator();
        IProcessorFull processor = IProcessorFull(vm.envAddress("PROCESSOR"));
        require(FACTORY.isCPU(address(processor)), "not a factory processor");
        ITransistors transistors = ITransistors(processor.transistors());
        address me = msg.sender;
        uint256 round = vm.envOr("ROUND_WEI", type(uint256).max);
        uint256 maxRounds = vm.envOr("MAX_ROUNDS", uint256(40));

        string[2] memory files = ["DRAWDOWN_BREAKER_V1.json", "ALLOCATION_BAND_V1.json"];
        bytes[2] memory nls;
        uint256[2] memory ids;
        uint256 gatesMissing;
        for (uint256 i = 0; i < 2; i++) {
            string memory json = vm.readFile(string.concat("../circuits/out/", files[i]));
            nls[i] = vm.parseJsonBytes(json, ".netlist");
            ids[i] = _findExisting(processor, me, keccak256(nls[i]));
            if (ids[i] == 0) gatesMissing += vm.parseJsonUint(json, ".gateCount");
            else console2.log(files[i], "already taped out as circuit", ids[i]);
        }
        uint256 need = gatesMissing + 3 * vm.envUint("BOND");
        uint256 reserve = 2 * processor.TAPEOUT_FEE() + 0.002 ether; // tape-outs + gas headroom

        vm.startBroadcast();
        uint256 rounds = _mintInRounds(transistors, me, need, round, reserve, maxRounds);
        for (uint256 i = 0; i < 2; i++) {
            if (ids[i] == 0) ids[i] = processor.tapeout{value: processor.TAPEOUT_FEE()}(nls[i], 16, 2);
        }
        vm.stopBroadcast();

        console2.log("mint rounds", rounds);
        console2.log("DRAWDOWN_ID  =", ids[0]);
        console2.log("ALLOCATION_ID=", ids[1]);
        console2.log("STEGO held for bonds", transistors.balanceOf(me, 0));
        console2.log("OKB left (wei)", me.balance);
    }

    /// @dev Mint until `me` holds `need` NAND, spending at most `round` per mint and withdrawing the
    /// creator proceeds straight after each one.
    function _mintInRounds(ITransistors transistors, address me, uint256 need, uint256 round, uint256 reserve, uint256 maxRounds)
        internal
        returns (uint256 rounds)
    {
        uint256 price = transistors.mintPrice();
        uint256 fee = FACTORY.protocolFee();
        while (transistors.balanceOf(me, 0) < need) {
            require(++rounds <= maxRounds, "too many rounds; raise ROUND_WEI or top up");
            uint256 budget = me.balance > reserve ? me.balance - reserve : 0;
            if (budget > round) budget = round;
            require(budget > fee + price, "not enough OKB for another round");
            uint256 n = (budget - fee) / price;
            uint256 missing = need - transistors.balanceOf(me, 0);
            if (n > missing) n = missing;
            transistors.mint{value: price * n + fee}(0, n);
            transistors.withdraw();
            require(transistors.owed(me) == 0, "proceeds not fully withdrawn");
        }
    }

    function _findExisting(IProcessorFull processor, address me, bytes32 h) internal view returns (uint256) {
        for (uint256 id = 1; id <= 64; id++) {
            try processor.netlist(id) returns (bytes memory nl) {
                if (nl.length == 0) return 0;
                if (keccak256(nl) == h && processor.ownerOf(id) == me) return id;
            } catch {
                return 0;
            }
        }
        return 0;
    }
}

/// Nerve Season: the bank-run game, using a live circuit as its exit rule. Gas only (no tape-out).
/// All settings are prefixed NERVE_ so they never clash with the vault's settings in the same shell.
/// PROCESSOR from env; optional NERVE_EXIT_RULE_CIRCUIT (1), NERVE_JOIN_HOURS (96), NERVE_SEASON_HOURS (144),
/// NERVE_TICKET (10), NERVE_MIN_DEPOSIT_WEI (0.01), NERVE_MAX_PER_WALLET_WEI (0.05), NERVE_SEASON_CAP_WEI (2),
/// NERVE_BASE_FEE_BPS (200), NERVE_THROTTLE_FEE_BPS (1000), NERVE_DESIGNER_CUT_BPS (1000),
/// NERVE_ENVELOPE (a WithdrawEnvelopeV1 is deployed if unset), NERVE_SEASON_NAME.
/// Designer seasons: set NERVE_EXIT_RULE_CIRCUIT to the chosen community circuit; its owner earns the cut.
contract DeployNerve is StegoScript {
    function run() external {
        _requireCreator();
        ITapeOutProcessor processor = ITapeOutProcessor(vm.envAddress("PROCESSOR"));
        require(FACTORY.isCPU(address(processor)), "not a factory processor");
        NerveSeason.Params memory p = NerveSeason.Params({
            name: vm.envOr("NERVE_SEASON_NAME", string("Stego Nerve - Season 1")),
            processor: processor,
            factory: IProtocolFee(address(FACTORY)),
            beacon: BEACON,
            circuitId: vm.envOr("NERVE_EXIT_RULE_CIRCUIT", uint256(1)),
            ticketTransistors: vm.envOr("NERVE_TICKET", uint256(10)),
            joinDeadline: uint64(block.timestamp + vm.envOr("NERVE_JOIN_HOURS", uint256(96)) * 1 hours),
            seasonEnd: uint64(block.timestamp + vm.envOr("NERVE_SEASON_HOURS", uint256(144)) * 1 hours),
            minDeposit: vm.envOr("NERVE_MIN_DEPOSIT_WEI", uint256(0.01 ether)),
            maxPerWallet: vm.envOr("NERVE_MAX_PER_WALLET_WEI", uint256(0.05 ether)),
            seasonCap: vm.envOr("NERVE_SEASON_CAP_WEI", uint256(2 ether)),
            baseFeeBps: vm.envOr("NERVE_BASE_FEE_BPS", uint256(200)),
            throttleFeeBps: vm.envOr("NERVE_THROTTLE_FEE_BPS", uint256(1000)),
            designerCutBps: vm.envOr("NERVE_DESIGNER_CUT_BPS", uint256(1000)),
            envelope: IPolicySpec(vm.envOr("NERVE_ENVELOPE", address(0)))
        });
        // Readable checks before anything is sent (the contract would reject these as BadParams).
        require(p.baseFeeBps <= p.throttleFeeBps, "NERVE_BASE_FEE_BPS must be <= NERVE_THROTTLE_FEE_BPS");
        require(p.throttleFeeBps <= 2000 && p.designerCutBps <= 2000, "fees above 20% are not allowed");
        require(p.joinDeadline <= p.seasonEnd, "NERVE_JOIN_HOURS must be <= NERVE_SEASON_HOURS");
        require(p.minDeposit > 0 && p.maxPerWallet >= p.minDeposit && p.seasonCap >= p.maxPerWallet, "deposit limits are inconsistent");
        console2.log("exit-rule circuit", p.circuitId);
        vm.startBroadcast();
        // Designer seasons: the exit rule is always checked against the WITHDRAW safety envelope.
        if (address(p.envelope) == address(0)) p.envelope = new WithdrawEnvelopeV1();
        NerveSeason nerve = new NerveSeason(p);
        vm.stopBroadcast();
        console2.log("NERVE        =", address(nerve));
        console2.log("joinDeadline =", p.joinDeadline);
        console2.log("seasonEnd    =", p.seasonEnd);
        console2.log("ticket cost  =", nerve.ticketCost());
    }
}

/// Step 4 (after the timelock, callable by anyone): activate all pending circuits. REGISTRY from env.
contract ActivatePolicies is StegoScript {
    function run() external {
        _requireXLayer();
        PolicyRegistry registry = PolicyRegistry(vm.envAddress("REGISTRY"));
        vm.startBroadcast();
        registry.activate("WITHDRAW");
        registry.activate("DRAWDOWN");
        registry.activate("ALLOCATION");
        vm.stopBroadcast();
    }
}
