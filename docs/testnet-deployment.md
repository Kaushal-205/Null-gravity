# Testnet Deployment Guide

This guide covers deploying the Null-Gravity Bridge to testnets using **public RPC endpoints** (no local Zcash node required).

## Prerequisites

- Node.js >= 18
- Rust >= 1.70
- Foundry (forge, cast, anvil)
- Docker & Docker Compose (optional, for local Aztec)

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     Public Infrastructure                        │
├─────────────────────────────────────────────────────────────────┤
│  Zcash Testnet          │  Ethereum Sepolia    │  Aztec Devnet  │
│  ┌─────────────────┐    │  ┌──────────────┐    │  ┌──────────┐  │
│  │ lightwalletd    │    │  │ Infura/      │    │  │ Aztec    │  │
│  │ (public gRPC)   │    │  │ Alchemy RPC  │    │  │ Sandbox  │  │
│  └────────┬────────┘    │  └──────┬───────┘    │  └────┬─────┘  │
│           │             │         │            │       │        │
└───────────┼─────────────┼─────────┼────────────┼───────┼────────┘
            │             │         │            │       │
            └─────────────┼─────────┼────────────┼───────┘
                          │         │            │
                    ┌─────▼─────────▼────────────▼─────┐
                    │         Sentinel AVS             │
                    │    (Your Infrastructure)         │
                    └──────────────────────────────────┘
```

## 1. Public RPC Endpoints

### Zcash Lightwalletd Endpoints

**Mainnet:**
| Provider | Endpoint | Notes |
|----------|----------|-------|
| zecpages (Community) | `https://lightwalletd.zecpages.com:443` | Recommended |
| Zcash Foundation | `https://lwd1.zcash-infra.com:9067` | High availability |
| Zcash Foundation | `https://lwd2.zcash-infra.com:9067` | Backup |
| Electric Coin Co | `https://mainnet.lightwalletd.com:9067` | Official |

**Testnet:**
| Provider | Endpoint | Notes |
|----------|----------|-------|
| Electric Coin Co | `https://lightwalletd.testnet.electriccoin.co:9067` | Official |
| Community | `https://testnet.lightwalletd.com:9067` | Alternative |

### Ethereum RPC Endpoints

| Provider | Sepolia URL | Free Tier |
|----------|-------------|-----------|
| Infura | `https://sepolia.infura.io/v3/YOUR_KEY` | 100k req/day |
| Alchemy | `https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY` | 300M CU/month |
| QuickNode | `https://your-endpoint.sepolia.quiknode.pro/` | 10M credits |
| Ankr | `https://rpc.ankr.com/eth_sepolia` | Public |

## 2. Create Vault Address

### Option A: Using Zallet (Recommended)

```bash
# Install zallet
cargo install zallet

# Generate new Sapling address for testnet
zallet --network testnet generate-address --type sapling

# Export viewing key
zallet --network testnet export-viewing-key <ADDRESS>
```

### Option B: Using Ywallet (GUI)

1. Download [Ywallet](https://ywallet.app/)
2. Create new wallet on testnet
3. Generate Sapling address
4. Export viewing key from settings

### Option C: Using zcash-cli (Legacy)

```bash
# If you have zcashd running
zcash-cli -testnet z_getnewaddress sapling
zcash-cli -testnet z_exportviewingkey <ADDRESS>
```

### Fund Your Vault

Get testnet ZEC from:
- [Zcash Testnet Faucet](https://faucet.zecpages.com/)
- Community Discord faucets

## 3. Deploy L1 Contracts (Sepolia)

### 3.1 Setup Environment

```bash
cd contracts/l1

# Create .env file
cat > .env << EOF
PRIVATE_KEY=0x<your-deployer-private-key>
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/<your-key>
ETHERSCAN_API_KEY=<your-etherscan-key>
L2_BRIDGE_ADDRESS=0x0000000000000000000000000000000000000000000000000000000000001234
MINIMUM_STAKE=10000000000000000
QUORUM_BPS=6700
EOF

# Install dependencies
forge install
```

### 3.2 Deploy Contracts

```bash
# Deploy to Sepolia
forge script script/Deploy.s.sol:DeployTestnet \
    --rpc-url $SEPOLIA_RPC_URL \
    --broadcast \
    --verify

# Note the deployed addresses from output
```

### 3.3 Verify on Etherscan

```bash
# Verify BLSVerifier
forge verify-contract <BLS_VERIFIER_ADDRESS> \
    src/BLSVerifier.sol:BLSVerifier \
    --chain sepolia

# Verify Inbox
forge verify-contract <INBOX_ADDRESS> \
    src/Inbox.sol:Inbox \
    --chain sepolia \
    --constructor-args $(cast abi-encode "constructor(bytes32)" <L2_BRIDGE_ADDRESS>)

# Verify ServiceManager
forge verify-contract <SERVICE_MANAGER_ADDRESS> \
    src/ServiceManager.sol:ServiceManager \
    --chain sepolia \
    --constructor-args $(cast abi-encode \
        "constructor(address,address,bytes32,address,uint256,uint256)" \
        <BLS_VERIFIER> <INBOX> <L2_BRIDGE> 0x0000000000000000000000000000000000000000 \
        10000000000000000 6700)
```

## 4. Configure Sentinel AVS

### 4.1 Build Sentinel

```bash
cd sentinel
cargo build --release
```

### 4.2 Create Configuration

```bash
cat > .env << EOF
# Zcash Configuration (Public Endpoint)
LIGHTWALLETD_URL=https://lightwalletd.testnet.electriccoin.co:9067
VAULT_VIEWING_KEY=<your-viewing-key>
VAULT_ADDRESS=<your-vault-address>
CONFIRMATION_DEPTH=12
ZCASH_NETWORK=testnet

# Ethereum Configuration
L1_RPC_URL=https://sepolia.infura.io/v3/<your-key>
SERVICE_MANAGER_ADDRESS=<deployed-address>

# Operator Configuration
OPERATOR_PRIVATE_KEY=<your-operator-key>

# Reliability
MAX_RETRIES=5
RETRY_DELAY_MS=2000
EOF
```

### 4.3 Register as Operator

```bash
# First, register BLS key
cast send $SERVICE_MANAGER_ADDRESS \
    "registerBLSKey((uint256,uint256))" \
    "(1,2)" \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $OPERATOR_PRIVATE_KEY

# Then, register as operator with stake (0.01 ETH for testnet)
cast send $SERVICE_MANAGER_ADDRESS \
    "registerOperator(uint256)" \
    "10000000000000000" \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $OPERATOR_PRIVATE_KEY \
    --value 0.01ether
```

### 4.4 Run Sentinel

```bash
# Run with logging
RUST_LOG=sentinel=info ./target/release/sentinel

# Or run as systemd service (production)
sudo cp sentinel.service /etc/systemd/system/
sudo systemctl enable sentinel
sudo systemctl start sentinel
```

## 5. CLI Setup

### 5.1 Install CLI

```bash
cd cli
npm install
npm run build
npm link
```

### 5.2 Configure CLI

```bash
cat > ~/.bridge/config.json << EOF
{
  "zcash": {
    "network": "testnet",
    "lightwalletdUrl": "https://lightwalletd.testnet.electriccoin.co:9067"
  },
  "ethereum": {
    "rpcUrl": "https://sepolia.infura.io/v3/<your-key>",
    "chainId": 11155111,
    "serviceManagerAddress": "<deployed-address>"
  },
  "aztec": {
    "pxeUrl": "http://localhost:8080",
    "bridgeAddress": "<aztec-bridge-address>"
  }
}
EOF
```

## 6. Test the Deployment

### 6.1 Check Status

```bash
bridge status
```

### 6.2 Test Deposit Flow

```bash
# 1. Create deposit
bridge deposit --amount 0.1 --aztec-address <your-aztec-address>
# Save the secret!

# 2. Wait for confirmations (check sentinel logs)

# 3. Claim on Aztec
bridge claim --secret <your-secret> --amount 0.1
```

### 6.3 Test Withdrawal Flow

```bash
bridge withdraw --amount 0.05 --zcash-address <your-zcash-address>
```

## 7. Monitoring

### Sentinel Logs

```bash
# View logs
journalctl -u sentinel -f

# Or if running directly
RUST_LOG=sentinel=debug ./target/release/sentinel
```

### Contract Events

```bash
# Watch for deposits
cast logs --address $SERVICE_MANAGER_ADDRESS \
    "DepositVerified(bytes32,uint256,bytes32,bytes32,bytes32)" \
    --rpc-url $SEPOLIA_RPC_URL
```

### Zcash Vault Balance

Use a block explorer or wallet:
- [Zcash Testnet Explorer](https://testnet.zcha.in/)
- Ywallet or Zingo wallet

## 8. Troubleshooting

### Common Issues

**1. Sentinel can't connect to lightwalletd**
```bash
# Test connection
grpcurl -plaintext lightwalletd.testnet.electriccoin.co:9067 list

# Try alternative endpoint
export LIGHTWALLETD_URL=https://testnet.lightwalletd.com:9067
```

**2. Transaction fails on Sepolia**
```bash
# Check operator registration
cast call $SERVICE_MANAGER_ADDRESS \
    "getOperator(address)" \
    $OPERATOR_ADDRESS \
    --rpc-url $SEPOLIA_RPC_URL

# Check ETH balance
cast balance $OPERATOR_ADDRESS --rpc-url $SEPOLIA_RPC_URL
```

**3. Signature verification fails**
- Ensure BLS key is registered before operator registration
- Check that payload hash matches between sentinel and contract

### Getting Help

- GitHub Issues: [null-gravity/bridge](https://github.com/null-gravity/bridge/issues)
- Zcash Community: [forum.zcashcommunity.com](https://forum.zcashcommunity.com/)

## 9. Security Checklist

Before mainnet:

- [ ] Use hardware wallet for operator key
- [ ] Set up key rotation procedures
- [ ] Configure monitoring and alerting
- [ ] Complete security audit
- [ ] Test disaster recovery
- [ ] Document incident response
- [ ] Set up multi-sig for admin functions
