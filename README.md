# PerpetualVault   

This project, **PerpetualVault**, is our official submission to the ETHGlobal Bangkok Hackathon. It’s a decentralized perpetual positions protocol focused on delivering security, transparency, and efficiency in trading, with Ledger integration for secure transaction signing.  

## About Ledger Integration  

Ledger is a critical part of our security architecture. By integrating ERC-7730, we ensure users can sign transactions securely and transparently, leveraging Ledger's clear signing features. This not only enhances the safety of the platform but also builds trust in every interaction.  

## What We Built  

**PerpetualVault** allows traders to open long or short positions on BTC with customizable size and collateral. Liquidity providers can deposit and withdraw liquidity, supporting the protocol and earning rewards in return.  

Our protocol simulates Chainlink’s `AggregatorV3Interface` to fetch real-time BTC/USD price data, guaranteeing accurate and reliable pricing for trading operations. This integration ensures fairness, decentralization, and transparency throughout the trading process.  

By blending advanced perpetual trading mechanics with Ledger's cutting-edge security, **PerpetualVault** delivers a robust, secure, and user-friendly trading experience.

# How to run
1.  **Install Foundry**

First run the command below to get foundryup, the Foundry toolchain installer:

``` bash
curl -L https://foundry.paradigm.xyz | bash
```

Then, in a new terminal session or after reloading your PATH, run it to get the latest forge and cast binaries:

``` console
foundryup
```

2. **Clone This Repo and install dependencies**
``` 
git clone https://github.com/anjanayraina/PerpetualVault.git
cd PerpetualVault
forge install
forge test
```
