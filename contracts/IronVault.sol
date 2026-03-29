// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IronToken.sol";

/**
 * @title IronVault
 * @notice Yield vault where depositors receive pro-rata shares that appreciate
 *         as protocol revenues and fee income accumulate inside the vault.
 * @dev Share accounting follows a simple ratio model: each share represents a
 *      proportional claim on the vault's total token balance. A withdrawal fee
 *      (expressed in basis points) is retained in the vault on every exit,
 *      compounding value for remaining shareholders.
 *      Inspired by ERC-4626 but implemented without the full interface overhead.
 */
contract IronVault {
    IronToken public immutable asset;
    string public constant name = "Iron Vault Shares";
    string public constant symbol = "ivIRON";
    uint8 public constant decimals = 18;

    uint256 public totalShares;
    mapping(address => uint256) public shares;

    address public owner;
    uint256 public withdrawalFee; // in bps (e.g., 50 = 0.5%)

    event Deposited(address indexed user, uint256 assets, uint256 sharesMinted);
    event Withdrawn(address indexed user, uint256 assets, uint256 sharesBurned);

    constructor(address _asset) {
        asset = IronToken(_asset);
        owner = msg.sender;
        withdrawalFee = 50; // 0.5%
    }

    // ═══════════════════════════════════════════════════════════════
    // CORE VAULT
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Total assets currently held by the vault.
     * @dev Returns the vault's live token balance, which includes deposited
     *      principal and any yield or fee revenue that has accumulated.
     */
    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function getPricePerShare() public view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (totalAssets() * 1e18) / totalShares;
    }

    function deposit(uint256 amount) external returns (uint256 mintedShares) {
        uint256 totalBefore = totalAssets();

        asset.transferFrom(msg.sender, address(this), amount);

        if (totalShares == 0 || totalBefore == 0) {
            mintedShares = amount;
        } else {
            mintedShares = (amount * totalShares) / totalBefore;
        }

        require(mintedShares > 0, "Vault: zero shares");

        shares[msg.sender] += mintedShares;
        totalShares += mintedShares;

        emit Deposited(msg.sender, amount, mintedShares);
    }

    function withdraw(uint256 shareAmount) external returns (uint256 assets) {
        require(shares[msg.sender] >= shareAmount, "Vault: insufficient shares");

        assets = (shareAmount * totalAssets()) / totalShares;

        // Apply withdrawal fee
        uint256 fee = (assets * withdrawalFee) / 10000;
        uint256 netAssets = assets - fee;

        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;

        asset.transfer(msg.sender, netAssets);
        // Fee stays in vault → benefits remaining shareholders

        emit Withdrawn(msg.sender, netAssets, shareAmount);
    }

    // ═══════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════

    function getUserBalance(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares[user] * totalAssets()) / totalShares;
    }

    function previewDeposit(uint256 amount) external view returns (uint256) {
        if (totalShares == 0) return amount;
        return (amount * totalShares) / totalAssets();
    }

    function previewWithdraw(uint256 shareAmount) external view returns (uint256) {
        if (totalShares == 0) return 0;
        uint256 assets = (shareAmount * totalAssets()) / totalShares;
        uint256 fee = (assets * withdrawalFee) / 10000;
        return assets - fee;
    }
}
