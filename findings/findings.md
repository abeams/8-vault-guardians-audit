### [H-1] `VaultShares::constructor` initializes an invalid `i_uniswapLiquidityToken` when the asset is WETH, causing WETH vaults to revert whenever funds are divested

**Description:** 

The `VaultShares::i_uniswapLiquidityToken` is intended to designate the Uniswap token of the pool used for investment by a `VaultShares` contract. According to the `UniswapAdapter` contract documentation, this should be a WETH-USDC pool if the asset of the vault is USDC or WETH, and a WETH-LINK pool if the asset is LINK. However, in the `VaultShares::constructor` code shown below, when a vault is created for WETH, the `i_uniswapLiquidityToken` ends up being assigned the zero address.

```javascript
    constructor(ConstructorData memory constructorData)
        ERC4626(constructorData.asset)
        ERC20(constructorData.vaultName, constructorData.vaultSymbol)
        AaveAdapter(constructorData.aavePool)
        UniswapAdapter(constructorData.uniswapRouter, constructorData.weth, constructorData.usdc)
    {
        ...
 >>>    i_uniswapLiquidityToken = IERC20(i_uniswapFactory.getPair(address(constructorData.asset), address(i_weth)));
    }
```

The modifier `VaultShares::divestThenInvest` checks the `VaultShares` contract's balance of `i_uniswapLiquidityToken` in order to remove liquidity from the Uniswap pool. When this address is 0, this call reverts, breaking the functionality of WETH vaults.

```javascript
    modifier divestThenInvest() {
    >>> uint256 uniswapLiquidityTokensBalance = i_uniswapLiquidityToken.balanceOf(address(this));
        uint256 aaveAtokensBalance = i_aaveAToken.balanceOf(address(this));
        ...
    }
```

**Impact:** WETH vaults are unusable.

**Proof of Concept:** 

The following proof of code demonstrates this issue. It can be run by adding it to the `WethFork.t.sol` file.

```javascript
    modifier hasGuardian() {
        deal(address(weth), guardian, mintAmount);
        console.log(weth.balanceOf(guardian));
        vm.startPrank(guardian);
        weth.approve(address(vaultGuardians), 10 ether);
        address wethVault = vaultGuardians.becomeGuardian(allocationData);
        wethVaultShares = VaultShares(wethVault);
        vm.stopPrank();
        _;
    }

    function testUniswapPoolFailsForWeth() public hasGuardian {
        assertEq(wethVaultShares.getUniswapLiquidtyToken(), address(0));
        vm.expectRevert();
        wethVaultShares.rebalanceFunds();
    }
```

**Recommended Mitigation:** 

This issue can be fixed by correctly assigning the `i_uniswapLiquidityToken` in the case of WETH, using similar logic as that in the `UniswapAdaptor` contract:

```diff
    constructor(ConstructorData memory constructorData)
        ERC4626(constructorData.asset)
        ERC20(constructorData.vaultName, constructorData.vaultSymbol)
        AaveAdapter(constructorData.aavePool)
        UniswapAdapter(constructorData.uniswapRouter, constructorData.weth, constructorData.usdc)
    {
        ...
-       i_uniswapLiquidityToken = IERC20(i_uniswapFactory.getPair(address(constructorData.asset), address(i_weth)));
+       IERC20 counterPartyToken = token == i_weth ? i_tokenOne : i_weth;
+       i_uniswapLiquidityToken = IERC20(i_uniswapFactory.getPair(address(constructorData.asset), address(counterPartyToken)));
    }
```

### [H-2] Share Calculation During Deposit Doesn't Take Into Account Invested Assets, Granting Too Many Shares

**Description:** 

`VaultShares::deposit` (as well as `VaultShares::mint`, see M-1), do not divest assets before calculating shares. 

```javascript
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        isActive
        nonReentrant
        returns (uint256)
    {
        if (assets > maxDeposit(receiver)) {
            revert VaultShares__DepositMoreThanMax(assets, maxDeposit(receiver));
        }

>>>     // The following lines do not take into account invested assets
        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);
        _mint(i_guardian, shares.ceilDiv(i_guardianAndDaoCut));
        _mint(i_vaultGuardians, shares / i_guardianAndDaoCut);

        _investFunds(assets);
        return shares;
    }
```

As shown in the code snippet, when the amount of shares to be granted in exchange for deposited assets is calculated, already invested assets (in either Uniswap or AAVE), are not taken into account. For example, if 100% of the vault's assets are invested in say AAVE, then when `ERC4626::_convertToShares` is called by `ERC4626::previewDeposit`, `totalAssets()` returns 0, and so a single wei deposited receives nearly half of the total shares of the vault.

```javascript
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view virtual returns     (uint256) {
        return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }
```

**Impact:** Miscalculation of shares results huge monetary loss for existing depositors.

**Proof of Concept:** 

The example given in the explanation is demonstrated in the following test:

```javascript
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

    function testDepositingWhenAssetsAreInvestedGivesTooManyShares() public         hasGuardianWithFullAaveAllocation {
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
```

**Recommended Mitigation:** The `VaultShares::deposit` function should also use the `divestThenInvest` modifier. The `mint` function should also be shadowed, see M-1.

```diff
function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        isActive
+       divestThenInvest
        nonReentrant
        returns (uint256)
    {
        if (assets > maxDeposit(receiver)) {
            revert VaultShares__DepositMoreThanMax(assets, maxDeposit(receiver));
        }

        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);
        _mint(i_guardian, shares / i_guardianAndDaoCut);
        _mint(i_vaultGuardians, shares / i_guardianAndDaoCut);

-       _investFunds(assets);
        return shares;
    }
```

### [H-3] A Guardian can bypass `VaultGuardiansBase::quitGuardian` and directly withdraw their initial stake from the vault without setting it to unactive or ceding control

**Description:** 

When a guardian wishes to withdraw their initial stake, the intended functionality is that they call `VaultGuardiansBase::quitGuardian`, which :
1. sets the `VaultGuardiansBase::s_guardians` mapping entry for the vault to 0
2. sets the vault to inactive
3. redeems all of the guardian's shares (which in doing so, divests all of the invested funds in the vault)

```javascript
    function _quitGuardian(IERC20 token) private returns (uint256) {
        IVaultShares tokenVault = IVaultShares(s_guardians[msg.sender][token]);
        s_guardians[msg.sender][token] = IVaultShares(address(0));
        emit GaurdianRemoved(msg.sender, token);
        tokenVault.setNotActive();
        uint256 maxRedeemable = tokenVault.maxRedeem(msg.sender);
        uint256 numberOfAssetsReturned = tokenVault.redeem(maxRedeemable, msg.sender, msg.sender);
        return numberOfAssetsReturned;
    }
```

An inactive vault will no longer allow updated allocations or invest funds, it will only allow withdrawals.

However, instead of calling `quitGuardian`, a guardian can directly call `VaultShares::redeem` (or `VaultShares::withdraw`). This never sets the token vault to inactive, so the guardian is still able to update the allocation etc. This essentially allows a guardian to manipulate users' funds without hardly any of his own at stake (around 1/1000 of the guardian's initial stake is allocated to the DAO and therefore cannot be withdrawn by the guardian).

**Impact:** Guardians can pull out their initial stake without giving up control of the vault

**Proof of Concept:**

The following test which can be added to `VaultGuardiansBaseTest.t.sol` demonstrates this issue:

```javascript
    function testGuardianCanRemoveStakeWithoutDeactivatingVault() public hasGuardian {
        // After the inflationary fee for the dao, guardian holds a little over 99.9% ownership
        uint256 guardianCanWithdraw = wethVaultShares.previewRedeem(wethVaultShares.balanceOf(guardian));
        assertEq(guardianCanWithdraw, 9990019960079840319);
        
        vm.startPrank(guardian);
        console.log(wethVaultShares.balanceOf(guardian));
        wethVaultShares.redeem(wethVaultShares.balanceOf(guardian), guardian, guardian);
        vm.stopPrank();

        // The balance remaining in the vault is only ~1/1000 of the minimum stake amount
        assertEq(weth.balanceOf(address(wethVaultShares)), 9980039920159681);
        // But the vault is still active
        assertEq(wethVaultShares.getIsActive(), true);
        assertEq(address(vaultGuardians.getVaultFromGuardianAndToken(guardian, weth)), address(wethVaultShares));
    }
```

**Recommended Mitigation:** 

A simple fix is to require redemptions (and withdrawals) of the guardian's shares to be done by the `VaultGuardians` contract. Note that this also affects funds that the guardian might invest in their own vault in addition to the initial stake, so a more sophisticated mitigation might be desired.

Here is an example of the modification to the `VaultShares::redeem` function. A similar change should be made to the `VaultShares::withdraw` function.

```diff
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(IERC4626, ERC4626)
        divestThenInvest
        nonReentrant
        returns (uint256)
    {
+       if(owner == i_guardian && msg.sender != i_vaultGuardians) {
+           revert VaultShares__NotVaultGuardianContract();
+       }
        uint256 assets = super.redeem(shares, receiver, owner);
        return assets;
    }
```

### [H-4] When a Guardian quits a vault, his governance tokens are not burned, letting a Guardian repeatedly create and quit vaults to mint governance tokens for ~1/1000 of their intended cost

**Description:** 

In the internal function `VaultGuardiansBase::_becomeTokenGuardian`, which is called when a vault is created for any of the three assets, the guardian is minted `VaultGuardiansBase::s_guardianStakePrice` of the VaultGuardianTokens, which are used for governance.

```javascript
function _becomeTokenGuardian(IERC20 token, VaultShares tokenVault) private returns (address) {
        s_guardians[msg.sender][token] = IVaultShares(address(tokenVault));
        emit GuardianAdded(msg.sender, token);
>>>     i_vgToken.mint(msg.sender, s_guardianStakePrice);
        token.safeTransferFrom(msg.sender, address(this), s_guardianStakePrice);
        bool succ = token.approve(address(tokenVault), s_guardianStakePrice);
        if (!succ) {
            revert VaultGuardiansBase__TransferFailed();
        }
        uint256 shares = tokenVault.deposit(s_guardianStakePrice, msg.sender);
        if (shares == 0) {
            revert VaultGuardiansBase__TransferFailed();
        }
        return address(tokenVault);
    }

```

 Afterwards, the guardian can quit their vault to recuperate nearly all of their staked asset, and still hold the VaultGuardiansTokens. The only part of their initial investment which cannot be withdrawn is that corresponding to the shares minted for the `VaultGuardians` contract.

This effectively allows an attacker to continuously call `VaultGuardiansBase::becomeGuardian` and then `VaultGuardiansBase::quitGuardian` (or the LINK/USDC equivalent if cheaper), to mint governance tokens cheaply. These governance tokens can then be used to permanently alter the `VaultGuardians` contract to be more favorable to the attacker.

**Impact:** Ability to mint cheap governance tokens jeopardizes the security of the DAO

**Proof of Concept:**

The following test which can be added to `VaultGuardiansBaseTest.t.sol` demonstrates one iteration of this attack:

```javascript
    function testCanCreateAndQuitGuardianToMintCheapGovernanceTokens() public {
        // Set up a weth vault
        assertEq(vaultGuardians.getGuardianStakePrice(), 10 ether);
        weth.mint(10 ether, guardian);
        vm.startPrank(guardian);
        weth.approve(address(vaultGuardians), 10 ether);
        address wethVault = vaultGuardians.becomeGuardian(doNothingAllocation);
        wethVaultShares = VaultShares(wethVault);
        vm.stopPrank();
        
        // Quit guardian
        vm.startPrank(guardian);
        wethVaultShares.approve(address(vaultGuardians), mintAmount);
        vaultGuardians.quitGuardian();
        vm.stopPrank();

        // Weth balance is almost the same as initial balance (minus about 1/1000) 
        assertEq(weth.balanceOf(guardian), 9990019960079840319);
        // But the guardian gets to keep his governance tokens
        assertEq(vaultGuardianToken.balanceOf(guardian), vaultGuardians.getGuardianStakePrice());
    }
```

**Recommended Mitigation:** 

One possible solution is to remove the transferability of the governance tokens, make them burnable, and then burn the same amount minted when `quitGuardian` is called. Note that this mitigation requires that `quitGuardian` is the only method which allows the guardian to withdraw his initial stake, see `H-2`.

```diff
    function _quitGuardian(IERC20 token) private returns (uint256) {
        IVaultShares tokenVault = IVaultShares(s_guardians[msg.sender][token]);
        s_guardians[msg.sender][token] = IVaultShares(address(0));
        emit GaurdianRemoved(msg.sender, token);
        tokenVault.setNotActive();
+       i_vgToken.burn(msg.sender, s_guardianStakePrice);
        uint256 maxRedeemable = tokenVault.maxRedeem(msg.sender);
        uint256 numberOfAssetsReturned = tokenVault.redeem(maxRedeemable, msg.sender, msg.sender);
        return numberOfAssetsReturned;
    }

```

### [H-5] The `VaultGuardianGovernor` contract has a quorum of only 4%, making the system vulnerable to malicious takeover.

**Description:** 

The `VaultGuardianGovernor::constructor` sets the `GovernerVotesQuorumFraction` to 4, which means that only 4% of votes are needed to execute a proposal.

```javascript
    constructor(IVotes _voteToken)
        Governor("VaultGuardianGovernor")
        GovernorVotes(_voteToken)
>>>     GovernorVotesQuorumFraction(4)
    {}
```

After controlling 4% of the votes, an attacker could change ownership of `VaultGuardians` to permanently remove the DAO from power, call `VaultGuardians::updateGuardianAndDaoCut` to set the cut to 0, removing the ability to deploy new vaults (as they would all revert on initial deposit due to divide by 0).


**Impact:** The `VaultGuardians` contract is at risk of malicious takeover.

**Recommended Mitigation:** 

The quorum should be at least more than 50%:

```diff
    constructor(IVotes _voteToken)
        Governor("VaultGuardianGovernor")
        GovernorVotes(_voteToken)
-       GovernorVotesQuorumFraction(4)
+       GovernorVotesQuorumFraction(4)
    {}
```

### [M-1] User can call `VaultShares::mint` to deposit assets without minting the fee shares for the Guardian or DAO. 

**Description:** `VaultShares` does not shadow the inherited `ERC3646::mint` function, so this is callable as as alternative to the `VaultShares::deposit` function. However, the `mint` function does not include the below code which mints additional shares as a fee for the Guardian and the DAO:

```javascript
        function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        isActive
        nonReentrant
        returns (uint256)
    {
        ...
        _mint(i_guardian, shares / i_guardianAndDaoCut);
        _mint(i_vaultGuardians, shares / i_guardianAndDaoCut);
        ...
    }

```

**Impact:** This allows users to bypass the entire fee mechanism of the Vault.

**Proof of Concept:** The following test which can be added to `VaultSharesTest.t.sol` shows the issue:

```javascript
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
```

**Recommended Mitigation:** 

The easist fix is to override`ERC4626::mint` function to revert.

```diff
+   function mint(uint256 shares, address receiver)
+       public
+       override(ERC4626, IERC4626)
+       returns (uint256)
+   {
+       revert VaultShares__NotSupported();
+   }
```

### [M-2] `VaultShares` preview functions give incorrect/misleading results due to invested assets

**Description:** 

The `VaultShares` contract inherits several view functions from `ERC4626`. These include the four preview functions, `previewDeposit`, `previewMint`, `previewRedeem`, `previewWithdraw`, as well as `convertToShares`, `convertToAssets`, and `maxWithdraw`. All of these use `totalAssets()` in their calculations, which unfortunately has the same issue as in H-2 - when it ignores currently invested assets.

```javascript
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view virtual returns     (uint256) {
        return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }
```

**Impact:** All of the above view functions return incorrect results when there are invested assets

**Proof of Concept:**

Here is an example test which can be added to `VaultSharesTest.t.sol`:

```javascript
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
```

**Recommended Mitigation:** 

Unfortunately, because these are view functions, using the `divestThenInvest` modifier is not feasible. Therefore, the best solution may be to simply shadow these to revert so that users are not otherwise mislead.

### [M-3] `UniswapAdapter::_uniswapInvest` invests more than intended, causing improper allocation and potentially reverts

**Description:** 

The `UniswapAdapter::_uniswapInvest` function takes a `token`, and `amount` parameter, and is intended to invest that amount of that type of token into a Uniswap pool. Because a Uniswap pool requires two tokens to add liquidity, the function chooses a counter-party token (WETH in most cases, USDC if the token is WETH), and first swaps half of `amount` to the counter-party token. Then it adds liquidity.

However, the `_uniswapInvest` function calculates the amount of `token` to approve, and then to pass as `amountADesired` in the call to `UniswapRouter::addLiquity` as `amountOfTokenToSwap + amounts[0]` (see below). Because half of the token has already been swapped into the counter-token, this value *should* just be `amountOfTokenToSwap`, which is `amount/2`. `amounts[0]` is the amount of token which was passed into the swap (also `amount/2`), so this is essentially approving `amount` tokens to add liquidity, as well as the `amount/2` tokens which were already used to swap to the counter-token. This meeans that `_uniswapInvest` uses 1.5 x `amount` tokens. If the `VaultShares::s_allocationData` allocated less than the extra .5 amount tokens to the `doNothing` category, this will cause the `VaultShares::_investFunds` function to revert. Otherwise, it will simply use tokens allocated to `doNothing` for the Uniswap investment.


```javascript

function _uniswapInvest(IERC20 token, uint256 amount) internal {
        IERC20 counterPartyToken = token == i_weth ? i_tokenOne : i_weth;
        // We will do half in WETH and half in the token
        uint256 amountOfTokenToSwap = amount / 2;
        // the path array is supplied to the Uniswap router, which allows us to create swap paths
        // in case a pool does not exist for the input token and the output token
        // however, in this case, we are sure that a swap path exists for all pair permutations of WETH, USDC and LINK
        // (excluding pair permutations including the same token type)
        // the element at index 0 is the address of the input token
        // the element at index 1 is the address of the output token
        s_pathArray = [address(token), address(counterPartyToken)];

        bool succ = token.approve(address(i_uniswapRouter), amountOfTokenToSwap);
        if (!succ) {
            revert UniswapAdapter__TransferFailed();
        }
        //@audit-med this is susceptible to mev attacks, especially with no slippage
        uint256[] memory amounts = i_uniswapRouter.swapExactTokensForTokens({
            amountIn: amountOfTokenToSwap,
            amountOutMin: 0,
            path: s_pathArray,
            to: address(this),
            deadline: block.timestamp
        });

        succ = counterPartyToken.approve(address(i_uniswapRouter), amounts[1]);
        if (!succ) {
            revert UniswapAdapter__TransferFailed();
        }
>>>     succ = token.approve(address(i_uniswapRouter), amountOfTokenToSwap + amounts[0]);
        if (!succ) {
            revert UniswapAdapter__TransferFailed();
        }

        // amounts[1] should be the WETH amount we got back
        (uint256 tokenAmount, uint256 counterPartyTokenAmount, uint256 liquidity) = i_uniswapRouter.addLiquidity({
            tokenA: address(token),
            tokenB: address(counterPartyToken),
>>>         amountADesired: amountOfTokenToSwap + amounts[0],
            amountBDesired: amounts[1],
            amountAMin: 0,
            amountBMin: 0,
            to: address(this),
            deadline: block.timestamp
        });
        emit UniswapInvested(tokenAmount, counterPartyTokenAmount, liquidity);
    }

```

**Impact:** Investment strategy used by `VaultShares` does not reflect intended allocation, and potentially reverts.

**Proof of Concept:**

The following test file uses a `UniswapAdapterWrapper` contract which simply exposes the private `UniswapAdapter::_uniswapInvest` and `UniswapAdapter::_uniswapDivest` functions as public.


Here is the `UniswapAdapterWrapper.sol` file:

```javascript
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
```

Here is the `UniswapAdapterTest.t.sol` file:

```javascript
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
```

**Recommended Mitigation:** 

The `_uniswapInvest` function should be modified to approve and transfer the correct amount of tokens to the `UniswapRouter`.

```diff
function _uniswapInvest(IERC20 token, uint256 amount) internal {
        IERC20 counterPartyToken = token == i_weth ? i_tokenOne : i_weth;
        // We will do half in WETH and half in the token
        uint256 amountOfTokenToSwap = amount / 2;
        // the path array is supplied to the Uniswap router, which allows us to create swap paths
        // in case a pool does not exist for the input token and the output token
        // however, in this case, we are sure that a swap path exists for all pair permutations of WETH, USDC and LINK
        // (excluding pair permutations including the same token type)
        // the element at index 0 is the address of the input token
        // the element at index 1 is the address of the output token
        s_pathArray = [address(token), address(counterPartyToken)];

        bool succ = token.approve(address(i_uniswapRouter), amountOfTokenToSwap);
        if (!succ) {
            revert UniswapAdapter__TransferFailed();
        }
        //@audit-med this is susceptible to mev attacks, especially with no slippage
        uint256[] memory amounts = i_uniswapRouter.swapExactTokensForTokens({
            amountIn: amountOfTokenToSwap,
            amountOutMin: 0,
            path: s_pathArray,
            to: address(this),
            deadline: block.timestamp
        });

        succ = counterPartyToken.approve(address(i_uniswapRouter), amounts[1]);
        if (!succ) {
            revert UniswapAdapter__TransferFailed();
        }
-       succ = token.approve(address(i_uniswapRouter), amountOfTokenToSwap + amounts[0]);
+       succ = token.approve(address(i_uniswapRouter), amountOfTokenToSwap);
        if (!succ) {
            revert UniswapAdapter__TransferFailed();
        }

        // amounts[1] should be the WETH amount we got back
        (uint256 tokenAmount, uint256 counterPartyTokenAmount, uint256 liquidity) = i_uniswapRouter.addLiquidity({
            tokenA: address(token),
            tokenB: address(counterPartyToken),
-           amountADesired: amountOfTokenToSwap + amounts[0],
+           amountADesired: amountOfTokenToSwap,
            amountBDesired: amounts[1],
            amountAMin: 0,
            amountBMin: 0,
            to: address(this),
            deadline: block.timestamp
        });
        emit UniswapInvested(tokenAmount, counterPartyTokenAmount, liquidity);
    }

```

### [M-4] `UniswapAdapter` uses no slippage parameters, putting invested funds at risk

**Description:** 

All of the Uniswap functions called by `UniswapAdapter` use slippage parameters of 0. This is *extremely* dangerous.

**Impact:** Swapping and adding/removing liquidity via Uniswap is vulnerable to slippage loss.

**Recommended Mitigation:** Slippage parameters should be used.

### [L-1] `VaultGuardiansBase::GUARDIAN_FEE` is never charged, contradicting documentation

**Description:** 

The `VaultGuardiansBase` contract has a fixed `GUARDIAN_FEE` constant, which is set to .1 ether. The docstring for `VaultGuardiansBase::becomeGuardian` states that:

```javascript
    /*
     * @notice allows a user to become a guardian
     * @notice they have to send an ETH amount equal to the fee, and a WETH amount equal to the stake price
     * 
     * @param wethAllocationData the allocation data for the WETH vault
     */
    function becomeGuardian(AllocationData memory wethAllocationData) external returns (address)
```

However, this `GUARDIAN_FEE` is never charged. It is not clear if the fee is also intended to apply to `VaultGuardiansBase::becomeTokenGuardian` as well, but it does not.

**Impact:** The intended fee `GUARDIAN_FEE` is never charged.

**Recommended Mitigation:** 

The `becomeGuardian` function should charge the `GUARDIAN_FEE`.

```diff
+    error VaultGuardiansBase__NotEnoughEth(uint256 amount, uint256 amountNeeded);

...

-    function becomeGuardian(AllocationData memory wethAllocationData) external returns (address) {
+    function becomeGuardian(AllocationData memory wethAllocationData) external payable returns (address) {
+       if(msg.value != GUARDIAN_FEE) {
+           revert VaultGuardiansBase__NotEnoughEth(msg.value, GUARDIAN_FEE);
+       }
        VaultShares wethVault =
        new VaultShares(IVaultShares.ConstructorData({
            asset: i_weth,
            vaultName: WETH_VAULT_NAME,
            vaultSymbol: WETH_VAULT_SYMBOL,
            guardian: msg.sender,
            allocationData: wethAllocationData,
            aavePool: i_aavePool,
            uniswapRouter: i_uniswapV2Router,
            guardianAndDaoCut: s_guardianAndDaoCut,
            vaultGuardians: address(this),
            weth: address(i_weth),
            usdc: address(i_tokenOne)
        }));
        return _becomeTokenGuardian(i_weth, wethVault);
    }
```

### [L-2] `VaultGuardiansBase` deploys the `VaultShares` contract for Link with the wrong name and symbol, potentially misleading users

**Description:** 

When the `VaultGuardiansBase` contract deploys a `VaultShares` contract for the asset Link, it sets the name and symbol to the same as the USDC vaults, "Vault Guardian USDC" and "vgUSDC" respectively.

```javascript
        function becomeTokenGuardian(AllocationData memory allocationData, IERC20 token)
        external
        onlyGuardian(i_weth)
        returns (address)
    {
        ...
        } else if (address(token) == address(i_tokenTwo)) {
            tokenVault =
            new VaultShares(IVaultShares.ConstructorData({
                asset: token,
        >>>     vaultName: TOKEN_ONE_VAULT_NAME,
        >>>     vaultSymbol: TOKEN_ONE_VAULT_SYMBOL,
                guardian: msg.sender,
                allocationData: allocationData,
                aavePool: i_aavePool,
                uniswapRouter: i_uniswapV2Router,
                guardianAndDaoCut: s_guardianAndDaoCut,
                vaultGuardians: address(this),
                weth: address(i_weth),
                usdc: address(i_tokenOne)
            }));
        ...
    }
```

**Impact:** LINK vaults are created with the wrong name and symbol.

**Proof of Concept:** 

The following proof of code demonstrates this issue. It can be run by adding it to the `VaultGuardiansBaseTest.t.sol` file.

```javascript
        function testBecomeTokenGuardianLinkHasWrongName() public hasGuardian {
        link.mint(mintAmount, guardian);
        vm.startPrank(guardian);
        link.approve(address(vaultGuardians), mintAmount);
        address tokenVault = vaultGuardians.becomeTokenGuardian(allocationData, link);
        linkVaultShares = VaultShares(tokenVault);
        vm.stopPrank();

        assertEq(linkVaultShares.name(), "Vault Guardian USDC");
        assertEq(linkVaultShares.symbol(), "vgUSDC");
    }
```

**Recommended Mitigation:** 

This issue can be fixed by correctly assigning the name and symbol for LINK.

```diff
    else if (address(token) == address(i_tokenTwo)) {
            tokenVault =
            new VaultShares(IVaultShares.ConstructorData({
                asset: token,
-               vaultName: TOKEN_ONE_VAULT_NAME,
-               vaultSymbol: TOKEN_ONE_VAULT_SYMBOL,
+               vaultName: TOKEN_TWO_VAULT_NAME,
+               vaultSymbol: TOKEN_TWO_VAULT_SYMBOL,
                guardian: msg.sender,
                allocationData: allocationData,
                aavePool: i_aavePool,
                uniswapRouter: i_uniswapV2Router,
                guardianAndDaoCut: s_guardianAndDaoCut,
                vaultGuardians: address(this),
                weth: address(i_weth),
                usdc: address(i_tokenOne)
            }));
    }
```

### [L-3] The Cost of Minting DAO Tokens Depends on the Vault Asset

**Description:** 

**Impact:** 

**Proof of Concept:**

**Recommended Mitigation:** 

### [L-4] Small Deposits To the Vault Do Not Incur Fees

**Description:** 

Because the `VaultShares` contract charges a fee based on dividing the number of shares minted by 
`VaultShares::i_guardianAndDaoCut` using standard floor division, when the number of shares minted is less than the `i_guardianAndDaoCut` value (which defaults to 1000), no shares are minted to the guardian or VaultGuardians.

```javascript
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        isActive
        nonReentrant
        returns (uint256)
    {
        if (assets > maxDeposit(receiver)) {
            revert VaultShares__DepositMoreThanMax(assets, maxDeposit(receiver));
        }

        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);
>>>     _mint(i_guardian, shares / i_guardianAndDaoCut);
>>>     _mint(i_vaultGuardians, shares / i_guardianAndDaoCut);

        _investFunds(assets);
        return shares;
    }

```

**Impact:** No fees are charged for small deposits to the vault

**Proof of Concept:** 

This is demonstrated in the following test, which can be added to `VaultSharesTest.t.sol`.

```javascript
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

    function testNoFeeForSmallDeposits() public hasGuardianWithDoNothingAllocation{
        uint256 userBalanceBefore = wethVaultShares.balanceOf(user);
        uint256 guardianBalanceBefore = wethVaultShares.balanceOf(guardian);
        uint256 vaultGuardiansBalanceBefore = wethVaultShares.balanceOf(address(vaultGuardians));

        // deposits that result in less than 1000 shares do not trigger a mint of shares
        // for the guardian or the dao
        uint256 amount = wethVaultShares.previewMint(999);
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
```

**Recommended Mitigation:** 

This may not be considered an issue for the protocol. However, an easy mitigation would be to take the ceiling of the division using `ceilDiv` from OpenZeppelin's Math library:


```diff
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        isActive
        nonReentrant
        returns (uint256)
    {
        if (assets > maxDeposit(receiver)) {
            revert VaultShares__DepositMoreThanMax(assets, maxDeposit(receiver));
        }

        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);
+       _mint(i_guardian, shares.ceilDiv(i_guardianAndDaoCut));
+       _mint(i_vaultGuardians, shares.ceilDiv(i_guardianAndDaoCut));
-       _mint(i_guardian, shares / i_guardianAndDaoCut);
-       _mint(i_vaultGuardians, shares / i_guardianAndDaoCut);

        _investFunds(assets);
        return shares;
    }
}
```

### [L-5] Events in `UniswapAdapter` are thrown with incorrect parameters when the asset is WETH

**Description:** 

The `UniswapAdapter` event has two events:
```javascript
    event UniswapInvested(uint256 tokenAmount, uint256 wethAmount, uint256 liquidity);
    event UniswapDivested(uint256 tokenAmount, uint256 wethAmount);
```

When the vault asset is WETH (and therefore the counterPartyToken is USDC), the `UniswapInvested` event is thrown like `emit UniswapInvested(tokenAmount, counterPartyTokenAmount, liquidity);`. This means that the `wethAmount` parameter is set as the amount of USDC token invested, which is incorrect. This same issue applied to the `UniswapDivested` event.

**Impact:** Off-chain services listening to these events will receive bad data.

**Mitigation:**

The events should be changed to include the non-WETH token, and in the case that the asset is WETH, the events should be thrown with the parameters switched around:

```javascript
    if(token == i_weth) {
        emit UniswapInvested(i_tokenOne, counterPartyTokenAmount, tokenAmount, liquidity);
    }
```

### [I-1] Function names are mispelled

**Description:** 

`VaultShares::getUniswapLiquidtyToken` should be `VaultShares::getUniswapLiquidityToken`


### [I-2] Event names are mispelled

**Description:** 

`VaultGuardiansBase::GaurdianRemoved` should be `VaultGuardiansBase::GuardianRemoved`.
`VaultGuardiansBase::DinvestedFromGuardian` should be `VaultGuardiansBase::DivestedFromGuardian`.

### [I-3] Interfaces are unused

**Description:** 

The `InvestableUniversalAdapter` interface is never used, and also its only two function signatures are 
commented out. The `IVaultGuardians` interface is also empty, and never used.

**Mitigation:**

`InvestableUniversalAdapter`: Either this file should be completely removed, or the functions should be uncommented and the `UniswapAdapter` and `AaveAdapter` should implement this interface.

`IVaultGuardians`: This file should be removed.

