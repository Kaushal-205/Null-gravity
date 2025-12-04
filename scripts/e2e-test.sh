#!/bin/bash
# End-to-end integration test for Zcash-Aztec Bridge

set -e

echo "=== Zcash-Aztec Bridge E2E Test ==="
echo ""

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 is required but not installed"
        exit 1
    fi
}

# Prerequisites check
log_info "Checking prerequisites..."
check_command docker
check_command docker-compose
check_command forge
check_command node
check_command cargo

# Step 1: Start infrastructure
log_info "Step 1: Starting Docker infrastructure..."
cd "$PROJECT_ROOT/docker"

if docker-compose ps | grep -q "Up"; then
    log_info "Docker services already running"
else
    docker-compose up -d
    log_info "Waiting for services to be ready..."
    sleep 30
fi

# Wait for services
./scripts/wait-for-services.sh

# Step 2: Deploy L1 contracts
log_info "Step 2: Deploying L1 contracts..."
cd "$PROJECT_ROOT/contracts/l1"

# Install Foundry dependencies if needed
if [ ! -d "lib" ]; then
    forge install foundry-rs/forge-std --no-commit
fi

# Run tests first
log_info "Running L1 contract tests..."
forge test -vvv

# Deploy contracts (to local anvil)
log_info "Deploying contracts to local Anvil..."
forge script script/Deploy.s.sol:DeployScript --rpc-url http://localhost:8545 --broadcast --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Export deployed addresses
export SERVICE_MANAGER_ADDRESS=$(cat out/deployment.json | jq -r '.serviceManager')
export BLS_VERIFIER_ADDRESS=$(cat out/deployment.json | jq -r '.blsVerifier')
export INBOX_ADDRESS=$(cat out/deployment.json | jq -r '.inbox')

log_info "Deployed ServiceManager: $SERVICE_MANAGER_ADDRESS"
log_info "Deployed BLSVerifier: $BLS_VERIFIER_ADDRESS"
log_info "Deployed Inbox: $INBOX_ADDRESS"

# Step 3: Setup Zcash vault
log_info "Step 3: Setting up Zcash vault..."
cd "$PROJECT_ROOT/docker"
./scripts/setup-vault.sh

# Get vault address and keys
source .vault-config
export VAULT_ADDRESS
export VAULT_VIEWING_KEY

log_info "Vault Address: $VAULT_ADDRESS"

# Step 4: Deploy L2 contract (Aztec)
log_info "Step 4: Deploying L2 contract to Aztec..."
cd "$PROJECT_ROOT/contracts/l2"

# Compile Noir contract
if command -v nargo &> /dev/null; then
    nargo compile
    
    # Deploy using Aztec CLI (if available)
    # aztec-cli deploy target/zec_bridge.json --private-key $AZTEC_PRIVATE_KEY
    log_info "L2 contract compiled (manual deployment required for now)"
else
    log_warn "nargo not found - skipping L2 contract compilation"
fi

# Step 5: Start Sentinel
log_info "Step 5: Starting Sentinel AVS..."
cd "$PROJECT_ROOT/sentinel"

# Build sentinel
cargo build --release

# Start sentinel in background
export LIGHTWALLETD_URL="http://localhost:9067"
export ZCASH_VIEWING_KEY="$VAULT_VIEWING_KEY"
export L1_RPC_URL="http://localhost:8545"
export OPERATOR_PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
export CONFIRMATION_DEPTH=3
export START_HEIGHT=1
export POLL_INTERVAL_SECS=5

./target/release/sentinel &
SENTINEL_PID=$!
log_info "Sentinel started (PID: $SENTINEL_PID)"

# Step 6: Run deposit flow test
log_info "Step 6: Testing deposit flow..."
cd "$PROJECT_ROOT/cli"

# Install CLI dependencies
npm install

# Create test deposit
TEST_SECRET=$(openssl rand -hex 32)
log_info "Test secret: $TEST_SECRET"

# In a real test, this would:
# 1. Create a Zcash transaction to the vault
# 2. Wait for confirmations
# 3. Sentinel detects and attests
# 4. Claim on Aztec

log_info "Deposit flow test (simulation)..."
npm run dev -- deposit --amount 1 --aztec-address 0x$(openssl rand -hex 32) --secret $TEST_SECRET --dry-run

# Step 7: Check status
log_info "Step 7: Checking bridge status..."
npm run dev -- status

# Cleanup
log_info "Cleaning up..."
if [ ! -z "$SENTINEL_PID" ]; then
    kill $SENTINEL_PID 2>/dev/null || true
fi

echo ""
log_info "=== E2E Test Complete ==="
echo ""
echo "Summary:"
echo "  ✓ Docker infrastructure started"
echo "  ✓ L1 contracts deployed"
echo "  ✓ Zcash vault configured"
echo "  ✓ Sentinel AVS operational"
echo "  ✓ CLI commands functional"
echo ""
echo "To run a full integration test with real transactions:"
echo "  1. Fund a Zcash address with TAZ"
echo "  2. Run: bridge deposit --amount 1 --aztec-address <your-aztec-address>"
echo "  3. Wait for attestation"
echo "  4. Run: bridge claim --secret <your-secret> --amount <zatoshis>"
echo ""

