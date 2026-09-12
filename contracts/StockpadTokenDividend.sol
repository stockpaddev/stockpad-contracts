// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ICollectable { function collectFees(uint256 id) external; }

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

    // --- auto-push-on-transfer: no bot/cron needed for the LAST mile (dividend pool -> wallet).
    // Every ordinary transfer (buy/sell/send) also pays out a FEW already-accrued holders, funded
    // by whoever is trading at that moment (a tiny gas add-on to their tx, same trick 2024-era
    // "reflection"/auto-claim tokens use). Bounded per-tx so gas stays predictable, and a failed
    // send NEVER reverts the underlying transfer — it just leaves that holder's reward pending for
    // the next rotation (or their own claimRewards()/an external pushRewards() call) instead of
    // bricking trading for everyone, which is the classic bug in this style of contract.
    address[] public holderRegistry;
    mapping(address => uint256) internal _regIndex; // 1-based; 0 = not registered
    uint256 public pushCursor;
    uint256 public constant AUTO_PUSH_PER_TX = 3;
    uint256 public constant AUTO_PUSH_GAS = 30000;

    // --- auto-collect-on-transfer: `curve` IS the V4Locker for this launch (set by the factory via
    // setCurve), so we can periodically ask it to sweep pool fees into this token's dividend pool
    // (or, in burn mode, buy+burn) — WITHOUT any external bot/cron, and regardless of which
    // platform the trade happened on (Stockpad, GMGN, Axiom, a raw router, anything). The ERC20
    // transfer hook fires no matter who initiated the trade, since every transfer must go through
    // it — that's what makes this platform-agnostic instead of only covering in-site trades.
    uint256 internal _transferNonce;
    uint256 public constant AUTO_COLLECT_EVERY = 20; // roughly once per 20 ordinary transfers
    uint256 public launchId;

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
    function setLaunchId(uint256 id) external {
        if (msg.sender != factory) revert NotFactory();
        launchId = id;
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

        // register any new non-excluded holder, then piggyback a small automatic reward push on
        // this transfer — AFTER the balance change is fully settled, so the push can't interfere
        // with the transfer it rides on.
        if (to != address(0) && !excluded[to] && _regIndex[to] == 0) {
            holderRegistry.push(to);
            _regIndex[to] = holderRegistry.length; // 1-based
        }

        // periodically ask the locker to sweep fees (collect -> distribute/burn), same try/catch
        // safety as the reward push: a revert here (e.g. nothing to collect yet, or a reentrant
        // call landing on the locker's own nonReentrant guard) never breaks the transfer it rides
        // on. Only fires on ordinary transfers (from/to both non-zero) — not on mint/burn — and
        // only when `curve` is actually set (mint-time transfers happen before setCurve runs).
        if (from != address(0) && to != address(0) && curve != address(0)) {
            unchecked { _transferNonce++; }
            if (_transferNonce % AUTO_COLLECT_EVERY == 0) {
                try ICollectable(curve).collectFees(launchId) {} catch {}
            }
        }
        _autoPush();
    }

    function _autoPush() internal {
        uint256 n = holderRegistry.length;
        if (n == 0) return;
        uint256 cursor = pushCursor;
        uint256 rounds = AUTO_PUSH_PER_TX < n ? AUTO_PUSH_PER_TX : n;
        for (uint256 i = 0; i < rounds; i++) {
            address h = holderRegistry[cursor % n];
            cursor++;
            uint256 amount = withdrawableRewardOf(h);
            if (amount == 0) continue;
            if (_safePay(h, amount)) {
                withdrawnRewards[h] += amount;
                emit RewardClaimed(h, amount);
            }
            // on failure: leave it pending, do NOT mark withdrawn, do NOT revert the transfer.
        }
        pushCursor = cursor % n;
    }

    // Never reverts the caller — a broken/malicious/expensive receiver only loses ITS OWN
    // auto-push turn, it can never brick transfers for everyone else.
    function _safePay(address to, uint256 amount) internal returns (bool) {
        if (rewardToken == address(0)) {
            (bool ok, ) = to.call{value: amount, gas: AUTO_PUSH_GAS}("");
            return ok;
        }
        try IERC20(rewardToken).transfer(to, amount) returns (bool ok) { return ok; }
        catch { return false; }
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

    // --- automated push (permissionless) ---
    // Pays each listed holder their OWN already-accrued reward directly, so a bot (or anyone) can
    // push rewards to holders instead of every holder having to call claimRewards() themselves.
    // Safe to leave permissionless: it can only ever pay a holder their own correctly-computed
    // balance, to their own address — there is no way to redirect or over-pay. The caller supplies
    // the holder list (this contract doesn't enumerate holders on-chain) and eats the gas cost;
    // callers should keep each batch small enough to fit one block's gas limit.
    function pushRewards(address[] calldata holders) external nonReentrant returns (uint256 totalPaid) {
        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            uint256 amount = withdrawableRewardOf(h);
            if (amount == 0) continue;
            withdrawnRewards[h] += amount;
            if (rewardToken == address(0)) { (bool ok, ) = h.call{value: amount}(""); require(ok, "eth send"); }
            else { IERC20(rewardToken).safeTransfer(h, amount); }
            totalPaid += amount;
            emit RewardClaimed(h, amount);
        }
    }

    receive() external payable {}
}
