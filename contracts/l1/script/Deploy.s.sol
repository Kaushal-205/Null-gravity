// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {ServiceManager} from "../src/ServiceManager.sol";
import {BLSVerifier} from "../src/BLSVerifier.sol";
import {Inbox} from "../src/Inbox.sol";

/**
 * @title Deploy
 * @notice Production deployment script for the Null-Gravity Bridge L1 contracts
 * 
 * Usage:
 *   # Local deployment (anvil)
 *   forge script script/Deploy.s.sol --broadcast --rpc-url http://localhost:8545
 * 
 *   # Testnet deployment (Sepolia)
 *   forge script script/Deploy.s.sol --broadcast --rpc-url $SEPOLIA_RPC_URL --verify
 * 
 *   # Mainnet deployment (with simulation first)
 *   forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL
 *   forge script script/Deploy.s.sol --broadcast --rpc-url $MAINNET_RPC_URL --verify
 */
contract Deploy is Script {
    // Default configuration (can be overridden via environment)
    uint256 constant DEFAULT_MINIMUM_STAKE = 1 ether;
    uint256 constant DEFAULT_QUORUM_BPS = 6700; // 67% (2/3 majority)
    bytes32 constant DEFAULT_L2_BRIDGE = bytes32(uint256(0x1234));

    function run() external {
        // Load configuration from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        bytes32 l2BridgeAddress = vm.envOr("L2_BRIDGE_ADDRESS", DEFAULT_L2_BRIDGE);
        uint256 minimumStake = vm.envOr("MINIMUM_STAKE", DEFAULT_MINIMUM_STAKE);
        uint256 quorumBps = vm.envOr("QUORUM_BPS", DEFAULT_QUORUM_BPS);
        address stakingToken = vm.envOr("STAKING_TOKEN", address(0)); // address(0) = native ETH

        console2.log("=== Deployment Configuration ===");
        console2.log("L2 Bridge Address:", vm.toString(l2BridgeAddress));
        console2.log("Minimum Stake:", minimumStake);
        console2.log("Quorum BPS:", quorumBps);
        console2.log("Staking Token:", stakingToken);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy BLSVerifier
        console2.log("Deploying BLSVerifier...");
        BLSVerifier blsVerifier = new BLSVerifier();
        console2.log("BLSVerifier deployed at:", address(blsVerifier));
        console2.log("  - Uses BLS precompiles:", blsVerifier.usesBLS());

        // 2. Deploy Inbox
        console2.log("Deploying Inbox...");
        Inbox inbox = new Inbox(l2BridgeAddress);
        console2.log("Inbox deployed at:", address(inbox));

        // 3. Deploy ServiceManager
        console2.log("Deploying ServiceManager...");
        ServiceManager serviceManager = new ServiceManager(
            address(blsVerifier),
            address(inbox),
            l2BridgeAddress,
            stakingToken,
            minimumStake,
            quorumBps
        );
        console2.log("ServiceManager deployed at:", address(serviceManager));

        // 4. Configure Inbox to authorize ServiceManager
        console2.log("Configuring Inbox...");
        inbox.setAuthorizedConsumer(address(serviceManager), true);
        console2.log("  - ServiceManager authorized as consumer");

        vm.stopBroadcast();

        // Log deployment summary
        console2.log("");
        console2.log("=== Deployment Summary ===");
        console2.log("Network:", block.chainid);
        console2.log("");
        console2.log("Contracts:");
        console2.log("  BLSVerifier:     ", address(blsVerifier));
        console2.log("  Inbox:           ", address(inbox));
        console2.log("  ServiceManager:  ", address(serviceManager));
        console2.log("");
        console2.log("Configuration:");
        console2.log("  L2 Bridge:       ", vm.toString(l2BridgeAddress));
        console2.log("  Minimum Stake:   ", minimumStake, "wei");
        console2.log("  Quorum:          ", quorumBps, "bps");
        console2.log("");
        console2.log("Next Steps:");
        console2.log("  1. Deploy ZecBridge on Aztec L2");
        console2.log("  2. Update L2 bridge address: serviceManager.setL2BridgeAddress(...)");
        console2.log("  3. Register operators with BLS keys");
        console2.log("  4. Start sentinel services");
    }
}

/**
 * @title DeployTestnet
 * @notice Testnet-specific deployment with test configuration
 */
contract DeployTestnet is Script {
    function run() external {
        // uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        bytes32 l2BridgeAddress = vm.envOr("L2_BRIDGE_ADDRESS", bytes32(uint256(0x1234)));

        vm.startBroadcast();

        // Deploy with lower stake for testing
        BLSVerifier blsVerifier = new BLSVerifier();
        Inbox inbox = new Inbox(l2BridgeAddress);
        ServiceManager serviceManager = new ServiceManager(
            address(blsVerifier),
            address(inbox),
            l2BridgeAddress,
            address(0), // ETH staking
            0.01 ether, // Lower stake for testnet
            5000 // 50% quorum
        );

        inbox.setAuthorizedConsumer(address(serviceManager), true);

        vm.stopBroadcast();

        console2.log("=== Testnet Deployment ===");
        console2.log("BLSVerifier:", address(blsVerifier));
        console2.log("Inbox:", address(inbox));
        console2.log("ServiceManager:", address(serviceManager));
    }
}

/**
 * @title VerifyDeployment
 * @notice Script to verify a deployment is working correctly
 */
contract VerifyDeployment is Script {
    function run() external view {
        address serviceManagerAddr = vm.envAddress("SERVICE_MANAGER_ADDRESS");
        
        ServiceManager sm = ServiceManager(payable(serviceManagerAddr));
        
        console2.log("=== Deployment Verification ===");
        console2.log("ServiceManager:", serviceManagerAddr);
        console2.log("  Owner:", sm.owner());
        console2.log("  BLS Verifier:", address(sm.blsVerifier()));
        console2.log("  Inbox:", address(sm.inbox()));
        console2.log("  L2 Bridge:", vm.toString(sm.l2BridgeAddress()));
        console2.log("  Min Stake:", sm.minimumStakeAmount());
        console2.log("  Quorum BPS:", sm.quorumThresholdBps());
        console2.log("  Active Operators:", sm.activeOperatorCount());
        console2.log("  Total Staked:", sm.totalStaked());
    }
}
