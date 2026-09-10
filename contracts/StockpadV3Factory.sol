// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StockpadTokenDividend} from "./StockpadTokenDividend.sol";
import {INonfungiblePositionManager, IUniswapV3Pool} from "./uniswap/IUniswapV3.sol";

interface IDivToken {
    function setCurve(address) external;
    function setExcluded(address, bool) external;
    function distributeReward(uint256) external payable;
    function dividendSupply() external view returns (uint256);
}

/// @title V3Locker
/// @notice Permanently holds a launch's Uniswap V3 LP position NFT (liquidity can never be
///         withdrawn). Anyone can `collectFees` — swap fees are collected and split:
///         protocol / creator / holders (holders paid in WETH via the dividend token).
contract V3Locker is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Pos { address token; address pool; address creator; bool holderRewards; uint16 holderShareBps; address pairToken; }
    INonfungiblePositionManager public immutable npm;
    address public immutable weth;
    address public immutable factory;
    address public immutable protocolRecipient;
    uint16 public constant PROTOCOL_BPS = 2000; // 20% of fees to protocol

    mapping(uint256 => Pos) public positions; // tokenId => info

    event Locked(uint256 indexed tokenId, address indexed token, address pool);
    event FeesCollected(uint256 indexed tokenId, uint256 wethFees, uint256 tokenFees, uint256 toCreator, uint256 toHolders, uint256 toProtocol);

    error NotFactory();
    constructor(address npm_, address weth_, address factory_, address protocol_) {
        npm = INonfungiblePositionManager(npm_); weth = weth_; factory = factory_; protocolRecipient = protocol_;
    }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) { return this.onERC721Received.selector; }

    function registerAndLock(uint256 tokenId, address token, address pool, address creator, bool holderRewards, uint16 holderShareBps, address pairToken) external {
        if (msg.sender != factory) revert NotFactory();
        positions[tokenId] = Pos(token, pool, creator, holderRewards, holderShareBps, pairToken);
        emit Locked(tokenId, token, pool);
    }

    /// Permissionless: collect the position's accrued swap fees and split them.
    /// The "pair asset" is WETH for ETH launches, or the paired Stock Token for stock launches —
    /// holders are paid rewards in exactly that asset (like Pons: hold an NVDA-paired coin, earn NVDA).
    function collectFees(uint256 tokenId) external nonReentrant {
        Pos memory p = positions[tokenId];
        require(p.token != address(0), "unknown");
        (uint256 a0, uint256 a1) = npm.collect(INonfungiblePositionManager.CollectParams({ tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max }));
        // figure out which side is the pair asset vs the launch token
        (uint256 pairFees, uint256 tokenFees) = IUniswapV3Pool(p.pool).token0() == p.pairToken ? (a0, a1) : (a1, a0);

        uint256 toProtocol = (pairFees * PROTOCOL_BPS) / 10000;
        uint256 rest = pairFees - toProtocol;
        // of the post-protocol remainder, `holderShareBps` goes to holders (as the pair asset),
        // the rest to the creator (their optional dev cut). holderRewards must be on + real holders.
        uint256 toHolders = (p.holderRewards && IDivToken(p.token).dividendSupply() > 0) ? (rest * p.holderShareBps) / 10000 : 0;
        uint256 toCreator = rest - toHolders;

        if (toProtocol > 0) IERC20(p.pairToken).safeTransfer(protocolRecipient, toProtocol);
        if (toCreator > 0) IERC20(p.pairToken).safeTransfer(p.creator, toCreator);
        if (toHolders > 0) { IERC20(p.pairToken).forceApprove(p.token, toHolders); IDivToken(p.token).distributeReward(toHolders); }
        // token-side fees go to the creator
        if (tokenFees > 0) IERC20(p.token).safeTransfer(p.creator, tokenFees);

        emit FeesCollected(tokenId, pairFees, tokenFees, toCreator, toHolders, toProtocol);
    }
    // No function ever transfers the position NFT out — liquidity is locked forever.
}

/// @title StockpadV3Factory  (option B — V3-native)
/// @notice Launches a fixed-supply token DIRECTLY into a real Uniswap V3 pool with single-sided
///         token liquidity, so it behaves like a bonding curve BUT is a real DEX pool from block 1
///         (tradable by any router/aggregator on Robinhood Chain). Priced in ETH; a stock is stored
///         as the theme (display "$TICKER · STOCK"). Holder rewards + permanent LP lock via V3Locker.
///         ⚠️ Unaudited. The V3 price/tick seeding MUST be validated on testnet before mainnet value.
contract StockpadV3Factory is Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    // default initial price ~ 1e-9 pair per token (used when priceDen arg is 0). The frontend
    // normally passes a computed priceDen so the starting market cap lands ~ $2.5k–3k for ANY stock.
    uint256 private constant PRICE_DEN = 1e9;
    uint16 public constant DEFAULT_HOLDER_SHARE_BPS = 4000; // default 40% of post-protocol fee to holders

    INonfungiblePositionManager public immutable npm;
    address public immutable weth;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    V3Locker public immutable locker;

    struct Launch { address token; address pool; address creator; string stock; uint256 tokenId; bool holderRewards; address pairToken; }
    Launch[] public launches;

    event TokenCreated(uint256 indexed id, address indexed token, address indexed pool, address creator, string name, string symbol, string stock, uint256 tokenId, bool holderRewards, address pairToken);

    error PoolInitFailed();

    constructor(address owner_, address npm_, address weth_, uint24 fee_, int24 tickSpacing_, address protocolRecipient_) Ownable(owner_) {
        npm = INonfungiblePositionManager(npm_); weth = weth_; fee = fee_; tickSpacing = tickSpacing_;
        locker = new V3Locker(npm_, weth_, address(this), protocolRecipient_);
    }

    /// @param pairToken the quote asset the coin trades against: address(0) = ETH (WETH); otherwise a
    ///        canonical Robinhood Stock Token (e.g. NVDA) — then price moves with the stock and holders
    ///        earn that stock token as rewards, exactly like Pons.
    /// @param creatorTo wallet that receives the creator's share of fees (a "creator wallet");
    ///        pass address(0) to use msg.sender.
    /// @param holderShareBps share (of the post-protocol trade fee) paid to holders as rewards;
    ///        the remainder is the creator's cut. Pass 0 for a pure dev-fee launch, up to 10000.
    /// @param priceDen sets the initial price = 1/priceDen (pair asset per token); pass 0 for the
    ///        default. The frontend computes it from the pair's USD value so the starting market cap
    ///        is ~ $2.5k–3k regardless of which stock is paired.
    function createLaunch(string calldata name, string calldata symbol, string calldata stock, address pairToken, address creatorTo, bool holderRewards, uint16 holderShareBps, uint256 priceDen)
        external returns (address tokenAddr, address poolAddr, uint256 tokenId)
    {
        require(holderShareBps <= 10000, "bps");
        uint256 den = priceDen == 0 ? PRICE_DEN : priceDen;
        require(den >= 1e3 && den <= 1e15, "den");
        address creator = creatorTo == address(0) ? msg.sender : creatorTo;
        address pair = pairToken == address(0) ? weth : pairToken;   // ETH launches quote in WETH
        // holders are paid rewards in the pair asset (WETH for ETH launches, the Stock Token otherwise)
        StockpadTokenDividend tok = new StockpadTokenDividend(name, symbol, TOTAL_SUPPLY, address(this), pair);
        tokenAddr = address(tok);
        bool tokenIsToken0 = tokenAddr < pair;
        (address token0, address token1) = tokenIsToken0 ? (tokenAddr, pair) : (pair, tokenAddr);

        // initial sqrtPriceX96 so the token starts very cheap in the pair asset
        uint160 sqrtPriceX96 = tokenIsToken0
            ? uint160(Math.sqrt(Math.mulDiv(1, 1 << 192, den)))              // price = pair/token, small
            : uint160(Math.sqrt(Math.mulDiv(den, 1 << 192, 1)));             // price = token/pair, large

        poolAddr = npm.createAndInitializePoolIfNecessary(token0, token1, fee, sqrtPriceX96);
        if (poolAddr == address(0)) revert PoolInitFailed();

        // exclude the pool/NPM from holder-reward accounting (they hold tokens but aren't holders)
        tok.setCurve(address(locker));      // locker is the authorized reward distributor
        tok.setExcluded(poolAddr, true);
        tok.setExcluded(address(npm), true);

        // single-sided token liquidity: place the whole supply on the token side of the range
        (, int24 curTick, , , , , ) = IUniswapV3Pool(poolAddr).slot0();
        int24 maxT = (int24(887272) / tickSpacing) * tickSpacing;
        int24 tickLower; int24 tickUpper; uint256 amt0; uint256 amt1;
        if (tokenIsToken0) { tickLower = _ceil(curTick); tickUpper = maxT; amt0 = TOTAL_SUPPLY; amt1 = 0; }
        else { tickLower = -maxT; tickUpper = _floor(curTick); amt0 = 0; amt1 = TOTAL_SUPPLY; }

        IERC20(tokenAddr).forceApprove(address(npm), TOTAL_SUPPLY);
        (tokenId, , , ) = npm.mint(INonfungiblePositionManager.MintParams({
            token0: token0, token1: token1, fee: fee, tickLower: tickLower, tickUpper: tickUpper,
            amount0Desired: amt0, amount1Desired: amt1, amount0Min: 0, amount1Min: 0,
            recipient: address(locker), deadline: block.timestamp + 3600
        }));

        locker.registerAndLock(tokenId, tokenAddr, poolAddr, creator, holderRewards, holderShareBps, pair);
        launches.push(Launch(tokenAddr, poolAddr, creator, stock, tokenId, holderRewards, pair));
        emit TokenCreated(launches.length - 1, tokenAddr, poolAddr, creator, name, symbol, stock, tokenId, holderRewards, pair);
    }

    function _ceil(int24 t) internal view returns (int24) { int24 s = tickSpacing; int24 r = (t / s) * s; if (r < t) r += s; return r; }
    function _floor(int24 t) internal view returns (int24) { int24 s = tickSpacing; int24 r = (t / s) * s; if (r > t) r -= s; return r; }

    function launchCount() external view returns (uint256) { return launches.length; }
    function getLaunch(uint256 id) external view returns (Launch memory) { return launches[id]; }
    function allLaunches() external view returns (Launch[] memory) { return launches; }
}
