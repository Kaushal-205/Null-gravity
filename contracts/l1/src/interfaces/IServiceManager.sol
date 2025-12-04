// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IServiceManager
 * @notice Interface for the Zcash-Aztec Bridge Service Manager
 * @dev Manages operator registration, signature verification, and message dispatch
 */
interface IServiceManager {
    // ============ Structs ============

    /// @notice Deposit payload from Zcash shielded transaction
    struct DepositPayload {
        bytes32 txHash;           // Zcash transaction hash
        uint256 amount;           // Amount in zatoshi (1 ZEC = 10^8 zatoshi)
        bytes32 secretHash;       // Hash of the claim secret
        bytes32 aztecAddress;     // Recipient's Aztec address
        uint64 nonce;             // Unique nonce for replay protection
        uint32 blockHeight;       // Zcash block height
    }

    /// @notice Operator information
    struct Operator {
        address addr;             // Operator address
        uint256 stake;            // Staked amount
        bool isActive;            // Whether operator is active
        uint256 registeredAt;     // Registration timestamp
    }

    // ============ Events ============

    /// @notice Emitted when an operator is registered
    event OperatorRegistered(address indexed operator, uint256 stake);

    /// @notice Emitted when an operator is deregistered
    event OperatorDeregistered(address indexed operator);

    /// @notice Emitted when an operator is slashed
    event OperatorSlashed(address indexed operator, uint256 amount, bytes reason);

    /// @notice Emitted when a deposit is verified and dispatched
    event DepositVerified(
        bytes32 indexed txHash,
        uint256 amount,
        bytes32 secretHash,
        bytes32 aztecAddress,
        bytes32 messageHash
    );

    /// @notice Emitted when a withdrawal is processed
    event WithdrawalProcessed(
        bytes32 indexed messageHash,
        uint256 amount,
        bytes32 zcashAddress
    );

    // ============ Errors ============

    error OperatorAlreadyRegistered();
    error OperatorNotRegistered();
    error InsufficientStake();
    error InvalidSignature();
    error InsufficientSignatures();
    error NonceAlreadyUsed();
    error InvalidPayload();
    error UnauthorizedCaller();

    // ============ Functions ============

    /**
     * @notice Register as an operator with stake
     * @param stake Amount to stake
     */
    function registerOperator(uint256 stake) external payable;

    /**
     * @notice Deregister an operator and return stake
     */
    function deregisterOperator() external;

    /**
     * @notice Verify signatures and dispatch deposit message to Aztec
     * @param payload The deposit payload from Zcash
     * @param aggregatedSig Aggregated BLS signature (or mock ECDSA signatures)
     * @param signers Array of operator addresses who signed
     * @return messageHash The hash of the dispatched L1->L2 message
     */
    function verifyAndDispatch(
        DepositPayload calldata payload,
        bytes calldata aggregatedSig,
        address[] calldata signers
    ) external payable returns (bytes32 messageHash);

    /**
     * @notice Slash an operator for misbehavior
     * @param operator Address of the operator to slash
     * @param proof Proof of misbehavior
     */
    function slashOperator(address operator, bytes calldata proof) external;

    /**
     * @notice Get operator information
     * @param operator Address of the operator
     * @return Operator struct
     */
    function getOperator(address operator) external view returns (Operator memory);

    /**
     * @notice Check if a nonce has been used
     * @param nonce The nonce to check
     * @return Whether the nonce has been used
     */
    function isNonceUsed(uint64 nonce) external view returns (bool);

    /**
     * @notice Get the minimum stake required for operators
     * @return Minimum stake amount
     */
    function minimumStake() external view returns (uint256);

    /**
     * @notice Get the quorum threshold for signature verification
     * @return Number of signatures required
     */
    function quorumThreshold() external view returns (uint256);

    /**
     * @notice Get total number of active operators
     * @return Count of active operators
     */
    function activeOperatorCount() external view returns (uint256);
}
