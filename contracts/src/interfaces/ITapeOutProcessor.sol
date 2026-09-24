// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Subset of the TapeOut processor ("circuits" contract) cloned by the TapeOut factory.
/// ABI taken from the tapeout.net frontend; eval() verified callable from contracts on X Layer.
interface ITapeOutProcessor {
    function eval(uint256 circuitId, bytes calldata input) external view returns (bytes memory);
    function circuitInfo(uint256 circuitId)
        external
        view
        returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount);
    function netlist(uint256 circuitId) external view returns (bytes memory);
    function ownerOf(uint256 circuitId) external view returns (address);
    function transistors() external view returns (address);
}
