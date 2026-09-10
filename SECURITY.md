# Security Policy

## Reporting a vulnerability

If you discover a security issue in the Stockpad contracts, please report it
**privately** first — do not open a public issue for an unpatched vulnerability.

- Open a [GitHub security advisory](https://github.com/stockpaddev/stockpad-contracts/security/advisories/new), or
- Reach out via the project's X / Twitter DMs.

Please include a clear description, affected contract(s), and a proof-of-concept
if possible. We aim to acknowledge reports promptly.

## Scope

In scope: the Solidity contracts in `contracts/` (the `StockpadV4Factory` and the
periphery it deploys — token, dividend, locker, fee escrow).

Out of scope: third-party dependencies (Uniswap, OpenZeppelin), the RPC provider,
wallet software, and the front-end interface.

## Non-custodial reminder

Stockpad is non-custodial. The contracts never take custody of user keys, and
the interface never asks for a seed phrase or private key. **Stockpad will never
DM you first or ask for your recovery phrase** — treat anyone who does as a scam.

## Audit status

These contracts are provided as-is and have **not** undergone a formal third-party
audit. Interacting with them carries risk, including total loss of funds. Do your
own research and never commit more than you can afford to lose. Nothing here is
financial advice.
