// Seed StockTokenRegistry with the CANONICAL Robinhood Stock Token addresses for the
// connected chain, fetched live from the official API (address is authoritative).
// Usage:
//   REGISTRY=0x... PRIVATE_KEY=0x... npx hardhat run scripts/seedRegistry.js --network rhMainnet
const hre = require("hardhat");
const { ethers } = hre;

async function fetchCanonical(chainId) {
  const res = await fetch("https://api.robinhood.com/rhj/assets", { headers: { accept: "application/json" } });
  if (!res.ok) throw new Error("assets API " + res.status);
  const j = await res.json();
  const out = [];
  for (const a of j.assets || []) {
    if (a.status !== "ASSET_STATUS_ACTIVE") continue;
    const dep = (a.deployments || []).find((d) => Number(d.chainId) === Number(chainId));
    if (dep && dep.contractAddress) out.push(ethers.getAddress(dep.contractAddress));
  }
  return out;
}

async function main() {
  const REGISTRY = process.env.REGISTRY;
  if (!REGISTRY) throw new Error("Set REGISTRY=0x... (deployed StockTokenRegistry)");
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);
  console.log("Seeding registry", REGISTRY, "on chainId", chainId);

  const canonical = await fetchCanonical(chainId);
  console.log("Canonical stock tokens for this chain:", canonical.length);
  if (!canonical.length) { console.log("None for this chain (e.g. testnet). Nothing to seed."); return; }

  const registry = await ethers.getContractAt("StockTokenRegistry", REGISTRY);
  // add in batches of 50 to stay within gas
  for (let i = 0; i < canonical.length; i += 50) {
    const batch = canonical.slice(i, i + 50);
    const tx = await registry.addMany(batch);
    await tx.wait();
    console.log("added", i + batch.length, "/", canonical.length);
  }
  console.log("done. registry.count() =", (await registry.count()).toString());
}
main().catch((e) => { console.error(e); process.exit(1); });
