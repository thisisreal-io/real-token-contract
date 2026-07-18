// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.0;

/**
 * @title SafeTimelockGuard
 * @notice Transaction Guard that enforces a 30-minute cooldown period for Safe transactions
 * @dev This guard intercepts Safe transactions and enforces a mandatory delay after
 *      signers approve, providing a security buffer before execution.
 * 
 * @author Real Estate Alliance League
 * @custom:website https://ThisIsREAL.io
 */

contract SafeTimelockGuard {
    
    // Safe wallet address
    address public immutable safe;
    
    // Cooldown period in seconds (30 minutes = 1800 seconds)
    uint256 public constant COOLDOWN_PERIOD = 1800; // 30 minutes
    
    // Expiration period in seconds (7 days = 604800 seconds)
    uint256 public constant EXPIRATION_PERIOD = 604800; // 7 days
    
    // Mapping to track when transactions were approved (by transaction hash)
    mapping(bytes32 => uint256) public transactionApprovedAt;
    
    // Mapping to track if transaction has been executed
    mapping(bytes32 => bool) public transactionExecuted;
    
    // Events
    event TransactionApproved(
        bytes32 indexed txHash,
        address to,
        uint256 value,
        bytes data,
        uint8 operation
    );
    
    event TransactionExecuted(bytes32 indexed txHash);
    
    /**
     * @param _safe Address of the Safe wallet this guard protects
     */
    constructor(address _safe) {
        require(_safe != address(0), "Safe cannot be zero address");
        safe = _safe;
    }
    
    /**
     * @notice Called by Safe before executing a transaction
     * @dev This function checks if the transaction has been approved and if
     *      the cooldown period has passed. If not approved, it records the
     *      approval time. If approved but cooldown not passed, it reverts.
     * 
     * @param to Destination address of the transaction
     * @param value Amount of ETH to send (in wei)
     * @param data Transaction data (encoded function call)
     * @param operation Operation type (0 = Call, 1 = DelegateCall)
     * @param safeTxGas Gas to use for Safe transaction execution
     * @param baseGas Gas costs for data used to trigger the safe transaction
     * @param gasPrice Gas price
     * @param gasToken Token address (if any) to refund gas
     * @param refundReceiver Address of receiver of gas payment (or 0 if tx.origin)
     * @param signatures Packed signature data
     * @param msgSender Address that triggered the transaction
     */
    function checkTransaction(
        address to,
        uint256 value,
        bytes memory data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures,
        address msgSender
    ) external {
        // Only allow calls from the Safe wallet
        require(msg.sender == safe, "Only Safe can call this guard");
        
        // Calculate transaction hash (matches Safe's internal hash calculation)
        bytes32 txHash = keccak256(
            abi.encodePacked(
                to,
                value,
                data,
                operation,
                safeTxGas,
                baseGas,
                gasPrice,
                gasToken,
                refundReceiver,
                safe
            )
        );
        
        // If transaction hasn't been approved yet, record approval time
        if (transactionApprovedAt[txHash] == 0) {
            transactionApprovedAt[txHash] = block.timestamp;
            emit TransactionApproved(txHash, to, value, data, operation);
            // Revert to prevent immediate execution - transaction needs cooldown
            revert("Transaction approved. Wait for cooldown period before execution.");
        }
        
        // Check if transaction has already been executed
        require(!transactionExecuted[txHash], "Transaction already executed");
        
        // Check if cooldown period has passed
        uint256 approvalTime = transactionApprovedAt[txHash];
        require(
            block.timestamp >= approvalTime + COOLDOWN_PERIOD,
            "Transaction still in cooldown period"
        );
        
        // Check if transaction has expired
        if (EXPIRATION_PERIOD > 0) {
            require(
                block.timestamp <= approvalTime + COOLDOWN_PERIOD + EXPIRATION_PERIOD,
                "Transaction has expired"
            );
        }
    }
    
    /**
     * @notice Called by Safe after executing a transaction
     * @dev This function marks the transaction as executed to prevent double execution
     * 
     * @param txHash Transaction hash
     * @param success Whether the transaction executed successfully
     */
    function checkAfterExecution(bytes32 txHash, bool success) external {
        // Only allow calls from Safe
        require(msg.sender == safe, "Only Safe can call this guard");
        
        if (success) {
            transactionExecuted[txHash] = true;
            emit TransactionExecuted(txHash);
        }
    }
    
    /**
     * @notice Check if a transaction can be executed
     * @param txHash Transaction hash to check
     * @return canExecute True if transaction can be executed
     * @return reason Reason why transaction cannot be executed (if applicable)
     */
    function canExecute(bytes32 txHash) external view returns (bool canExecute, string memory reason) {
        if (transactionApprovedAt[txHash] == 0) {
            return (false, "Transaction not approved yet");
        }
        
        if (transactionExecuted[txHash]) {
            return (false, "Transaction already executed");
        }
        
        uint256 approvalTime = transactionApprovedAt[txHash];
        
        if (block.timestamp < approvalTime + COOLDOWN_PERIOD) {
            return (false, "Cooldown period not passed");
        }
        
        if (EXPIRATION_PERIOD > 0) {
            if (block.timestamp > approvalTime + COOLDOWN_PERIOD + EXPIRATION_PERIOD) {
                return (false, "Transaction has expired");
            }
        }
        
        return (true, "");
    }
    
    /**
     * @notice Get remaining cooldown time for a transaction
     * @param txHash Transaction hash
     * @return remainingTime Remaining cooldown time in seconds (0 if cooldown passed, max uint256 if not approved)
     */
    function getRemainingCooldown(bytes32 txHash) external view returns (uint256 remainingTime) {
        if (transactionApprovedAt[txHash] == 0) {
            return type(uint256).max; // Not approved yet
        }
        
        uint256 approvalTime = transactionApprovedAt[txHash];
        uint256 cooldownEnd = approvalTime + COOLDOWN_PERIOD;
        
        if (block.timestamp >= cooldownEnd) {
            return 0; // Cooldown passed
        }
        
        return cooldownEnd - block.timestamp;
    }
    
    /**
     * @notice Get transaction approval timestamp
     * @param txHash Transaction hash
     * @return approvalTime Timestamp when transaction was approved (0 if not approved)
     */
    function getApprovalTime(bytes32 txHash) external view returns (uint256 approvalTime) {
        return transactionApprovedAt[txHash];
    }
    
    /**
     * @notice Check if transaction has expired
     * @param txHash Transaction hash
     * @return expired True if transaction has expired
     */
    function isExpired(bytes32 txHash) external view returns (bool expired) {
        if (transactionApprovedAt[txHash] == 0) {
            return false; // Not approved yet
        }
        
        if (EXPIRATION_PERIOD == 0) {
            return false; // No expiration
        }
        
        uint256 approvalTime = transactionApprovedAt[txHash];
        return block.timestamp > approvalTime + COOLDOWN_PERIOD + EXPIRATION_PERIOD;
    }
}


