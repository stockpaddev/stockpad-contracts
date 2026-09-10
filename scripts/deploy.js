// Deploy the Stockpad v2 core (Registry, FeeEscrow, Factory) and wire them.
// Usage:
//   RH testnet:  PRIVATE_KEY=0x... npx hardhat run scripts/deploy.js --network rhTestnet
//   RH mainnet:  PRIVATE_KEY=0x... npx hardhat run scripts/deploy.js --network rhMainnet
// NEVER commit your PRIVATE_KEY. The deployer is the initial owner of Registry & Factory.
const hre = require("hardhat");
const { ethers } = hre;

const VIRT = ethers.parseEther("3");    // virtual quote reserve seed
const THRESH = ethers.parseEther("10"); // net quote raised to graduate

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  console.log("Network:", net.name, "chainId", net.chainId.toString());
  console.log("Deployer:", deployer.address);

  const Registry = await ethers.getContractFactory("StockTokenRegistry");
  const registry = await Registry.deploy(deployer.address);
  await registry.waitForDeployment();

  const Escrow = await ethers.getContractFactory("FeeEscrow");
  const escrow = await Escrow.deploy();
  await escrow.waitForDeployment();

  const Factory = await ethers.getContractFactory("StockpadFactory");
  const factory = await Factory.deploy(
    deployer.address,
    await registry.getAddress(),
    await escrow.getAddress(),
    deployer.address, // protocolRecipient (change later via setProtocolRecipient)
    VIRT, THRESH
  );
  await factory.waitForDeployment();

  const initTx = await escrow.initFactory(await factory.getAddress());
  await initTx.wait();

  // --- Graduation manager (Uniswap V3) ---
  // Verified on Robinhood Chain mainnet (4663): NonfungiblePositionManager + WETH.
  const chainId = Number(net.chainId);
  const V3_NPM = process.env.V3_NPM || (chainId === 4663 ? "0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3" : "");
  const WETH   = process.env.WETH   || (chainId === 4663 ? "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73" : "");
  const V3_FEE = Number(process.env.V3_FEE || 10000);   // 1% tier
  const TICK_SPACING = Number(process.env.V3_TICK_SPACING || 200);
  let gradAddr = "(not deployed — set V3_NPM & WETH for this chain)";
  if (V3_NPM && WETH) {
    const Grad = await ethers.getContractFactory("GraduationManager");
    const grad = await Grad.deploy(await factory.getAddress(), V3_NPM, WETH, V3_FEE, TICK_SPACING);
    await grad.waitForDeployment();
    await (await factory.setGraduationManager(await grad.getAddress())).wait();
    gradAddr = await grad.getAddress();
    console.log("GraduationManager deployed + wired.");
  }

  console.log("\n=== Stockpad v2 deployed ===");
  console.log("Registry:         ", await registry.getAddress());
  console.log("FeeEscrow:        ", await escrow.getAddress());
  console.log("Factory:          ", await factory.getAddress());
  console.log("GraduationManager:", gradAddr);
  console.log("Uniswap V3 NPM:   ", V3_NPM || "(none)");
  console.log("WETH:             ", WETH || "(none)");
  console.log("V3 fee/tickSpacing:", V3_FEE, "/", TICK_SPACING);
  console.log("protocolRecipient:", deployer.address);
  console.log("virtualQuoteSeed:", VIRT.toString(), "gradThreshold:", THRESH.toString());
  console.log("\nNext: seed the registry with canonical stock tokens:");
  console.log("  REGISTRY=" + (await registry.getAddress()) + " PRIVATE_KEY=0x... npx hardhat run scripts/seedRegistry.js --network " + hre.network.name);
  console.log("\nGraduation manager (Uniswap V3) is added in the graduation stage:");
  console.log("  factory.setGraduationManager(<manager>)");
}
main().catch((e) => { console.error(e); process.exit(1); });
