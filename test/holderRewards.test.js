const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(String(n));
const ETH = 0, ERC20 = 1;
const VIRT = E(3), THRESH = E(10000), FEE = 300; // high threshold so we don't graduate; 3% fee

async function setup() {
  const [deployer, creator, u1, u2, u3, protocol] = await ethers.getSigners();
  const registry = await (await ethers.getContractFactory("StockTokenRegistry")).deploy(deployer.address);
  const escrow = await (await ethers.getContractFactory("FeeEscrow")).deploy();
  const factory = await (await ethers.getContractFactory("StockpadFactory")).deploy(
    deployer.address, await registry.getAddress(), await escrow.getAddress(), protocol.address, VIRT, THRESH);
  await escrow.initFactory(await factory.getAddress());
  const nvda = await (await ethers.getContractFactory("MockERC20")).deploy("Nvidia RH", "NVDA", 18);
  await registry.add(await nvda.getAddress());
  return { deployer, creator, u1, u2, u3, protocol, registry, escrow, factory, nvda };
}
const curveAt = (a) => ethers.getContractAt("StockpadCurve", a);
const tokAt = (a) => ethers.getContractAt("StockpadTokenDividend", a);

async function create(factory, creator, pairType, pairToken, holderRewards) {
  const rc = await (await factory.connect(creator).createLaunch("Holder Coin", "HODL", pairType, pairToken, FEE, holderRewards)).wait();
  const ev = rc.logs.map(l => { try { return factory.interface.parseLog(l); } catch { return null; } }).find(x => x && x.name === "TokenCreated");
  return { token: ev.args.token, curve: ev.args.curve };
}

describe("Stockpad v2 — holder rewards (paid in the pair asset)", () => {
  it("ETH launch: holders accrue ETH rewards proportionally and can claim; curve is excluded", async () => {
    const { factory, creator, u1, u2, u3 } = await setup();
    const { token, curve } = await create(factory, creator, ETH, ethers.ZeroAddress, true);
    const c = await curveAt(curve), t = await tokAt(token);

    await c.connect(u1).buy(0, 0, { value: E(1) });   // u1 first holder (its own fee folds to creator)
    await c.connect(u2).buy(0, 0, { value: E(1) });   // u2 buy -> holder fee distributed to u1
    await c.connect(u3).buy(0, 0, { value: E(1) });   // u3 buy -> distributed to u1 + u2

    // curve holds the bulk of supply but is excluded from dividends
    const totalSupply = await t.totalSupply();
    const divSupply = await t.dividendSupply();
    expect(divSupply).to.be.lt(totalSupply / 2n);      // curve's huge balance is excluded
    expect(await t.excluded(curve)).to.equal(true);

    const w1 = await t.withdrawableRewardOf(u1.address);
    const w2 = await t.withdrawableRewardOf(u2.address);
    expect(w1).to.be.gt(0);                            // u1 earned ETH holder rewards
    expect(w2).to.be.gt(0);                            // u2 earned from u3's buy
    expect(w1).to.be.gt(w2);                           // u1 held longer / through more trades

    // claim pays ETH
    const before = await ethers.provider.getBalance(u1.address);
    const tx = await t.connect(u1).claimRewards();
    const rc = await tx.wait();
    const after = await ethers.provider.getBalance(u1.address);
    expect(after).to.equal(before - rc.gasUsed * rc.gasPrice + w1);
    expect(await t.withdrawableRewardOf(u1.address)).to.equal(0);
  });

  it("Stock-Token launch: holder rewards are paid in the SAME Stock Token (NVDA), claimable", async () => {
    const { factory, creator, u1, u2, nvda } = await setup();
    const nvdaAddr = await nvda.getAddress();
    await nvda.mint(u1.address, E(100)); await nvda.mint(u2.address, E(100));
    const { token, curve } = await create(factory, creator, ERC20, nvdaAddr, true);
    const c = await curveAt(curve), t = await tokAt(token);
    expect(await t.rewardToken()).to.equal(nvdaAddr);   // reward asset == the pair token

    await nvda.connect(u1).approve(curve, E(100));
    await nvda.connect(u2).approve(curve, E(100));
    await c.connect(u1).buy(E(5), 0);                   // u1 holder
    await c.connect(u2).buy(E(5), 0);                   // u2 buy -> NVDA holder fee to u1

    const w1 = await t.withdrawableRewardOf(u1.address);
    expect(w1).to.be.gt(0);                             // rewards denominated in NVDA
    const before = await nvda.balanceOf(u1.address);
    await t.connect(u1).claimRewards();
    expect(await nvda.balanceOf(u1.address)).to.equal(before + w1); // claimed in NVDA, not ETH
  });

  it("holderRewards OFF: all of the vault (post-protocol) goes to the creator, holders get nothing", async () => {
    const { factory, creator, u1, u2 } = await setup();
    const { token, curve } = await create(factory, creator, ETH, ethers.ZeroAddress, false);
    const c = await curveAt(curve), t = await tokAt(token);
    await c.connect(u1).buy(0, 0, { value: E(1) });
    await c.connect(u2).buy(0, 0, { value: E(1) });
    expect(await t.withdrawableRewardOf(u1.address)).to.equal(0);
  });
});
