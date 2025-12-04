# Null-Gravity Bridge: Zcash ↔ Aztec

A privacy-preserving bridge between Zcash's shielded transactions and Aztec's private L2.

## 🌉 Overview

Null-Gravity enables users to:
- **Deposit** ZEC from Zcash shielded addresses to mint zZEC on Aztec
- **Transfer** zZEC privately within Aztec
- **Withdraw** zZEC back to Zcash shielded addresses

The bridge preserves privacy at every step using:
- Zcash Sapling shielded transactions
- Aztec's private execution environment
- Partial notes pattern to break timing correlation

## 🏗️ Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│     Zcash       │     │   Ethereum L1   │     │    Aztec L2     │
│   (Shielded)    │     │                 │     │   (Private)     │
├─────────────────┤     ├─────────────────┤     ├─────────────────┤
│                 │     │                 │     │                 │
│  Vault Address  │────▶│ ServiceManager  │────▶│   ZecBridge     │
│  (Sapling)      │     │    (AVS)        │     │    (Noir)       │
│                 │     │                 │     │                 │
└────────┬────────┘     └────────┬────────┘     └─────────────────┘
         │                       │
         │    ┌──────────────────┘
         │    │
    ┌────▼────▼────┐
    │   Sentinel   │
    │    (Rust)    │
    │              │
    │ • Scanner    │
    │ • Signer     │
    │ • Submitter  │
    └──────────────┘
```

## 📁 Project Structure

```
zcash/
├── docker/                 # Docker orchestration
│   ├── docker-compose.yml  # zebrad, lightwalletd, anvil, aztec-sandbox
│   ├── zebrad.toml         # Zebrad configuration (modern Zcash node)
│   ├── docker-compose.testnet.yml  # Testnet config (public endpoints)
│   └── scripts/            # Setup scripts
├── contracts/
│   ├── l1/                 # Solidity contracts (Foundry)
│   │   ├── src/
│   │   │   ├── ServiceManager.sol   # Main AVS contract
│   │   │   ├── BLSVerifier.sol      # BLS12-381 signature verification
│   │   │   ├── Inbox.sol            # L1→L2 message inbox
│   │   │   └── interfaces/
│   │   └── test/
│   └── l2/                 # Noir contracts (Aztec)
│       └── src/
│           └── main.nr     # ZecBridge contract
├── sentinel/               # Rust AVS
│   └── src/
│       ├── main.rs
│       ├── scanner.rs
│       ├── memo.rs
│       └── signer.rs
├── cli/                    # TypeScript CLI
│   └── src/
│       ├── deposit.ts
│       ├── claim.ts
│       └── withdraw.ts
└── docs/
    └── testnet-deployment.md
```

## 🚀 Quick Start

### Prerequisites

- Docker & Docker Compose
- Node.js >= 18
- Rust >= 1.70
- Foundry (forge, cast, anvil)

### Option A: Local Development (with zebrad)

```bash
cd docker
docker-compose up -d

# Wait for services to be ready
./scripts/wait-for-services.sh

# Setup vault address
./scripts/setup-vault.sh
```

### Option B: Using Public RPC Endpoints (Recommended for Testnet)

No local Zcash node needed! Use public lightwalletd endpoints:

```bash
# Testnet
export LIGHTWALLETD_URL=https://lightwalletd.testnet.electriccoin.co:9067

# Mainnet
export LIGHTWALLETD_URL=https://lightwalletd.zecpages.com:443
```

See [Testnet Deployment Guide](docs/testnet-deployment.md) for full setup.

### 2. Deploy Contracts

```bash
# Deploy L1 contracts
cd contracts/l1
forge install
forge build
forge test

# Deploy to local anvil
forge script script/Deploy.s.sol --broadcast --rpc-url http://localhost:8545
```

### 3. Run Sentinel

```bash
cd sentinel
cargo build --release

# Configure environment
cp .env.example .env
# Edit .env with your configuration

./target/release/sentinel
```

### 4. Use the CLI

```bash
cd cli
npm install
npm run build
npm link

# Deposit ZEC
bridge deposit --amount 10 --aztec-address 0x...

# Claim zZEC
bridge claim --secret 0x... --amount 10

# Withdraw to Zcash
bridge withdraw --amount 5 --zcash-address zs...

# Check status
bridge status
```

## 🔐 Security Model

### Deposit Flow

1. User sends shielded ZEC to vault with memo containing:
   - Aztec recipient address
   - Secret hash for claiming
2. Sentinel detects deposit after N confirmations
3. Sentinel signs attestation and submits to ServiceManager
4. ServiceManager verifies signatures and dispatches L1→L2 message
5. User claims zZEC on Aztec by proving knowledge of secret

### Withdrawal Flow

1. User burns zZEC on Aztec
2. L2→L1 message emitted with withdrawal request
3. Operators observe finalized withdrawal
4. FROST threshold signing creates Zcash transaction
5. ZEC sent to user's shielded address

### Security Considerations

- **Replay Protection**: Nonce tracking in ServiceManager
- **Confirmation Depth**: Configurable block confirmations
- **Partial Notes**: Decouples deposit visibility from claim privacy
- **Threshold Signatures**: FROST for vault key management (future)

## 🧪 Testing

### Run All Tests

```bash
# L1 contract tests
cd contracts/l1
forge test -vvv

# Rust tests
cd sentinel
cargo test

# Integration tests
./scripts/integration-test.sh
```

### Test Coverage

```bash
cd contracts/l1
forge coverage
```

## 📖 Documentation

- [Testnet Deployment Guide](docs/testnet-deployment.md)
- [Architecture Deep Dive](docs/architecture.md)
- [Security Considerations](docs/security.md)

## 🛣️ Roadmap

- [x] Phase 1: Infrastructure & Docker setup
- [x] Phase 2: L1 Solidity contracts (Production-ready)
  - [x] BLS12-381 signature verification (EIP-2537)
  - [x] ServiceManager with staking & slashing
  - [x] L1→L2 message inbox
- [x] Phase 3: L2 Noir contracts
- [x] Phase 4: Rust Sentinel AVS
- [x] Phase 5: TypeScript CLI
- [ ] Phase 6: FROST threshold signatures for vault
- [ ] Phase 7: Security audit
- [ ] Phase 8: Testnet deployment
- [ ] Phase 9: Mainnet deployment

## 🤝 Contributing

Contributions are welcome! Please read our [Contributing Guide](CONTRIBUTING.md) first.

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.

## 🔒 Security Features

The L1 contracts include production-ready security features:

- **BLS12-381 Signatures**: Real cryptographic verification using EIP-2537 precompiles
- **Two-Step Ownership**: Prevents accidental ownership transfers
- **Reentrancy Protection**: All state-changing functions protected
- **Pausable**: Emergency pause functionality
- **Unbonding Period**: 7-day delay for stake withdrawals
- **Configurable Quorum**: Adjustable signature threshold
- **Slashing**: Fraud proof-based stake slashing
- **EIP-712 Typed Data**: Secure message signing

## ⚠️ Disclaimer

This software has not been audited. While the contracts are production-ready in terms of features, a security audit is required before mainnet deployment. Use at your own risk on testnets.


<!-- 
Contract	Address
BLSVerifier	0x5FbDB2315678afecb367f032d93F642f64180aa3
Inbox	0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
ServiceManager	0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0 -->



