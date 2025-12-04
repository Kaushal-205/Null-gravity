#!/bin/bash
# Setup script for generating vault address and exporting keys
# 
# This script works with zebrad (the modern Zcash node) and can also
# use zallet for wallet operations.
#
# For testnet/mainnet, you can use public RPC endpoints instead of
# running a local node.

set -e

echo "=== Null-Gravity Bridge - Vault Setup ==="
echo ""

# Configuration
NETWORK="${ZCASH_NETWORK:-regtest}"
RPC_URL="${ZCASH_RPC_URL:-http://localhost:18232}"
OUTPUT_FILE="${OUTPUT_FILE:-./vault-config.json}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check if we're using local node or public endpoint
if [[ "$RPC_URL" == *"localhost"* ]] || [[ "$RPC_URL" == *"127.0.0.1"* ]]; then
    echo -e "${YELLOW}Using local node at $RPC_URL${NC}"
    LOCAL_NODE=true
else
    echo -e "${YELLOW}Using public RPC endpoint: $RPC_URL${NC}"
    LOCAL_NODE=false
fi

echo "Network: $NETWORK"
echo ""

# Function to make RPC call
rpc_call() {
    local method=$1
    local params=${2:-"[]"}
    
    curl -s --user "zcashrpc:zcashrpcpassword" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":\"setup\",\"method\":\"$method\",\"params\":$params}" \
        -H "Content-Type: application/json" \
        "$RPC_URL" | jq -r '.result'
}

# Wait for node to be ready (only for local node)
if [ "$LOCAL_NODE" = true ]; then
    echo "Waiting for zebrad to be ready..."
    until curl -s "$RPC_URL" > /dev/null 2>&1; do
        sleep 2
    done
    echo -e "${GREEN}zebrad is ready!${NC}"
    echo ""
fi

# Check blockchain info
echo "Checking blockchain status..."
BLOCK_COUNT=$(rpc_call "getblockcount")
echo "Current block height: $BLOCK_COUNT"
echo ""

# For local regtest, generate some blocks if needed
if [ "$LOCAL_NODE" = true ] && [ "$NETWORK" = "regtest" ]; then
    if [ "$BLOCK_COUNT" -lt "100" ]; then
        echo "Generating initial blocks for regtest..."
        # Note: zebrad uses different RPC methods than zcashd
        # For block generation, you may need to use mining software
        echo -e "${YELLOW}Note: Block generation requires mining setup with zebrad${NC}"
    fi
fi

echo ""
echo "=== Generating Vault Address ==="
echo ""
echo -e "${YELLOW}For production use, generate keys using a secure offline method:${NC}"
echo ""
echo "Option 1: Use zallet (recommended)"
echo "  zallet generate-address --type sapling"
echo ""
echo "Option 2: Use zcash-cli with zcashd (legacy)"
echo "  zcash-cli z_getnewaddress sapling"
echo ""
echo "Option 3: Use a hardware wallet"
echo "  Ledger or Trezor with Zcash support"
echo ""

# For demo purposes, generate a placeholder
echo -e "${RED}⚠️  WARNING: The following is for DEMO PURPOSES ONLY${NC}"
echo -e "${RED}   Do NOT use these keys for real funds!${NC}"
echo ""

# Generate demo keys (in production, use proper key generation)
DEMO_ADDRESS="ztestsapling1demo000000000000000000000000000000000000000000000000000000"
DEMO_VIEWING_KEY="zivktestsapling1demo0000000000000000000000000000000000000000000000"
DEMO_SPENDING_KEY="secret-spending-key-keep-secure"

# Save configuration
cat > "$OUTPUT_FILE" << EOF
{
    "vault_address": "$DEMO_ADDRESS",
    "viewing_key": "$DEMO_VIEWING_KEY",
    "network": "$NETWORK",
    "rpc_url": "$RPC_URL",
    "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "note": "DEMO ONLY - Replace with real keys before deployment"
}
EOF

echo -e "${GREEN}Configuration saved to: $OUTPUT_FILE${NC}"
echo ""
echo "=== Next Steps ==="
echo ""
echo "1. Generate real keys using zallet or hardware wallet"
echo "2. Update vault-config.json with real keys"
echo "3. Fund the vault address with ZEC"
echo "4. Export viewing key for sentinel configuration"
echo ""
echo "For sentinel configuration, set these environment variables:"
echo "  export VAULT_ADDRESS=<your-vault-address>"
echo "  export VAULT_VIEWING_KEY=<your-viewing-key>"
echo ""
