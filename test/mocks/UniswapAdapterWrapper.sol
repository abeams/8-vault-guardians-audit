// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {UniswapAdapter, IERC20} from "../../src/protocol/investableUniverseAdapters/UniswapAdapter.sol";

contract UniswapAdapterWrapper is UniswapAdapter {

    constructor(address uniswapRouter, address weth, address tokenOne) 
        UniswapAdapter(uniswapRouter, weth, tokenOne) {}

    function uniswapInvest(IERC20 token, uint256 amount) external {
        _uniswapInvest(token, amount);
    }

    function uniswapDivest(IERC20 token, uint256 liquidityAmount) external returns (uint256 amountOfAssetReturned) {
        return _uniswapDivest(token, liquidityAmount);
    }
}