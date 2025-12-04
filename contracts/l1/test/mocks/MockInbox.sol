// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IInbox} from "../../src/interfaces/IInbox.sol";

/**
 * @title MockInbox
 * @notice Mock implementation of Aztec's L1->L2 inbox for testing
 */
contract MockInbox is IInbox {
    // ============ State Variables ============

    /// @notice Counter for generating unique message hashes
    uint256 private messageCounter;

    /// @notice Mapping of message hash to pending status
    mapping(bytes32 => bool) private pendingMessages;

    /// @notice Mapping of message hash to message data
    mapping(bytes32 => L1ToL2Msg) private messages;

    /// @notice The L2 bridge address
    bytes32 public override l2BridgeAddress;

    /// @notice Minimum fee for messages
    uint256 public constant override minimumFee = 0;

    // ============ Constructor ============

    constructor(bytes32 _l2BridgeAddress) {
        l2BridgeAddress = _l2BridgeAddress;
    }

    // ============ External Functions ============

    /**
     * @inheritdoc IInbox
     */
    function sendL1ToL2Message(
        bytes32 recipient,
        bytes32 content,
        bytes32 secretHash,
        uint256 deadline
    ) external payable returns (bytes32 messageHash) {
        if (recipient == bytes32(0)) revert InvalidRecipient();

        messageCounter++;

        // Generate unique message hash
        messageHash = keccak256(
            abi.encode(msg.sender, recipient, content, secretHash, deadline, messageCounter)
        );

        if (pendingMessages[messageHash]) revert MessageAlreadyExists();

        // Store message
        messages[messageHash] = L1ToL2Msg({
            sender: msg.sender,
            recipient: recipient,
            content: content,
            secretHash: secretHash,
            fee: msg.value,
            deadline: deadline
        });

        pendingMessages[messageHash] = true;

        emit MessageSent(messageHash, msg.sender, recipient, content, msg.value);

        return messageHash;
    }

    /**
     * @inheritdoc IInbox
     */
    function cancelL1ToL2Message(bytes32 messageHash) external {
        if (!pendingMessages[messageHash]) revert MessageNotFound();

        L1ToL2Msg storage message = messages[messageHash];
        if (block.number <= message.deadline) revert MessageNotExpired();
        if (message.sender != msg.sender) revert UnauthorizedCaller();

        pendingMessages[messageHash] = false;

        // Return fee to sender
        if (message.fee > 0) {
            payable(msg.sender).transfer(message.fee);
        }

        emit MessageCancelled(messageHash);
    }

    /**
     * @inheritdoc IInbox
     */
    function isMessagePending(bytes32 messageHash) external view returns (bool) {
        return pendingMessages[messageHash];
    }

    // ============ Test Helper Functions ============

    /**
     * @notice Simulate message consumption on L2 (for testing)
     * @param messageHash The message to consume
     */
    function consumeMessage(bytes32 messageHash) external {
        if (!pendingMessages[messageHash]) revert MessageNotFound();
        pendingMessages[messageHash] = false;
        emit MessageConsumed(messageHash);
    }

    /**
     * @notice Get message data (for testing)
     * @param messageHash The message hash
     * @return The message data
     */
    function getMessage(bytes32 messageHash) external view returns (L1ToL2Msg memory) {
        return messages[messageHash];
    }

    /**
     * @notice Set the L2 bridge address (for testing)
     * @param _l2BridgeAddress The new L2 bridge address
     */
    function setL2BridgeAddress(bytes32 _l2BridgeAddress) external {
        l2BridgeAddress = _l2BridgeAddress;
    }

    // ============ Errors ============

    error UnauthorizedCaller();
}

