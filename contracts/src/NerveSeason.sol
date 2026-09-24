// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

import {ITapeOutProcessor} from "./interfaces/ITapeOutProcessor.sol";
import {IPolicySpec} from "./interfaces/IPolicySpec.sol";

interface ITicketTransistors is IERC1155 {
    function mint(uint256 id, uint256 amount) external payable;
    function mintPrice() external view returns (uint256);
}

interface IProtocolFee {
    function protocolFee() external view returns (uint256);
}

/// @title NerveSeason
/// @notice A bank-run game whose exit rule is a TapeOut circuit.
///
/// Players join with a small OKB deposit; joining mints and burns a STEGO ticket in the same
/// transaction. Anyone may leave before the season ends, but the circuit decides the price of leaving:
///   ALLOW    -> pays the base "nerve tax"
///   THROTTLE -> a rush is on: pays the higher throttle fee
///   HALT     -> today's exit budget is used up; try again tomorrow
/// Every fee goes into the pot. When the season ends, everyone still in gets their deposit back
/// plus a share of the pot weighted by OKB x time committed (points = amount x seconds left until the
/// season ends, at the moment of joining), so early joiners earn more; a cut goes to the owner of the
/// exit-rule circuit. Leaving early removes points in proportion to the amount taken out.
///
/// STEGO Boost: while joins are open, a player can burn STEGO (minted and burned in the same
/// transaction) to raise their pot weight by +5% per 10 STEGO, up to +50%.
/// Designer seasons: the exit-rule circuit can be any community design on the processor; if an
/// envelope is given, the constructor refuses circuits that break it at the envelope's probe inputs,
/// and the circuit's NFT owner collects the designer cut.
///
/// No owner, no admin, no way for anyone to take players' funds. Parameters are immutable.
contract NerveSeason is ReentrancyGuard, ERC1155Holder {
    uint8 public constant ALLOW = 0;
    uint8 public constant THROTTLE = 1;
    uint8 public constant HALT = 2;
    uint256 public constant BPS = 10_000;
    uint256 public constant DAY = 1 days;
    uint256 public constant NAND_ID = 0;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ITapeOutProcessor public immutable processor;
    ITicketTransistors public immutable transistors;
    IProtocolFee public immutable factory;
    IBeacon public immutable beacon;
    address public immutable pinnedImplementation;
    uint256 public immutable circuitId;

    uint256 public immutable ticketTransistors;
    uint64 public immutable joinDeadline;
    uint64 public immutable seasonEnd;
    uint256 public immutable minDeposit;
    uint256 public immutable maxPerWallet;
    uint256 public immutable seasonCap;
    uint256 public immutable baseFeeBps;
    uint256 public immutable throttleFeeBps;
    uint256 public immutable designerCutBps;
    IPolicySpec public immutable envelope; // safety envelope the exit rule was checked against (0 = none)

    uint256 public constant BOOST_UNIT_TRANSISTORS = 10;
    uint256 public constant BOOST_STEP_BPS = 500; // +5% pot weight per unit
    uint256 public constant MAX_BOOST_BPS = 5000; // at most +50%

    /// @notice Human-readable season name, e.g. "Stego Nerve - Season 1".
    string public name;

    mapping(address => uint256) public principal;
    mapping(address => bool) public hasTicket;
    uint256 public totalPrincipal;
    mapping(address => uint256) public points; // OKB x seconds committed until seasonEnd
    uint256 public totalPoints;
    uint256 public pot;
    uint256 public players; // wallets that ever joined
    uint256 public activePlayers; // wallets with principal > 0
    uint256 public ticketsBurned; // STEGO burned as tickets
    uint256 public boostBurned; // STEGO burned as boosts
    mapping(address => uint256) public boostBps;

    uint64 public day;
    uint256 public dayStartPrincipal;
    uint256 public dayOutflow;

    bool public settled;
    uint256 public finalPrincipal;
    uint256 public finalPoints;
    uint256 public finalPot;
    uint256 public designerOwed;

    struct Params {
        string name;
        ITapeOutProcessor processor;
        IProtocolFee factory;
        IBeacon beacon;
        uint256 circuitId;
        uint256 ticketTransistors;
        uint64 joinDeadline;
        uint64 seasonEnd;
        uint256 minDeposit;
        uint256 maxPerWallet;
        uint256 seasonCap;
        uint256 baseFeeBps;
        uint256 throttleFeeBps;
        uint256 designerCutBps;
        IPolicySpec envelope;
    }

    event Joined(address indexed player, uint256 amount, uint256 ticketCost, bool newPlayer);
    event Exited(address indexed player, uint256 amount, uint256 fee, uint8 verdict, uint8 a, uint8 b);
    event Funded(address indexed from, uint256 amount);
    event Settled(uint256 finalPrincipal, uint256 finalPot, uint256 designerCut, address designer);
    event Claimed(address indexed player, uint256 principal, uint256 share);
    event DesignerPaid(address indexed designer, uint256 amount);
    event Boosted(address indexed player, uint256 units, uint256 newBoostBps, uint256 cost);

    error JoinClosed();
    error SeasonOver();
    error SeasonNotOver();
    error TooSmall();
    error WalletCap();
    error SeasonFull();
    error BadAmount();
    error ExitHalted(uint8 a, uint8 b);
    error NothingToClaim();
    error NotDesigner();
    error TransferFailed();
    error BadParams();
    error BadRule(uint8 a, uint8 b, uint8 verdict);
    error NotPlaying();
    error BoostCap();
    error WrongValue(uint256 sent, uint256 need);

    constructor(Params memory p) {
        (uint32 nIn, uint32 nOut, uint32 nState,) = p.processor.circuitInfo(p.circuitId);
        if (
            nIn != 16 || nOut != 2 || nState != 0 || p.joinDeadline > p.seasonEnd || p.seasonEnd <= block.timestamp
                || p.baseFeeBps > p.throttleFeeBps || p.throttleFeeBps > 2_000 || p.designerCutBps > 2_000
                || p.minDeposit == 0 || p.maxPerWallet < p.minDeposit || p.seasonCap < p.maxPerWallet
        ) revert BadParams();

        if (address(p.envelope) != address(0)) {
            bytes memory probes = p.envelope.probes();
            for (uint256 i = 0; i + 1 < probes.length; i += 2) {
                uint8 a = uint8(probes[i]);
                uint8 b = uint8(probes[i + 1]);
                uint8 v = uint8(p.processor.eval(p.circuitId, abi.encodePacked(a, b))[0]) & 3;
                if (v > HALT) v = HALT;
                if (!p.envelope.allowed(a, b, v)) revert BadRule(a, b, v);
            }
        }
        envelope = p.envelope;
        name = p.name;
        processor = p.processor;
        transistors = ITicketTransistors(p.processor.transistors());
        factory = p.factory;
        beacon = p.beacon;
        pinnedImplementation = p.beacon.implementation();
        circuitId = p.circuitId;
        ticketTransistors = p.ticketTransistors;
        joinDeadline = p.joinDeadline;
        seasonEnd = p.seasonEnd;
        minDeposit = p.minDeposit;
        maxPerWallet = p.maxPerWallet;
        seasonCap = p.seasonCap;
        baseFeeBps = p.baseFeeBps;
        throttleFeeBps = p.throttleFeeBps;
        designerCutBps = p.designerCutBps;
    }

    // ================================================================ views

    /// @notice OKB needed on top of the deposit for a first-time player's STEGO ticket.
    function ticketCost() public view returns (uint256) {
        if (ticketTransistors == 0) return 0;
        return transistors.mintPrice() * ticketTransistors + factory.protocolFee();
    }

    /// @notice What leaving with `amount` would cost right now, and why.
    function exitQuote(uint256 amount) public view returns (uint8 v, uint256 fee, uint8 a, uint8 b) {
        (uint256 start, uint256 out) = _dayView();
        if (start == 0) return (ALLOW, _fee(amount, baseFeeBps), 0, 0);
        a = _q(out, start, false);
        b = _q(amount, start, true);
        v = _verdict(a, b);
        if (v >= HALT) return (HALT, 0, a, b);
        fee = _fee(amount, v == THROTTLE ? throttleFeeBps : baseFeeBps);
    }

    /// @notice Largest amount `player` can take out right now without a HALT.
    function maxExit(address player) external view returns (uint256) {
        uint256 bal = principal[player];
        (uint256 start, uint256 out) = _dayView();
        if (start == 0 || bal == 0) return bal;
        uint8 a = _q(out, start, false);
        if (_verdict(a, 0) >= HALT) return 0;
        uint256 lo = 0;
        uint256 hi = 255;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (_verdict(a, uint8(mid)) < HALT) lo = mid;
            else hi = mid - 1;
        }
        if (lo == 255) return bal;
        uint256 cap = lo * start / 256;
        return cap < bal ? cap : bal;
    }

    /// @notice True when TapeOut has upgraded its processor code since this season started.
    function processorUpgraded() public view returns (bool) {
        return beacon.implementation() != pinnedImplementation;
    }

    /// @notice What a player would receive if the season settled with the current numbers.
    function projectedPayout(address player) external view returns (uint256 principal_, uint256 share) {
        principal_ = principal[player];
        if (settled) return (principal_, finalPoints == 0 ? 0 : finalPot * points[player] / finalPoints);
        if (totalPoints == 0) return (principal_, 0);
        share = _potAfterCut() * points[player] / totalPoints;
    }

    /// @notice What depositing `amount` now would return if everyone currently in stays to the end:
    /// the pot share it would earn and the ticket it would cost `player` (0 if they already have one).
    function joinQuote(address player, uint256 amount) external view returns (uint256 share, uint256 ticket) {
        ticket = hasTicket[player] ? 0 : ticketCost();
        if (block.timestamp >= joinDeadline || amount == 0) return (0, ticket);
        uint256 pts = amount * (seasonEnd - block.timestamp) * (BPS + boostBps[player]) / BPS;
        uint256 mine = points[player] + pts;
        share = _potAfterCut() * mine / (totalPoints + pts) - (totalPoints == 0 ? 0 : _potAfterCut() * points[player] / totalPoints);
    }

    /// @notice OKB cost of `units` boost units (10 STEGO each), minted and burned in one transaction.
    function boostCost(uint256 units) public view returns (uint256) {
        return transistors.mintPrice() * units * BOOST_UNIT_TRANSISTORS + factory.protocolFee();
    }

    /// @notice Extra pot share `units` more boost would give `player` if everyone stays, and its cost.
    function boostQuote(address player, uint256 units) external view returns (uint256 extraShare, uint256 cost) {
        cost = boostCost(units);
        uint256 old = boostBps[player];
        if (units == 0 || old + units * BOOST_STEP_BPS > MAX_BOOST_BPS || points[player] == 0) return (0, cost);
        uint256 extra = points[player] * (units * BOOST_STEP_BPS) / (BPS + old);
        uint256 pc = _potAfterCut();
        extraShare = pc * (points[player] + extra) / (totalPoints + extra) - pc * points[player] / totalPoints;
    }

    function _potAfterCut() internal view returns (uint256) {
        return pot - pot * designerCutBps / BPS;
    }

    // ================================================================ play

    function join() external payable nonReentrant {
        if (block.timestamp >= joinDeadline) revert JoinClosed();
        _roll();

        uint256 amount = msg.value;
        uint256 cost;
        bool newPlayer = !hasTicket[msg.sender];
        if (newPlayer) {
            cost = ticketCost();
            if (amount <= cost) revert TooSmall();
            amount -= cost;
            hasTicket[msg.sender] = true;
            players++;
            if (ticketTransistors != 0) {
                transistors.mint{value: cost}(NAND_ID, ticketTransistors);
                transistors.safeTransferFrom(address(this), DEAD, NAND_ID, ticketTransistors, "");
                ticketsBurned += ticketTransistors;
            }
        }
        if (principal[msg.sender] == 0 && amount < minDeposit) revert TooSmall();
        if (principal[msg.sender] + amount > maxPerWallet) revert WalletCap();
        if (totalPrincipal + amount > seasonCap) revert SeasonFull();

        if (principal[msg.sender] == 0) activePlayers++;
        principal[msg.sender] += amount;
        totalPrincipal += amount;
        uint256 pts = amount * (seasonEnd - block.timestamp) * (BPS + boostBps[msg.sender]) / BPS;
        points[msg.sender] += pts;
        totalPoints += pts;
        emit Joined(msg.sender, amount, cost, newPlayer);
    }

    /// @notice Burn STEGO to raise your pot weight: +5% per unit (10 STEGO), up to +50%. Joins must be open.
    function boost(uint256 units) external payable nonReentrant {
        if (block.timestamp >= joinDeadline) revert JoinClosed();
        if (principal[msg.sender] == 0) revert NotPlaying();
        uint256 old = boostBps[msg.sender];
        uint256 add = units * BOOST_STEP_BPS;
        if (units == 0 || old + add > MAX_BOOST_BPS) revert BoostCap();
        uint256 cost = boostCost(units);
        if (msg.value != cost) revert WrongValue(msg.value, cost);

        uint256 n = units * BOOST_UNIT_TRANSISTORS;
        transistors.mint{value: cost}(NAND_ID, n);
        transistors.safeTransferFrom(address(this), DEAD, NAND_ID, n, "");
        boostBurned += n;

        uint256 extra = points[msg.sender] * add / (BPS + old);
        points[msg.sender] += extra;
        totalPoints += extra;
        boostBps[msg.sender] = old + add;
        emit Boosted(msg.sender, units, old + add, cost);
    }

    function exit(uint256 amount) external nonReentrant {
        if (block.timestamp >= seasonEnd) revert SeasonOver();
        uint256 bal = principal[msg.sender];
        if (amount == 0 || amount > bal) revert BadAmount();
        _roll();

        (uint8 v, uint256 fee, uint8 a, uint8 b) = exitQuote(amount);
        if (v >= HALT) revert ExitHalted(a, b);

        principal[msg.sender] = bal - amount;
        totalPrincipal -= amount;
        uint256 removed = bal == amount ? points[msg.sender] : points[msg.sender] * amount / bal;
        points[msg.sender] -= removed;
        totalPoints -= removed;
        if (bal == amount) activePlayers--;
        dayOutflow += amount;
        pot += fee;
        emit Exited(msg.sender, amount, fee, v, a, b);
        _send(msg.sender, amount - fee);
    }

    /// @notice Anyone can add to the pot before the season ends (e.g. the creator's 25% commitment).
    function fund() external payable {
        if (block.timestamp >= seasonEnd) revert SeasonOver();
        pot += msg.value;
        emit Funded(msg.sender, msg.value);
    }

    // ================================================================ end of season

    function settle() public {
        if (block.timestamp < seasonEnd) revert SeasonNotOver();
        if (settled) return;
        settled = true;
        uint256 cut = totalPrincipal == 0 ? pot : pot * designerCutBps / BPS;
        designerOwed = cut;
        finalPot = pot - cut;
        finalPrincipal = totalPrincipal;
        finalPoints = totalPoints;
        emit Settled(finalPrincipal, finalPot, cut, processor.ownerOf(circuitId));
    }

    function claim() external nonReentrant {
        settle();
        uint256 amount = principal[msg.sender];
        if (amount == 0) revert NothingToClaim();
        uint256 share = finalPot * points[msg.sender] / finalPoints;
        principal[msg.sender] = 0;
        points[msg.sender] = 0;
        emit Claimed(msg.sender, amount, share);
        _send(msg.sender, amount + share);
    }

    /// @notice The owner of the exit-rule circuit NFT collects the designer cut.
    function claimDesigner() external nonReentrant {
        settle();
        if (processor.ownerOf(circuitId) != msg.sender) revert NotDesigner();
        uint256 amount = designerOwed;
        designerOwed = 0;
        emit DesignerPaid(msg.sender, amount);
        _send(msg.sender, amount);
    }

    // ================================================================ internal

    /// @dev Circuit verdict. Fails open (ALLOW) if TapeOut upgraded its code or eval fails, so players
    /// can never be trapped by something outside this contract.
    function _verdict(uint8 a, uint8 b) internal view returns (uint8) {
        if (processorUpgraded()) return ALLOW;
        try processor.eval(circuitId, abi.encodePacked(a, b)) returns (bytes memory out) {
            if (out.length == 0) return ALLOW;
            uint8 v = uint8(out[0]) & 3;
            return v >= HALT ? HALT : v;
        } catch {
            return ALLOW;
        }
    }

    /// @dev Exit budget base: the larger of today's opening pool and the current pool, so deposits
    /// made earlier today count too (otherwise day-one players would face a near-zero base).
    function _dayView() internal view returns (uint256 start, uint256 out) {
        if (uint64(block.timestamp / DAY) != day) return (totalPrincipal, 0);
        start = dayStartPrincipal > totalPrincipal ? dayStartPrincipal : totalPrincipal;
        out = dayOutflow;
    }

    function _roll() internal {
        uint64 d = uint64(block.timestamp / DAY);
        if (d != day) {
            day = d;
            dayStartPrincipal = totalPrincipal;
            dayOutflow = 0;
        }
    }

    function _q(uint256 x, uint256 unit, bool up) internal pure returns (uint8) {
        uint256 q = x * 256 / unit;
        if (up && q * unit < x * 256) q++;
        return q > 255 ? 255 : uint8(q);
    }

    function _fee(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * bps + BPS - 1) / BPS;
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
