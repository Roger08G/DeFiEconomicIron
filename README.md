# IronForge Protocol

> **Category**: Lending Market · Yield Vault · DeFi · Economic Invariants
> **Difficulty**: Medium
> **Solidity**: `^0.8.20` · **Framework**: Foundry
> **Total Findings to Discover**: 5 (1 Critical · 3 High · 1 Medium)
> **Lab Type**: Intentionally Vulnerable — Educational Use Only

A modular DeFi protocol featuring a variable-rate lending market, a pro-rata yield vault, token staking with streaming rewards, and a weighted fee distributor — designed for Ethereum Mainnet.

---

## Overview

IronForge provides a suite of tightly integrated on-chain financial primitives:

- **IronVault** — Yield vault where depositors receive shares that appreciate as protocol revenue accumulates. Inspired by ERC-4626.
- **IronLendingMarket** — Over-collateralised lending with a kinked two-slope interest rate model. Rates scale gently below 80 % utilisation and steeply above it.
- **IronStaking** — Synthetix-style staking contract that streams reward tokens to depositors at an admin-configurable emission rate.
- **IronFeeDistributor** — Permissionless fee distribution to N weighted recipients. Anyone may trigger a distribution round once fees have been collected.
- **IronToken** — Standard ERC-20 used as the protocol's native token (`IRON`, 18 decimals).

---

## Architecture

```
                    ┌────────────────────────────────────┐
                    │          User / Frontend            │
                    └───┬──────────┬──────────┬──────────┘
                        │          │          │
           ┌────────────▼──────┐   │   ┌──────▼──────────────┐
           │    IronVault      │   │   │  IronLendingMarket  │
           │  (yield vault)    │   │   │  (variable-rate     │
           │                   │   │   │   lending)          │
           └────────┬──────────┘   │   └──────┬──────────────┘
                    │              │           │
                    │         ┌────▼────────┐  │
                    │         │ IronStaking  │  │
                    │         │ (streaming   │  │
                    │         │  rewards)    │  │
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

## Contracts

| Contract | File | nSLOC | Description |
|---|---|---|---|
| `IronToken` | `contracts/IronToken.sol` | ~70 | Native ERC-20 with owner-controlled mint / burn |
| `IronVault` | `contracts/IronVault.sol` | ~110 | Pro-rata yield vault with configurable withdrawal fee |
| `IronLendingMarket` | `contracts/IronLendingMarket.sol` | ~200 | Over-collateralised lending with kinked interest rate model |
| `IronStaking` | `contracts/IronStaking.sol` | ~160 | Token staking with configurable streaming reward emission |
| `IronFeeDistributor` | `contracts/IronFeeDistributor.sol` | ~130 | Weighted fee distribution to registered protocol recipients |

---

## Interest Rate Model

`IronLendingMarket` uses a two-slope kinked rate curve:

```
Rate (APR)  │                                            ╱
            │                                          ╱
            │                              slope₂ = 1,500 %
            │──────────────────────────────────── kink @ 80 %
            │                    ╱ slope₁ = 3.75 %
            │                  ╱
            │________________╱  base = 2 %
            └──────────────────────────────────── Utilisation
            0 %               80 %              100 %
```

| Utilisation | Approx. APR |
|---|---|
| 50 % | ~3.9 % |
| 79 % | ~5.0 % |
| 81 % | ~78 % |
| 95 % | ~1,130 % |

---

## Parameters

| Parameter | Value | Description |
|---|---|---|
| `COLLATERAL_FACTOR` | 7,500 bps (75 %) | Maximum LTV for borrowers |
| `KINK` | 8,000 bps (80 %) | Utilisation point where slope changes |
| `BASE_RATE` | 200 bps (2 %) | Minimum annualised interest rate |
| `SLOPE_1` | 375 bps | Rate slope below kink |
| `SLOPE_2` | 150,000 bps | Rate slope above kink |
| `BLOCKS_PER_YEAR` | 2,628,000 | Assumed ~12 s average block time |
| Withdrawal fee | 50 bps (0.5 %) | Vault exit fee retained for remaining LPs |

---

## Getting Started

### Prerequisites

[Foundry](https://book.getfoundry.sh/) must be installed:

```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup
```

### Install & Build

```bash
forge install
forge build
```

### Run Tests

```bash
forge test -vvv
```

---

## License

MIT
