# Stockpad — Smart Contracts

Official repository for the [Stockpad](https://stockpadrh-app-live.netlify.app) launchpad smart contracts on the **Robinhood Chain** (EVM, chain ID `4663`).

Stockpad lets anyone launch a fixed-supply ERC-20 token that goes **straight into a real Uniswap V4 pool**, paired with a real stock token (NVDA, AAPL, TSLA…), ETH, or USDG. There is **no bonding curve and no graduation step** — every coin is tradable from block one, and its liquidity is locked at launch. A small trading fee is taken in the pool's pair asset and shared with the coin's creator and holders.

> Stockpad is non-custodial software. Your wallet signs every transaction; Stockpad never holds your keys or funds. Nothing here is financial advice.

## Deployed contracts (Robinhood Chain · 4663)

| Contract | Address |
| --- | --- |
| **StockpadV4Factory** (current) | `0x309E552113553D99d05801C31230FBd67e50F570` |
| StockpadV4Factory (legacy) | `0x3a97D922C3B9188Ae34A0D2913f7c7A37792f8f3` |
| StockpadV4Factory (legacy) | `0xBBB05533093D09730D1CC91f98f5d92a3B8c4406` |

## Repository structure

```
├── contracts/
│   ├── StockpadV4Factory.sol      # current V4-native factory (launch → live Uniswap V4 pool, on-chain logoURI, auto-collect)
│   ├── StockpadToken.sol          # fixed-supply ERC-20 launched by the factory
│   ├── StockpadTokenDividend.sol  # holder dividend / reward accounting
│   ├── Locker.sol                 # permanent liquidity lock + fee routing
│   ├── FeeEscrow.sol              # protocol fee escrow
│   ├── StockTokenRegistry.sol     # registry of canonical stock tokens
│   ├── StockpadV3Factory.sol      # earlier V3-native factory (kept for reference)
│   ├── StockpadFactory.sol        # V1 factory (kept for reference)
│   ├── StockpadCurve.sol          # V1/V2 curve (legacy)
│   ├── GraduationManager.sol      # legacy graduation logic (unused in V4)
│   └── uniswap/                   # Uniswap V3 / V4 interfaces used by the factories
└── README.md
```

The **current** product is `StockpadV4Factory` — the V1/V3/curve files are kept for transparency and history.

## How a V4 launch works

1. The factory mints a fixed-supply ERC-20 (`StockpadToken`).
2. It creates a real Uniswap V4 pool paired with the chosen asset (stock token / ETH / USDG) and seeds one-sided liquidity.
3. Liquidity is locked in `Locker` at launch — there is no withdrawal path.
4. Each in-app trade takes a small fee in the pair asset; a share goes to holders (via `StockpadTokenDividend`) and/or the creator, the rest to the protocol fee escrow.
5. Creators claim their fees, and holders claim their dividends, from the app dashboard.

## Fees

- **Trade fee:** a small percentage of each trade, taken in the pool's pair asset (set per launch).
- **Protocol share:** a portion of that trade fee accrues to the protocol; the rest goes to holders / creator.
- **Launch fee:** a small fixed ETH fee per launch.

Exact values are on-chain and visible in the factory.

## License

MIT, unless a file header states otherwise. Files derived from Uniswap (interfaces / math) retain their upstream licenses (MIT / GPL-2.0-or-later / BUSL-1.1) as noted in their headers.

## Links

- App: https://stockpadrh-app-live.netlify.app
- Docs: https://stockpadrh-app-live.netlify.app/docs
