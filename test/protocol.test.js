const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(String(n));
const ETH = 0, ERC20 = 1;
const VIRT = E(3), THRESH = E(10), FEE = 200; // 2%

async function deploy() {
  const [deployer, creator, user, protocol] = await ethers.getSigners();

  const Registry = await ethers.getContractFactory("StockTokenRegistry");
  const registry = await Registry.deploy(deployer.address);

  const Escrow = await ethers.getContractFactory("FeeEscrow");
  const escrow = await Escrow.deploy();

  const Factory = await ethers.getContractFactory("StockpadFactory");
  const factory = await Factory.deploy(deployer.address, await registry.getAddress(), await escrow.getAddress(), protocol.address, VIRT, THRESH);

  await escrow.initFactory(await factory.getAddress());

  // canonical + fake stock token (18 decimals, like real Robinhood Stock Tokens)
  const Mock = await ethers.getContractFactory("MockERC20");
  const nvda = await Mock.deploy("Nvidia Robinhood Token", "NVDA", 18);
  const fakeNvda = await Mock.deploy("Nvidia (FAKE)", "NVDA", 18);
  await registry.add(await nvda.getAddress()); // only the canonical one is allowlisted

  return { deployer, creator, user, protocol, registry, escrow, factory, nvda, fakeNvda };
}

async function curveAt(addr) { return await ethers.getContractAt("StockpadCurve", addr); }
async function tokenAt(addr) { return await ethers.getContractAt("StockpadToken", addr); }

async function createEth(factory, creator) {
  const tx = await factory.connect(creator).createLaunch("My ETH Coin", "MEC", ETH, ethers.ZeroAddress, FEE, false);
  const rc = await tx.wait();
  const ev = rc.logs.map(l => { try { return factory.interface.parseLog(l); } catch { return null; } }).find(x => x && x.name === "TokenCreated");
  return { token: ev.args.token, curve: ev.args.curve, ev };
}
async function createNvda(factory, creator, nvdaAddr) {
  const tx = await factory.connect(creator).createLaunch("Nvidia Frog", "NVDAFROG", ERC20, nvdaAddr, FEE, false);
  const rc = await tx.wait();
  const ev = rc.logs.map(l => { try { return factory.interface.parseLog(l); } catch { return null; } }).find(x => x && x.name === "TokenCreated");
  return { token: ev.args.token, curve: ev.args.curve, ev };
}

describe("Stockpad v2 — ETH mode", () => {
  it("TEST 1: creates an ETH launch and emits TokenCreated (pairType ETH, pairToken 0)", async () => {
    const { factory, creator } = await deploy();
    const { ev, curve } = await createEth(factory, creator);
    expect(ev.args.pairType).to.equal(ETH);
    expect(ev.args.pairToken).to.equal(ethers.ZeroAddress);
    const c = await curveAt(curve);
    expect(await c.pairType()).to.equal(ETH);
    expect(await c.creator()).to.equal(creator.address);
  });

  it("TEST 2 & 11-analog: buys with ETH, receives Stockpad tokens", async () => {
    const { factory, creator, user } = await deploy();
    const { curve, token } = await createEth(factory, creator);
    const c = await curveAt(curve), t = await tokenAt(token);
    const before = await t.balanceOf(user.address);
    await c.connect(user).buy(0, 0, { value: E(1) });
    expect(await t.balanceOf(user.address)).to.be.gt(before);
  });

  it("TEST 3: sells Stockpad tokens back for ETH", async () => {
    const { factory, creator, user } = await deploy();
    const { curve, token } = await createEth(factory, creator);
    const c = await curveAt(curve), t = await tokenAt(token);
    await c.connect(user).buy(0, 0, { value: E(1) });
    const bal = await t.balanceOf(user.address);
    await t.connect(user).approve(curve, bal);
    const ethBefore = await ethers.provider.getBalance(user.address);
    await c.connect(user).sell(bal, 0);
    // got some ETH back (net of gas this is approximate; assert token spent)
    expect(await t.balanceOf(user.address)).to.equal(0n);
    expect(await ethers.provider.getBalance(user.address)).to.be.gt(ethBefore - E(0.02));
  });

  it("TEST 4 & 5: creator earns ETH in escrow and can claim it", async () => {
    const { factory, escrow, creator, user } = await deploy();
    const { curve } = await createEth(factory, creator);
    const c = await curveAt(curve);
    await c.connect(user).buy(0, 0, { value: E(1) });
    const claimable = await escrow.getClaimableETH(creator.address);
    expect(claimable).to.be.gt(0); // TEST 4
    const before = await ethers.provider.getBalance(creator.address);
    const tx = await escrow.connect(creator).claim();
    const rc = await tx.wait();
    const gas = rc.gasUsed * rc.gasPrice;
    const after = await ethers.provider.getBalance(creator.address);
    expect(after).to.equal(before - gas + claimable); // TEST 5 exact
    expect(await escrow.getClaimableETH(creator.address)).to.equal(0);
  });
});

describe("Stockpad v2 — Stock Token mode (real ERC-20 movement)", () => {
  it("TEST 6: creates an NVDA-paired launch", async () => {
    const { factory, creator, nvda } = await deploy();
    const { ev } = await createNvda(factory, creator, await nvda.getAddress());
    expect(ev.args.pairType).to.equal(ERC20);
    expect(ev.args.pairToken).to.equal(await nvda.getAddress());
  });

  it("TEST 7 & 22: rejects a non-canonical (fake) NVDA and any unsupported pair", async () => {
    const { factory, creator, fakeNvda } = await deploy();
    await expect(factory.connect(creator).createLaunch("x", "x", ERC20, await fakeNvda.getAddress(), FEE, false))
      .to.be.revertedWithCustomError(factory, "InvalidPair");
    await expect(factory.connect(creator).createLaunch("x", "x", ERC20, ethers.ZeroAddress, FEE, false))
      .to.be.revertedWithCustomError(factory, "InvalidPair");
  });

  it("TEST 8-13: approve + buy with real NVDA, balances move both ways on sell", async () => {
    const { factory, creator, user, nvda } = await deploy();
    const nvdaAddr = await nvda.getAddress();
    await nvda.mint(user.address, E(100)); // user starts with 100 NVDA
    const { curve, token } = await createNvda(factory, creator, nvdaAddr);
    const c = await curveAt(curve), t = await tokenAt(token);

    await nvda.connect(user).approve(curve, E(100));       // TEST 8
    const nvdaBefore = await nvda.balanceOf(user.address);
    await c.connect(user).buy(E(5), 0);                     // TEST 9: buy with 5 NVDA
    expect(await nvda.balanceOf(user.address)).to.equal(nvdaBefore - E(5)); // TEST 10: NVDA down exactly 5
    const tok = await t.balanceOf(user.address);
    expect(tok).to.be.gt(0);                                // TEST 11: Stockpad token up

    await t.connect(user).approve(curve, tok);
    const nvdaMid = await nvda.balanceOf(user.address);
    await c.connect(user).sell(tok, 0);                     // TEST 12: sell
    expect(await t.balanceOf(user.address)).to.equal(0n);
    expect(await nvda.balanceOf(user.address)).to.be.gt(nvdaMid); // TEST 13: receives NVDA back
  });

  it("TEST 14 & 15: creator earns NVDA and claims the SAME token (not ETH)", async () => {
    const { factory, escrow, creator, user, nvda } = await deploy();
    const nvdaAddr = await nvda.getAddress();
    await nvda.mint(user.address, E(100));
    const { curve } = await createNvda(factory, creator, nvdaAddr);
    const c = await curveAt(curve);
    await nvda.connect(user).approve(curve, E(100));
    await c.connect(user).buy(E(5), 0);

    const claimable = await escrow.getClaimableToken(creator.address, nvdaAddr);
    expect(claimable).to.be.gt(0);                          // TEST 14
    expect(await escrow.getClaimableETH(creator.address)).to.equal(0); // reward is NVDA, not ETH
    const before = await nvda.balanceOf(creator.address);
    await escrow.connect(creator).claimToken(nvdaAddr);     // TEST 15
    expect(await nvda.balanceOf(creator.address)).to.equal(before + claimable);
  });
});

describe("Stockpad v2 — safety & invariants", () => {
  it("TEST 20: slippage protection reverts when minOut not met", async () => {
    const { factory, creator, user } = await deploy();
    const { curve } = await createEth(factory, creator);
    const c = await curveAt(curve);
    await expect(c.connect(user).buy(0, E(1e12), { value: E(1) })).to.be.revertedWithCustomError(c, "Slippage");
  });

  it("TEST 21: FeeEscrow.claim is reentrancy-safe", async () => {
    const [deployer] = await ethers.getSigners();
    const Escrow = await ethers.getContractFactory("FeeEscrow");
    const escrow = await Escrow.deploy();
    await escrow.initFactory(deployer.address);            // deployer acts as factory
    const Att = await ethers.getContractFactory("ReentrantClaimer");
    const att = await Att.deploy(await escrow.getAddress());
    await escrow.authorizeCurve(await att.getAddress(), true);
    await att.creditSelf({ value: E(1) });                 // attacker credited 1 ETH
    await expect(att.attack()).to.be.reverted;             // reentrant claim blocked
  });

  it("TEST 23: pair asset is immutable after creation", async () => {
    const { factory, creator, nvda } = await deploy();
    const { curve } = await createNvda(factory, creator, await nvda.getAddress());
    const c = await curveAt(curve);
    expect(await c.pairToken()).to.equal(await nvda.getAddress());
    expect(await c.pairType()).to.equal(ERC20);
    // no setter exists for pairType/pairToken (they are immutable) — compile-time guarantee
    expect(c.setPairToken).to.equal(undefined);
  });

  it("TEST 24: claim cannot double-spend", async () => {
    const { factory, escrow, creator, user } = await deploy();
    const { curve } = await createEth(factory, creator);
    const c = await curveAt(curve);
    await c.connect(user).buy(0, 0, { value: E(1) });
    await escrow.connect(creator).claim();
    await expect(escrow.connect(creator).claim()).to.be.revertedWithCustomError(escrow, "NothingToClaim");
  });

  it("TEST 25: ETH and ERC-20 reward ledgers stay separate", async () => {
    const { factory, escrow, creator, user, nvda } = await deploy();
    const nvdaAddr = await nvda.getAddress();
    // ETH launch earns ETH
    const eth = await createEth(factory, creator);
    await (await curveAt(eth.curve)).connect(user).buy(0, 0, { value: E(1) });
    // NVDA launch earns NVDA
    await nvda.mint(user.address, E(50));
    const nv = await createNvda(factory, creator, nvdaAddr);
    await nvda.connect(user).approve(nv.curve, E(50));
    await (await curveAt(nv.curve)).connect(user).buy(E(5), 0);

    expect(await escrow.getClaimableETH(creator.address)).to.be.gt(0);
    expect(await escrow.getClaimableToken(creator.address, nvdaAddr)).to.be.gt(0);
    // claiming ETH does not affect the NVDA ledger
    const nvdaClaim = await escrow.getClaimableToken(creator.address, nvdaAddr);
    await escrow.connect(creator).claim();
    expect(await escrow.getClaimableETH(creator.address)).to.equal(0);
    expect(await escrow.getClaimableToken(creator.address, nvdaAddr)).to.equal(nvdaClaim);
  });

  it("TEST 16 (partial): curve stops trading once the graduation threshold is reached", async () => {
    const { factory, creator, user } = await deploy();
    const { curve } = await createEth(factory, creator);
    const c = await curveAt(curve);
    await c.connect(user).buy(0, 0, { value: E(11) }); // net > 10 ETH threshold
    expect(await c.graduated()).to.equal(true);
    await expect(c.connect(user).buy(0, 0, { value: E(1) })).to.be.revertedWithCustomError(c, "Graduated");
  });
});
