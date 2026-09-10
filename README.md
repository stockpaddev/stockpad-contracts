<p align="center">
  <img src="media/logo.png" alt="Stockpad" width="88" height="88">
</p>

<h1 align="center">Stockpad — Smart Contracts</h1>

<p align="center">
  <a href="#"><img alt="Chain" src="https://img.shields.io/badge/Robinhood%20Chain-4663-00d179"></a>
  <a href="#"><img alt="Solidity" src="https://img.shields.io/badge/Solidity-%5E0.8-363636"></a>
  <a href="#"><img alt="Uniswap" src="https://img.shields.io/badge/Uniswap-V4-ff007a"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/License-MIT-blue"></a>
</p>

<p align="center">
  Official repository for the <a href="https://stockpadrh-app-live.netlify.app">Stockpad</a> launchpad smart contracts on the <b>Robinhood Chain</b> (EVM, chain ID <code>4663</code>).
</p>

---

Stockpad lets anyone launch a fixed-supply ERC-20 token that goes **straight into a real Uniswap V4 pool**, paired with a real stock token (NVDA, AAPL, TSLA…), ETH, or USDG. There is **no bonding curve and no graduation step** — every coin is tradable from block one, and its liquidity is **locked at launch**. A small trading fee is taken in the pool's pair asset and shared with the coin's creator and its holders.

> Stockpad is non-custodial software. Your wallet signs every transaction; Stockpad never holds your keys or funds. These contracts are unaudited. Nothing here is financial advice.

## Contents

- [Deployed contracts](#deployed-contracts)
- [How a launch works](#how-a-launch-works)
- [Repository layout](#repository-layout)
- [Build & test](#build--test)
- [ABIs](#abis)
- [Fees](#fees)
- [Security](#security)
- [License](#license)
- [Links](#links)

## Deployed contracts

Robinhood Chain · chain ID `4663` · gas token `ETH`. Full machine-readable list in [`deployments.json`](deployments.json).

| Contract | Address |
| --- | --- |
| **StockpadV4Factory** (current) | [`0x309E552113553D99d05801C31230FBd67e50F570`](https://robinhoodchain.blockscout.com/address/0x309E552113553D99d05801C31230FBd67e50F570) |
| StockpadV4Factory (legacy) | `0x3a97D922C3B9188Ae34A0D2913f7c7A37792f8f3` |
| StockpadV4Factory (legacy) | `0xBBB05533093D09730D1CC91f98f5d92a3B8c4406` |
| Uniswap V4 PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` |

## How a launch works

1. The factory mints a fixed-supply ERC-20 (`StockpadToken`).
2. It creates a real Uniswap V4 pool paired with the chosen asset (stock token / ETH / USDG) and seeds one-sided liquidity.
3. Liquidity is locked in `Locker` at launch — there is no withdrawal path.
4. Each in-app trade takes a small fee in the pair asset; a share goes to holders (via `StockpadTokenDividend`) and/or the creator, the rest to the protocol fee escrow.
5. Creators claim their fees, and holders claim their dividends, from the app dashboard.

```
 create ──▶ fixed-supply ERC-20 ──▶ live Uniswap V4 pool ──▶ liquidity locked
                                            │
                              trade fee (in pair asset)
                                            │
                        ┌───────────────────┼───────────────────┐
                     holders             creator            protocol
```

## Repository layout

```
├── contracts/
│   ├── StockpadV4Factory.sol      # current V4-native factory (launch → live V4 pool, on-chain logoURI, auto-collect)
│   ├── StockpadToken.sol          # fixed-supply ERC-20 launched by the factory
│   ├── StockpadTokenDividend.sol  # holder dividend / reward accounting
│   ├── Locker.sol                 # permanent liquidity lock + fee routing
│   ├── FeeEscrow.sol              # protocol fee escrow
│   ├── StockTokenRegistry.sol     # registry of canonical stock tokens
│   ├── StockpadV3Factory.sol      # earlier V3-native factory (reference)
│   ├── StockpadFactory.sol        # V1 factory (reference)
│   ├── StockpadCurve.sol          # V1/V2 curve (legacy)
│   ├── GraduationManager.sol      # legacy graduation logic (unused in V4)
│   └── uniswap/                   # Uniswap V3 / V4 interfaces
├── abi/                           # extracted ABIs (Factory, Token, Locker, Swapper)
├── test/                          # Hardhat test suite
├── deployments.json               # chain + contract addresses
├── hardhat.config.js
├── SECURITY.md
└── README.md
```

The **current** product is `StockpadV4Factory`; the V1/V3/curve files are kept for transparency and history.

## Build & test

Requires Node 18+ and npm.

```bash
npm install
npx hardhat compile
npx hardhat test
```

The suite in [`test/`](test) covers the V4-native launch path, holder rewards, and the legacy curve/graduation paths.

## ABIs

Ready-to-use JSON ABIs live in [`abi/`](abi):

| File | Contract |
| --- | --- |
| `abi/Factory.json` | StockpadV4Factory |
| `abi/Token.json` | StockpadToken |
| `abi/Locker.json` | Locker |
| `abi/Swapper.json` | in-app swap helper (auto-collect) |

## Fees

- **Trade fee** — a small percentage of each trade, taken in the pool's pair asset (set per launch).
- **Protocol share** — a portion of that trade fee accrues to the protocol; the rest goes to holders / the creator.
- **Launch fee** — a small fixed ETH fee per launch.

Exact values are on-chain and readable from the factory.

## Security

These contracts are **unaudited**. See [`SECURITY.md`](SECURITY.md) for the disclosure policy and scope. Interacting carries risk, including total loss of funds.

## License

MIT (see [`LICENSE`](LICENSE)), unless a file header states otherwise. Files derived from Uniswap (interfaces / math) retain their upstream licenses (MIT / GPL-2.0-or-later / BUSL-1.1) as noted in their headers.

## Links

- **App:** https://stockpadrh-app-live.netlify.app
- **Docs:** https://stockpadrh-app-live.netlify.app/docs
- **Explorer:** https://robinhoodchain.blockscout.com
