// HONEST VALIDATION for option B: launch a token, then do a REAL buy -> sell round-trip
// through the live Uniswap V3 SwapRouter. This is the step that proves the single-sided
// price/tick seeding is correct on a real V3 (which cannot be verified with a local mock).
// RUN THIS ON TESTNET (46630) BEFORE PUTTING REAL VALUE ON MAINNET.
//
//   FACTORY=0x... SWAP_ROUTER=0x... PRIVATE_KEY=0x... npx hardhat run scripts/validateV3.js --network rhTestnet
//
// Defaults use the MAINNET-verified NPM/WETH; SWAP_ROUTER defaults to the address noted for
// Robinhood Chain — CONFIRM it on-chain for your network before trusting the result.
const { ethers } = require("hardhat");

const ROUTER_ABI = [
  // Uniswap V3 SwapRouter (v1 — struct carries a deadline). If the chain has SwapRouter02,
  // set ROUTER_KIND=02 to drop the deadline field.
  "function exactInputSingle((address tokenIn,address tokenOut,uint24 fee,address recipient,uint256 deadline,uint256 amountIn,uint256 amountOutMinimum,uint160 sqrtPriceLimitX96)) payable returns (uint256)",
];
const ROUTER02_ABI = [
  "function exactInputSingle((address tokenIn,address tokenOut,uint24 fee,address recipient,uint256 amountIn,uint256 amountOutMinimum,uint160 sqrtPriceLimitX96)) payable returns (uint256)",
];
const ERC20_ABI = [
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
  "function deposit() payable",
];

async function main() {
  const [me] = await ethers.getSigners();
  const FEE = Number(process.env.FEE || 10000);
  const WETH = process.env.WETH || "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73";
  const ROUTER = process.env.SWAP_ROUTER || "0xcaF681a66d020601342297493863e78c959e5cB2";
  const kind02 = process.env.ROUTER_KIND === "02";
  const buyEth = ethers.parseEther(process.env.BUY_ETH || "0.001");

  const factory = await ethers.getContractAt("StockpadV3Factory", process.env.FACTORY);
  console.log("Factory:", await factory.getAddress(), "router:", ROUTER, kind02 ? "(SwapRouter02)" : "(SwapRouter)");

  // 1) launch
  console.log("\n[1] createLaunch $HOPE / NVIDIA ...");
  const tx = await factory.createLaunch("Hope", "HOPE", "NVIDIA", true);
  const rc = await tx.wait();
  const id = (await factory.launchCount()) - 1n;
  const L = await factory.getLaunch(id);
  console.log("    token:", L.token, "pool:", L.pool, "tokenId:", L.tokenId.toString());

  const token = await ethers.getContractAt(ERC20_ABI, L.token);
  const weth = await ethers.getContractAt(ERC20_ABI, WETH);
  const router = new ethers.Contract(ROUTER, kind02 ? ROUTER02_ABI : ROUTER_ABI, me);

  // 2) wrap + approve + BUY (WETH -> TOKEN)
  console.log("\n[2] buy with", ethers.formatEther(buyEth), "ETH ...");
  await (await weth.deposit({ value: buyEth })).wait();
  await (await weth.approve(ROUTER, buyEth)).wait();
  const dl = Math.floor(Date.now() / 1000) + 600;
  const buyParams = kind02
    ? { tokenIn: WETH, tokenOut: L.token, fee: FEE, recipient: me.address, amountIn: buyEth, amountOutMinimum: 0, sqrtPriceLimitX96: 0 }
    : { tokenIn: WETH, tokenOut: L.token, fee: FEE, recipient: me.address, deadline: dl, amountIn: buyEth, amountOutMinimum: 0, sqrtPriceLimitX96: 0 };
  await (await router.exactInputSingle(buyParams)).wait();
  const bought = await token.balanceOf(me.address);
  console.log("    got", ethers.formatEther(bought), "HOPE");
  if (bought === 0n) throw new Error("BUY returned 0 tokens — price/tick seeding is wrong. DO NOT go to mainnet.");

  // 3) approve + SELL (TOKEN -> WETH)
  console.log("\n[3] sell it all back ...");
  await (await token.approve(ROUTER, bought)).wait();
  const wethBefore = await weth.balanceOf(me.address);
  const sellParams = kind02
    ? { tokenIn: L.token, tokenOut: WETH, fee: FEE, recipient: me.address, amountIn: bought, amountOutMinimum: 0, sqrtPriceLimitX96: 0 }
    : { tokenIn: L.token, tokenOut: WETH, fee: FEE, recipient: me.address, deadline: dl, amountIn: bought, amountOutMinimum: 0, sqrtPriceLimitX96: 0 };
  await (await router.exactInputSingle(sellParams)).wait();
  const wethBack = (await weth.balanceOf(me.address)) - wethBefore;
  console.log("    got back", ethers.formatEther(wethBack), "WETH (≈ buy minus 2× the", FEE / 10000, "% fee)");
  if (wethBack === 0n) throw new Error("SELL returned 0 — pool not tradable both ways.");

  // 4) fees accrued to the locked position -> anyone can split them
  console.log("\n[4] collect + split fees ...");
  const locker = await ethers.getContractAt("V3Locker", await factory.locker());
  await (await locker.collectFees(L.tokenId)).wait();
  console.log("\n✅ ROUND-TRIP OK — the launch is a live, tradable V3 pool. Safe to consider mainnet.");
}
main().catch((e) => { console.error("\n❌", e.message || e); process.exit(1); });
