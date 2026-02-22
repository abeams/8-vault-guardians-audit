// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Base_Test} from "../../Base.t.sol";
import {console} from "forge-std/console.sol";
import {VaultShares} from "../../../src/protocol/VaultShares.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {VaultShares, IERC20} from "../../../src/protocol/VaultShares.sol";

import {console} from "forge-std/console.sol";

contract VaultSharesTest is Base_Test {
    uint256 mintAmount = 100 ether;
    address guardian = makeAddr("guardian");
    address user = makeAddr("user");
    AllocationData allocationData = AllocationData(
        500, // hold
        250, // uniswap
        250 // aave
    );
    VaultShares public wethVaultShares;
    uint256 public defaultGuardianAndDaoCut = 1000;

    AllocationData newAllocationData = AllocationData(
        0, // hold
        500, // uniswap
        500 // aave
    );

    function setUp() public override {
        Base_Test.setUp();
    }

    modifier hasGuardian() {
        weth.mint(mintAmount, guardian);
        vm.startPrank(guardian);
        weth.approve(address(vaultGuardians), mintAmount);
        address wethVault = vaultGuardians.becomeGuardian(allocationData);
        wethVaultShares = VaultShares(wethVault);
        vm.stopPrank();
        _;
    }

    modifier hasGuardianWithDoNothingAllocation() {
        AllocationData memory doNothingAllocationData = AllocationData(
            1000, // hold
            0, // uniswap
            0 // aave
        );

        weth.mint(mintAmount, guardian);
        vm.startPrank(guardian);
        weth.approve(address(vaultGuardians), mintAmount);
        address wethVault = vaultGuardians.becomeGuardian(doNothingAllocationData);
        wethVaultShares = VaultShares(wethVault);
        vm.stopPrank();
        _;
    }

    modifier hasGuardianWithFullAaveAllocation() {
        AllocationData memory fullAaveAllocationData = AllocationData(
            0, // hold
            0, // uniswap
            1000 // aave
        );

        weth.mint(mintAmount, guardian);
        vm.startPrank(guardian);
        weth.approve(address(vaultGuardians), mintAmount);
        address wethVault = vaultGuardians.becomeGuardian(fullAaveAllocationData);
        wethVaultShares = VaultShares(wethVault);
        vm.stopPrank();
        _;
    }

    function testViewFunctionsAreBroken() public hasGuardianWithFullAaveAllocation {
        assertEq(wethVaultShares.convertToAssets(10 ether), 0);
        assertEq(wethVaultShares.convertToShares(1), 10020000000000000001);
    }

    function testDepositingWhenAssetsAreInvestedGivesTooManyShares() public hasGuardianWithFullAaveAllocation {
        weth.mint(1, user);

        uint256 userBalanceBefore = weth.balanceOf(user);

        vm.startPrank(user);
        weth.approve(address(wethVaultShares), 1);
        wethVaultShares.deposit(1, user);

        uint256 shares = wethVaultShares.balanceOf(user);
        wethVaultShares.redeem(shares, user, user);
        
        uint256 userBalanceAfter = weth.balanceOf(user);
        // User converts 1 wei to nearly 5 eth
        assertEq(userBalanceAfter - userBalanceBefore, 4995004995004995004);
    }

    function testVaultViewFunctionsAreMisleading() public hasGuardianWithFullAaveAllocation {
        console.log(wethVaultShares.previewDeposit(1));
    }

    function testNoFeeForSmallDeposits() public hasGuardianWithDoNothingAllocation{
        uint256 userBalanceBefore = wethVaultShares.balanceOf(user);
        uint256 guardianBalanceBefore = wethVaultShares.balanceOf(guardian);
        uint256 vaultGuardiansBalanceBefore = wethVaultShares.balanceOf(address(vaultGuardians));

        // deposits that result in less than 1000 shares do not trigger a mint of shares
        // for the guardian or the dao
        uint256 amount = wethVaultShares.previewMint(999);
        console.log(amount);
        weth.mint(amount, user);
        vm.startPrank(user);
        weth.approve(address(wethVaultShares), amount);
        wethVaultShares.deposit(amount, user);
        vm.stopPrank();

        uint256 userBalanceAfter = wethVaultShares.balanceOf(user);
        uint256 guardianBalanceAfter = wethVaultShares.balanceOf(guardian);
        uint256 vaultGuardiansBalanceAfter = wethVaultShares.balanceOf(address(vaultGuardians));


        assertEq(userBalanceAfter - userBalanceBefore, 999);
        assertEq(guardianBalanceAfter - guardianBalanceBefore, 0);
        assertEq(vaultGuardiansBalanceAfter - vaultGuardiansBalanceBefore, 0);
    }



    function testSetupVaultShares() public hasGuardian {
        assertEq(wethVaultShares.getGuardian(), guardian);
        assertEq(wethVaultShares.getGuardianAndDaoCut(), defaultGuardianAndDaoCut);
        assertEq(wethVaultShares.getVaultGuardians(), address(vaultGuardians));
        assertEq(wethVaultShares.getIsActive(), true);
        assertEq(wethVaultShares.getAaveAToken(), address(awethTokenMock));
        assertEq(
            address(wethVaultShares.getUniswapLiquidtyToken()), uniswapFactoryMock.getPair(address(weth), address(weth))
        );
    }

    function testSetNotActive() public hasGuardian {
        vm.prank(wethVaultShares.getVaultGuardians());
        wethVaultShares.setNotActive();
        assertEq(wethVaultShares.getIsActive(), false);
    }

    function testOnlyVaultGuardiansCanSetNotActive() public hasGuardian {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(VaultShares.VaultShares__NotVaultGuardianContract.selector));
        wethVaultShares.setNotActive();
    }

    function testOnlyCanSetNotActiveIfActive() public hasGuardian {
        vm.startPrank(wethVaultShares.getVaultGuardians());
        wethVaultShares.setNotActive();
        vm.expectRevert(abi.encodeWithSelector(VaultShares.VaultShares__NotActive.selector));
        wethVaultShares.setNotActive();
        vm.stopPrank();
    }

    function testUpdateHoldingAllocation() public hasGuardian {
        vm.startPrank(wethVaultShares.getVaultGuardians());
        wethVaultShares.updateHoldingAllocation(newAllocationData);
        assertEq(wethVaultShares.getAllocationData().holdAllocation, newAllocationData.holdAllocation);
        assertEq(wethVaultShares.getAllocationData().uniswapAllocation, newAllocationData.uniswapAllocation);
        assertEq(wethVaultShares.getAllocationData().aaveAllocation, newAllocationData.aaveAllocation);
    }

    function testOnlyVaultGuardiansCanUpdateAllocationData() public hasGuardian {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(VaultShares.VaultShares__NotVaultGuardianContract.selector));
        wethVaultShares.updateHoldingAllocation(newAllocationData);
    }

    function testOnlyupdateAllocationDataWhenActive() public hasGuardian {
        vm.startPrank(wethVaultShares.getVaultGuardians());
        wethVaultShares.setNotActive();
        vm.expectRevert(abi.encodeWithSelector(VaultShares.VaultShares__NotActive.selector));
        wethVaultShares.updateHoldingAllocation(newAllocationData);
        vm.stopPrank();
    }

    function testMustUpdateAllocationDataWithCorrectPrecision() public hasGuardian {
        AllocationData memory badAllocationData = AllocationData(0, 200, 500);
        uint256 totalBadAllocationData =
            badAllocationData.holdAllocation + badAllocationData.aaveAllocation + badAllocationData.uniswapAllocation;

        vm.startPrank(wethVaultShares.getVaultGuardians());
        vm.expectRevert(
            abi.encodeWithSelector(VaultShares.VaultShares__AllocationNot100Percent.selector, totalBadAllocationData)
        );
        wethVaultShares.updateHoldingAllocation(badAllocationData);
        vm.stopPrank();
    }

    function testUserCanDepositFunds() public hasGuardian {
        weth.mint(mintAmount, user);
        vm.startPrank(user);
        weth.approve(address(wethVaultShares), mintAmount);
        wethVaultShares.deposit(mintAmount, user);

        assert(wethVaultShares.balanceOf(user) > 0);
    }

    function testUserDepositsFundsAndDaoAndGuardianGetShares() public hasGuardian {
        uint256 startingGuardianBalance = wethVaultShares.balanceOf(guardian);
        uint256 startingDaoBalance = wethVaultShares.balanceOf(address(vaultGuardians));

        weth.mint(mintAmount, user);
        vm.startPrank(user);
        console.log(wethVaultShares.totalSupply());
        weth.approve(address(wethVaultShares), mintAmount);
        wethVaultShares.deposit(mintAmount, user);

        assert(wethVaultShares.balanceOf(guardian) > startingGuardianBalance);
        assert(wethVaultShares.balanceOf(address(vaultGuardians)) > startingDaoBalance);
    }


    function testUserCanDepositFundsViaMintWithoutFee() public hasGuardian {
        uint256 startingGuardianBalance = wethVaultShares.balanceOf(guardian);
        uint256 startingDaoBalance = wethVaultShares.balanceOf(address(vaultGuardians));
        uint256 startingUserBalance = wethVaultShares.balanceOf(user);

        console.log(wethVaultShares.totalSupply());


        weth.mint(mintAmount, user);
        vm.startPrank(user);
        weth.approve(address(wethVaultShares), mintAmount);
        uint256 shares = wethVaultShares.previewDeposit(mintAmount);
        wethVaultShares.mint(shares, user);

        console.log(wethVaultShares.totalSupply());

        assert(wethVaultShares.balanceOf(user) > startingUserBalance);
        assert(wethVaultShares.balanceOf(guardian) == startingGuardianBalance);
        assert(wethVaultShares.balanceOf(address(vaultGuardians)) == startingDaoBalance);
    }

    modifier userIsInvested() {
        weth.mint(mintAmount, user);
        vm.startPrank(user);
        weth.approve(address(wethVaultShares), mintAmount);
        wethVaultShares.deposit(mintAmount, user);
        vm.stopPrank();
        _;
    }

    function testRebalanceResultsInTheSameOutcome() public hasGuardian userIsInvested {
        uint256 startingUniswapLiquidityTokensBalance =
            IERC20(wethVaultShares.getUniswapLiquidtyToken()).balanceOf(address(wethVaultShares));
        uint256 startingAaveAtokensBalance = IERC20(wethVaultShares.getAaveAToken()).balanceOf(address(wethVaultShares));

        wethVaultShares.rebalanceFunds();

        assertEq(
            IERC20(wethVaultShares.getUniswapLiquidtyToken()).balanceOf(address(wethVaultShares)),
            startingUniswapLiquidityTokensBalance
        );
        assertEq(
            IERC20(wethVaultShares.getAaveAToken()).balanceOf(address(wethVaultShares)), startingAaveAtokensBalance
        );
    }

    function testWithdraw() public hasGuardian userIsInvested {
        uint256 startingBalance = weth.balanceOf(user);
        uint256 startingSharesBalance = wethVaultShares.balanceOf(user);
        uint256 amoutToWithdraw = 1 ether;

        vm.prank(user);
        wethVaultShares.withdraw(amoutToWithdraw, user, user);

        assertEq(weth.balanceOf(user), startingBalance + amoutToWithdraw);
        assert(wethVaultShares.balanceOf(user) < startingSharesBalance);
    }

    function testRedeem() public hasGuardian userIsInvested {
        uint256 startingBalance = weth.balanceOf(user);
        uint256 startingSharesBalance = wethVaultShares.balanceOf(user);
        uint256 amoutToRedeem = 1 ether;

        vm.prank(user);
        wethVaultShares.redeem(amoutToRedeem, user, user);

        assert(weth.balanceOf(user) > startingBalance);
        assertEq(wethVaultShares.balanceOf(user), startingSharesBalance - amoutToRedeem);
    }
}
