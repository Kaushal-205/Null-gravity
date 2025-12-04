// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IInbox} from "./interfaces/IInbox.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title Inbox
 * @notice Production L1→L2 message inbox for the Zcash-Aztec Bridge
 * @dev Stores messages that can be consumed by the L2 rollup
 * 
 * Message Flow:
 * 1. L1 contract calls sendL1ToL2Message
 * 2. Message is stored with unique hash
 * 3. L2 sequencer includes message in block
 * 4. L2 contract consumes message by proving inclusion
 * 
 * Security:
 * - Messages have deadlines for expiry
 * - Fees prevent spam
 * - Only authorized contracts can mark messages as consumed
 */
contract Inbox is IInbox, Ownable, ReentrancyGuard, Pausable {
    // ============ Constants ============

    /// @notice Minimum fee for L1→L2 messages (prevents spam)
    uint256 public constant MINIMUM_FEE = 0.001 ether;

    /// @notice Maximum message deadline (blocks)
    uint256 public constant MAX_DEADLINE_BLOCKS = 50400; // ~7 days at 12s blocks

    /// @notice Minimum message deadline (blocks)
    uint256 public constant MIN_DEADLINE_BLOCKS = 100;

    // ============ State Variables ============

    /// @notice The L2 bridge contract address
    bytes32 public override l2BridgeAddress;

    /// @notice Counter for generating unique message IDs
    uint256 private _messageNonce;

    /// @notice Mapping of message hash to message data
    mapping(bytes32 => L1ToL2Msg) private _messages;

    /// @notice Mapping of message hash to pending status
    mapping(bytes32 => bool) private _pendingMessages;

    /// @notice Mapping of message hash to consumed status
    mapping(bytes32 => bool) private _consumedMessages;

    /// @notice Authorized L2 message consumers (rollup contracts)
    mapping(address => bool) public authorizedConsumers;

    /// @notice Total fees collected
    uint256 public collectedFees;

    // ============ Events ============

    /// @notice Emitted when a consumer is authorized/deauthorized
    event ConsumerAuthorized(address indexed consumer, bool authorized);

    /// @notice Emitted when fees are withdrawn
    event FeesWithdrawn(address indexed recipient, uint256 amount);

    /// @notice Emitted when L2 bridge address is updated
    event L2BridgeAddressUpdated(bytes32 indexed oldAddress, bytes32 indexed newAddress);

    // ============ Errors ============

    error DeadlineTooShort();
    error DeadlineTooLong();
    error UnauthorizedConsumer();
    error UnauthorizedCaller();
    error MessageAlreadyConsumed();
    error InvalidL2Address();

    // ============ Constructor ============

    constructor(bytes32 _l2BridgeAddress) Ownable(msg.sender) {
        if (_l2BridgeAddress == bytes32(0)) revert InvalidL2Address();
        l2BridgeAddress = _l2BridgeAddress;
    }

    // ============ External Functions ============

    /**
     * @inheritdoc IInbox
     * @dev Creates a new L1→L2 message with the provided parameters
     */
    function sendL1ToL2Message(
        bytes32 recipient,
        bytes32 content,
        bytes32 secretHash,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused returns (bytes32 messageHash) {
        // Validate inputs
        if (recipient == bytes32(0)) revert InvalidRecipient();
        if (msg.value < MINIMUM_FEE) revert InsufficientFee();
        
        uint256 blocksUntilDeadline = deadline > block.number ? deadline - block.number : 0;
        if (blocksUntilDeadline < MIN_DEADLINE_BLOCKS) revert DeadlineTooShort();
        if (blocksUntilDeadline > MAX_DEADLINE_BLOCKS) revert DeadlineTooLong();

        // Increment nonce
        _messageNonce++;

        // Compute unique message hash
        messageHash = keccak256(
            abi.encode(
                msg.sender,
                recipient,
                content,
                secretHash,
                deadline,
                _messageNonce,
                block.chainid
            )
        );

        // Ensure uniqueness
        if (_pendingMessages[messageHash]) revert MessageAlreadyExists();

        // Store message
        _messages[messageHash] = L1ToL2Msg({
            sender: msg.sender,
            recipient: recipient,
            content: content,
            secretHash: secretHash,
            fee: msg.value,
            deadline: deadline
        });

        _pendingMessages[messageHash] = true;
        collectedFees += msg.value;

        emit MessageSent(messageHash, msg.sender, recipient, content, msg.value);

        return messageHash;
    }

    /**
     * @inheritdoc IInbox
     * @dev Allows message sender to cancel expired messages and reclaim fee
     */
    function cancelL1ToL2Message(bytes32 messageHash) external nonReentrant {
        if (!_pendingMessages[messageHash]) revert MessageNotFound();
        if (_consumedMessages[messageHash]) revert MessageAlreadyConsumed();

        L1ToL2Msg storage message = _messages[messageHash];
        
        // Only sender can cancel
        if (message.sender != msg.sender) revert UnauthorizedCaller();
        
        // Message must be expired
        if (block.number <= message.deadline) revert MessageNotExpired();

        // Mark as no longer pending
        _pendingMessages[messageHash] = false;

        // Refund fee
        uint256 refund = message.fee;
        if (refund > 0) {
            collectedFees -= refund;
            (bool success, ) = payable(msg.sender).call{value: refund}("");
            require(success, "Fee refund failed");
        }

        emit MessageCancelled(messageHash);
    }

    /**
     * @notice Mark a message as consumed (called by L2 rollup bridge)
     * @param messageHash The hash of the consumed message
     */
    function consumeMessage(bytes32 messageHash) external nonReentrant {
        if (!authorizedConsumers[msg.sender]) revert UnauthorizedConsumer();
        if (!_pendingMessages[messageHash]) revert MessageNotFound();
        if (_consumedMessages[messageHash]) revert MessageAlreadyConsumed();

        _pendingMessages[messageHash] = false;
        _consumedMessages[messageHash] = true;

        emit MessageConsumed(messageHash);
    }

    /**
     * @inheritdoc IInbox
     */
    function isMessagePending(bytes32 messageHash) external view returns (bool) {
        return _pendingMessages[messageHash] && !_consumedMessages[messageHash];
    }

    /**
     * @notice Check if a message has been consumed
     * @param messageHash The message hash to check
     * @return Whether the message has been consumed
     */
    function isMessageConsumed(bytes32 messageHash) external view returns (bool) {
        return _consumedMessages[messageHash];
    }

    /**
     * @inheritdoc IInbox
     */
    function minimumFee() external pure returns (uint256) {
        return MINIMUM_FEE;
    }

    /**
     * @notice Get message data
     * @param messageHash The message hash
     * @return The message data
     */
    function getMessage(bytes32 messageHash) external view returns (L1ToL2Msg memory) {
        return _messages[messageHash];
    }

    /**
     * @notice Get current message nonce
     * @return The current nonce
     */
    function messageNonce() external view returns (uint256) {
        return _messageNonce;
    }

    // ============ Admin Functions ============

    /**
     * @notice Authorize or deauthorize a message consumer
     * @param consumer The consumer address
     * @param authorized Whether to authorize
     */
    function setAuthorizedConsumer(address consumer, bool authorized) external onlyOwner {
        authorizedConsumers[consumer] = authorized;
        emit ConsumerAuthorized(consumer, authorized);
    }

    /**
     * @notice Update the L2 bridge address
     * @param newL2BridgeAddress The new L2 bridge address
     */
    function setL2BridgeAddress(bytes32 newL2BridgeAddress) external onlyOwner {
        if (newL2BridgeAddress == bytes32(0)) revert InvalidL2Address();
        bytes32 oldAddress = l2BridgeAddress;
        l2BridgeAddress = newL2BridgeAddress;
        emit L2BridgeAddressUpdated(oldAddress, newL2BridgeAddress);
    }

    /**
     * @notice Withdraw collected fees
     * @param recipient The recipient address
     * @param amount The amount to withdraw
     */
    function withdrawFees(address payable recipient, uint256 amount) external onlyOwner {
        require(amount <= collectedFees, "Insufficient fees");
        collectedFees -= amount;
        
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Fee withdrawal failed");
        
        emit FeesWithdrawn(recipient, amount);
    }

    /**
     * @notice Pause the contract
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Receive Function ============

    receive() external payable {
        collectedFees += msg.value;
    }
}

