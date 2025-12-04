// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IInbox
 * @notice Interface for Aztec L1->L2 message inbox
 * @dev This interface is used to send messages from L1 (Ethereum) to L2 (Aztec)
 */
interface IInbox {
    // ============ Structs ============

    /// @notice L1 to L2 message structure
    struct L1ToL2Msg {
        address sender;           // L1 sender address
        bytes32 recipient;        // L2 recipient (contract address on Aztec)
        bytes32 content;          // Message content hash
        bytes32 secretHash;       // Hash for private claiming
        uint256 fee;              // Fee for L2 processing
        uint256 deadline;         // Message expiry deadline
    }

    // ============ Events ============

    /// @notice Emitted when a message is sent to L2
    event MessageSent(
        bytes32 indexed messageHash,
        address indexed sender,
        bytes32 indexed recipient,
        bytes32 content,
        uint256 fee
    );

    /// @notice Emitted when a message is consumed on L2
    event MessageConsumed(bytes32 indexed messageHash);

    /// @notice Emitted when a message expires and is cancelled
    event MessageCancelled(bytes32 indexed messageHash);

    // ============ Errors ============

    error InsufficientFee();
    error MessageAlreadyExists();
    error MessageNotFound();
    error MessageNotExpired();
    error InvalidRecipient();

    // ============ Functions ============

    /**
     * @notice Send a message from L1 to L2
     * @param recipient The L2 contract address to receive the message
     * @param content The message content (typically a hash of the full payload)
     * @param secretHash Hash of the secret for private claiming
     * @param deadline Block number after which the message can be cancelled
     * @return messageHash The unique identifier for this message
     */
    function sendL1ToL2Message(
        bytes32 recipient,
        bytes32 content,
        bytes32 secretHash,
        uint256 deadline
    ) external payable returns (bytes32 messageHash);

    /**
     * @notice Cancel an expired message and reclaim the fee
     * @param messageHash The hash of the message to cancel
     */
    function cancelL1ToL2Message(bytes32 messageHash) external;

    /**
     * @notice Check if a message exists and is pending
     * @param messageHash The hash of the message
     * @return Whether the message exists and hasn't been consumed
     */
    function isMessagePending(bytes32 messageHash) external view returns (bool);

    /**
     * @notice Get the minimum fee required for L1->L2 messages
     * @return The minimum fee in wei
     */
    function minimumFee() external view returns (uint256);

    /**
     * @notice Get the L2 contract address for the bridge
     * @return The Aztec contract address
     */
    function l2BridgeAddress() external view returns (bytes32);
}
