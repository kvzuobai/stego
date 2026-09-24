// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Safety envelope for a policy slot. It does not fix one exact function: it states what any
/// circuit in the slot must and must never do, so different authors can design genuinely different
/// policies inside it. A circuit is slashable if it breaks the envelope at a single input, or if a
/// riskier input ever gets a softer verdict (monotonicity).
/// Pin interface: input byte0 = A, byte1 = B; output pin0 + 2*pin1 = verdict (0 ALLOW, 1 THROTTLE, 2 HALT).
interface IPolicySpec {
    function name() external pure returns (string memory);
    /// @notice Whether verdict `v` (0..2) is acceptable at input (a, b).
    function allowed(uint8 a, uint8 b, uint8 v) external pure returns (bool);
    /// @notice Direction in which each input makes things riskier: +1 higher is riskier, -1 lower is
    /// riskier, 0 no monotonicity requirement on that input.
    function riskDirection() external pure returns (int8 dirA, int8 dirB);
    /// @notice Inputs checked when a circuit is proposed, packed as (a, b) byte pairs.
    function probes() external pure returns (bytes memory);
}
