# IronForge Protocol — Lending Market & Fee Distribution

> **Benchmark ID**: `defi_economic_invariant_7`  
> **nSLOC**: ~770  
> **Contracts**: 5  
> **Planted Vulnerabilities**: 5 (1 Critical, 3 High, 1 Medium)  
> **Chain**: Ethereum Mainnet (simulated)

---

## 1. Protocol Overview

**IronForge** is a lending-and-yield protocol with variable interest rate markets, auto-compounding vaults susceptible to donation attacks, and a multi-recipient fee distributor. Users deposit assets to earn yield in vaults, borrow against collateral with a kinked interest rate curve, stake tokens for admin-configurable streaming rewards, and participate in proportional protocol fee distribution.

The protocol is designed so that:
- Users **deposit** tokens into `IronVault` which tracks assets via `balanceOf(address(this))`
- Users **borrow** against collateral via `IronLendingMarket` with a kinked interest curve
- Interest rates follow a **jump-rate model**: low slope below 80% utilization, 60x steeper above
- Users **stake** IRON tokens in `IronStaking` for streaming reward distribution
- Protocol fees are **distributed** proportionally to N recipients via `IronFeeDistributor`
- Standard ERC20 (`IronToken`) is used throughout with classic `approve()` pattern

The protocol's simplicity is deceptive — each component has a subtle economic vulnerability that requires specific detection capabilities.

---

## 2. Architecture

```
                    ┌────────────────────────────────────┐
                    │          User / Frontend            │
                    └───┬──────────┬──────────┬──────────┘
                        │          │          │
           ┌────────────▼──────┐   │   ┌──────▼──────────────┐
           │    IronVault      │   │   │  IronLendingMarket  │
           │  (yield vault     │   │   │  (variable-rate     │
           │   uses balanceOf) │   │   │   lending + kink)   │
           └────────┬──────────┘   │   └──────┬──────────────┘
                    │              │           │
                    │         ┌────▼────────┐  │
                    │         │ IronStaking  │  │
                    │         │ (rewards w/  │  │
                    │         │  rate change)│  │
                    │         └─────────────┘   │
                    │                           │
           ┌────────▼───────────────────────────▼──┐
           │         IronFeeDistributor            │
           │  (multi-recipient proportional fees)  │
           └───────────────────────────────────────┘

                    ┌──────────────┐
                    │  IronToken   │
                    │ (IRON ERC20) │
                    └──────────────┘
```

---

## 3. Contracts

| Contract | File | nSLOC | Description |
|----------|------|-------|-------------|
| `IronToken` | `IronToken.sol` | ~70 | ERC20 with owner mint/burn, classic `approve()` without increaseAllowance |
| `IronVault` | `IronVault.sol` | ~180 | Yield vault using `token.balanceOf(address(this))` for `totalAssets()` |
| `IronLendingMarket` | `IronLendingMarket.sol` | ~220 | Variable-rate lending with 80% utilization kink (5% → 305% APR jump) |
| `IronStaking` | `IronStaking.sol` | ~160 | Synthetix-style staking with admin-changeable `rewardRate` |
| `IronFeeDistributor` | `IronFeeDistributor.sol` | ~140 | Proportional fee distribution to N weighted recipients |

**Total nSLOC**: ~770

---

## 4. Scope & Focus

All 5 contracts are in scope. This benchmark tests detection of **common but impactful DeFi patterns** that are frequently missed:
- Vault share price manipulation via donation (distinct from first-depositor attacks)
- Interest rate kink exploitation by manipulating utilization
- Reward settlement gaps when admin parameters change
- Cumulative rounding loss in proportional distribution
- Classic ERC20 approval front-running

Out of scope: Gas optimization, code style, informational findings.

---

## 5. Known Vulnerabilities (Post-Audit Disclosure)

The following 5 vulnerabilities were confirmed during the audit. They are disclosed here for educational purposes.

---

### V-01: Donation Attack on Active Vault — Share Price Inflation via Direct Transfer

| Field | Value |
|-------|-------|
| **Severity** | Critical |
| **Impact** | Direct Fund Loss — subsequent depositors receive fewer shares |
| **Likelihood** | High (single-transaction, no prerequisites) |
| **File** | `IronVault.sol` |
| **Location** | `totalAssets()` reads `token.balanceOf(address(this))`; `deposit()` uses this for share calculation |
| **Difficulty** | Medium |

**Description**: Unlike the classic first-depositor inflation attack (tested in BM1 on empty vaults), this vulnerability works on a vault that **already has active depositors**. The attacker directly transfers tokens to the vault contract via `token.transfer(vault, amount)` — bypassing `deposit()`. Since `totalAssets()` reads `token.balanceOf(address(this))`, the donated tokens inflate the total assets without minting new shares.

This raises the share price, meaning subsequent depositors receive drastically fewer shares per token. The attacker, who holds pre-existing shares, can then redeem at the inflated share price — effectively capturing a portion of every subsequent deposit.

**Exploit Path**:
1. Vault has 10,000 IRON and 10,000 shares (price = 1:1)
2. Attacker holds 1,000 shares (from prior deposit)
3. Attacker calls `IronToken.transfer(vault, 90,000 IRON)` → vault now has 100,000 IRON
4. Share price jumps to 10 IRON per share
5. Victim deposits 9,999 IRON → `convertToShares = 9999 * 10000 / 100000 = 999` shares (lost ~1 IRON to rounding)
6. At extreme ratios: victim deposits 9 IRON → `9 * 10000 / 100000 = 0` shares → total loss
7. Attacker redeems 1,000 shares → receives 10,000 IRON (including portion of victim's deposit)

**Key Difference from BM1**: BM1's first-depositor attack requires an empty vault. This attacks an active vault with existing depositors, making it more practical in production.

**Recommendation**: Use an internal `_totalAssets` tracker updated only during `deposit()` and `withdraw()`, not `balanceOf()`. Or implement virtual shares/assets offset per EIP-4626.

---

### V-02: Interest Rate Kink Jump Exploitation

| Field | Value |
|-------|-------|
| **Severity** | High |
| **Impact** | Indirect Fund Loss — existing borrowers forced to pay 60x higher interest |
| **Likelihood** | Medium (requires capital and understanding of the rate model) |
| **File** | `IronLendingMarket.sol` |
| **Location** | `getInterestRate()` — 80% kink threshold, 300% jump multiplier |
| **Difficulty** | Medium |

**Description**: The lending market uses a kinked interest rate model:
- Below 80% utilization: base rate = 5% APR (gentle slope)
- Above 80% utilization: rate = 5% + 300% × (util - 0.8) / 0.2 → up to **305% APR**

An attacker who is simultaneously a lender and borrower can manipulate the utilization rate to force all other borrowers into the high-rate regime, then profit from the interest rate spread as a lender.

**Exploit Path**:
1. Market has 1M IRON deposited, 600K borrowed (60% utilization, 5% APR)
2. Attacker deposits 500K IRON → market now has 1.5M deposited
3. Utilization drops to 40% → rate stays low → other users borrow more
4. Market grows to 1.5M deposited, 1.1M borrowed (73% utilization)
5. Attacker withdraws their 500K deposit → market: 1M deposited, 1.1M borrowed
6. Utilization jumps to **110%** (above kink) → rate spikes to ~305% APR
7. All existing borrowers now pay 60x more interest
8. Attacker's lending position (on another address) earns the inflated interest
9. Attacker repays their own borrow (cost = 1 block of high interest)

**Recommendation**: Implement interest rate smoothing (e.g., TWAP of utilization over N blocks), or cap the maximum interest rate, or require accrual before any parameter-changing operation.

---

### V-03: Reward Rate Change Without Pending Settlement

| Field | Value |
|-------|-------|
| **Severity** | High |
| **Impact** | Permanent Loss of Earned Rewards for Stakers |
| **Likelihood** | High (triggers on normal admin operations) |
| **File** | `IronStaking.sol` |
| **Location** | `setRewardRate()` changes rate without calling `_updateRewards()` first |
| **Difficulty** | Easy |

**Description**: When the admin calls `setRewardRate(newRate)` to adjust the reward emission rate, the function does NOT call `_updateRewards()` before changing the rate. All pending but unclaimed rewards accumulated since the last staking interaction are retroactively recalculated using the NEW rate instead of the rate that was active when they were earned.

This is different from BM6 V-02 (which is about reward debt not carrying over on transfer). This is about the global reward rate changing without settling the pending rewards first.

**Exploit Path**:
1. Reward rate = 100 IRON/block. Alice has been staking for 1,000 blocks.
2. Alice's pending rewards = 100 × 1,000 × (her_share / total_staked)
3. Admin calls `setRewardRate(10)` (10x reduction)
4. `_updateRewards()` is NOT called before the rate change
5. Next time Alice claims: rewards computed at NEW rate (10 IRON/block) for the entire period
6. Alice receives 10x less than she earned → **90% of her rewards permanently lost**
7. Conversely, if rate increases: stakers get unearned windfall

**Recommendation**: Always call `_updateRewards()` (or equivalent `_accrueRewards()`) at the beginning of `setRewardRate()` to settle all pending rewards at the old rate before applying the new one.

---

### V-04: Proportional Distribution Rounding Drain

| Field | Value |
|-------|-------|
| **Severity** | High |
| **Impact** | Cumulative Value Leakage — dust permanently locked in contract |
| **Likelihood** | High (occurs on every distribution) |
| **File** | `IronFeeDistributor.sol` |
| **Location** | `distribute()` — per-recipient integer division truncates up to 1 wei per recipient |
| **Difficulty** | Medium |

**Description**: Protocol fees are distributed proportionally to N weighted recipients: `share_i = (totalFees * weight_i) / totalWeight`. With integer division, each calculation can lose up to 1 wei. With N recipients, up to N wei is lost per distribution call. This dust is never distributed and accumulates permanently in the contract.

While individual losses are tiny, the cumulative effect over millions of distributions becomes significant:
- 100 recipients × 10M distributions = 1 billion wei = **1 IRON** leaked
- With higher-value tokens or more frequent distributions, the leakage scales linearly

**Exploit Path**:
1. FeeDistributor has 3 recipients with weights [33, 33, 34] (total = 100)
2. Distribution of 100 wei: recipient[0] = 33, recipient[1] = 33, recipient[2] = 34 → sum = 100 (OK)
3. Distribution of 99 wei: recipient[0] = 32, recipient[1] = 32, recipient[2] = 33 → sum = 97 → **2 wei dust**
4. Distribution of 10 wei: recipient[0] = 3, recipient[1] = 3, recipient[2] = 3 → sum = 9 → **1 wei dust**
5. After 10M distributions with avg 1.5 wei dust: 15M wei permanently trapped

**Recommendation**: After distributing to all recipients, compute the difference between total input and sum of outputs, and add the remainder to the last recipient, or implement a `sweepDust()` function.

---

### V-05: ERC20 Approval Race Condition

| Field | Value |
|-------|-------|
| **Severity** | Medium |
| **Impact** | Allowance Over-Extraction (up to 1.5x intended) |
| **Likelihood** | Medium (requires mempool monitoring) |
| **File** | `IronToken.sol` |
| **Location** | `approve()` — classic ERC20 race without `increaseAllowance/decreaseAllowance` |
| **Difficulty** | Easy |

**Description**: `IronToken` implements the standard ERC20 `approve(spender, amount)` function which directly overwrites the allowance. The well-known race condition: if a user changes an allowance from A to B, the spender can front-run the `approve(B)` transaction by spending the old allowance A, then after the `approve(B)` is mined, spend the new allowance B — extracting A + B total instead of the intended B.

**Exploit Path**:
1. User has `approve(spender, 100)` → spender's allowance = 100
2. User wants to change to `approve(spender, 50)` → submits tx
3. Spender sees pending tx in mempool → front-runs with `transferFrom(user, spender, 100)`
4. `approve(spender, 50)` is mined → allowance now = 50
5. Spender calls `transferFrom(user, spender, 50)` again
6. Total extracted: 150 tokens instead of intended 50

**Recommendation**: Implement `increaseAllowance()` and `decreaseAllowance()` functions, or require setting allowance to 0 before changing to a non-zero value.

---

## 6. Vulnerability Summary

| ID | Name | Severity | Impact | Difficulty | Primary Contract |
|----|------|----------|--------|------------|-----------------|
| V-01 | Donation Attack (Active Vault) | **Critical** | Direct fund loss | Medium | IronVault |
| V-02 | Interest Rate Kink Jump | **High** | Inflated interest on borrowers | Medium | IronLendingMarket |
| V-03 | Reward Rate Change w/o Settlement | **High** | Permanent reward loss | Easy | IronStaking |
| V-04 | Proportional Rounding Drain | **High** | Cumulative value leakage | Medium | IronFeeDistributor |
| V-05 | ERC20 Approval Race | **Medium** | Allowance over-extraction | Easy | IronToken |

**Severity Distribution**: 1 Critical, 3 High, 1 Medium

---

## 7. Key Differences from Previous Benchmarks

| Aspect | Key Distinction |
|--------|----------------|
| **V-01 (Donation)** | Targets active vault with depositors (BM1 tested empty vault first-depositor) |
| **V-02 (Kink)** | Interest rate manipulation via utilization control (not tested elsewhere) |
| **V-03 (Rate Change)** | Global reward rate change loses pending rewards (BM6 tested transfer-based debt gap) |
| **V-04 (Rounding)** | Multi-recipient proportional distribution dust (BM2 tested cumulative P-product loss) |
| **V-05 (Approval)** | Classic ERC20 race condition (foundational but not tested in BM1-6) |

---

## 8. Build & Test

```bash
cd server/examples/defi_economic_invariant_7
forge build
```
