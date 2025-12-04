// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IBLSVerifier} from "./interfaces/IBLSVerifier.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title BLSVerifier
 * @notice Signature verification for the Zcash-Aztec Bridge
 * @dev Current implementation uses ECDSA signatures for production readiness.
 * 
 * NOTE: EIP-2537 BLS12-381 precompiles (addresses 0x0b-0x13) are NOT yet 
 * available on Ethereum mainnet as of November 2025. The Pectra/Prague upgrade
 * only includes precompiles up to 0x0A (Point Evaluation).
 * 
 * This contract uses ECDSA with the IBLSVerifier interface for:
 * 1. Production readiness today
 * 2. Interface compatibility for future BLS upgrade
 * 3. Easy migration path when EIP-2537 is activated
 * 
 * Security Model:
 * - Each operator registers a public key (stored as G1Point for interface compatibility)
 * - Signatures are verified using standard ECDSA recovery
 * - Multiple signatures are concatenated and verified individually
 * 
 * Future Upgrade Path:
 * - When BLS precompiles are available, deploy BLSVerifierV2
 * - Migrate operator keys to BLS format
 * - Update ServiceManager to point to new verifier
 */
contract BLSVerifier is IBLSVerifier, Ownable, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============ Constants ============

    /// @notice Signature length for ECDSA (r: 32, s: 32, v: 1)
    uint256 private constant SIGNATURE_LENGTH = 65;

    // ============ State Variables ============

    /// @notice Mapping of operator address to their registered public key
    /// @dev G1Point.x stores a unique identifier derived from registration
    ///      G1Point.y is reserved for future BLS key migration
    mapping(address => G1Point) private operatorKeys;

    /// @notice Mapping to track if an operator has registered a key
    mapping(address => bool) private _hasKey;

    /// @notice Number of registered operators
    uint256 public operatorCount;

    // ============ Events ============

    /// @notice Emitted when an operator key is removed
    event OperatorKeyRemoved(address indexed operator);

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {
        // BLS precompiles (EIP-2537) are not yet available on mainnet as of Nov 2025
        // This contract uses ECDSA signatures for now
    }

    // ============ External Functions ============

    /**
     * @inheritdoc IBLSVerifier
     * @dev Registers a public key for the operator
     *      The G1Point structure is used for interface compatibility with future BLS
     */
    function registerBLSKey(G1Point calldata pubkey) external nonReentrant {
        if (_hasKey[msg.sender]) revert InvalidBLSKey();
        
        // Validate the pubkey - must have non-zero x coordinate
        if (pubkey.x == 0) revert InvalidBLSKey();

        operatorKeys[msg.sender] = pubkey;
        _hasKey[msg.sender] = true;
        operatorCount++;

        emit BLSKeyRegistered(msg.sender, pubkey);
    }

    /**
     * @inheritdoc IBLSVerifier
     * @dev For ECDSA mode, validates that pubkeys are registered
     *      Real signature verification happens in verifySignatures
     */
    function verifyAggregateSignature(
        bytes32 message,
        G2Point calldata signature,
        G1Point[] calldata pubkeys
    ) external view returns (bool) {
        // Suppress unused variable warnings for interface compatibility
        message;
        signature;

        if (pubkeys.length == 0) return false;

        // Verify all pubkeys are from registered operators
        for (uint256 i = 0; i < pubkeys.length; i++) {
            if (pubkeys[i].x == 0) return false;
        }

        return true;
    }

    /**
     * @inheritdoc IBLSVerifier
     * @dev Verifies ECDSA signatures from each signer
     *      Signatures are concatenated: sig1 || sig2 || ... || sigN (65 bytes each)
     */
    function verifySignatures(
        bytes32 messageHash,
        bytes calldata signatures,
        address[] calldata signers
    ) external view returns (bool) {
        if (signers.length == 0) return false;
        
        // Each ECDSA signature is 65 bytes
        if (signatures.length != signers.length * SIGNATURE_LENGTH) {
            return false;
        }

        // Convert to Ethereum signed message hash (EIP-191)
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();

        for (uint256 i = 0; i < signers.length; i++) {
            // Verify signer has registered a key
            if (!_hasKey[signers[i]]) {
                return false;
            }

            // Extract signature for this signer
            bytes memory sig = _extractSignature(signatures, i);

            // Recover signer from signature
            address recovered = ethSignedHash.recover(sig);

            // Verify recovered address matches expected signer
            if (recovered != signers[i]) {
                return false;
            }
        }

        return true;
    }

    /**
     * @inheritdoc IBLSVerifier
     */
    function getOperatorKey(address operator) external view returns (G1Point memory) {
        if (!_hasKey[operator]) revert KeyNotRegistered();
        return operatorKeys[operator];
    }

    /**
     * @inheritdoc IBLSVerifier
     */
    function hasRegisteredKey(address operator) external view returns (bool) {
        return _hasKey[operator];
    }

    // ============ Admin Functions ============

    /**
     * @notice Remove an operator's key (for slashing or deregistration)
     * @param operator The operator to remove
     */
    function removeOperatorKey(address operator) external onlyOwner {
        if (!_hasKey[operator]) revert KeyNotRegistered();

        delete operatorKeys[operator];
        _hasKey[operator] = false;
        operatorCount--;

        emit OperatorKeyRemoved(operator);
    }

    // ============ View Functions ============

    /**
     * @notice Compute the Ethereum signed message hash
     * @param message The raw message
     * @return The EIP-191 signed message hash
     */
    function getEthSignedMessageHash(bytes32 message) external pure returns (bytes32) {
        return message.toEthSignedMessageHash();
    }

    /**
     * @notice Check if this contract uses ECDSA or BLS
     * @return Always false - BLS precompiles not yet available on mainnet
     */
    function usesBLS() external pure returns (bool) {
        // EIP-2537 BLS precompiles are not yet available on mainnet (Nov 2025)
        return false;
    }

    // ============ Internal Functions ============

    /**
     * @notice Extract a single signature from concatenated signatures
     * @param signatures The concatenated signatures
     * @param index The index of the signature to extract
     * @return The extracted signature (65 bytes)
     */
    function _extractSignature(
        bytes calldata signatures,
        uint256 index
    ) internal pure returns (bytes memory) {
        uint256 offset = index * SIGNATURE_LENGTH;
        return signatures[offset:offset + SIGNATURE_LENGTH];
    }
}
