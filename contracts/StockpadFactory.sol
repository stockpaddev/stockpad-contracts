// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StockpadTokenDividend} from "./StockpadTokenDividend.sol";
import {StockpadCurve, IFeeEscrow} from "./StockpadCurve.sol";

interface IDividendToken { function setCurve(address curve) external; }

interface IRegistry { function isSupportedPairToken(address token) external view returns (bool); }
interface IEscrowAuth { function authorizeCurve(address curve, bool allowed) external; }

/// @title StockpadFactory (v2)
/// @notice Creates two-mode launches: ETH-paired or canonical Stock-Token-paired.
///         The pair asset is fixed permanently at creation.
contract StockpadFactory is Ownable2Step {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether; // 1e9 * 1e18, minted once
    uint16  public constant PROTOCOL_SHARE_BPS = 2000;          // 20% of the trade fee to protocol
    uint16  public constant HOLDER_SHARE_BPS   = 4000;          // 40% of the vault to holders (when enabled)
    uint16  public constant MAX_FEE_BPS = 300;                  // 3% max total trade fee
    uint256 public immutable virtualQuoteSeed;                  // virtual quote reserve seed
    uint256 public immutable gradThreshold;                     // net quote raised to graduate

    IRegistry public immutable registry;
    address   public immutable escrow;
    address   public protocolRecipient;
    address   public graduationManager; // set in the graduation stage; may finalize DEX migration

    enum PairType { ETH, ERC20 }

    struct Launch {
        address token;
        address curve;
        address creator;
        uint8   pairType;   // 0 = ETH, 1 = ERC20
        address pairToken;  // address(0) for ETH
        uint16  feeBps;
        bytes32 poolId;     // set at graduation (Uniswap V3 pool)
        address locker;     // set at graduation (LP lock)
    }
    Launch[] public launches;

    event TokenCreated(uint256 indexed id, address indexed token, address indexed curve, address creator, string name, string symbol, uint8 pairType, address pairToken, uint16 feeBps);
    event PairSelected(uint256 indexed id, uint8 pairType, address pairToken);
    event GraduationRecorded(uint256 indexed id, bytes32 poolId, address locker);
    event ProtocolRecipientUpdated(address recipient);
    event GraduationManagerUpdated(address manager);

    error InvalidPair();
    error FeeTooHigh();
    error ZeroAddress();
    error NotGraduationManager();

    constructor(address owner_, address registry_, address escrow_, address protocolRecipient_, uint256 virtualQuoteSeed_, uint256 gradThreshold_)
        Ownable(owner_)
    {
        if (registry_ == address(0) || escrow_ == address(0) || protocolRecipient_ == address(0)) revert ZeroAddress();
        registry = IRegistry(registry_);
        escrow = escrow_;
        protocolRecipient = protocolRecipient_;
        virtualQuoteSeed = virtualQuoteSeed_;
        gradThreshold = gradThreshold_;
    }

    function createLaunch(
        string calldata name,
        string calldata symbol,
        PairType pairType,
        address pairToken,
        uint16 feeBps,
        bool holderRewards
    ) external returns (address tokenAddr, address curveAddr) {
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (pairType == PairType.ETH) {
            if (pairToken != address(0)) revert InvalidPair();
        } else {
            // Stock-Token mode: only canonical, allowlisted tokens (address is authoritative)
            if (pairToken == address(0) || !registry.isSupportedPairToken(pairToken)) revert InvalidPair();
        }

        // holder rewards are paid in the pair asset: ETH (address(0)) or the Stock Token
        address rewardToken = pairType == PairType.ETH ? address(0) : pairToken;
        StockpadTokenDividend tok = new StockpadTokenDividend(name, symbol, TOTAL_SUPPLY, address(this), rewardToken);
        StockpadCurve curve = new StockpadCurve(
            address(tok),
            StockpadCurve.PairType(uint8(pairType)),
            pairToken,
            msg.sender,
            IFeeEscrow(escrow),
            protocolRecipient,
            feeBps,
            PROTOCOL_SHARE_BPS,
            holderRewards ? HOLDER_SHARE_BPS : uint16(0),
            TOTAL_SUPPLY,
            virtualQuoteSeed,
            gradThreshold
        );
        IDividendToken(address(tok)).setCurve(address(curve)); // excludes the curve from dividends
        IERC20(address(tok)).transfer(address(curve), TOTAL_SUPPLY);
        IEscrowAuth(escrow).authorizeCurve(address(curve), true);

        uint256 id = launches.length;
        launches.push(Launch(address(tok), address(curve), msg.sender, uint8(pairType), pairToken, feeBps, bytes32(0), address(0)));
        emit TokenCreated(id, address(tok), address(curve), msg.sender, name, symbol, uint8(pairType), pairToken, feeBps);
        emit PairSelected(id, uint8(pairType), pairToken);
        return (address(tok), address(curve));
    }

    // --- graduation bookkeeping (Uniswap V3 migration performed by the graduation manager) ---
    function setGraduationManager(address m) external onlyOwner { graduationManager = m; emit GraduationManagerUpdated(m); }

    /// @notice Called by the graduation manager to pull a graduated curve's liquidity to itself
    ///         (the manager then creates the Uniswap V3 pool and locks the LP).
    function releaseForGraduation(uint256 id) external returns (uint256 tokenAmount, uint256 quoteAmount) {
        if (msg.sender != graduationManager) revert NotGraduationManager();
        return StockpadCurve(payable(launches[id].curve)).finalize(graduationManager);
    }
    function recordGraduation(uint256 id, bytes32 poolId, address locker) external {
        if (msg.sender != graduationManager) revert NotGraduationManager();
        launches[id].poolId = poolId;
        launches[id].locker = locker;
        emit GraduationRecorded(id, poolId, locker);
    }

    function setProtocolRecipient(address r) external onlyOwner { if (r == address(0)) revert ZeroAddress(); protocolRecipient = r; emit ProtocolRecipientUpdated(r); }

    // --- views ---
    function launchCount() external view returns (uint256) { return launches.length; }
    function getLaunch(uint256 id) external view returns (Launch memory) { return launches[id]; }
    function allLaunches() external view returns (Launch[] memory) { return launches; }
    function isGraduated(uint256 id) external view returns (bool) { return StockpadCurve(payable(launches[id].curve)).graduated(); }
}
