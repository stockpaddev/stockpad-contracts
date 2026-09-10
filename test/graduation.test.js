const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(String(n));
const ETH = 0, ERC20 = 1;
const VIRT = E(3), THRESH = E(10), FEE = 200;

async function setup() {
  const [deployer, creator, user, protocol] = await ethers.getSigners();
  const registry = await (await ethers.getContractFactory("StockTokenRegistry")).deploy(deployer.address);
  const escrow = await (await ethers.getContractFactory("FeeEscrow")).deploy();
  const factory = await (await ethers.getContractFactory("StockpadFactory")).deploy(
    deployer.address, await registry.getAddress(), await escrow.getAddress(), protocol.address, VIRT, THRESH);
  await escrow.initFactory(await factory.getAddress());

  const weth = await (await ethers.getContractFactory("MockWETH9")).deploy();
  const npm = await (await ethers.getContractFactory("MockNonfungiblePositionManager"))
    .deploy(ethers.ZeroAddress, await weth.getAddress());
  const grad = await (await ethers.getContractFactory("GraduationManager"))
    .deploy(await factory.getAddress(), await npm.getAddress(), await weth.getAddress(), 10000, 200);
  await factory.setGraduationManager(await grad.getAddress());

  const nvda = await (await ethers.getContractFactory("MockERC20")).deploy("Nvidia RH", "NVDA", 18);
  await registry.add(await nvda.getAddress());

  return { deployer, creator, user, protocol, registry, escrow, factory, weth, npm, grad, nvda };
}
const curveAt = (a) => ethers.getContractAt("StockpadCurve", a);

async function createEth(factory, creator) {
  const rc = await (await factory.connect(creator).createLaunch("Eth Coin", "EC", ETH, ethers.ZeroAddress, FEE, false)).wait();
  const ev = rc.logs.map(l => { try { return factory.interface.parseLog(l); } catch { return null; } }).find(x => x && x.name === "TokenCreated");
  return { id: Number(ev.args.id), token: ev.args.token, curve: ev.args.curve };
}
async function createNvda(factory, creator, nvda) {
  const rc = await (await factory.connect(creator).createLaunch("Nvda Frog", "NF", ERC20, nvda, FEE, false)).wait();
  const ev = rc.logs.map(l => { try { return factory.interface.parseLog(l); } catch { return null; } }).find(x => x && x.name === "TokenCreated");
  return { id: Number(ev.args.id), token: ev.args.token, curve: ev.args.curve };
}

describe("Stockpad v2 — graduation to Uniswap V3 (mocked NPM, real ERC20/721 movement)", () => {
  it("TEST 16 & 17: ETH launch graduates -> real pool created + LP NFT locked", async () => {
    const { factory, npm, grad, creator, user } = await setup();
    const { id, curve } = await createEth(factory, creator);
    const c = await curveAt(curve);
    await c.connect(user).buy(0, 0, { value: E(11) });   // cross threshold
    expect(await c.graduated()).to.equal(true);

    await grad.graduate(id);                              // perform migration

    const L = await factory.getLaunch(id);
    expect(L.poolId).to.not.equal(ethers.ZeroHash);      // TEST 16: pool recorded
    const locker = await grad.locker();
    expect(L.locker).to.equal(locker);
    // TEST 17: the LP position NFT (tokenId 1) is owned by the locker
    expect(await npm.ownerOf(1)).to.equal(locker);
    const lk = await ethers.getContractAt("Locker", locker);
    expect(await lk.lockedCount()).to.equal(1);
    expect(await lk.locked(await npm.getAddress(), 1)).to.equal(true);
  });

  it("TEST 18: creator cannot withdraw the locked liquidity", async () => {
    const { factory, npm, grad, creator, user } = await setup();
    const { id } = await createEth(factory, creator);
    const c = await curveAt((await factory.getLaunch(id)).curve);
    await c.connect(user).buy(0, 0, { value: E(11) });
    await grad.graduate(id);
    const locker = await grad.locker();
    const lk = await ethers.getContractAt("Locker", locker);
    // Locker exposes NO withdraw/transfer of the position — compile-time guarantee
    expect(lk.withdraw).to.equal(undefined);
    expect(lk.transferPosition).to.equal(undefined);
    // creator cannot move the NFT (they never own it; locker does and has no transfer path)
    expect(await npm.ownerOf(1)).to.equal(locker);
    // even an NFT transfer attempt by the creator reverts (not owner/approved)
    await expect(npm.connect(creator).transferFrom(locker, creator.address, 1)).to.be.reverted;
    expect(await npm.ownerOf(1)).to.equal(locker); // still locked
  });

  it("TEST 19: after graduation the curve stops and the DEX pool exists for external trading", async () => {
    const { factory, grad, creator, user } = await setup();
    const { id, curve } = await createEth(factory, creator);
    const c = await curveAt(curve);
    await c.connect(user).buy(0, 0, { value: E(11) });
    await grad.graduate(id);
    // curve trading is closed
    await expect(c.connect(user).buy(0, 0, { value: E(1) })).to.be.revertedWithCustomError(c, "Graduated");
    // and the real DEX pool is registered for external/DEX trading
    expect((await factory.getLaunch(id)).poolId).to.not.equal(ethers.ZeroHash);
  });

  it("STOCK-TOKEN graduation: NVDA launch graduates -> TOKEN/NVDA pool, NVDA liquidity locked", async () => {
    const { factory, npm, grad, creator, user, nvda } = await setup();
    const nvdaAddr = await nvda.getAddress();
    await nvda.mint(user.address, E(50));
    const { id, curve } = await createNvda(factory, creator, nvdaAddr);
    const c = await curveAt(curve);
    await nvda.connect(user).approve(curve, E(50));
    await c.connect(user).buy(E(12), 0);                 // net > 10 NVDA -> graduate
    expect(await c.graduated()).to.equal(true);

    await grad.graduate(id);
    const L = await factory.getLaunch(id);
    expect(L.poolId).to.not.equal(ethers.ZeroHash);
    const locker = await grad.locker();
    expect(await npm.ownerOf(1)).to.equal(locker);
    // the pool actually received real NVDA + launch-token liquidity
    const pool = await npm.poolOf(1);
    expect(await nvda.balanceOf(pool)).to.be.gt(0);
  });

  it("cannot finalize a curve before graduation (no premature liquidity pull)", async () => {
    const { factory, grad, creator, user } = await setup();
    const { id } = await createEth(factory, creator);
    const c = await curveAt((await factory.getLaunch(id)).curve);
    await c.connect(user).buy(0, 0, { value: E(1) });    // below threshold -> not graduated
    await expect(grad.graduate(id)).to.be.revertedWithCustomError(grad, "NotGraduated");
  });
});
