// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {StockpadTokenDividend} from "./StockpadTokenDividend.sol";
import {IPoolManager, IUnlockCallback, PoolKey, ModifyLiquidityParams, SwapParams, BalanceDeltaLib} from "./uniswap/IUniswapV4.sol";
import {IWETH9} from "./uniswap/IUniswapV3.sol";

interface IDivToken4 {
    function setCurve(address) external;
    function setExcluded(address, bool) external;
    function distributeReward(uint256) external payable;
    function dividendSupply() external view returns (uint256);
}

// Uniswap V3 SwapRouter02 (exact-input, multi-hop via encoded path). Used ONLY for the optional
// atomic dev buy on stock/USDG-paired launches: ETH -> pair asset before the V4 pair -> token hop.
interface ISwapRouterV3 {
    struct ExactInputParams { bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum; }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

// Our own V4 swapper (defined below) — used by the locker to convert token-side fees into the pair
// asset, so creators/holders receive the FULL fee value in the pair (FLY/ETH/USDG), never meme tokens.
interface ISwapper4 {
    function swapExactIn(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minOut, address to) external payable returns (uint256);
}

/// @title V4Locker
/// @notice Owns a launch's Uniswap V4 liquidity position INSIDE the singleton PoolManager (there is
///         no NFT — the position is keyed by this contract's address and is never withdrawn, so the
///         liquidity is locked forever). Anyone can `collectFees`: the pool's accrued swap fees are
///         collected and split protocol / holders / creator, all paid in the pair asset (WETH for ETH
///         launches, the Stock Token for stock launches — holders earn that stock, like Pons).
contract V4Locker is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using BalanceDeltaLib for int256;

    IPoolManager public immutable pm;
    address public immutable factory;
    address public immutable protocolRecipient;
    address public immutable weth;
    uint16 public constant PROTOCOL_BPS = 2000; // 20% of fees to protocol (Stockpad dev revenue)

    struct Pos {
        address token; address pair; address creator; bool holderRewards; uint16 holderShareBps;
        PoolKey key; int24 tickLower; int24 tickUpper; bool burn;
    }
    // burn sink — tokens sent here are unspendable (no key), i.e. permanently removed from circulation
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    mapping(uint256 => Pos) public positions;
    // creator's claimable balance (in the PAIR asset), accrued when holder-sharing is OFF
    mapping(uint256 => uint256) public creatorOwedPair;
    mapping(uint256 => uint256) public creatorOwedToken; // retained for ABI compatibility; always 0 now
    address public swapper; // set once by the factory; used to convert token-side fees into the pair asset

    uint8 private constant OP_PROVIDE = 1;
    uint8 private constant OP_COLLECT = 2;

    event FeesDistributed(uint256 indexed id, uint256 pairFees, uint256 tokenFees, uint256 toCreator, uint256 toHolders, uint256 toProtocol);
    event CreatorClaimed(uint256 indexed id, uint256 pairAmount, uint256 tokenAmount);
    event FeesBurned(uint256 indexed id, uint256 pairSpent, uint256 tokensBoughtBurned, uint256 tokenFeesBurned, uint256 toProtocol);
    error NotFactory();
    error NotPoolManager();
    error NotSingleSided();
    error NotCreator();

    constructor(address pm_, address factory_, address protocol_, address weth_) {
        pm = IPoolManager(pm_); factory = factory_; protocolRecipient = protocol_; weth = weth_;
    }
    receive() external payable {}

    // Called by the factory right after it initializes the pool and funds this locker with the token.
    function provide(uint256 id, Pos calldata p, uint128 liquidity) external {
        if (msg.sender != factory) revert NotFactory();
        positions[id] = p;
        pm.unlock(abi.encode(OP_PROVIDE, id, int256(uint256(liquidity))));
    }

    // One-time wiring from the factory (the swapper is deployed alongside this locker).
    function setSwapper(address s) external { if (msg.sender != factory) revert NotFactory(); require(swapper == address(0), "set"); swapper = s; }

    /// Permissionless "Distribute": pull the pool's accrued swap fees and split them.
    /// Protocol share -> Stockpad dev wallet in ETH. The remainder goes ENTIRELY to holders when
    /// holder-sharing was enabled at launch, otherwise it is held for the creator to CLAIM.
    function collectFees(uint256 id) external nonReentrant {
        Pos memory p = positions[id];
        require(p.token != address(0), "unknown");
        bytes memory ret = pm.unlock(abi.encode(OP_COLLECT, id, int256(0)));
        (uint256 pairFees, uint256 tokenFees) = abi.decode(ret, (uint256, uint256));

        // BURN MODE (buyback-and-burn): protocol keeps its 20% (ETH), the rest of the pair-side fees are
        // used to BUY the meme token from this very pool and are sent to the dead address, and the
        // token-side fees are burned directly. Net effect: continuous deflation + buy pressure. No
        // holder dividends and no creator income in this mode.
        if (p.burn) {
            uint256 toProtocolB = (pairFees * PROTOCOL_BPS) / 10000;
            uint256 restB = pairFees - toProtocolB;
            if (toProtocolB > 0) {
                if (p.pair == weth) { IWETH9(weth).withdraw(toProtocolB); (bool ok, ) = protocolRecipient.call{value: toProtocolB}(""); require(ok, "eth"); }
                else IERC20(p.pair).safeTransfer(protocolRecipient, toProtocolB);
            }
            uint256 bought;
            if (restB > 0 && swapper != address(0)) {
                bool payWithPair = (p.key.currency0 == p.pair); // buying the meme: input is the pair side
                IERC20(p.pair).forceApprove(swapper, restB);
                try ISwapper4(swapper).swapExactIn(p.key, payWithPair, restB, 0, DEAD) returns (uint256 got) { bought = got; }
                catch { IERC20(p.pair).forceApprove(swapper, 0); restB = 0; } // couldn't route — leave for a later collect
            }
            if (tokenFees > 0) IERC20(p.token).safeTransfer(DEAD, tokenFees);
            emit FeesBurned(id, restB, bought, tokenFees, toProtocolB);
            return;
        }

        // Convert the token-side (meme) fees into the PAIR asset so creators/holders receive the FULL
        // fee value in the pair (FLY/ETH/USDG) — never meme tokens. Sold back through the same pool.
        if (tokenFees > 0 && swapper != address(0)) {
            IERC20(p.token).forceApprove(swapper, tokenFees);
            bool zeroForOne = (p.key.currency0 == p.token); // selling the meme token: input is the token side
            try ISwapper4(swapper).swapExactIn(p.key, zeroForOne, tokenFees, 0, address(this)) returns (uint256 got) {
                // when the pair is WETH the swapper returns native ETH — re-wrap so pairFees stays in WETH units
                if (p.pair == weth) { IWETH9(weth).deposit{value: got}(); }
                pairFees += got;
            } catch { /* if the swap can't route, leave token fees for a later collect */ }
        }

        uint256 toProtocol = (pairFees * PROTOCOL_BPS) / 10000;
        uint256 rest = pairFees - toProtocol;
        bool toHolders = p.holderRewards && IDivToken4(p.token).dividendSupply() > 0;

        // Stockpad dev revenue: always ETH (unwrap when the pair is WETH)
        if (toProtocol > 0) {
            if (p.pair == weth) { IWETH9(weth).withdraw(toProtocol); (bool ok, ) = protocolRecipient.call{value: toProtocol}(""); require(ok, "eth"); }
            else IERC20(p.pair).safeTransfer(protocolRecipient, toProtocol);
        }
        if (rest > 0) {
            if (toHolders) { IERC20(p.pair).forceApprove(p.token, rest); IDivToken4(p.token).distributeReward(rest); }
            else creatorOwedPair[id] += rest;               // creator claims later — all in the PAIR asset
        }

        emit FeesDistributed(id, pairFees, tokenFees, toHolders ? 0 : rest, toHolders ? rest : 0, toProtocol);
    }

    /// Creator-only: claim accrued fees — paid in the pair asset (ETH when the pair is WETH, else the
    /// Stock Token) plus any token-side fees.
    function claimCreator(uint256 id) external nonReentrant {
        Pos memory p = positions[id];
        if (msg.sender != p.creator) revert NotCreator();
        uint256 pairAmt = creatorOwedPair[id];
        creatorOwedPair[id] = 0;                     // zero BEFORE external call (checks-effects-interactions)
        if (pairAmt > 0) {
            if (p.pair == weth) { IWETH9(weth).withdraw(pairAmt); (bool ok, ) = p.creator.call{value: pairAmt}(""); require(ok, "eth"); }
            else IERC20(p.pair).safeTransfer(p.creator, pairAmt);   // PAIR ASSET ONLY (ETH or the stock)
        }
        emit CreatorClaimed(id, pairAmt, 0);
    }
    function creatorClaimable(uint256 id) external view returns (uint256 pairAmt, uint256 tokenAmt) { return (creatorOwedPair[id], 0); }

    // ---- V4 unlock callback: all pool interaction happens here ----
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(pm)) revert NotPoolManager();
        (uint8 op, uint256 id, int256 liq) = abi.decode(data, (uint8, uint256, int256));
        Pos memory p = positions[id];

        if (op == OP_PROVIDE) {
            (int256 callerDelta, ) = pm.modifyLiquidity(p.key, ModifyLiquidityParams(p.tickLower, p.tickUpper, liq, bytes32(0)), "");
            int256 owed0 = -int256(callerDelta.amount0());
            int256 owed1 = -int256(callerDelta.amount1());
            // single-sided: exactly one currency is owed, and it must be the launch token
            bool tokenIs0 = p.key.currency0 == p.token;
            if (tokenIs0) { if (owed1 > 0) revert NotSingleSided(); _settle(p.key.currency0, uint256(owed0)); }
            else          { if (owed0 > 0) revert NotSingleSided(); _settle(p.key.currency1, uint256(owed1)); }
            return "";
        } else {
            // liquidityDelta = 0 -> feesAccrued credited to us as a positive delta
            (int256 d, ) = pm.modifyLiquidity(p.key, ModifyLiquidityParams(p.tickLower, p.tickUpper, int256(0), bytes32(0)), "");
            uint256 a0 = d.amount0() > 0 ? uint256(int256(d.amount0())) : 0;
            uint256 a1 = d.amount1() > 0 ? uint256(int256(d.amount1())) : 0;
            if (a0 > 0) pm.take(p.key.currency0, address(this), a0);
            if (a1 > 0) pm.take(p.key.currency1, address(this), a1);
            (uint256 pairFees, uint256 tokenFees) = p.key.currency0 == p.pair ? (a0, a1) : (a1, a0);
            return abi.encode(pairFees, tokenFees);
        }
    }

    function _settle(address currency, uint256 amount) internal {
        if (amount == 0) return;
        pm.sync(currency);
        IERC20(currency).safeTransfer(address(pm), amount);
        pm.settle();
    }
    // No function withdraws principal liquidity — it is locked forever.
}

/// @title StockpadV4Swapper
/// @notice Minimal, self-contained V4 exact-input swapper (unlock/swap/settle/take) so the site can
///         trade V4 pools WITHOUT depending on Robinhood's modified Universal Router. Wraps/unwraps
///         ETH automatically when the pair asset is WETH.
contract StockpadV4Swapper is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using BalanceDeltaLib for int256;
    IPoolManager public immutable pm;
    address public immutable weth;
    uint160 private constant MIN_SQRT = 4295128739;
    uint160 private constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;
    error NotPoolManager();

    constructor(address pm_, address weth_) { pm = IPoolManager(pm_); weth = weth_; }
    receive() external payable {}

    /// Swap `amountIn` of the input currency for the output currency of `key`.
    function swapExactIn(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minOut, address to)
        public payable nonReentrant returns (uint256 out)
    {
        address tokenIn = zeroForOne ? key.currency0 : key.currency1;
        address tokenOut = zeroForOne ? key.currency1 : key.currency0;
        if (tokenIn == weth && msg.value > 0) { require(msg.value == amountIn, "value"); IWETH9(weth).deposit{value: amountIn}(); }
        else IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        out = abi.decode(pm.unlock(abi.encode(key, zeroForOne, amountIn)), (uint256));
        require(out >= minOut, "slippage");

        if (tokenOut == weth) { IWETH9(weth).withdraw(out); (bool ok, ) = to.call{value: out}(""); require(ok, "eth"); }
        else IERC20(tokenOut).safeTransfer(to, out);
    }

    /// Same as swapExactIn, but ALSO triggers the locker to distribute that pool's accrued fees right
    /// after the swap — so holder dividends stay current on every in-site trade WITHOUT a second
    /// signature. The collect is best-effort: if it reverts, the trade still succeeds.
    function swapExactInAndCollect(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minOut, address to, address locker, uint256 id)
        external payable returns (uint256 out)
    {
        out = swapExactIn(key, zeroForOne, amountIn, minOut, to);
        if (locker != address(0)) { try V4Locker(payable(locker)).collectFees(id) {} catch {} }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(pm)) revert NotPoolManager();
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        int256 d = pm.swap(key, SwapParams(zeroForOne, -int256(amountIn), zeroForOne ? MIN_SQRT + 1 : MAX_SQRT - 1), "");
        int128 a0 = d.amount0(); int128 a1 = d.amount1();
        address tokenIn = zeroForOne ? key.currency0 : key.currency1;
        address tokenOut = zeroForOne ? key.currency1 : key.currency0;
        uint256 owe = zeroForOne ? uint256(int256(-a0)) : uint256(int256(-a1));
        uint256 got = zeroForOne ? uint256(int256(a1)) : uint256(int256(a0));
        pm.sync(tokenIn); IERC20(tokenIn).safeTransfer(address(pm), owe); pm.settle();
        pm.take(tokenOut, address(this), got);
        return abi.encode(got);
    }
}

/// @title StockpadV4Factory (V4-native)
/// @notice Launches a fixed-supply token into a real Uniswap V4 pool with single-sided token
///         liquidity and a CUSTOM trade fee (V4 has no fee-tier cap — e.g. 2%). Tradable by any V4
///         router/aggregator from block 1. The fee accrues to the permanently-locked position and is
///         split protocol / holders / creator (holders paid in the pair asset). Also charges a small
///         one-time launch fee (protocol/dev revenue). Pair the pool with ETH (WETH), USDG, or a real
///         Stock Token (then price moves with the stock and holders earn that stock).
///         ⚠️ Unaudited. V4 tick/liquidity/settle accounting MUST be validated on testnet first.
contract StockpadV4Factory is Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    address public constant DEAD_ADDR = 0x000000000000000000000000000000000000dEaD;
    IPoolManager public immutable pm;
    address public immutable weth;
    V4Locker public immutable locker;
    StockpadV4Swapper public immutable swapper;
    uint256 public launchFee;          // one-time ETH fee per launch (owner-settable), forwarded to protocol
    address public immutable protocolRecipient;
    address public immutable v3Router;  // Uniswap V3 SwapRouter02 (for the ETH->pair leg of a stock/USDG dev buy)

    struct Launch { address token; bytes32 poolId; address creator; string stock; bool holderRewards; address pairToken; uint24 fee; }
    Launch[] public launches;
    // per-launch metadata (logo + socials). Stored separately so allLaunches()'s tuple stays
    // unchanged and older readers keep decoding. Read with logoURI(id)/logoOf(token), website*/twitter*.
    mapping(uint256 => string) public logoURI;
    mapping(address => string) public logoOf;
    mapping(uint256 => string) public website;
    mapping(address => string) public websiteOf;
    mapping(uint256 => string) public twitter;   // X / Twitter URL or handle
    mapping(address => string) public twitterOf;
    // buyback-and-burn mode flag (kept OUT of the Launch tuple so allLaunches() stays ABI-compatible)
    mapping(uint256 => bool) public burnMode;
    mapping(address => bool) public burnOf;

    // caller-supplied off-chain math (ticks/liquidity/price for a single-sided token position)
    struct LaunchParams {
        string name; string symbol; string stock;
        address pairToken;      // 0 = WETH (ETH)
        address creatorTo;      // 0 = msg.sender
        bool holderRewards; uint16 holderShareBps;
        bool burn;              // true = buyback-and-burn mode (fees buy the meme & are burned; overrides holderRewards)
        uint24 fee;             // pips, e.g. 20000 = 2%
        int24 tickSpacing; int24 tickLower; int24 tickUpper;
        uint128 liquidity; uint160 sqrtPriceX96;
        bytes32 salt;           // CREATE2 salt so the frontend can predict token<->pair ordering
        string logoURI;         // logo URL (IPFS/https) shown across the site for everyone
        string website;         // project website (stored on-chain, emitted for indexers)
        string twitter;         // X / Twitter (stored on-chain, emitted for indexers)
        // Optional atomic dev buy: the creator's first buy, executed in THIS tx.
        // devBuy amount = msg.value - launchFee. For a WETH pair leave devBuyPath empty (ETH buys directly);
        // for a stock/USDG pair, devBuyPath is the V3 exact-input path ETH(WETH)->...->pairToken.
        bytes devBuyPath;
    }

    event TokenCreated(uint256 indexed id, address indexed token, bytes32 indexed poolId, address creator, string name, string symbol, string stock, bool holderRewards, address pairToken, uint24 fee, string logoURI, string website, string twitter);
    event DevBuy(uint256 indexed id, address indexed creator, uint256 ethIn, uint256 tokensOut);

    constructor(address owner_, address pm_, address weth_, address protocolRecipient_, uint256 launchFee_, address v3Router_) Ownable(owner_) {
        pm = IPoolManager(pm_); weth = weth_; protocolRecipient = protocolRecipient_; launchFee = launchFee_; v3Router = v3Router_;
        locker = new V4Locker(pm_, address(this), protocolRecipient_, weth_);
        swapper = new StockpadV4Swapper(pm_, weth_);
        locker.setSwapper(address(swapper)); // lets the locker convert token-side fees into the pair asset
    }

    function setLaunchFee(uint256 f) external onlyOwner { launchFee = f; }

    function createLaunch(LaunchParams calldata pr) external payable returns (address tokenAddr, bytes32 poolId) {
        require(msg.value >= launchFee, "launch fee");
        require(pr.holderShareBps <= 10000, "bps");
        address pair = pr.pairToken == address(0) ? weth : pr.pairToken;
        address creator = pr.creatorTo == address(0) ? msg.sender : pr.creatorTo;

        // CREATE2 with a caller-chosen salt so the frontend can predict the token address (and thus
        // the token<->pair ordering) before launch, to compute the single-sided range/liquidity.
        StockpadTokenDividend tok = new StockpadTokenDividend{salt: pr.salt}(pr.name, pr.symbol, TOTAL_SUPPLY, address(this), pair);
        tokenAddr = address(tok);
        (address c0, address c1) = tokenAddr < pair ? (tokenAddr, pair) : (pair, tokenAddr);
        PoolKey memory key = PoolKey(c0, c1, pr.fee, pr.tickSpacing, address(0));
        poolId = keccak256(abi.encode(key));

        pm.initialize(key, pr.sqrtPriceX96);

        // holders aren't the pool/PM; exclude them from dividend accounting
        tok.setCurve(address(locker));
        tok.setLaunchId(launches.length); // same id used below for locker.provide(...) — needed so the
                                           // token's own transfer hook can call locker.collectFees(id)
        tok.setExcluded(address(pm), true);
        tok.setExcluded(address(locker), true);
        if (pr.burn) tok.setExcluded(DEAD_ADDR, true); // burned tokens must not accrue dividends

        // fund the locker with the whole supply, then it adds the single-sided position (and locks it)
        IERC20(tokenAddr).safeTransfer(address(locker), TOTAL_SUPPLY);
        locker.provide(launches.length, V4Locker.Pos(tokenAddr, pair, creator, pr.holderRewards, pr.holderShareBps, key, pr.tickLower, pr.tickUpper, pr.burn), pr.liquidity);

        uint256 id = launches.length;
        launches.push(Launch(tokenAddr, poolId, creator, pr.stock, pr.holderRewards, pair, pr.fee));
        if (pr.burn) { burnMode[id] = true; burnOf[tokenAddr] = true; }
        if (bytes(pr.logoURI).length > 0) { logoURI[id] = pr.logoURI; logoOf[tokenAddr] = pr.logoURI; }
        if (bytes(pr.website).length > 0) { website[id] = pr.website; websiteOf[tokenAddr] = pr.website; }
        if (bytes(pr.twitter).length > 0) { twitter[id] = pr.twitter; twitterOf[tokenAddr] = pr.twitter; }
        emit TokenCreated(id, tokenAddr, poolId, creator, pr.name, pr.symbol, pr.stock, pr.holderRewards, pair, pr.fee, pr.logoURI, pr.website, pr.twitter);

        // forward the one-time launch fee to the protocol
        if (launchFee > 0) { (bool ok, ) = protocolRecipient.call{value: launchFee}(""); require(ok, "fee send"); }

        // optional ATOMIC dev buy — the creator's first buy in this same tx (snipe-proof)
        uint256 devBuy = msg.value - launchFee;
        if (devBuy > 0) {
            _devBuy(id, key, pair, creator, devBuy, pr.devBuyPath);
        }
    }

    // Executes the creator's first buy with `ethIn` wei, sending the bought tokens to `creator`.
    // WETH pair: ETH -> token directly via our V4 swapper. Stock/USDG pair: ETH -> pair via V3
    // (using the caller-supplied path) then pair -> token via our V4 swapper.
    function _devBuy(uint256 id, PoolKey memory key, address pair, address creator, uint256 ethIn, bytes memory path) internal {
        bool zeroForOne = (key.currency0 == pair); // buying the token: input is the pair side
        uint256 out;
        if (pair == weth) {
            out = swapper.swapExactIn{value: ethIn}(key, zeroForOne, ethIn, 0, creator);
        } else {
            require(path.length > 0, "devbuy path");
            uint256 gotPair = ISwapRouterV3(v3Router).exactInput{value: ethIn}(
                ISwapRouterV3.ExactInputParams({ path: path, recipient: address(this), amountIn: ethIn, amountOutMinimum: 0 })
            );
            IERC20(pair).forceApprove(address(swapper), gotPair);
            out = swapper.swapExactIn(key, zeroForOne, gotPair, 0, creator);
        }
        emit DevBuy(id, creator, ethIn, out);
    }

    function launchCount() external view returns (uint256) { return launches.length; }
    function getLaunch(uint256 id) external view returns (Launch memory) { return launches[id]; }
    function allLaunches() external view returns (Launch[] memory) { return launches; }
}
