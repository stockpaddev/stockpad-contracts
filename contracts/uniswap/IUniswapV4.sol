// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Minimal Uniswap V4 core interfaces (subset) used by the V4-native launcher.
/// V4 is a singleton PoolManager with an unlock/settle/take accounting model.
/// Currency is an address under the hood; BalanceDelta packs two int128 amounts in one int256
/// (amount0 = high 128 bits, amount1 = low 128 bits).

struct PoolKey {
    address currency0;   // must be < currency1
    address currency1;
    uint24 fee;          // in pips (1e-6). 20000 = 2%. V4 has NO fee-tier restriction.
    int24 tickSpacing;
    address hooks;       // address(0) = no hook
}

struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;   // negative = exact input
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function unlock(bytes calldata data) external returns (bytes memory);
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external returns (int256 callerDelta, int256 feesAccrued);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// V4 StateView (periphery) — read-only pool state.
interface IStateView {
    function getSlot0(bytes32 poolId) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

/// Helpers for the packed BalanceDelta (int256).
library BalanceDeltaLib {
    function amount0(int256 d) internal pure returns (int128) { return int128(d >> 128); }
    function amount1(int256 d) internal pure returns (int128) { return int128(d); }
}
