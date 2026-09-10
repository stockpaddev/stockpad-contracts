const { expect } = require("chai");
const { ethers } = require("hardhat");

// Flow test for option B (V3-native launcher). This proves the WIRING end-to-end against a
// mock Uniswap V3: create pool -> single-sided token liquidity -> LP NFT permanently locked ->
// collectFees splits protocol/creator/holders (holders paid in WETH via the dividend token).
// NOTE: the mock does NOT reproduce real V3 tick/price math — that must be validated on
// Robinhood testnet (46630) with a live buy->sell round-trip before mainnet value.
describe("StockpadV3Factory (option B, V3-native)", function () {
  const FEE = 10000, SPACING = 200;
  let owner, creator, buyer, protocol;
  let weth, npm, factory, locker;

  beforeEach(async () => {
    [owner, creator, buyer, protocol] = await ethers.getSigners();
    weth = await (await ethers.getContractFactory("MockWETH9")).deploy();
    npm = await (await ethers.getContractFactory("MockNonfungiblePositionManager"))
      .deploy(ethers.ZeroAddress, await weth.getAddress());
    factory = await (await ethers.getContractFactory("StockpadV3Factory"))
      .deploy(owner.address, await npm.getAddress(), await weth.getAddress(), FEE, SPACING, protocol.address);
    locker = await ethers.getContractAt("V3Locker", await factory.locker());
  });

  async function launch(holderRewards = true) {
    const tx = await factory.connect(creator).createLaunch("Hope", "HOPE", "NVIDIA", ethers.ZeroAddress, ethers.ZeroAddress, holderRewards, 4000, 0);
    await tx.wait();
    const L = await factory.getLaunch(0);
    const token = await ethers.getContractAt("StockpadTokenDividend", L.token);
    const pool = await ethers.getContractAt("MockV3Pool", L.pool);
    return { L, token, pool, tokenId: L.tokenId };
  }

  it("launches into a real pool and permanently locks the LP position", async () => {
    const { L, token, pool, tokenId } = await launch();
    expect(await factory.launchCount()).to.equal(1n);
    // whole supply seeded as liquidity, held by the pool
    expect(await token.balanceOf(await pool.getAddress())).to.equal(await factory.TOTAL_SUPPLY());
    // LP NFT is owned by the locker and there is no path to move it out
    expect(await npm.ownerOf(tokenId)).to.equal(await locker.getAddress());
    expect(L.stock).to.equal("NVIDIA");
    expect(L.creator).to.equal(creator.address);
  });

  it("collectFees pays holders (in WETH) + creator + protocol when there are real holders", async () => {
    const { token, pool, tokenId } = await launch(true);

    // simulate a buyer receiving tokens from the pool => a real (non-excluded) holder exists
    const held = ethers.parseEther("1000000");
    await pool.simSwapOut(await token.getAddress(), buyer.address, held);
    expect(await token.dividendSupply()).to.equal(held);

    // simulate 1 WETH of accrued swap fees on the WETH side of the position
    const feeWeth = ethers.parseEther("1");
    await weth.deposit({ value: feeWeth });
    await weth.transfer(await npm.getAddress(), feeWeth);
    const tokenIsToken0 = (await pool.token0()) === (await token.getAddress());
    // WETH is the *other* side; seed it as the correct token index
    if (tokenIsToken0) await npm.seedFees(tokenId, 0, feeWeth);
    else await npm.seedFees(tokenId, feeWeth, 0);

    const protoBefore = await weth.balanceOf(protocol.address);
    const creatorBefore = await weth.balanceOf(creator.address);
    await locker.collectFees(tokenId);

    const proto = (await weth.balanceOf(protocol.address)) - protoBefore;      // 20%
    const toHolders = feeWeth * 8000n / 10000n * 4000n / 10000n;                // 40% of the 80% remainder
    const toCreator = feeWeth - proto - toHolders;
    expect(proto).to.equal(feeWeth * 2000n / 10000n);
    expect((await weth.balanceOf(creator.address)) - creatorBefore).to.equal(toCreator);

    // holder can claim their WETH reward (magnified-dividend math may drop <=1 wei of dust)
    const claimable = await token.withdrawableRewardOf(buyer.address);
    expect(claimable).to.be.closeTo(toHolders, 2n);
    await token.connect(buyer).claimRewards();
    expect(await weth.balanceOf(buyer.address)).to.equal(claimable);
  });

  it("STOCK-paired: pool is MEME/STOCK and holders earn the STOCK token as rewards (like Pons)", async () => {
    // a mock canonical Stock Token (e.g. NVDA)
    const nvda = await (await ethers.getContractFactory("MockERC20")).deploy("Nvidia RH", "NVDA", 18);
    await nvda.mint(owner.address, ethers.parseEther("1000000"));
    const tx = await factory.connect(creator).createLaunch("Jensen", "JEN", "NVIDIA", await nvda.getAddress(), ethers.ZeroAddress, true, 4000, 0);
    await tx.wait();
    const L = await factory.getLaunch(0);
    const token = await ethers.getContractAt("StockpadTokenDividend", L.token);
    const pool = await ethers.getContractAt("MockV3Pool", L.pool);
    expect(L.pairToken).to.equal(await nvda.getAddress());
    // reward token of the dividend token must be NVDA
    expect(await token.rewardToken()).to.equal(await nvda.getAddress());
    // one of the pool sides is NVDA (not WETH)
    const sides = [await pool.token0(), await pool.token1()].map(a => a.toLowerCase());
    expect(sides).to.include((await nvda.getAddress()).toLowerCase());

    // a buyer becomes a holder
    const held = ethers.parseEther("1000000");
    await pool.simSwapOut(await token.getAddress(), buyer.address, held);

    // simulate NVDA fees accrued on the pair side
    const feeNvda = ethers.parseEther("10");
    await nvda.transfer(await npm.getAddress(), feeNvda);
    const tokenIsToken0 = (await pool.token0()) === (await token.getAddress());
    if (tokenIsToken0) await npm.seedFees(L.tokenId, 0, feeNvda); else await npm.seedFees(L.tokenId, feeNvda, 0);

    await locker.collectFees(L.tokenId);
    // holder can claim NVDA rewards (40% of the 80% post-protocol remainder)
    const claimable = await token.withdrawableRewardOf(buyer.address);
    expect(claimable).to.be.closeTo(feeNvda * 8000n / 10000n * 4000n / 10000n, 2n);
    await token.connect(buyer).claimRewards();
    expect(await nvda.balanceOf(buyer.address)).to.equal(claimable);
  });

  it("with no holders, the holder share rolls to the creator", async () => {
    const { pool, tokenId, token } = await launch(true);
    const feeWeth = ethers.parseEther("1");
    await weth.deposit({ value: feeWeth });
    await weth.transfer(await npm.getAddress(), feeWeth);
    const tokenIsToken0 = (await pool.token0()) === (await token.getAddress());
    if (tokenIsToken0) await npm.seedFees(tokenId, 0, feeWeth); else await npm.seedFees(tokenId, feeWeth, 0);

    const creatorBefore = await weth.balanceOf(creator.address);
    await locker.collectFees(tokenId);
    // creator gets the full 80% remainder (no holders to pay)
    expect((await weth.balanceOf(creator.address)) - creatorBefore).to.equal(feeWeth * 8000n / 10000n);
  });
});
