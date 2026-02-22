// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Base_Test} from "../../Base.t.sol";
import {console} from "forge-std/console.sol";
import {UniswapAdapterWrapper} from "../../mocks/UniswapAdapterWrapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";

contract UniswapAdapterTest is Base_Test {
    UniswapAdapterWrapper public uniswapAdapterWrapper;

    function setUp() public override {
        Base_Test.setUp();
        uniswapAdapterWrapper = new UniswapAdapterWrapper(uniswapRouter, address(weth), address(usdc));
    }

    function testUniswapAdapterInvestsMoreThanIntended() public {
        usdc.mint(2 ether, address(uniswapAdapterWrapper));

        uniswapAdapterWrapper.uniswapInvest(IERC20(usdc), 1 ether);

        // This should be equal to 1 ether
        assertEq(usdc.balanceOf(address(uniswapAdapterWrapper)), (1 ether) / 2);
    }
}
