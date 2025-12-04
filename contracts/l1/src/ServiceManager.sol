// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IServiceManager} from "./interfaces/IServiceManager.sol";
import {IBLSVerifier} from "./interfaces/IBLSVerifier.sol";
import {IInbox} from "./interfaces/IInbox.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ServiceManager
 * @notice Production AVS contract for the Zcash-Aztec Bridge
 * @dev Manages operator registration, BLS signature verification, and L1→L2 message dispatch
 * 
 * Security Features:
 * - Two-step ownership transfer
 * - Reentrancy protection
 * - Pausable for emergencies
 * - Configurable quorum and stake requirements
 * - Slashing with fraud proofs
 * - Unbonding period for withdrawals
 */
contract ServiceManager is IServiceManager, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Domain separator for EIP-712 signatures
    bytes32 public constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    /// @notice Deposit payload type hash for EIP-712
    bytes32 public constant DEPOSIT_PAYLOAD_TYPEHASH = keccak256(
        "DepositPayload(bytes32 txHash,uint256 amount,bytes32 secretHash,bytes32 aztecAddress,uint64 nonce,uint32 blockHeight)"
    );

    /// @notice Maximum number of operators
    uint256 public constant MAX_OPERATORS = 100;

    /// @notice Unbonding period in blocks (~7 days at 12s blocks)
    uint256 public constant UNBONDING_PERIOD = 50400;

    /// @notice Maximum slash percentage (50%)
    uint256 public constant MAX_SLASH_PERCENTAGE = 5000;

    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10000;

    // ============ Immutable State ============

    /// @notice BLS signature verifier contract
    IBLSVerifier public immutable blsVerifier;

    /// @notice Aztec inbox contract for L1→L2 messaging
    IInbox public immutable inbox;

    /// @notice Staking token (address(0) for native ETH)
    IERC20 public immutable stakingToken;

    /// @notice EIP-712 domain separator
    bytes32 public immutable DOMAIN_SEPARATOR;

    // ============ Configurable State ============

    /// @notice L2 bridge contract address on Aztec
    bytes32 public l2BridgeAddress;

    /// @notice Minimum stake required to become an operator
    uint256 public minimumStakeAmount;

    /// @notice Quorum threshold - percentage of operators required (in basis points)
    uint256 public quorumThresholdBps;

    /// @notice Slash percentage for misbehavior (in basis points)
    uint256 public slashPercentageBps;

    /// @notice Fee for L1→L2 messages
    uint256 public messageFee;

    /// @notice Message deadline in blocks
    uint256 public messageDeadlineBlocks;

    // ============ Operator State ============

    /// @notice Mapping of operator address to operator info
    mapping(address => Operator) private _operators;

    /// @notice Array of all operator addresses (for enumeration)
    address[] private _operatorList;

    /// @notice Mapping of nonce to whether it has been used
    mapping(uint64 => bool) private _usedNonces;

    /// @notice Mapping of operator to pending withdrawal info
    mapping(address => PendingWithdrawal) private _pendingWithdrawals;

    /// @notice Total number of active operators
    uint256 private _activeOperatorCount;

    /// @notice Total staked amount
    uint256 public totalStaked;

    // ============ Structs ============

    /// @notice Pending withdrawal info
    struct PendingWithdrawal {
        uint256 amount;
        uint256 unlockBlock;
    }

    // ============ Events ============

    /// @notice Emitted when configuration is updated
    event ConfigUpdated(string param, uint256 oldValue, uint256 newValue);

    /// @notice Emitted when L2 bridge address is updated
    event L2BridgeAddressUpdated(bytes32 oldAddress, bytes32 newAddress);

    /// @notice Emitted when withdrawal is initiated
    event WithdrawalInitiated(address indexed operator, uint256 amount, uint256 unlockBlock);

    /// @notice Emitted when withdrawal is completed
    event WithdrawalCompleted(address indexed operator, uint256 amount);

    // ============ Errors ============

    error MaxOperatorsReached();
    error InvalidConfiguration();
    error WithdrawalPending();
    error WithdrawalNotReady();
    error NoWithdrawalPending();
    error InvalidSlashProof();
    error ZeroAddress();
    error ZeroAmount();

    // ============ Constructor ============

    /**
     * @notice Initialize the ServiceManager
     * @param _blsVerifier Address of the BLS verifier contract
     * @param _inbox Address of the Aztec inbox contract
     * @param _l2BridgeAddress Address of the ZecBridge contract on Aztec
     * @param _stakingToken Address of staking token (address(0) for native ETH)
     * @param _minimumStake Minimum stake required
     * @param _quorumThresholdBps Quorum threshold in basis points
     */
    constructor(
        address _blsVerifier,
        address _inbox,
        bytes32 _l2BridgeAddress,
        address _stakingToken,
        uint256 _minimumStake,
        uint256 _quorumThresholdBps
    ) Ownable(msg.sender) {
        if (_blsVerifier == address(0)) revert ZeroAddress();
        if (_inbox == address(0)) revert ZeroAddress();
        if (_l2BridgeAddress == bytes32(0)) revert InvalidConfiguration();
        if (_quorumThresholdBps == 0 || _quorumThresholdBps > BASIS_POINTS) revert InvalidConfiguration();

        blsVerifier = IBLSVerifier(_blsVerifier);
        inbox = IInbox(_inbox);
        l2BridgeAddress = _l2BridgeAddress;
        stakingToken = IERC20(_stakingToken);
        minimumStakeAmount = _minimumStake;
        quorumThresholdBps = _quorumThresholdBps;
        slashPercentageBps = 2000; // 20% default
        messageFee = 0.001 ether;
        messageDeadlineBlocks = 1000;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256("NullGravityBridge"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    // ============ External Functions ============

    /**
     * @inheritdoc IServiceManager
     * @dev Operators must first register a BLS key with the verifier
     */
    function registerOperator(uint256 stake) external payable nonReentrant whenNotPaused {
        if (_operators[msg.sender].isActive) revert OperatorAlreadyRegistered();
        if (stake < minimumStakeAmount) revert InsufficientStake();
        if (_activeOperatorCount >= MAX_OPERATORS) revert MaxOperatorsReached();
        if (!blsVerifier.hasRegisteredKey(msg.sender)) revert InvalidSignature();

        // Transfer stake
        if (address(stakingToken) == address(0)) {
            // Native ETH staking
            if (msg.value != stake) revert InsufficientStake();
        } else {
            // ERC20 staking
            stakingToken.safeTransferFrom(msg.sender, address(this), stake);
        }

        _operators[msg.sender] = Operator({
            addr: msg.sender,
            stake: stake,
            isActive: true,
            registeredAt: block.timestamp
        });

        _operatorList.push(msg.sender);
        _activeOperatorCount++;
        totalStaked += stake;

        emit OperatorRegistered(msg.sender, stake);
    }

    /**
     * @inheritdoc IServiceManager
     * @dev Initiates unbonding period - stake cannot be withdrawn immediately
     */
    function deregisterOperator() external nonReentrant {
        Operator storage op = _operators[msg.sender];
        if (!op.isActive) revert OperatorNotRegistered();
        if (_pendingWithdrawals[msg.sender].amount > 0) revert WithdrawalPending();

        op.isActive = false;
        _activeOperatorCount--;

        // Initiate unbonding
        _pendingWithdrawals[msg.sender] = PendingWithdrawal({
            amount: op.stake,
            unlockBlock: block.number + UNBONDING_PERIOD
        });

        totalStaked -= op.stake;
        op.stake = 0;

        emit OperatorDeregistered(msg.sender);
        emit WithdrawalInitiated(msg.sender, _pendingWithdrawals[msg.sender].amount, _pendingWithdrawals[msg.sender].unlockBlock);
    }

    /**
     * @notice Complete withdrawal after unbonding period
     */
    function completeWithdrawal() external nonReentrant {
        PendingWithdrawal storage withdrawal = _pendingWithdrawals[msg.sender];
        if (withdrawal.amount == 0) revert NoWithdrawalPending();
        if (block.number < withdrawal.unlockBlock) revert WithdrawalNotReady();

        uint256 amount = withdrawal.amount;
        delete _pendingWithdrawals[msg.sender];

        // Transfer stake back
        if (address(stakingToken) == address(0)) {
            (bool success, ) = payable(msg.sender).call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            stakingToken.safeTransfer(msg.sender, amount);
        }

        emit WithdrawalCompleted(msg.sender, amount);
    }

    /**
     * @inheritdoc IServiceManager
     */
    function verifyAndDispatch(
        DepositPayload calldata payload,
        bytes calldata aggregatedSig,
        address[] calldata signers
    ) external payable nonReentrant whenNotPaused returns (bytes32 messageHash) {
        // Validate payload
        if (payload.amount == 0) revert InvalidPayload();
        if (payload.secretHash == bytes32(0)) revert InvalidPayload();
        if (payload.aztecAddress == bytes32(0)) revert InvalidPayload();
        if (msg.value < messageFee) revert InsufficientStake();

        // Check nonce hasn't been used
        if (_usedNonces[payload.nonce]) revert NonceAlreadyUsed();

        // Calculate required signatures based on quorum
        uint256 requiredSigners = (_activeOperatorCount * quorumThresholdBps + BASIS_POINTS - 1) / BASIS_POINTS;
        if (requiredSigners == 0) requiredSigners = 1;
        if (signers.length < requiredSigners) revert InsufficientSignatures();

        // Verify all signers are registered operators
        for (uint256 i = 0; i < signers.length; i++) {
            if (!_operators[signers[i]].isActive) revert OperatorNotRegistered();
            // Check for duplicates
            for (uint256 j = i + 1; j < signers.length; j++) {
                if (signers[i] == signers[j]) revert InvalidSignature();
            }
        }

        // Compute EIP-712 typed data hash
        bytes32 payloadHash = _computePayloadHash(payload);

        // Verify BLS aggregate signature
        bool valid = blsVerifier.verifySignatures(payloadHash, aggregatedSig, signers);
        if (!valid) revert InvalidSignature();

        // Mark nonce as used
        _usedNonces[payload.nonce] = true;

        // Compute content hash for L2 message
        bytes32 contentHash = keccak256(
            abi.encode(
                payload.amount,
                payload.secretHash,
                payload.aztecAddress,
                payload.txHash
            )
        );

        // Dispatch message to Aztec L2
        messageHash = inbox.sendL1ToL2Message{value: messageFee}(
            l2BridgeAddress,
            contentHash,
            payload.secretHash,
            block.number + messageDeadlineBlocks
        );

        emit DepositVerified(
            payload.txHash,
            payload.amount,
            payload.secretHash,
            payload.aztecAddress,
            messageHash
        );

        // Refund excess ETH
        if (msg.value > messageFee) {
            (bool success, ) = payable(msg.sender).call{value: msg.value - messageFee}("");
            require(success, "Refund failed");
        }

        return messageHash;
    }

    /**
     * @inheritdoc IServiceManager
     * @dev Slashes operator stake based on fraud proof
     */
    function slashOperator(address operator, bytes calldata proof) external onlyOwner nonReentrant {
        Operator storage op = _operators[operator];
        if (!op.isActive && op.stake == 0) revert OperatorNotRegistered();

        // Verify fraud proof (simplified - in production use ZK proof or dispute game)
        if (!_verifyFraudProof(operator, proof)) revert InvalidSlashProof();

        uint256 slashAmount = (op.stake * slashPercentageBps) / BASIS_POINTS;
        if (slashAmount > op.stake) slashAmount = op.stake;

        op.stake -= slashAmount;
        totalStaked -= slashAmount;

        // Deactivate if below minimum
        if (op.stake < minimumStakeAmount && op.isActive) {
            op.isActive = false;
            _activeOperatorCount--;
        }

        // Transfer slashed amount to treasury (owner)
        if (address(stakingToken) == address(0)) {
            (bool success, ) = payable(owner()).call{value: slashAmount}("");
            require(success, "Slash transfer failed");
        } else {
            stakingToken.safeTransfer(owner(), slashAmount);
        }

        emit OperatorSlashed(operator, slashAmount, proof);
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IServiceManager
     */
    function getOperator(address operator) external view returns (Operator memory) {
        return _operators[operator];
    }

    /**
     * @inheritdoc IServiceManager
     */
    function isNonceUsed(uint64 nonce) external view returns (bool) {
        return _usedNonces[nonce];
    }

    /**
     * @inheritdoc IServiceManager
     */
    function minimumStake() external view returns (uint256) {
        return minimumStakeAmount;
    }

    /**
     * @inheritdoc IServiceManager
     */
    function quorumThreshold() external view returns (uint256) {
        return (_activeOperatorCount * quorumThresholdBps + BASIS_POINTS - 1) / BASIS_POINTS;
    }

    /**
     * @inheritdoc IServiceManager
     */
    function activeOperatorCount() external view returns (uint256) {
        return _activeOperatorCount;
    }

    /**
     * @notice Get all operator addresses
     * @return Array of operator addresses
     */
    function getOperators() external view returns (address[] memory) {
        return _operatorList;
    }

    /**
     * @notice Get pending withdrawal info
     * @param operator The operator address
     * @return amount The pending withdrawal amount
     * @return unlockBlock The block when withdrawal can be completed
     */
    function getPendingWithdrawal(address operator) external view returns (uint256 amount, uint256 unlockBlock) {
        PendingWithdrawal storage w = _pendingWithdrawals[operator];
        return (w.amount, w.unlockBlock);
    }

    // ============ Admin Functions ============

    /**
     * @notice Update minimum stake requirement
     * @param newMinimumStake New minimum stake amount
     */
    function setMinimumStake(uint256 newMinimumStake) external onlyOwner {
        emit ConfigUpdated("minimumStake", minimumStakeAmount, newMinimumStake);
        minimumStakeAmount = newMinimumStake;
    }

    /**
     * @notice Update quorum threshold
     * @param newQuorumBps New quorum threshold in basis points
     */
    function setQuorumThreshold(uint256 newQuorumBps) external onlyOwner {
        if (newQuorumBps == 0 || newQuorumBps > BASIS_POINTS) revert InvalidConfiguration();
        emit ConfigUpdated("quorumThreshold", quorumThresholdBps, newQuorumBps);
        quorumThresholdBps = newQuorumBps;
    }

    /**
     * @notice Update slash percentage
     * @param newSlashBps New slash percentage in basis points
     */
    function setSlashPercentage(uint256 newSlashBps) external onlyOwner {
        if (newSlashBps > MAX_SLASH_PERCENTAGE) revert InvalidConfiguration();
        emit ConfigUpdated("slashPercentage", slashPercentageBps, newSlashBps);
        slashPercentageBps = newSlashBps;
    }

    /**
     * @notice Update L2 bridge address
     * @param newL2BridgeAddress New L2 bridge address
     */
    function setL2BridgeAddress(bytes32 newL2BridgeAddress) external onlyOwner {
        if (newL2BridgeAddress == bytes32(0)) revert InvalidConfiguration();
        emit L2BridgeAddressUpdated(l2BridgeAddress, newL2BridgeAddress);
        l2BridgeAddress = newL2BridgeAddress;
    }

    /**
     * @notice Update message fee
     * @param newFee New message fee
     */
    function setMessageFee(uint256 newFee) external onlyOwner {
        emit ConfigUpdated("messageFee", messageFee, newFee);
        messageFee = newFee;
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

    // ============ Internal Functions ============

    /**
     * @notice Compute EIP-712 typed data hash for deposit payload
     * @param payload The deposit payload
     * @return The typed data hash
     */
    function _computePayloadHash(DepositPayload calldata payload) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                DEPOSIT_PAYLOAD_TYPEHASH,
                payload.txHash,
                payload.amount,
                payload.secretHash,
                payload.aztecAddress,
                payload.nonce,
                payload.blockHeight
            )
        );

        return keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );
    }

    /**
     * @notice Verify a fraud proof (simplified)
     * @dev In production, implement proper fraud proof verification
     * @param operator The operator being slashed
     * @param proof The fraud proof data
     * @return Whether the proof is valid
     */
    function _verifyFraudProof(address operator, bytes calldata proof) internal pure returns (bool) {
        // Simplified: proof must be at least 32 bytes and start with operator address
        if (proof.length < 52) return false;
        
        address proofOperator = address(bytes20(proof[0:20]));
        return proofOperator == operator;
    }

    // ============ Receive Function ============

    receive() external payable {}
}
