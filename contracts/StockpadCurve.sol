// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IFeeEscrow {
    function creditETH(address creator) external payable;
    function creditToken(address creator, address token, uint256 amount) external;
}
interface IDividend {
    function distributeReward(uint256 amount) external payable;
    function dividendSupply() external view returns (uint256);
}

/// @title StockpadCurve
/// @notice One bonding-curve architecture, two quote-settlement modes:
///         PairType.ETH   -> quote asset is native ETH (buy uses msg.value)
///         PairType.ERC20 -> quote asset is a canonical Robinhood Stock Token (SafeERC20)
///         Constant-product with virtual reserves. Integer math only. Creator fees are
///         credited to the FeeEscrow in the SAME quote asset (ETH or the Stock Token).
contract StockpadCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum PairType { ETH, ERC20 }

    // --- immutable config ---
    IERC20  public immutable token;         // the launched Stockpad token
    PairType public immutable pairType;
    address public immutable pairToken;     // address(0) for ETH, else canonical stock token
    address public immutable creator;
    address public immutable factory;
    IFeeEscrow public immutable escrow;
    address public immutable protocolRecipient;
    uint16  public immutable feeBps;        // total trade fee (<=300 = 3%)
    uint16  public immutable protocolShareBps; // share of the fee to protocol
    uint16  public immutable holderShareBps;   // share of the vault (post-protocol) to holders
    uint256 public immutable gradThreshold; // quote raised (net) that triggers graduation

    // --- curve state (constant product with virtual reserves) ---
    uint256 public reserveQuote;   // virtual quote reserve
    uint256 public reserveToken;   // token reserve on the curve
    uint256 public k;              // invariant
    uint256 public quoteRaised;    // net real quote collected (excludes fees)
    bool    public graduated;
    bool    public finalized;      // liquidity released to the graduation manager

    event Trade(address indexed trader, bool isBuy, uint256 quoteAmount, uint256 tokenAmount, uint256 feePaid, uint256 priceX18);
    event FeesAccrued(address indexed creator, uint256 creatorFee, uint256 holderFee, uint256 protocolFee);
    event GraduationReady(uint256 quoteRaised, uint256 tokenReserveLeft);

    error Graduated();
    error WrongPayment();
    error ZeroAmount();
    error Slippage();
    error InsufficientLiquidity();

    modifier notGraduated() { if (graduated) revert Graduated(); _; }

    constructor(
        address token_, PairType pairType_, address pairToken_, address creator_,
        IFeeEscrow escrow_, address protocolRecipient_,
        uint16 feeBps_, uint16 protocolShareBps_, uint16 holderShareBps_,
        uint256 onCurveTokenSupply_, uint256 virtualQuoteSeed_, uint256 gradThreshold_
    ) {
        token = IERC20(token_);
        pairType = pairType_;
        pairToken = pairToken_;
        creator = creator_;
        factory = msg.sender;
        escrow = escrow_;
        protocolRecipient = protocolRecipient_;
        feeBps = feeBps_;
        protocolShareBps = protocolShareBps_;
        holderShareBps = holderShareBps_;
        gradThreshold = gradThreshold_;

        reserveToken = onCurveTokenSupply_;
        reserveQuote = virtualQuoteSeed_;
        k = reserveQuote * reserveToken;
    }

    // ---------------- views ----------------
    /// price = quote per token, scaled 1e18
    function price() public view returns (uint256) { return (reserveQuote * 1e18) / reserveToken; }

    function quoteBuy(uint256 quoteIn) public view returns (uint256 tokensOut) {
        uint256 fee = (quoteIn * feeBps) / 10000;
        uint256 net = quoteIn - fee;
        uint256 newQ = reserveQuote + net;
        tokensOut = reserveToken - (k / newQ);
    }

    function quoteSell(uint256 tokenIn) public view returns (uint256 quoteOut) {
        uint256 newT = reserveToken + tokenIn;
        uint256 gross = reserveQuote - (k / newT);
        uint256 fee = (gross * feeBps) / 10000;
        quoteOut = gross - fee;
    }

    // ---------------- trading ----------------
    /// @param quoteIn  ERC20 mode: amount of pair token to spend. ETH mode: ignored (uses msg.value)
    function buy(uint256 quoteIn, uint256 minTokensOut) external payable nonReentrant notGraduated {
        uint256 amountIn;
        if (pairType == PairType.ETH) {
            if (msg.value == 0) revert ZeroAmount();
            amountIn = msg.value;
        } else {
            if (msg.value != 0) revert WrongPayment();
            if (quoteIn == 0) revert ZeroAmount();
            amountIn = quoteIn;
            IERC20(pairToken).safeTransferFrom(msg.sender, address(this), amountIn);
        }

        uint256 fee = (amountIn * feeBps) / 10000;
        uint256 net = amountIn - fee;
        uint256 newQ = reserveQuote + net;
        uint256 newT = k / newQ;
        uint256 out = reserveToken - newT;
        if (out < minTokensOut) revert Slippage();
        if (out > token.balanceOf(address(this))) revert InsufficientLiquidity();

        reserveQuote = newQ;
        reserveToken = newT;
        quoteRaised += net;

        _distributeFee(fee);
        token.safeTransfer(msg.sender, out);

        emit Trade(msg.sender, true, amountIn, out, fee, price());
        if (quoteRaised >= gradThreshold) _markGraduationReady();
    }

    function sell(uint256 tokenIn, uint256 minQuoteOut) external nonReentrant notGraduated {
        if (tokenIn == 0) revert ZeroAmount();
        token.safeTransferFrom(msg.sender, address(this), tokenIn);

        uint256 newT = reserveToken + tokenIn;
        uint256 newQ = k / newT;
        uint256 gross = reserveQuote - newQ;
        uint256 fee = (gross * feeBps) / 10000;
        uint256 out = gross - fee;
        if (out < minQuoteOut) revert Slippage();
        if (out > _realQuoteBalance()) revert InsufficientLiquidity();

        reserveQuote = newQ;
        reserveToken = newT;
        quoteRaised = quoteRaised > gross ? quoteRaised - gross : 0;

        _distributeFee(fee);

        if (pairType == PairType.ETH) {
            (bool ok, ) = msg.sender.call{value: out}("");
            if (!ok) revert InsufficientLiquidity();
        } else {
            IERC20(pairToken).safeTransfer(msg.sender, out);
        }

        emit Trade(msg.sender, false, out, tokenIn, fee, price());
    }

    // ---------------- internals ----------------
    function _realQuoteBalance() internal view returns (uint256) {
        return pairType == PairType.ETH ? address(this).balance : IERC20(pairToken).balanceOf(address(this));
    }

    function _distributeFee(uint256 fee) internal {
        if (fee == 0) return;
        uint256 protocolFee = (fee * protocolShareBps) / 10000;
        uint256 vault = fee - protocolFee;
        uint256 holderFee = holderShareBps > 0 ? (vault * holderShareBps) / 10000 : 0;
        // only pay holders if real holders exist; otherwise fold into the creator's share
        if (holderFee > 0 && IDividend(address(token)).dividendSupply() == 0) holderFee = 0;
        uint256 creatorFee = vault - holderFee;

        if (pairType == PairType.ETH) {
            if (protocolFee > 0) { (bool ok, ) = protocolRecipient.call{value: protocolFee}(""); require(ok, "protocol fee"); }
            if (creatorFee > 0) escrow.creditETH{value: creatorFee}(creator);
            if (holderFee > 0) IDividend(address(token)).distributeReward{value: holderFee}(holderFee);
        } else {
            if (protocolFee > 0) IERC20(pairToken).safeTransfer(protocolRecipient, protocolFee);
            if (creatorFee > 0) { IERC20(pairToken).safeTransfer(address(escrow), creatorFee); escrow.creditToken(creator, pairToken, creatorFee); }
            if (holderFee > 0) { IERC20(pairToken).forceApprove(address(token), holderFee); IDividend(address(token)).distributeReward(holderFee); }
        }
        emit FeesAccrued(creator, creatorFee, holderFee, protocolFee);
    }

    function _markGraduationReady() internal {
        graduated = true; // curve trading stops here; DEX migration handled by the graduation module
        emit GraduationReady(quoteRaised, reserveToken);
    }

    error NotFactory();
    error NotGraduated();
    error AlreadyFinalized();
    event Finalized(address indexed to, uint256 tokenAmount, uint256 quoteAmount);

    /// @notice Release the graduation liquidity (remaining token balance + real quote) to `to`.
    ///         Callable only by the factory (which routes it to the graduation manager) after the
    ///         curve has graduated. One-time. Nobody can pull curve funds before graduation.
    function finalize(address to) external returns (uint256 tokenAmount, uint256 quoteAmount) {
        if (msg.sender != factory) revert NotFactory();
        if (!graduated) revert NotGraduated();
        if (finalized) revert AlreadyFinalized();
        finalized = true;

        tokenAmount = token.balanceOf(address(this));
        if (tokenAmount > 0) token.safeTransfer(to, tokenAmount);

        if (pairType == PairType.ETH) {
            quoteAmount = address(this).balance;
            if (quoteAmount > 0) { (bool ok, ) = to.call{value: quoteAmount}(""); if (!ok) revert InsufficientLiquidity(); }
        } else {
            quoteAmount = IERC20(pairToken).balanceOf(address(this));
            if (quoteAmount > 0) IERC20(pairToken).safeTransfer(to, quoteAmount);
        }
        emit Finalized(to, tokenAmount, quoteAmount);
    }

    receive() external payable {}
}
