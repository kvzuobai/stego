// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPolicySpec} from "../interfaces/IPolicySpec.sol";

// Solidity mirrors of ENVELOPES in circuits/policies.mjs. Envelopes are constants: a slot's rules never change.

uint8 constant ALLOW = 0;
uint8 constant THROTTLE = 1;
uint8 constant HALT = 2;

/// A = withdrawn this epoch, B = this request; both in epochStartAssets/256 units. s = A + B.
contract WithdrawEnvelopeV1 is IPolicySpec {
    function name() external pure returns (string memory) {
        return "WITHDRAW_ENVELOPE_V1";
    }

    function allowed(uint8 a, uint8 b, uint8 v) public pure returns (bool) {
        uint256 s = uint256(a) + b;
        if (s <= 12 && v != ALLOW) return false; // small exits (<= ~4.7%) never blocked or charged
        if (s <= 38 && v == HALT) return false; // exits up to ~15% never refused
        if (s > 64 && v == ALLOW) return false; // above ~25% there must be a brake
        return true;
    }

    function riskDirection() external pure returns (int8, int8) {
        return (1, 1);
    }

    function probes() external pure returns (bytes memory) {
        return hex"0000" hex"0c00" hex"060c" hex"2600" hex"1313" hex"4100" hex"2121" hex"ffff" hex"80ff";
    }
}

/// A = share price now, B = at epoch start; both as fraction of high-water mark, 255 = at HWM.
contract DrawdownEnvelopeV1 is IPolicySpec {
    function name() external pure returns (string memory) {
        return "DRAWDOWN_ENVELOPE_V1";
    }

    function allowed(uint8 a, uint8 b, uint8 v) public pure returns (bool) {
        uint256 drop = b > a ? uint256(b) - a : 0;
        if (a >= 250 && drop <= 2 && v != ALLOW) return false; // no false alarms near the HWM
        if (a < 230 && v == ALLOW) return false; // > ~10% drawdown needs a brake
        if (a < 204 && v != HALT) return false; // > ~20% drawdown must stop deposits
        return true;
    }

    function riskDirection() external pure returns (int8, int8) {
        return (-1, 1);
    }

    function probes() external pure returns (bytes memory) {
        return hex"ffff" hex"fafc" hex"e5e5" hex"cbcb" hex"0000" hex"e6ff";
    }
}

/// A = deployed share after the move, B = before; 0..255 = 0..100% of vault assets.
contract AllocationEnvelopeV1 is IPolicySpec {
    function name() external pure returns (string memory) {
        return "ALLOCATION_ENVELOPE_V1";
    }

    function allowed(uint8 a, uint8 b, uint8 v) public pure returns (bool) {
        uint256 d = a > b ? uint256(a) - b : uint256(b) - a;
        if (a > 230 && v != HALT) return false; // never deploy > ~90%
        if (d > 51 && v != HALT) return false; // never move > ~20% of TVL at once
        if (a <= 128 && d <= 13 && v != ALLOW) return false; // small moves under 50% always allowed
        return true;
    }

    function riskDirection() external pure returns (int8, int8) {
        return (0, 0);
    }

    function probes() external pure returns (bytes memory) {
        return hex"0000" hex"0d00" hex"8075" hex"e7e7" hex"4000" hex"ffff" hex"0040";
    }
}
