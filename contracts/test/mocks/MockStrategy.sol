// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

/// @notice Strategy whose value can be marked up or down to simulate profit and loss.
contract MockStrategy is IStrategy {
    IERC20 internal immutable _asset;
    address public immutable vault;

    constructor(IERC20 asset_, address vault_) {
        _asset = asset_;
        vault = vault_;
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    function totalAssets() external view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    function deposit(uint256 amount) external {
        require(msg.sender == vault, "vault");
        _asset.transferFrom(vault, address(this), amount);
    }

    function withdraw(uint256 amount) external {
        require(msg.sender == vault, "vault");
        _asset.transfer(vault, amount);
    }

    /// @dev Test hook: lose `amount` of assets.
    function loss(uint256 amount, address sink) external {
        _asset.transfer(sink, amount);
    }
}
