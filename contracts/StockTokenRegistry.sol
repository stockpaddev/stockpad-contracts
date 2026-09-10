// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title StockTokenRegistry
/// @notice Allowlist of canonical Robinhood Chain Stock Token contracts that may be
///         used as a launch's quote/pair asset. Address is authoritative — a token
///         with the same ticker but a different address is NOT canonical and must not
///         be added. Seed from https://api.robinhood.com/rhj/assets (chainId 4663).
contract StockTokenRegistry is Ownable2Step {
    mapping(address => bool) private _supported;
    address[] private _list;
    mapping(address => uint256) private _idx; // 1-based

    event PairTokenAdded(address indexed token);
    event PairTokenRemoved(address indexed token);

    error ZeroAddress();

    constructor(address owner_) Ownable(owner_) {}

    function isSupportedPairToken(address token) external view returns (bool) {
        return _supported[token];
    }

    function add(address token) public onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (!_supported[token]) {
            _supported[token] = true;
            _list.push(token);
            _idx[token] = _list.length;
            emit PairTokenAdded(token);
        }
    }

    function addMany(address[] calldata tokens) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) add(tokens[i]);
    }

    function remove(address token) external onlyOwner {
        if (_supported[token]) {
            _supported[token] = false;
            uint256 i = _idx[token];
            uint256 last = _list.length;
            if (i != last) { address lastTok = _list[last - 1]; _list[i - 1] = lastTok; _idx[lastTok] = i; }
            _list.pop();
            _idx[token] = 0;
            emit PairTokenRemoved(token);
        }
    }

    function count() external view returns (uint256) { return _list.length; }
    function all() external view returns (address[] memory) { return _list; }
}
