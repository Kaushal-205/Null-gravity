// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {ServiceManager} from "../src/ServiceManager.sol";
import {BLSVerifier} from "../src/BLSVerifier.sol";
import {Inbox} from "../src/Inbox.sol";
import {IServiceManager} from "../src/interfaces/IServiceManager.sol";
import {IBLSVerifier} from "../src/interfaces/IBLSVerifier.sol";

/**
 * @title ServiceManagerTest
 * @notice Comprehensive tests for the production ServiceManager contract
 */
contract ServiceManagerTest is Test {
    ServiceManager public serviceManager;
    BLSVerifier public blsVerifier;
    Inbox public inbox;

    address public owner;
    address public operator1;
    address public operator2;
    address public user;

    bytes32 public constant L2_BRIDGE_ADDRESS = bytes32(uint256(0x123456789));
    uint256 public constant MINIMUM_STAKE = 1 ether;
    uint256 public constant QUORUM_BPS = 5000; // 50%

    // Allow test contract to receive ETH (for slashing)
    receive() external payable {}

    function setUp() public {
        owner = address(this);
        operator1 = makeAddr("operator1");
        operator2 = makeAddr("operator2");
        user = makeAddr("user");

        // Deploy production contracts
        blsVerifier = new BLSVerifier();
        inbox = new Inbox(L2_BRIDGE_ADDRESS);

        // Deploy ServiceManager with ETH staking (address(0))
        serviceManager = new ServiceManager(
            address(blsVerifier),
            address(inbox),
            L2_BRIDGE_ADDRESS,
            address(0), // Native ETH staking
            MINIMUM_STAKE,
            QUORUM_BPS
        );

        // Authorize ServiceManager to consume messages
        inbox.setAuthorizedConsumer(address(serviceManager), true);

        // Fund operators
        vm.deal(operator1, 100 ether);
        vm.deal(operator2, 100 ether);
        vm.deal(user, 10 ether);
    }

    // ============ Registration Tests ============

    function test_RegisterOperator() public {
        // First register BLS key
        vm.startPrank(operator1);
        blsVerifier.registerBLSKey(IBLSVerifier.G1Point({x: 1, y: 2}));

        // Then register as operator with stake
        serviceManager.registerOperator{value: MINIMUM_STAKE}(MINIMUM_STAKE);

        IServiceManager.Operator memory op = serviceManager.getOperator(operator1);
        assertEq(op.addr, operator1);
        assertEq(op.stake, MINIMUM_STAKE);
        assertTrue(op.isActive);
        assertEq(serviceManager.activeOperatorCount(), 1);
        assertEq(serviceManager.totalStaked(), MINIMUM_STAKE);

        vm.stopPrank();
    }

    function test_RevertWhen_RegisterWithoutBLSKey() public {
        vm.startPrank(operator1);

        // Try to register without BLS key
        vm.expectRevert(IServiceManager.InvalidSignature.selector);
        serviceManager.registerOperator{value: MINIMUM_STAKE}(MINIMUM_STAKE);

        vm.stopPrank();
    }

    function test_RevertWhen_InsufficientStake() public {
        vm.startPrank(operator1);
        blsVerifier.registerBLSKey(IBLSVerifier.G1Point({x: 1, y: 2}));

        vm.expectRevert(IServiceManager.InsufficientStake.selector);
        serviceManager.registerOperator{value: 0.1 ether}(0.1 ether);

        vm.stopPrank();
    }

    function test_RevertWhen_AlreadyRegistered() public {
        vm.startPrank(operator1);
        blsVerifier.registerBLSKey(IBLSVerifier.G1Point({x: 1, y: 2}));
        serviceManager.registerOperator{value: MINIMUM_STAKE}(MINIMUM_STAKE);

        vm.expectRevert(IServiceManager.OperatorAlreadyRegistered.selector);
        serviceManager.registerOperator{value: MINIMUM_STAKE}(MINIMUM_STAKE);

        vm.stopPrank();
    }

    // ============ Deregistration Tests ============

    function test_DeregisterOperator() public {
        // Setup
        vm.startPrank(operator1);
        blsVerifier.registerBLSKey(IBLSVerifier.G1Point({x: 1, y: 2}));
        serviceManager.registerOperator{value: MINIMUM_STAKE}(MINIMUM_STAKE);

        // Deregister
        serviceManager.deregisterOperator();

        IServiceManager.Operator memory op = serviceManager.getOperator(operator1);
        assertFalse(op.isActive);
        assertEq(serviceManager.activeOperatorCount(), 0);

        // Check pending withdrawal
        (uint256 amount, uint256 unlockBlock) = serviceManager.getPendingWithdrawal(operator1);
        assertEq(amount, MINIMUM_STAKE);
        assertGt(unlockBlock, block.number);

        vm.stopPrank();
    }

    function test_CompleteWithdrawal() public {
        // Setup and deregister
        vm.startPrank(operator1);
        blsVerifier.registerBLSKey(IBLSVerifier.G1Point({x: 1, y: 2}));
        serviceManager.registerOperator{value: MINIMUM_STAKE}(MINIMUM_STAKE);
        serviceManager.deregisterOperator();

        // Fast forward past unbonding period
        vm.roll(block.number + 50401);

        uint256 balanceBefore = operator1.balance;
        serviceManager.completeWithdrawal();
        uint256 balanceAfter = operator1.balance;

        assertEq(balanceAfter - balanceBefore, MINIMUM_STAKE);

        // Verify withdrawal cleared
        (uint256 amount,) = serviceManager.getPendingWithdrawal(operator1);
        assertEq(amount, 0);

        vm.stopPrank();
    }

    function test_RevertWhen_WithdrawTooEarly() public {
        vm.startPrank(operator1);
        blsVerifier.registerBLSKey(IBLSVerifier.G1Point({x: 1, y: 2}));
        serviceManager.registerOperator{value: MINIMUM_STAKE}(MINIMUM_STAKE);
        serviceManager.deregisterOperator();

        // Try to withdraw before unbonding period
        vm.expectRevert(ServiceManager.WithdrawalNotReady.selector);
        serviceManager.completeWithdrawal();

        vm.stopPrank();
    }

    // ============ Slashing Tests ============

    function test_SlashOperator() public {
        // Setup
        vm.prank(operator1);
        blsVerifier.registerBLSKey(IBLSVerifier.G1Point({x: 1, y: 2}));
        vm.prank(operator1);
        serviceManager.registerOperator{value: MINIMUM_STAKE}(MINIMUM_STAKE);

        uint256 ownerBalanceBefore = owner.balance;

        // Create valid fraud proof (starts with operator address)
        bytes memory proof = abi.encodePacked(operator1, bytes32(uint256(123)));

        // Slash as owner
        serviceManager.slashOperator(operator1, proof);

        // Verify slash
        IServiceManager.Operator memory op = serviceManager.getOperator(operator1);
        uint256 expectedSlash = (MINIMUM_STAKE * 2000) / 10000; // 20%
        assertEq(op.stake, MINIMUM_STAKE - expectedSlash);

        // Verify slashed amount transferred to owner
        assertEq(owner.balance - ownerBalanceBefore, expectedSlash);
    }

    function test_SlashOperator_DeactivatesIfBelowMinimum() public {
        // Setup with exactly minimum stake
        vm.prank(operator1);
        blsVerifier.registerBLSKey(IBLSVerifier.G1Point({x: 1, y: 2}));
        vm.prank(operator1);
        serviceManager.registerOperator{value: MINIMUM_STAKE}(MINIMUM_STAKE);

        bytes memory proof = abi.encodePacked(operator1, bytes32(uint256(123)));

        // Slash multiple times to go below minimum
        serviceManager.slashOperator(operator1, proof);
        serviceManager.slashOperator(operator1, proof);
        serviceManager.slashOperator(operator1, proof);

        IServiceManager.Operator memory op = serviceManager.getOperator(operator1);
        assertFalse(op.isActive);
    }

    // ============ Configuration Tests ============

    function test_SetMinimumStake() public {
        uint256 newMinStake = 2 ether;
        serviceManager.setMinimumStake(newMinStake);
        assertEq(serviceManager.minimumStakeAmount(), newMinStake);
    }

    function test_SetQuorumThreshold() public {
        uint256 newQuorum = 6000; // 60%
        serviceManager.setQuorumThreshold(newQuorum);
        assertEq(serviceManager.quorumThresholdBps(), newQuorum);
    }

    function test_RevertWhen_InvalidQuorumThreshold() public {
        vm.expectRevert(ServiceManager.InvalidConfiguration.selector);
        serviceManager.setQuorumThreshold(0);

        vm.expectRevert(ServiceManager.InvalidConfiguration.selector);
        serviceManager.setQuorumThreshold(10001);
    }

    function test_SetL2BridgeAddress() public {
        bytes32 newAddress = bytes32(uint256(0xdeadbeef));
        serviceManager.setL2BridgeAddress(newAddress);
        assertEq(serviceManager.l2BridgeAddress(), newAddress);
    }

    // ============ Pause Tests ============

    function test_Pause() public {
        serviceManager.pause();

        vm.prank(operator1);
        blsVerifier.registerBLSKey(IBLSVerifier.G1Point({x: 1, y: 2}));

        vm.expectRevert();
        vm.prank(operator1);
        serviceManager.registerOperator{value: MINIMUM_STAKE}(MINIMUM_STAKE);
    }

    function test_Unpause() public {
        serviceManager.pause();
        serviceManager.unpause();

        vm.prank(operator1);
        blsVerifier.registerBLSKey(IBLSVerifier.G1Point({x: 1, y: 2}));
        vm.prank(operator1);
        serviceManager.registerOperator{value: MINIMUM_STAKE}(MINIMUM_STAKE);

        assertEq(serviceManager.activeOperatorCount(), 1);
    }

    // ============ View Function Tests ============

    function test_GetOperators() public {
        // Register two operators
        vm.prank(operator1);
        blsVerifier.registerBLSKey(IBLSVerifier.G1Point({x: 1, y: 2}));
        vm.prank(operator1);
        serviceManager.registerOperator{value: MINIMUM_STAKE}(MINIMUM_STAKE);

        vm.prank(operator2);
        blsVerifier.registerBLSKey(IBLSVerifier.G1Point({x: 3, y: 4}));
        vm.prank(operator2);
        serviceManager.registerOperator{value: MINIMUM_STAKE}(MINIMUM_STAKE);

        address[] memory operators = serviceManager.getOperators();
        assertEq(operators.length, 2);
        assertEq(operators[0], operator1);
        assertEq(operators[1], operator2);
    }

    function test_QuorumThreshold() public {
        // With 0 operators, threshold should be 0 (but min 1 in verifyAndDispatch)
        assertEq(serviceManager.quorumThreshold(), 0);

        // Register 2 operators
        vm.prank(operator1);
        blsVerifier.registerBLSKey(IBLSVerifier.G1Point({x: 1, y: 2}));
        vm.prank(operator1);
        serviceManager.registerOperator{value: MINIMUM_STAKE}(MINIMUM_STAKE);

        vm.prank(operator2);
        blsVerifier.registerBLSKey(IBLSVerifier.G1Point({x: 3, y: 4}));
        vm.prank(operator2);
        serviceManager.registerOperator{value: MINIMUM_STAKE}(MINIMUM_STAKE);

        // With 50% quorum and 2 operators, need 1 signature
        assertEq(serviceManager.quorumThreshold(), 1);
    }

    // ============ Access Control Tests ============

    function test_RevertWhen_NonOwnerCallsAdminFunction() public {
        vm.prank(user);
        vm.expectRevert();
        serviceManager.setMinimumStake(2 ether);

        vm.prank(user);
        vm.expectRevert();
        serviceManager.pause();

        vm.prank(user);
        vm.expectRevert();
        bytes memory proof = abi.encodePacked(operator1, bytes32(0));
        serviceManager.slashOperator(operator1, proof);
    }

    // ============ Ownership Transfer Tests ============

    function test_TwoStepOwnershipTransfer() public {
        address newOwner = makeAddr("newOwner");

        // Initiate transfer
        serviceManager.transferOwnership(newOwner);
        assertEq(serviceManager.owner(), owner); // Still old owner

        // Accept transfer
        vm.prank(newOwner);
        serviceManager.acceptOwnership();
        assertEq(serviceManager.owner(), newOwner);
    }
}
