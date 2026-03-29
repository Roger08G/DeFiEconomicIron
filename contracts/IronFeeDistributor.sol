// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IronToken.sol";

/**
 * @title IronFeeDistributor
 * @notice Distributes protocol fee revenue proportionally to registered
 *         recipients. Each recipient carries a weight that determines their
 *         pro-rata share of every distribution round.
 * @dev Recipients are stored in a dynamic array managed by the owner.
 *      Weights can be updated by removing and re-adding a recipient.
 *      Integer-division remainders (dust) are tracked in {accumulatedDust}
 *      for transparency and potential future governance action.
 *      The {distribute} function is permissionless — anyone may trigger it.
 */
contract IronFeeDistributor {
    IronToken public feeToken;
    address public owner;

    struct Recipient {
        address addr;
        uint256 weight;
    }

    Recipient[] public recipients;
    uint256 public totalWeight;
    uint256 public totalDistributed;
    uint256 public distributionCount;

    // Track how much each recipient has received
    mapping(address => uint256) public totalReceived;

    // Accumulated undistributed dust
    uint256 public accumulatedDust;

    event RecipientAdded(address indexed recipient, uint256 weight);
    event RecipientRemoved(address indexed recipient);
    event Distributed(uint256 amount, uint256 recipientCount, uint256 dustLost);
    event FeesCollected(uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Distributor: not owner");
        _;
    }

    constructor(address _feeToken) {
        feeToken = IronToken(_feeToken);
        owner = msg.sender;
    }

    // ═══════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════

    function addRecipient(address addr, uint256 weight) external onlyOwner {
        require(weight > 0, "Distributor: zero weight");
        recipients.push(Recipient({addr: addr, weight: weight}));
        totalWeight += weight;
        emit RecipientAdded(addr, weight);
    }

    function removeRecipient(uint256 index) external onlyOwner {
        require(index < recipients.length, "Distributor: invalid index");
        totalWeight -= recipients[index].weight;
        emit RecipientRemoved(recipients[index].addr);

        // Swap and pop
        recipients[index] = recipients[recipients.length - 1];
        recipients.pop();
    }

    // ═══════════════════════════════════════════════════════════════
    // FEE COLLECTION
    // ═══════════════════════════════════════════════════════════════

    function collectFees(uint256 amount) external {
        feeToken.transferFrom(msg.sender, address(this), amount);
        emit FeesCollected(amount);
    }

    // ═══════════════════════════════════════════════════════════════
    // DISTRIBUTION
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Distribute the contract's full fee balance to all recipients
     *         in proportion to their registered weights.
     * @dev Permissionless — anyone may call this function.
     *      Integer division is applied per recipient; any remainder (dust)
     *      remains in the contract and is reflected in {accumulatedDust}.
     */
    function distribute() external {
        uint256 balance = feeToken.balanceOf(address(this));
        require(balance > 0, "Distributor: nothing to distribute");
        require(recipients.length > 0, "Distributor: no recipients");
        require(totalWeight > 0, "Distributor: zero total weight");

        uint256 totalSent = 0;

        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 share = (balance * recipients[i].weight) / totalWeight;

            if (share > 0) {
                feeToken.transfer(recipients[i].addr, share);
                totalReceived[recipients[i].addr] += share;
                totalSent += share;
            }
        }

        // Dust = what couldn't be distributed due to rounding
        uint256 dust = balance - totalSent;
        accumulatedDust += dust;

        totalDistributed += totalSent;
        distributionCount += 1;

        emit Distributed(totalSent, recipients.length, dust);
    }

    // ═══════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════

    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }

    function pendingDistribution() external view returns (uint256) {
        return feeToken.balanceOf(address(this));
    }

    function getRecipientShare(uint256 index) external view returns (address, uint256, uint256) {
        Recipient storage r = recipients[index];
        return (r.addr, r.weight, (10000 * r.weight) / totalWeight); // share in bps
    }

    /**
     * @notice Calculate total rounding loss over all distributions.
     */
    function totalRoundingLoss() external view returns (uint256) {
        return accumulatedDust;
    }
}
