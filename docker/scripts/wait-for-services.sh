#!/bin/bash
# Wait for all bridge services to be ready

set -e

echo "=== Waiting for Bridge Services ==="

# Function to wait for a service
wait_for_service() {
    local name=$1
    local check_cmd=$2
    local max_attempts=${3:-60}
    local attempt=1

    echo "Waiting for $name..."
    while [ $attempt -le $max_attempts ]; do
        if eval "$check_cmd" > /dev/null 2>&1; then
            echo "$name is ready!"
            return 0
        fi
        echo "  Attempt $attempt/$max_attempts - $name not ready yet..."
        sleep 2
        attempt=$((attempt + 1))
    done

    echo "ERROR: $name failed to become ready after $max_attempts attempts"
    return 1
}

# Wait for zcashd
wait_for_service "zcashd" "zcash-cli -regtest getblockchaininfo"

# Wait for lightwalletd
wait_for_service "lightwalletd" "grpcurl -plaintext localhost:9067 list"

# Wait for anvil
wait_for_service "anvil" "cast block-number --rpc-url http://localhost:8545"

# Wait for aztec-sandbox
wait_for_service "aztec-sandbox" "curl -sf http://localhost:8080/status"

echo ""
echo "=== All Services Ready ==="
echo ""
echo "Service Endpoints:"
echo "  - Zcash RPC:      http://localhost:18232"
echo "  - Lightwalletd:   localhost:9067 (gRPC)"
echo "  - Anvil (L1):     http://localhost:8545"
echo "  - Aztec PXE:      http://localhost:8080"
echo ""
