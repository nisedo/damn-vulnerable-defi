# Withdrawal

## Vulnerability

The `Withdrawal` challenge demonstrates a **token bridge protection** scenario where a suspicious malicious withdrawal has been detected among legitimate ones. The vulnerability lies in the fact that anyone can create withdrawal requests on L2, and if they get included in the Merkle tree, they can be executed on L1.

However, the **operator role** in `L1Gateway` provides special powers that can be leveraged to protect the bridge:
1. **Operators can skip Merkle proof verification** - They can finalize ANY withdrawal parameters, not just those in the Merkle tree
2. **The `TokenBridge.totalDeposits` counter** tracks deposited amounts and can underflow when withdrawing more than available

The suspicious withdrawal #2 attempts to steal 999,000 DVT (nearly all bridge funds). Looking at the message data:
- Inner l2Sender: `0xea475d60c118d7058bef4bdd9c32ba51139a74e0`
- Amount: `999,000e18` DVT

The key insight is that `TokenBridge.executeTokenWithdrawal` performs an unchecked subtraction on `totalDeposits`:

```solidity
function executeTokenWithdrawal(address receiver, uint256 amount) external {
    if (msg.sender != address(l1Forwarder) || l1Forwarder.getSender() == otherBridge) revert Unauthorized();
    totalDeposits -= amount;  // Can underflow!
    token.transfer(receiver, amount);
}
```

If `totalDeposits < amount`, the subtraction causes an arithmetic underflow panic, reverting the call.

Crucially, in `L1Gateway.finalizeWithdrawal`, the leaf is marked as finalized **BEFORE** the external call:

```solidity
finalizedWithdrawals[leaf] = true;
counter++;
xSender = l2Sender;
bool success;
assembly {
    success := call(gas(), target, 0, add(message, 0x20), mload(message), 0, 0)
}
```

This means even if the call fails, the withdrawal is still marked as finalized!

## Solution

The exploit leverages the operator's ability to create arbitrary withdrawals to cause a `totalDeposits` underflow:

1. **Create a fake withdrawal** to drain tokens from the bridge:
   - As an operator, finalize a crafted withdrawal to send 1,000 DVT to a dummy address
   - This reduces `totalDeposits` from 1,000,000 to 999,000

2. **Finalize legitimate withdrawals** (0, 1, 3):
   - Each withdraws 10 DVT
   - `totalDeposits` becomes 999,000 - 30 = 998,970

3. **Finalize the suspicious withdrawal** (#2):
   - It attempts to withdraw 999,000 DVT
   - `totalDeposits -= 999000e18` causes underflow: `998,970 - 999,000 = UNDERFLOW!`
   - The call reverts with `panic: arithmetic underflow`
   - BUT the leaf is already marked as finalized!

Final state:
- Bridge balance: 998,970 DVT (> 99% of initial 1,000,000)
- All 4 required withdrawal leaves are finalized
- The suspicious withdrawal was blocked without transferring tokens
- Player ends with 0 tokens

```solidity
// Step 1: Create fake withdrawal to cause underflow
address dummyReceiver = address(0xdead);
bytes memory fakeWithdrawalMsg = abi.encodeCall(
    L1Forwarder.forwardMessage,
    (100, dummyReceiver, address(l1TokenBridge),
     abi.encodeCall(TokenBridge.executeTokenWithdrawal, (dummyReceiver, 1000e18)))
);
l1Gateway.finalizeWithdrawal(100, l2Handler_addr, address(l1Forwarder), timestamp, fakeWithdrawalMsg, new bytes32[](0));

// Step 2: Finalize legitimate withdrawals (0, 1, 3) - 30 DVT total

// Step 3: Finalize suspicious withdrawal #2
// This will fail due to underflow, but leaf is still finalized!
```

## Key Takeaways

1. **Operator privileges** can be used defensively to protect bridge funds
2. **Arithmetic checks** (Solidity 0.8+) can be weaponized to prevent malicious withdrawals
3. **State changes before external calls** (even for security reasons) can have unintended consequences - here it allows marking failed withdrawals as finalized
4. **Bridge security** requires careful accounting to prevent both overflow and underflow attacks

