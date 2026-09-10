// Deploy the option-B V3-native launcher (StockpadV3Factory, which also deploys its V3Locker).
//
//   PRIVATE_KEY=0x... npx hardhat run scripts/deployV3.js --network rhTestnet   # validate first!
//   PRIVATE_KEY=0x... npx hardhat run scripts/deployV3.js --network rhMainnet
//
// Verified Robinhood Chain MAINNET infra (checked on-chain):
//   NPM  0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3
//   WETH 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
// TESTNET (46630) addresses are NOT verified — pass them via env before deploying there.
const { ethers, network } = require("hardhat");

async function main() {
  const NPM = process.env.NPM || "0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3";
  const WETH = process.env.WETH || "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73";
  const FEE = Number(process.env.FEE || 10000);            // 1% tier (spacing 200)
  const SPACING = Number(process.env.TICK_SPACING || 200);
  const [signer] = await ethers.getSigners();
  const protocol = process.env.PROTOCOL_RECIPIENT || signer.address;

  console.log("Network:", network.name, "deployer:", signer.address);
  console.log("NPM:", NPM, "WETH:", WETH, "fee:", FEE, "spacing:", SPACING, "protocol:", protocol);

  // sanity: confirm the NPM really points at this WETH (catches wrong-network addresses)
  const npm = await ethers.getContractAt(
    ["function WETH9() view returns (address)", "function factory() view returns (address)"], NPM);
  const npmWeth = await npm.WETH9().catch(() => null);
  if (npmWeth && npmWeth.toLowerCase() !== WETH.toLowerCase())
    throw new Error(`NPM.WETH9()=${npmWeth} != WETH ${WETH} — wrong addresses for ${network.name}?`);

  const F = await ethers.getContractFactory("StockpadV3Factory");
  const factory = await F.deploy(signer.address, NPM, WETH, FEE, SPACING, protocol);
  await factory.waitForDeployment();
  const addr = await factory.getAddress();
  const locker = await factory.locker();
  console.log("\nStockpadV3Factory:", addr);
  console.log("V3Locker:", locker);
  console.log("\nPaste into js/config.js:  FILE_FACTORY_V3 = \"" + addr + "\"");
}
main().catch((e) => { console.error(e); process.exit(1); });
