// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title FeeEscrow
/// @notice Holds creator rewards until claimed. Rewards are credited in the launch's
///         quote asset: native ETH for ETH launches, the paired Stock Token for
///         Stock-Token launches. Separate ledgers per asset — never combined.
/// @dev Only curves authorized by the factory may credit. Anyone can claim only their own.
contract FeeEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public factory;
    mapping(address => bool) public isCurve; // authorized crediters

    mapping(address => uint256) public ethBalance;                       // creator => ETH
    mapping(address => mapping(address => uint256)) public tokenBalance; // creator => token => amount

    event CurveAuthorized(address indexed curve, bool allowed);
    event RewardCredited(address indexed creator, uint256 amount);                       // ETH
    event RewardClaimed(address indexed creator, uint256 amount);                        // ETH
    event RewardCreditedToken(address indexed creator, address indexed token, uint256 amount);
    event RewardClaimedToken(address indexed creator, address indexed token, uint256 amount);

    error NotFactory();
    error NotAuthorized();
    error FactoryAlreadySet();
    error NothingToClaim();
    error TransferFailed();

    modifier onlyFactory() { if (msg.sender != factory) revert NotFactory(); _; }
    modifier onlyCurve() { if (!isCurve[msg.sender]) revert NotAuthorized(); _; }

    /// one-time wiring: the deployer sets the factory after both are deployed
    function initFactory(address factory_) external {
        if (factory != address(0)) revert FactoryAlreadySet();
        factory = factory_;
    }

    function authorizeCurve(address curve, bool allowed) external onlyFactory {
        isCurve[curve] = allowed;
        emit CurveAuthorized(curve, allowed);
    }

    // --- crediting (called by authorized curves) ---
    function creditETH(address creator) external payable onlyCurve {
        ethBalance[creator] += msg.value;
        emit RewardCredited(creator, msg.value);
    }

    /// @dev the curve must transfer `amount` of `token` to this escrow BEFORE calling
    function creditToken(address creator, address token, uint256 amount) external onlyCurve {
        tokenBalance[creator][token] += amount;
        emit RewardCreditedToken(creator, token, amount);
    }

    // --- claiming (creator withdraws their own) ---
    function claim() external nonReentrant {
        uint256 amt = ethBalance[msg.sender];
        if (amt == 0) revert NothingToClaim();
        ethBalance[msg.sender] = 0; // effects before interaction
        (bool ok, ) = msg.sender.call{value: amt}("");
        if (!ok) revert TransferFailed();
        emit RewardClaimed(msg.sender, amt);
    }

    function claimToken(address token) external nonReentrant {
        uint256 amt = tokenBalance[msg.sender][token];
        if (amt == 0) revert NothingToClaim();
        tokenBalance[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amt);
        emit RewardClaimedToken(msg.sender, token, amt);
    }

    // --- views ---
    function getClaimableETH(address creator) external view returns (uint256) { return ethBalance[creator]; }
    function getClaimableToken(address creator, address token) external view returns (uint256) { return tokenBalance[creator][token]; }

    receive() external payable {} // accept ETH forwarded by curves via creditETH
}
