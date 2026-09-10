// Discover the Uniswap V3 NonfungiblePositionManager on Robinhood Chain via RPC only.
// Strategy: V3 factory PoolCreated -> a pool -> that pool's Mint(sender) is the NPM.
const { ethers } = require("hardhat");

const RPC = process.env.RH_RPC_URL || "https://rpc.mainnet.chain.robinhood.com";
const FACTORY = "0x1f7d7550B1b028f7571E69A784071F0205FD2EfA";

const FACTORY_ABI = ["event PoolCreated(address indexed token0,address indexed token1,uint24 indexed fee,int24 tickSpacing,address pool)"];
const POOL_ABI = ["event Mint(address sender,address indexed owner,int24 indexed tickLower,int24 indexed tickUpper,uint128 amount,uint256 amount0,uint256 amount1)"];
const NPM_PROBE = ["function positions(uint256) view returns (uint96,address,address,address,uint24,int24,int24,uint128,uint256,uint256,uint128,uint128)","function factory() view returns (address)","function WETH9() view returns (address)"];

async function chunkedLogs(provider, filter, from, to, step) {
  let out = [];
  for (let s = from; s <= to; s += step + 1) {
    const e = Math.min(to, s + step);
    try { out = out.concat(await provider.getLogs({ ...filter, fromBlock: s, toBlock: e })); if (out.length) break; } catch (_) {}
  }
  return out;
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const latest = await provider.getBlockNumber();
  console.log("latest block", latest);
  const fac = new ethers.Contract(FACTORY, FACTORY_ABI, provider);
  const topic = fac.interface.getEvent("PoolCreated").topicHash;

  // scan recent-first in 400k chunks
  let pools = [];
  for (let end = latest; end > 0 && !pools.length; end -= 4000000) {
    const start = Math.max(0, end - 4000000);
    const logs = await chunkedLogs(provider, { address: FACTORY, topics: [topic] }, start, end, 400000);
    for (const l of logs) { const p = fac.interface.parseLog(l); pools.push({ pool: p.args.pool, fee: Number(p.args.fee), t0: p.args.token0, t1: p.args.token1, block: l.blockNumber }); }
    if (pools.length) console.log("found", pools.length, "pools in blocks", start, "-", end);
  }
  if (!pools.length) { console.log("No V3 pools found by PoolCreated scan."); return; }
  console.log("sample pool:", pools[0]);

  // find a Mint on the first few pools -> sender = NPM candidate
  const poolIface = new ethers.Interface(POOL_ABI);
  const mintTopic = poolIface.getEvent("Mint").topicHash;
  for (const pl of pools.slice(0, 8)) {
    const logs = await chunkedLogs(provider, { address: pl.pool, topics: [mintTopic] }, Math.max(0, pl.block - 10), latest, 2000000);
    if (logs.length) {
      const m = poolIface.parseLog(logs[0]);
      const npm = m.args.sender;
      console.log("Mint sender (NPM candidate):", npm, "in pool", pl.pool);
      // probe it
      try {
        const probe = new ethers.Contract(npm, NPM_PROBE, provider);
        const f = await probe.factory().catch(() => null);
        const w = await probe.WETH9().catch(() => null);
        const code = await provider.getCode(npm);
        console.log("  factory():", f, "| WETH9():", w, "| codeSize:", (code.length - 2) / 2);
      } catch (e) { console.log("  probe failed:", e.message); }
      return;
    }
  }
  console.log("No Mint events found on sampled pools.");
}
main().catch((e) => { console.error(e); process.exit(1); });
