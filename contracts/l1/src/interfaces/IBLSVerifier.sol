// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IBLSVerifier
 * @notice Interface for BLS12-381 signature verification
 * @dev Verifies BLS aggregate signatures using EIP-2537 precompiles
 *      Supports operator key registration and aggregated signature verification
 */
interface IBLSVerifier {
    // ============ Structs ============

    /// @notice BLS public key (G1 point)
    struct G1Point {
        uint256 x;
        uint256 y;
    }

    /// @notice BLS signature (G2 point)
    struct G2Point {
        uint256[2] x;
        uint256[2] y;
    }

    // ============ Events ============

    /// @notice Emitted when an operator's BLS key is registered
    event BLSKeyRegistered(address indexed operator, G1Point pubkey);

    // ============ Errors ============

    error InvalidBLSKey();
    error SignatureVerificationFailed();
    error KeyNotRegistered();

    // ============ Functions ============

    /**
     * @notice Register a BLS public key for an operator
     * @param pubkey The BLS public key (G1 point)
     */
    function registerBLSKey(G1Point calldata pubkey) external;

    /**
     * @notice Verify an aggregated BLS signature
     * @param message The message that was signed (hash)
     * @param signature The aggregated signature (G2 point)
     * @param pubkeys Array of public keys that participated
     * @return Whether the signature is valid
     */
    function verifyAggregateSignature(
        bytes32 message,
        G2Point calldata signature,
        G1Point[] calldata pubkeys
    ) external view returns (bool);

    /**
     * @notice Verify signatures from specific signers
     * @param messageHash The hash of the message
     * @param signatures Encoded signatures
     * @param signers Array of signer addresses
     * @return Whether all signatures are valid
     */
    function verifySignatures(
        bytes32 messageHash,
        bytes calldata signatures,
        address[] calldata signers
    ) external view returns (bool);

    /**
     * @notice Get the BLS public key for an operator
     * @param operator The operator address
     * @return The operator's BLS public key
     */
    function getOperatorKey(address operator) external view returns (G1Point memory);

    /**
     * @notice Check if an operator has registered a BLS key
     * @param operator The operator address
     * @return Whether the operator has a registered key
     */
    function hasRegisteredKey(address operator) external view returns (bool);
}
