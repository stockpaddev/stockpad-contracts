const { expect } = require("chai");
const { ethers } = require("hardhat");

// Flow test for the V4-native launcher against a mock PoolManager. Proves the wiring:
// initialize -> unlock/modifyLiquidity/settle (single-sided token in) -> locked position ->
// collectFees (unlock/modifyLiquidity(0)/take) -> split protocol/holders/creator + launch fee.
// NOTE: the mock does NOT reproduce real V4 tick/liquidity math — validate on testnet before mainnet.
describe("StockpadV4Factory (V4-native, custom fee)", function () {
  const FEE = 20000, SPACING = 200; // 2% pool fee (V4 has no tier cap)
  const LAUNCH_FEE = ethers.parseEther("0.0005");
  const SUPPLY = ethers.parseEther("1000000000");
  let owner, creator, buyer, protocol, weth, pm, factory, locker;

  function keyOf(token, pairAddr) {
    const [c0, c1] = BigInt(token) < BigInt(pairAddr) ? [token, pairAddr] : [pairAddr, token];
    return { currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: ethers.ZeroAddress };
  }

  beforeEach(async () => {
    [owner, creator, buyer, protocol] = await ethers.getSigners();
    weth = await (await ethers.getContractFactory("MockWETH9")).deploy();
    pm = await (await ethers.getContractFactory("MockV4PoolManager")).deploy(await weth.getAddress());
    factory = await (await ethers.getContractFactory("StockpadV4Factory"))
      .deploy(owner.address, await pm.getAddress(), await weth.getAddress(), protocol.address, LAUNCH_FEE);
    locker = await ethers.getContractAt("V4Locker", await factory.locker());
  });

  async function launch(holderRewards = true, holderShareBps = 5000) {
    const p = {
      name: "Hope", symbol: "HOPE", stock: "NVIDIA",
      pairToken: ethers.ZeroAddress, creatorTo: ethers.ZeroAddress,
      holderRewards, holderShareBps, fee: FEE, tickSpacing: SPACING,
      tickLower: 0, tickUpper: 0, liquidity: SUPPLY, sqrtPriceX96: 1n << 96n,
      salt: ethers.ZeroHash, logoURI: "ipfs://testlogo"
    };
    const tx = await factory.connect(creator).createLaunch(p, { value: LAUNCH_FEE });
    await tx.wait();
    const L = await factory.getLaunch(0);
    const token = await ethers.getContractAt("StockpadTokenDividend", L.token);
    return { L, token };
  }

  it("charges the launch fee and locks single-sided liquidity in the pool manager", async () => {
    const before = await ethers.provider.getBalance(protocol.address);
    const { token } = await launch();
    expect(await factory.launchCount()).to.equal(1n);
    // the whole supply was settled into the PoolManager (locked liquidity)
    expect(await token.balanceOf(await pm.getAddress())).to.equal(SUPPLY);
    // launch fee went to the protocol
    expect((await ethers.provider.getBalance(protocol.address)) - before).to.equal(LAUNCH_FEE);
  });

  async function seedWethFees(token, feeWeth) {
    const tokenAddr = await token.getAddress(), wethAddr = await weth.getAddress();
    await weth.deposit({ value: feeWeth });
    await weth.transfer(await pm.getAddress(), feeWeth);
    const key = keyOf(tokenAddr, wethAddr);
    const wethIs0 = BigInt(wethAddr) < BigInt(tokenAddr);
    await pm.seedFees(key, wethIs0 ? feeWeth : 0, wethIs0 ? 0 : feeWeth);
  }

  it("holder-sharing ON: protocol gets ETH, ALL the remainder goes to holders", async () => {
    const { token } = await launch(true);
    const held = ethers.parseEther("1000000");
    await pm.simSwapOut(await token.getAddress(), buyer.address, held);

    const feeWeth = ethers.parseEther("1");
    await seedWethFees(token, feeWeth);
    const protoBefore = await ethers.provider.getBalance(protocol.address);
    await locker.collectFees(0);
    expect((await ethers.provider.getBalance(protocol.address)) - protoBefore).to.equal(feeWeth * 2000n / 10000n);

    const toHolders = feeWeth * 8000n / 10000n; // ON => 100% of the 80% remainder to holders
    const claimable = await token.withdrawableRewardOf(buyer.address);
    expect(claimable).to.be.closeTo(toHolders, 2n);
    await token.connect(buyer).claimRewards();
    expect(await weth.balanceOf(buyer.address)).to.equal(claimable);
  });

  it("holder-sharing OFF: remainder is the creator's to CLAIM (in ETH), creator-only", async () => {
    const { token } = await launch(false);
    const feeWeth = ethers.parseEther("1");
    await seedWethFees(token, feeWeth);
    await locker.collectFees(0); // permissionless distribute -> accrues to the creator

    const [owedPair] = await locker.creatorClaimable(0);
    expect(owedPair).to.equal(feeWeth * 8000n / 10000n); // all 80% remainder held for the creator

    await expect(locker.connect(buyer).claimCreator(0)).to.be.revertedWithCustomError(locker, "NotCreator");
    const before = await ethers.provider.getBalance(creator.address);
    const rc = await (await locker.connect(creator).claimCreator(0)).wait();
    const after = await ethers.provider.getBalance(creator.address);
    // creator received ~owedPair in native ETH (minus gas)
    expect(after - before + rc.gasUsed * rc.gasPrice).to.be.closeTo(owedPair, 10n ** 13n);
  });

  it("StockpadV4Swapper buys the token with ETH (wrap -> V4 swap -> deliver token)", async () => {
    const { token } = await launch();
    const tokenAddr = await token.getAddress(), wethAddr = await weth.getAddress();
    const swapper = await ethers.getContractAt("StockpadV4Swapper", await factory.swapper());
    const key = keyOf(tokenAddr, wethAddr);
    const wethIs0 = BigInt(wethAddr) < BigInt(tokenAddr);
    const amountIn = ethers.parseEther("0.1");
    // buy: input = WETH (sent as ETH). zeroForOne when WETH is currency0.
    await swapper.connect(buyer).swapExactIn(key, wethIs0, amountIn, 0, buyer.address, { value: amountIn });
    // mock is 1:1, so the buyer receives amountIn worth of the token
    expect(await token.balanceOf(buyer.address)).to.equal(amountIn);
  });

  it("stores the launch logo URL on-chain (logoURI / logoOf)", async () => {
    const { token } = await launch();
    expect(await factory.logoURI(0)).to.equal("ipfs://testlogo");
    expect(await factory.logoOf(await token.getAddress())).to.equal("ipfs://testlogo");
  });

  it("swapExactInAndCollect auto-distributes fees to holders in the same trade", async () => {
    const { token } = await launch(true); // holder-sharing ON
    const tokenAddr = await token.getAddress(), wethAddr = await weth.getAddress();
    const swapper = await ethers.getContractAt("StockpadV4Swapper", await factory.swapper());
    const key = keyOf(tokenAddr, wethAddr);
    const wethIs0 = BigInt(wethAddr) < BigInt(tokenAddr);
    // give the buyer some tokens so they're a holder that can receive dividends
    const held = ethers.parseEther("1000000");
    await pm.simSwapOut(tokenAddr, buyer.address, held);
    // seed pool fees, then buy via the auto-collect variant -> should distribute without a separate call
    await seedWethFees(token, ethers.parseEther("1"));
    const amountIn = ethers.parseEther("0.1");
    await swapper.connect(buyer).swapExactInAndCollect(key, wethIs0, amountIn, 0, buyer.address, await factory.locker(), 0, { value: amountIn });
    expect(await token.withdrawableRewardOf(buyer.address)).to.be.gt(0n);
  });
});
