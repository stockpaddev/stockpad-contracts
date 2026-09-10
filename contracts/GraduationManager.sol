// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {INonfungiblePositionManager, IWETH9} from "./uniswap/IUniswapV3.sol";
import {Locker} from "./Locker.sol";

interface IStockpadFactoryGrad {
    struct Launch { address token; address curve; address creator; uint8 pairType; address pairToken; uint16 feeBps; bytes32 poolId; address locker; }
    function getLaunch(uint256 id) external view returns (Launch memory);
    function releaseForGraduation(uint256 id) external returns (uint256 tokenAmount, uint256 quoteAmount);
    function recordGraduation(uint256 id, bytes32 poolId, address locker) external;
}
interface ICurveGrad { function graduated() external view returns (bool); function finalized() external view returns (bool); }

/// @title GraduationManager
/// @notice Performs the REAL Uniswap V3 migration at graduation: pulls the curve's
///         remaining token + quote, creates/initializes the V3 pool, mints a full-range
///         LP position to the Locker (permanently locked), and records the pool.
///         ETH launches pair TOKEN/WETH; Stock-Token launches pair TOKEN/STOCKTOKEN.
contract GraduationManager is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IStockpadFactoryGrad public immutable factory;
    INonfungiblePositionManager public immutable npm;
    address public immutable weth;
    uint24  public immutable fee;      // e.g. 10000 (1%)
    int24   public immutable tickSpacing;
    Locker  public immutable locker;

    event GraduationStarted(uint256 indexed id, address curve);
    event PoolCreated(uint256 indexed id, address indexed pool, address token0, address token1);
    event LiquidityLocked(uint256 indexed id, uint256 tokenId, address pool);

    error NotGraduated();
    error NothingToGraduate();

    constructor(address factory_, address npm_, address weth_, uint24 fee_, int24 tickSpacing_) {
        factory = IStockpadFactoryGrad(factory_);
        npm = INonfungiblePositionManager(npm_);
        weth = weth_;
        fee = fee_;
        tickSpacing = tickSpacing_;
        locker = new Locker(address(this));
    }

    function graduate(uint256 id) external nonReentrant {
        IStockpadFactoryGrad.Launch memory L = factory.getLaunch(id);
        if (!ICurveGrad(L.curve).graduated()) revert NotGraduated();

        (uint256 tokenAmt, uint256 quoteAmt) = factory.releaseForGraduation(id);
        if (tokenAmt == 0 || quoteAmt == 0) revert NothingToGraduate();
        emit GraduationStarted(id, L.curve);

        address launchToken = L.token;
        address quoteToken;
        if (L.pairType == 0) {
            // ETH mode: wrap the received ETH into WETH
            IWETH9(weth).deposit{value: quoteAmt}();
            quoteToken = weth;
        } else {
            quoteToken = L.pairToken;
        }

        // sort tokens for the V3 pool
        (address token0, address token1, uint256 amt0, uint256 amt1) =
            launchToken < quoteToken
                ? (launchToken, quoteToken, tokenAmt, quoteAmt)
                : (quoteToken, launchToken, quoteAmt, tokenAmt);

        // sqrtPriceX96 = sqrt(amount1/amount0) * 2^96, computed with 512-bit-safe math
        uint160 sqrtPriceX96 = uint160(Math.sqrt(Math.mulDiv(amt1, 1 << 192, amt0)));

        address pool = npm.createAndInitializePoolIfNecessary(token0, token1, fee, sqrtPriceX96);
        emit PoolCreated(id, pool, token0, token1);

        IERC20(token0).forceApprove(address(npm), amt0);
        IERC20(token1).forceApprove(address(npm), amt1);

        int24 maxTick = (int24(887272) / tickSpacing) * tickSpacing;
        INonfungiblePositionManager.MintParams memory p = INonfungiblePositionManager.MintParams({
            token0: token0, token1: token1, fee: fee,
            tickLower: -maxTick, tickUpper: maxTick,
            amount0Desired: amt0, amount1Desired: amt1,
            amount0Min: 0, amount1Min: 0,
            recipient: address(locker), deadline: block.timestamp + 3600
        });
        (uint256 tokenId, , , ) = npm.mint(p);

        locker.registerLock(address(npm), tokenId, pool);
        factory.recordGraduation(id, bytes32(uint256(uint160(pool))), address(locker));
        emit LiquidityLocked(id, tokenId, pool);
    }

    receive() external payable {}
}
