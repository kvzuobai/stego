// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal strategy adapter an StegoVault can deploy idle assets into.
interface IStrategy {
    function asset() external view returns (address);
    function vault() external view returns (address);
    function totalAssets() external view returns (uint256);
    /// @dev Pulls `amount` of asset from the vault (vault approves first).
    function deposit(uint256 amount) external;
    /// @dev Sends `amount` of asset back to the vault.
    function withdraw(uint256 amount) external;
}
