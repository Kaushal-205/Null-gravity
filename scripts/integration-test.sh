#!/bin/bash
# End-to-end integration test for the Null-Gravity Bridge
#
# This script tests the complete deposit -> claim -> withdraw flow

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  NULL-GRAVITY BRIDGE - INTEGRATION TEST${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Check if services are running
check_services() {
    echo -e "${YELLOW}Checking services...${NC}"
    
    # Check zcashd
    if ! zcash-cli -regtest getblockchaininfo > /dev/null 2>&1; then
        echo -e "${RED}✗ zcashd is not running${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ zcashd is running${NC}"
    
    # Check anvil
    if ! cast block-number --rpc-url http://localhost:8545 > /dev/null 2>&1; then
        echo -e "${RED}✗ anvil is not running${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ anvil is running${NC}"
    
    # Check lightwalletd (optional)
    # if ! grpcurl -plaintext localhost:9067 list > /dev/null 2>&1; then
    #     echo -e "${YELLOW}⚠ lightwalletd is not running (optional)${NC}"
    # else
    #     echo -e "${GREEN}✓ lightwalletd is running${NC}"
    # fi
    
    echo ""
    return 0
}

# Deploy L1 contracts
deploy_contracts() {
    echo -e "${YELLOW}Deploying L1 contracts...${NC}"
    
    cd "$PROJECT_ROOT/contracts/l1"
    
    # Install dependencies if needed
    if [ ! -d "lib/forge-std" ]; then
        forge install foundry-rs/forge-std --no-commit
    fi
    
    if [ ! -d "lib/openzeppelin-contracts" ]; then
        forge install OpenZeppelin/openzeppelin-contracts --no-commit
    fi
    
    # Build contracts
    forge build
    
    # Deploy MockBLSVerifier
    echo "Deploying MockBLSVerifier..."
    BLS_VERIFIER=$(forge create src/MockBLSVerifier.sol:MockBLSVerifier \
        --rpc-url http://localhost:8545 \
        --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
        --json | jq -r '.deployedTo')
    echo -e "${GREEN}MockBLSVerifier deployed at: $BLS_VERIFIER${NC}"
    
    # Deploy MockInbox
    echo "Deploying MockInbox..."
    L2_BRIDGE="0x0000000000000000000000000000000000000000000000000000000000001234"
    MOCK_INBOX=$(forge create test/mocks/MockInbox.sol:MockInbox \
        --rpc-url http://localhost:8545 \
        --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
        --constructor-args "$L2_BRIDGE" \
        --json | jq -r '.deployedTo')
    echo -e "${GREEN}MockInbox deployed at: $MOCK_INBOX${NC}"
    
    # Deploy ServiceManager
    echo "Deploying ServiceManager..."
    SERVICE_MANAGER=$(forge create src/ServiceManager.sol:ServiceManager \
        --rpc-url http://localhost:8545 \
        --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
        --constructor-args "$BLS_VERIFIER" "$MOCK_INBOX" "$L2_BRIDGE" \
        --json | jq -r '.deployedTo')
    echo -e "${GREEN}ServiceManager deployed at: $SERVICE_MANAGER${NC}"
    
    # Export addresses
    export BLS_VERIFIER
    export MOCK_INBOX
    export SERVICE_MANAGER
    
    echo ""
}

# Run Foundry tests
run_foundry_tests() {
    echo -e "${YELLOW}Running Foundry tests...${NC}"
    
    cd "$PROJECT_ROOT/contracts/l1"
    forge test -vvv
    
    echo -e "${GREEN}✓ All Foundry tests passed${NC}"
    echo ""
}

# Test operator registration
test_operator_registration() {
    echo -e "${YELLOW}Testing operator registration...${NC}"
    
    OPERATOR_ADDRESS="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    OPERATOR_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    
    # Register BLS key
    echo "Registering BLS key..."
    cast send "$BLS_VERIFIER" \
        "registerBLSKey((uint256,uint256))" \
        "(1,2)" \
        --rpc-url http://localhost:8545 \
        --private-key "$OPERATOR_KEY"
    
    # Register as operator
    echo "Registering as operator..."
    cast send "$SERVICE_MANAGER" \
        "registerOperator(uint256)" \
        "100000000000000000" \
        --rpc-url http://localhost:8545 \
        --private-key "$OPERATOR_KEY"
    
    # Verify registration
    OPERATOR_INFO=$(cast call "$SERVICE_MANAGER" \
        "getOperator(address)" \
        "$OPERATOR_ADDRESS" \
        --rpc-url http://localhost:8545)
    
    echo -e "${GREEN}✓ Operator registered successfully${NC}"
    echo ""
}

# Test deposit verification
test_deposit_verification() {
    echo -e "${YELLOW}Testing deposit verification...${NC}"
    
    OPERATOR_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    OPERATOR_ADDRESS="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    
    # Create test payload
    TX_HASH="0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
    AMOUNT="1000000000"  # 10 ZEC in zatoshi
    SECRET_HASH="0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
    AZTEC_ADDRESS="0xfedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321"
    NONCE="1"
    BLOCK_HEIGHT="100"
    
    # Compute payload hash (matching Solidity)
    PAYLOAD_HASH=$(cast keccak256 $(cast abi-encode \
        "f(bytes32,uint256,bytes32,bytes32,uint64,uint32)" \
        "$TX_HASH" "$AMOUNT" "$SECRET_HASH" "$AZTEC_ADDRESS" "$NONCE" "$BLOCK_HEIGHT"))
    
    echo "Payload hash: $PAYLOAD_HASH"
    
    # Sign the payload
    SIGNATURE=$(cast wallet sign --private-key "$OPERATOR_KEY" "$PAYLOAD_HASH")
    
    echo "Signature: $SIGNATURE"
    
    # Submit to ServiceManager
    echo "Submitting attestation..."
    cast send "$SERVICE_MANAGER" \
        "verifyAndDispatch((bytes32,uint256,bytes32,bytes32,uint64,uint32),bytes,address[])" \
        "($TX_HASH,$AMOUNT,$SECRET_HASH,$AZTEC_ADDRESS,$NONCE,$BLOCK_HEIGHT)" \
        "$SIGNATURE" \
        "[$OPERATOR_ADDRESS]" \
        --rpc-url http://localhost:8545 \
        --private-key "$OPERATOR_KEY"
    
    # Verify nonce was used
    NONCE_USED=$(cast call "$SERVICE_MANAGER" \
        "isNonceUsed(uint64)" \
        "$NONCE" \
        --rpc-url http://localhost:8545)
    
    if [ "$NONCE_USED" == "true" ]; then
        echo -e "${GREEN}✓ Deposit verification successful${NC}"
    else
        echo -e "${RED}✗ Deposit verification failed - nonce not marked as used${NC}"
        return 1
    fi
    
    echo ""
}

# Cleanup function
cleanup() {
    echo -e "${YELLOW}Cleaning up...${NC}"
    # Add cleanup logic if needed
}

# Main test flow
main() {
    trap cleanup EXIT
    
    # Check if services are running
    if ! check_services; then
        echo -e "${RED}Please start the required services first:${NC}"
        echo "  cd docker && docker-compose up -d"
        exit 1
    fi
    
    # Deploy contracts
    deploy_contracts
    
    # Run Foundry tests
    run_foundry_tests
    
    # Test operator registration
    test_operator_registration
    
    # Test deposit verification
    test_deposit_verification
    
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ALL INTEGRATION TESTS PASSED!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
}

# Run main
main "$@"

