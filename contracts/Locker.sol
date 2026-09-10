// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @title Locker
/// @notice Permanently locks Uniswap V3 LP position NFTs received at graduation.
///         There is NO function that transfers a locked position out — liquidity is
///         locked forever. The creator can never withdraw the user-facing liquidity.
contract Locker is IERC721Receiver {
    address public immutable graduationManager;

    // nft contract => tokenId => locked
    mapping(address => mapping(uint256 => bool)) public locked;
    uint256 public lockedCount;

    event LiquidityLocked(address indexed nft, uint256 indexed tokenId, address indexed pool);

    error NotManager();

    constructor(address graduationManager_) { graduationManager = graduationManager_; }

    /// Called by the graduation manager to register a locked position (the NFT is
    /// transferred directly to this contract via safeTransferFrom / mint-to-locker).
    function registerLock(address nft, uint256 tokenId, address pool) external {
        if (msg.sender != graduationManager) revert NotManager();
        locked[nft][tokenId] = true;
        lockedCount++;
        emit LiquidityLocked(nft, tokenId, pool);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
    // No withdraw / transfer function exists. Positions stay here permanently.
}
