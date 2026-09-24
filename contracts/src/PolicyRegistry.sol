// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

import {ITapeOutProcessor} from "./interfaces/ITapeOutProcessor.sol";
import {IPolicySpec} from "./interfaces/IPolicySpec.sol";

/// @title PolicyRegistry
/// @notice Binds TapeOut circuits to named policy slots that vaults enforce on-chain.
///
/// Each slot has a safety envelope (IPolicySpec). Authors may design any circuit inside it, so
/// policies genuinely differ. Lifecycle: propose (bond transistors, pass probes) -> curator approves
/// -> timelock -> active. At any time anyone may prove a circuit breaks its envelope, either at one
/// input or by giving a riskier input a softer verdict; the bond and unclaimed rewards go to them.
///
/// TapeOut processors are upgradeable through a beacon. The registry pins the implementation it was
/// reviewed against. If TapeOut upgrades it, slashing freezes (so honest authors cannot be slashed
/// for a change they did not make) and vaults stop trusting verdicts until the curator re-pins.
contract PolicyRegistry is Ownable2Step, ReentrancyGuard, ERC1155Holder {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Pending,
        Active,
        Retired,
        Slashed
    }

    struct Slot {
        IPolicySpec spec;
        uint256 active; // circuit id, 0 = none
        uint256 pending; // circuit id, 0 = none
        uint64 pendingEta;
    }

    struct Candidate {
        bytes32 slot;
        address author;
        Status status;
        bool approved;
        bytes32 netlistHash;
        uint256 bond;
        uint256 rewards;
    }

    uint8 public constant HALT = 2;
    uint256 public constant NAND_ID = 0; // ERC-1155 id of the NAND transistor

    ITapeOutProcessor public immutable processor;
    IBeacon public immutable beacon;
    IERC1155 public immutable transistors;
    IERC20 public immutable rewardToken;
    uint256 public immutable bondAmount;
    uint64 public immutable timelock;

    address public pinnedImplementation;
    bytes32[] public slotIds;
    mapping(bytes32 => Slot) public slots;
    mapping(uint256 => Candidate) public candidates;
    uint256 public unallocatedRewards;
    /// @notice Cumulative rewards streamed in by each address. Lets anyone audit public commitments
    /// such as the STEGO creator's 25% of mint proceeds.
    mapping(address => uint256) public notifiedBy;

    event SlotAdded(bytes32 indexed slot, address spec);
    event Proposed(bytes32 indexed slot, uint256 indexed circuitId, address indexed author, uint64 eta);
    event Approved(bytes32 indexed slot, uint256 indexed circuitId);
    event Activated(bytes32 indexed slot, uint256 indexed circuitId, uint256 replaced);
    event Cancelled(bytes32 indexed slot, uint256 indexed circuitId);
    event Slashed(bytes32 indexed slot, uint256 indexed circuitId, address indexed challenger, bytes evidence);
    event Tampered(bytes32 indexed slot, uint256 indexed circuitId);
    event Repinned(address oldImplementation, address newImplementation);
    event BondWithdrawn(uint256 indexed circuitId, address indexed author, uint256 amount);
    event RewardNotified(address indexed from, uint256 amount);
    event RewardClaimed(uint256 indexed circuitId, address indexed author, uint256 amount);

    error UnknownSlot();
    error SlotExists();
    error SlotBusy();
    error NotCircuitOwner();
    error BadPinout(uint32 nIn, uint32 nOut, uint32 nState);
    error AlreadyRegistered();
    error ProbeFailed(uint8 a, uint8 b, uint8 got);
    error NothingPending();
    error NotApproved();
    error TooEarly();
    error NotAuthor();
    error NotChallengeable();
    error NotACounterexample();
    error NotAnOrderedPair();
    error ProcessorUpgraded();
    error NotRetired();
    error NotTampered();

    constructor(
        address owner_,
        ITapeOutProcessor processor_,
        IBeacon beacon_,
        IERC20 rewardToken_,
        uint256 bondAmount_,
        uint64 timelock_
    ) Ownable(owner_) {
        processor = processor_;
        beacon = beacon_;
        pinnedImplementation = beacon_.implementation();
        transistors = IERC1155(processor_.transistors());
        rewardToken = rewardToken_;
        bondAmount = bondAmount_;
        timelock = timelock_;
    }

    // ---------------------------------------------------------------- slots & curation

    /// @notice Slots and their envelopes are append-only: an existing slot's rules can never change.
    function addSlot(bytes32 slot, IPolicySpec spec) external onlyOwner {
        if (address(slots[slot].spec) != address(0)) revert SlotExists();
        slots[slot].spec = spec;
        slotIds.push(slot);
        emit SlotAdded(slot, address(spec));
    }

    function slotCount() external view returns (uint256) {
        return slotIds.length;
    }

    /// @notice The curator chooses which envelope-compliant design goes live. The timelock still applies.
    function approve(uint256 circuitId) external onlyOwner {
        Candidate storage c = candidates[circuitId];
        if (c.status != Status.Pending) revert NothingPending();
        c.approved = true;
        emit Approved(c.slot, circuitId);
    }

    /// @notice True when TapeOut has upgraded the processor implementation since it was pinned.
    function processorUpgraded() public view returns (bool) {
        return beacon.implementation() != pinnedImplementation;
    }

    /// @notice After reviewing a TapeOut upgrade, the curator re-pins to resume normal operation.
    function repin() external onlyOwner {
        address old = pinnedImplementation;
        pinnedImplementation = beacon.implementation();
        emit Repinned(old, pinnedImplementation);
    }

    // ---------------------------------------------------------------- lifecycle

    function propose(bytes32 slot, uint256 circuitId) external nonReentrant {
        if (processorUpgraded()) revert ProcessorUpgraded();
        Slot storage s = slots[slot];
        if (address(s.spec) == address(0)) revert UnknownSlot();
        if (s.pending != 0) revert SlotBusy();
        if (candidates[circuitId].status != Status.None) revert AlreadyRegistered();
        if (processor.ownerOf(circuitId) != msg.sender) revert NotCircuitOwner();

        (uint32 nIn, uint32 nOut, uint32 nState,) = processor.circuitInfo(circuitId);
        if (nIn != 16 || nOut != 2 || nState != 0) revert BadPinout(nIn, nOut, nState);

        bytes memory p = s.spec.probes();
        for (uint256 i = 0; i + 1 < p.length; i += 2) {
            uint8 a = uint8(p[i]);
            uint8 b = uint8(p[i + 1]);
            uint8 got = _evalRaw(circuitId, a, b);
            if (!s.spec.allowed(a, b, got)) revert ProbeFailed(a, b, got);
        }

        transistors.safeTransferFrom(msg.sender, address(this), NAND_ID, bondAmount, "");

        uint64 eta = uint64(block.timestamp) + timelock;
        s.pending = circuitId;
        s.pendingEta = eta;
        candidates[circuitId] = Candidate({
            slot: slot,
            author: msg.sender,
            status: Status.Pending,
            approved: false,
            netlistHash: keccak256(processor.netlist(circuitId)),
            bond: bondAmount,
            rewards: 0
        });
        emit Proposed(slot, circuitId, msg.sender, eta);
    }

    /// @notice Anyone can activate an approved pending circuit once its timelock has passed.
    function activate(bytes32 slot) external {
        Slot storage s = slots[slot];
        uint256 id = s.pending;
        if (id == 0) revert NothingPending();
        if (!candidates[id].approved) revert NotApproved();
        if (block.timestamp < s.pendingEta) revert TooEarly();

        uint256 old = s.active;
        if (old != 0) candidates[old].status = Status.Retired;
        s.active = id;
        s.pending = 0;
        s.pendingEta = 0;
        candidates[id].status = Status.Active;
        emit Activated(slot, id, old);
    }

    /// @notice The author, or the curator (to reject a design), can withdraw a pending proposal.
    function cancel(bytes32 slot) external {
        Slot storage s = slots[slot];
        uint256 id = s.pending;
        if (id == 0) revert NothingPending();
        if (candidates[id].author != msg.sender && msg.sender != owner()) revert NotAuthor();
        s.pending = 0;
        s.pendingEta = 0;
        candidates[id].status = Status.Retired;
        emit Cancelled(slot, id);
    }

    /// @notice Prove the circuit gives an out-of-envelope verdict at one input.
    function challenge(uint256 circuitId, uint8 a, uint8 b) external nonReentrant {
        Candidate storage c = _challengeable(circuitId);
        IPolicySpec spec = slots[c.slot].spec;
        uint8 v = _evalRaw(circuitId, a, b);
        if (spec.allowed(a, b, v)) revert NotACounterexample();
        _slash(c, circuitId, abi.encode(a, b, v));
    }

    /// @notice Prove the circuit gives a softer verdict to a riskier input: (a2, b2) is at least as
    /// risky as (a1, b1) in every direction the envelope defines, yet verdict(a2, b2) < verdict(a1, b1).
    function challengeMonotone(uint256 circuitId, uint8 a1, uint8 b1, uint8 a2, uint8 b2) external nonReentrant {
        Candidate storage c = _challengeable(circuitId);
        (int8 dirA, int8 dirB) = slots[c.slot].spec.riskDirection();
        if (!_riskierOrEqual(dirA, a1, a2) || !_riskierOrEqual(dirB, b1, b2) || (a1 == a2 && b1 == b2)) {
            revert NotAnOrderedPair();
        }
        uint8 v1 = _evalRaw(circuitId, a1, b1);
        uint8 v2 = _evalRaw(circuitId, a2, b2);
        if (v2 >= v1) revert NotACounterexample();
        _slash(c, circuitId, abi.encode(a1, b1, v1, a2, b2, v2));
    }

    /// @notice If the processor ever serves a different netlist for a circuit, anyone can pull it out
    /// of service. The author is not at fault, so the bond stays withdrawable.
    function reportTamper(uint256 circuitId) external {
        Candidate storage c = candidates[circuitId];
        if (c.status != Status.Pending && c.status != Status.Active) revert NotChallengeable();
        if (keccak256(processor.netlist(circuitId)) == c.netlistHash) revert NotTampered();
        _detach(slots[c.slot], circuitId);
        c.status = Status.Retired;
        emit Tampered(c.slot, circuitId);
    }

    function withdrawBond(uint256 circuitId) external nonReentrant {
        Candidate storage c = candidates[circuitId];
        if (c.author != msg.sender) revert NotAuthor();
        if (c.status != Status.Retired) revert NotRetired();
        uint256 bond = c.bond;
        c.bond = 0;
        emit BondWithdrawn(circuitId, msg.sender, bond);
        if (bond != 0) transistors.safeTransferFrom(address(this), msg.sender, NAND_ID, bond, "");
    }

    // ---------------------------------------------------------------- rewards

    /// @notice Vaults (or sponsors) stream rewards here; split evenly across slots with an active circuit.
    function notifyReward(uint256 amount) external nonReentrant {
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        notifiedBy[msg.sender] += amount;
        emit RewardNotified(msg.sender, amount);

        uint256 pot = amount + unallocatedRewards;
        uint256 live;
        for (uint256 i = 0; i < slotIds.length; i++) {
            if (slots[slotIds[i]].active != 0) live++;
        }
        if (live == 0) {
            unallocatedRewards = pot;
            return;
        }
        uint256 share = pot / live;
        for (uint256 i = 0; i < slotIds.length; i++) {
            uint256 id = slots[slotIds[i]].active;
            if (id != 0) candidates[id].rewards += share;
        }
        unallocatedRewards = pot - share * live;
    }

    function claimRewards(uint256 circuitId) external nonReentrant {
        Candidate storage c = candidates[circuitId];
        if (c.author != msg.sender) revert NotAuthor();
        if (c.status == Status.Slashed) revert NotChallengeable();
        uint256 r = c.rewards;
        c.rewards = 0;
        emit RewardClaimed(circuitId, msg.sender, r);
        if (r != 0) rewardToken.safeTransfer(msg.sender, r);
    }

    // ---------------------------------------------------------------- enforcement

    /// @notice Verdict of the slot's active circuit. ok = false when the slot has no active circuit,
    /// eval fails, or TapeOut upgraded the processor since it was pinned; callers decide whether to
    /// fail open or closed.
    function verdict(bytes32 slot, uint8 a, uint8 b) external view returns (uint8 v, bool ok) {
        uint256 id = slots[slot].active;
        if (id == 0 || processorUpgraded()) return (0, false);
        try processor.eval(id, abi.encodePacked(a, b)) returns (bytes memory out) {
            if (out.length == 0) return (0, false);
            return (_norm(uint8(out[0]) & 3), true);
        } catch {
            return (0, false);
        }
    }

    function activeCircuit(bytes32 slot) external view returns (uint256) {
        return slots[slot].active;
    }

    // ---------------------------------------------------------------- internal

    function _challengeable(uint256 circuitId) internal view returns (Candidate storage c) {
        if (processorUpgraded()) revert ProcessorUpgraded();
        c = candidates[circuitId];
        if (c.status != Status.Pending && c.status != Status.Active) revert NotChallengeable();
    }

    function _slash(Candidate storage c, uint256 circuitId, bytes memory evidence) internal {
        _detach(slots[c.slot], circuitId);
        c.status = Status.Slashed;
        uint256 bond = c.bond;
        uint256 rewards = c.rewards;
        c.bond = 0;
        c.rewards = 0;
        emit Slashed(c.slot, circuitId, msg.sender, evidence);

        if (bond != 0) transistors.safeTransferFrom(address(this), msg.sender, NAND_ID, bond, "");
        if (rewards != 0) rewardToken.safeTransfer(msg.sender, rewards);
    }

    /// @dev `to` is at least as risky as `from` along an axis with direction `dir` (0 = must be equal).
    function _riskierOrEqual(int8 dir, uint8 from, uint8 to) internal pure returns (bool) {
        if (dir > 0) return to >= from;
        if (dir < 0) return to <= from;
        return to == from;
    }

    function _evalRaw(uint256 circuitId, uint8 a, uint8 b) internal view returns (uint8) {
        bytes memory out = processor.eval(circuitId, abi.encodePacked(a, b));
        return _norm(uint8(out[0]) & 3);
    }

    function _norm(uint8 v) internal pure returns (uint8) {
        return v >= HALT ? HALT : v;
    }

    function _detach(Slot storage s, uint256 circuitId) internal {
        if (s.active == circuitId) s.active = 0;
        if (s.pending == circuitId) {
            s.pending = 0;
            s.pendingEta = 0;
        }
    }
}
