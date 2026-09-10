// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title StockpadToken
/// @notice Fixed-supply launch token. The full supply is minted once at deploy to the
///         curve; there is no mint function, so supply is permanently fixed. Decimals 18.
///         The token is the SAME ERC-20 before and after graduation (no migration).
contract StockpadToken is ERC20 {
    uint8 private constant _DECIMALS = 18;

    constructor(string memory name_, string memory symbol_, uint256 supply_, address mintTo_)
        ERC20(name_, symbol_)
    {
        _mint(mintTo_, supply_); // minted once; no further minting exists
    }

    function decimals() public pure override returns (uint8) { return _DECIMALS; }
}
