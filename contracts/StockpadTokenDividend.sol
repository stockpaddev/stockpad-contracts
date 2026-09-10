// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title StockpadTokenDividend
/// @notice Fixed-supply (1e9, 18 dec) launch token that ALSO pays holder rewards in the
///         launch's pair asset (ETH or the paired Stock Token). Uses the well-known
///         magnified-dividend accounting so holders accrue proportionally to holdings,
///         and can claim anytime. Non-holder addresses (the curve, the factory, LP locker)
///         are excluded so pre-graduation curve supply never dilutes real holders.
contract StockpadTokenDividend is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant MAGNITUDE = 2 ** 128;
    uint8 private constant _DECIMALS = 18;

    address public immutable rewardToken;  // address(0) = native ETH
    address public factory;
    address public curve;

    uint256 public magnifiedRewardPerShare;
    mapping(address => int256) internal _corrections;
    mapping(address => uint256) public withdrawnRewards;
    mapping(address => bool) public excluded;
    uint256 public dividendSupply;          // sum of balances of NON-excluded holders

    event RewardsDistributed(uint256 amount);
    event RewardClaimed(address indexed holder, uint256 amount);
    event ExcludedSet(address indexed account, bool excluded);

    error NotFactory();
    error NotCurve();
    error NoShares();
    error WrongPayment();

    constructor(string memory n, string memory s, uint256 supply, address mintTo, address rewardToken_)
        ERC20(n, s)
    {
        factory = msg.sender;
        rewardToken = rewardToken_;
        excluded[mintTo] = true;      // factory holds then seeds the curve; not a real holder
        excluded[address(0)] = true;
        _mint(mintTo, supply);
    }

    function decimals() public pure override returns (uint8) { return _DECIMALS; }

    // --- admin (factory) ---
    function setCurve(address c) external {
        if (msg.sender != factory) revert NotFactory();
        curve = c;
        _setExcluded(c, true);
    }
    function setExcluded(address a, bool v) external {
        if (msg.sender != factory) revert NotFactory();
        _setExcluded(a, v);
    }
    function _setExcluded(address a, bool v) internal {
        if (excluded[a] == v) return;
        uint256 bal = balanceOf(a);
        excluded[a] = v;
        if (v) { if (bal > 0) { dividendSupply -= bal; _corrections[a] += int256(magnifiedRewardPerShare * bal); } }
        else   { if (bal > 0) { dividendSupply += bal; _corrections[a] -= int256(magnifiedRewardPerShare * bal); } }
        emit ExcludedSet(a, v);
    }

    // --- dividend accounting on every balance change ---
    function _update(address from, address to, uint256 value) internal override {
        uint256 mrps = magnifiedRewardPerShare;
        if (from != address(0) && !excluded[from]) { _corrections[from] += int256(mrps * value); dividendSupply -= value; }
        if (to != address(0) && !excluded[to])     { _corrections[to]   -= int256(mrps * value); dividendSupply += value; }
        super._update(from, to, value);
    }

    // --- distribute holder rewards (called by the curve, in the pair asset) ---
    function distributeReward(uint256 amount) external payable {
        if (msg.sender != curve) revert NotCurve();
        if (dividendSupply == 0) revert NoShares();
        if (rewardToken == address(0)) { if (msg.value != amount) revert WrongPayment(); }
        else { if (msg.value != 0) revert WrongPayment(); IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount); }
        magnifiedRewardPerShare += (amount * MAGNITUDE) / dividendSupply;
        emit RewardsDistributed(amount);
    }

    // --- views ---
    function cumulativeRewardOf(address a) public view returns (uint256) {
        int256 v = int256(magnifiedRewardPerShare * balanceOf(a)) + _corrections[a];
        return uint256(v) / MAGNITUDE;
    }
    function withdrawableRewardOf(address a) public view returns (uint256) {
        return cumulativeRewardOf(a) - withdrawnRewards[a];
    }

    // --- claim ---
    function claimRewards() external nonReentrant returns (uint256 amount) {
        amount = withdrawableRewardOf(msg.sender);
        if (amount == 0) return 0;
        withdrawnRewards[msg.sender] += amount;
        if (rewardToken == address(0)) { (bool ok, ) = msg.sender.call{value: amount}(""); require(ok, "eth send"); }
        else { IERC20(rewardToken).safeTransfer(msg.sender, amount); }
        emit RewardClaimed(msg.sender, amount);
    }

    receive() external payable {}
}
