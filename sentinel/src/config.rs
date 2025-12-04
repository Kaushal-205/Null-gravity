//! Configuration management for the Sentinel AVS
//!
//! Supports both local development (zebrad + lightwalletd) and
//! production deployments using public RPC endpoints.

use anyhow::{Context, Result};
use serde::Deserialize;
use std::env;

/// Public Lightwalletd endpoints
pub mod endpoints {
    /// Mainnet lightwalletd endpoints
    pub const MAINNET_ENDPOINTS: &[&str] = &[
        "https://lightwalletd.zecpages.com:443",      // Community (zecpages)
        "https://lwd1.zcash-infra.com:9067",          // Zcash Foundation
        "https://lwd2.zcash-infra.com:9067",          // Zcash Foundation
        "https://mainnet.lightwalletd.com:9067",      // Electric Coin Co
        "https://zcash.mysideoftheweb.com:9067",      // Community
    ];

    /// Testnet lightwalletd endpoints
    pub const TESTNET_ENDPOINTS: &[&str] = &[
        "https://lightwalletd.testnet.electriccoin.co:9067",
        "https://testnet.lightwalletd.com:9067",
    ];

    /// Get default endpoint for network
    pub fn default_for_network(network: &str) -> &'static str {
        match network {
            "mainnet" => MAINNET_ENDPOINTS[0],
            "testnet" => TESTNET_ENDPOINTS[0],
            _ => "http://localhost:9067", // regtest/local
        }
    }
}

/// Sentinel configuration
#[derive(Debug, Clone, Deserialize)]
pub struct SentinelConfig {
    /// Lightwalletd gRPC URL
    pub lightwalletd_url: String,

    /// Whether to use TLS for lightwalletd connection
    pub lightwalletd_tls: bool,

    /// Zcash viewing key for the vault address (Sapling IVK)
    pub viewing_key: String,

    /// Vault shielded address to monitor
    pub vault_address: String,

    /// Number of confirmations required before attesting
    pub confirmation_depth: u32,

    /// L1 (Ethereum) RPC URL
    pub l1_rpc_url: String,

    /// ServiceManager contract address on L1
    pub service_manager_address: String,

    /// Operator's private key for signing (hex encoded)
    pub operator_private_key: String,

    /// Network type (regtest, testnet, mainnet)
    pub network: String,

    /// Retry configuration for RPC calls
    pub max_retries: u32,

    /// Retry delay in milliseconds
    pub retry_delay_ms: u64,
}

impl SentinelConfig {
    /// Load configuration from environment variables
    pub fn load() -> Result<Self> {
        // Try to load .env file
        dotenvy::dotenv().ok();

        let network = env::var("ZCASH_NETWORK").unwrap_or_else(|_| "regtest".to_string());

        // Determine lightwalletd URL based on network if not explicitly set
        let lightwalletd_url = env::var("LIGHTWALLETD_URL")
            .unwrap_or_else(|_| endpoints::default_for_network(&network).to_string());

        // Detect if TLS should be used based on URL
        let lightwalletd_tls = lightwalletd_url.starts_with("https://");

        let config = Self {
            lightwalletd_url,
            lightwalletd_tls,

            viewing_key: env::var("VAULT_VIEWING_KEY")
                .context("VAULT_VIEWING_KEY environment variable not set")?,

            vault_address: env::var("VAULT_ADDRESS")
                .context("VAULT_ADDRESS environment variable not set")?,

            confirmation_depth: env::var("CONFIRMATION_DEPTH")
                .unwrap_or_else(|_| {
                    // Higher confirmation depth for mainnet
                    match network.as_str() {
                        "mainnet" => "24".to_string(),
                        "testnet" => "12".to_string(),
                        _ => "6".to_string(),
                    }
                })
                .parse()
                .context("Invalid CONFIRMATION_DEPTH")?,

            l1_rpc_url: env::var("L1_RPC_URL")
                .unwrap_or_else(|_| "http://localhost:8545".to_string()),

            service_manager_address: env::var("SERVICE_MANAGER_ADDRESS")
                .context("SERVICE_MANAGER_ADDRESS environment variable not set")?,

            operator_private_key: env::var("OPERATOR_PRIVATE_KEY")
                .context("OPERATOR_PRIVATE_KEY environment variable not set")?,

            network,

            max_retries: env::var("MAX_RETRIES")
                .unwrap_or_else(|_| "3".to_string())
                .parse()
                .unwrap_or(3),

            retry_delay_ms: env::var("RETRY_DELAY_MS")
                .unwrap_or_else(|_| "1000".to_string())
                .parse()
                .unwrap_or(1000),
        };

        config.validate()?;
        Ok(config)
    }

    /// Validate configuration values
    fn validate(&self) -> Result<()> {
        // Validate viewing key format
        if self.viewing_key.is_empty() {
            anyhow::bail!("Viewing key cannot be empty");
        }

        // Validate vault address based on network
        let valid_prefix = match self.network.as_str() {
            "mainnet" => self.vault_address.starts_with("zs"),
            "testnet" => self.vault_address.starts_with("ztestsapling"),
            "regtest" => {
                self.vault_address.starts_with("zregtestsapling")
                    || self.vault_address.starts_with("ztestsapling")
            }
            _ => false,
        };

        if !valid_prefix {
            anyhow::bail!(
                "Invalid vault address format for {} network",
                self.network
            );
        }

        // Validate private key format (should be 64 hex chars or 0x prefixed)
        let key = self
            .operator_private_key
            .strip_prefix("0x")
            .unwrap_or(&self.operator_private_key);
        if key.len() != 64 || !key.chars().all(|c| c.is_ascii_hexdigit()) {
            anyhow::bail!("Invalid operator private key format");
        }

        // Validate network
        match self.network.as_str() {
            "regtest" | "testnet" | "mainnet" => {}
            _ => anyhow::bail!("Invalid network: must be regtest, testnet, or mainnet"),
        }

        // Validate lightwalletd URL
        if !self.lightwalletd_url.starts_with("http://")
            && !self.lightwalletd_url.starts_with("https://")
        {
            anyhow::bail!("Invalid lightwalletd URL format");
        }

        Ok(())
    }

    /// Check if using public endpoint
    pub fn is_public_endpoint(&self) -> bool {
        !self.lightwalletd_url.contains("localhost")
            && !self.lightwalletd_url.contains("127.0.0.1")
    }

    /// Get recommended confirmation depth for network
    pub fn recommended_confirmation_depth(&self) -> u32 {
        match self.network.as_str() {
            "mainnet" => 24,  // ~1 hour
            "testnet" => 12,  // ~30 minutes
            _ => 6,           // ~15 minutes for regtest
        }
    }
}

/// Example .env file content for different environments
pub const EXAMPLE_ENV_LOCAL: &str = r#"
# Sentinel AVS Configuration - Local Development
# Uses local zebrad + lightwalletd via Docker

# Local lightwalletd endpoint
LIGHTWALLETD_URL=http://localhost:9067

# Vault viewing key (Sapling IVK) - generated by setup-vault.sh
VAULT_VIEWING_KEY=zivkregtestsapling1...

# Vault shielded address
VAULT_ADDRESS=zregtestsapling1...

# Number of confirmations before attesting
CONFIRMATION_DEPTH=6

# Local Ethereum (anvil)
L1_RPC_URL=http://localhost:8545

# ServiceManager contract address
SERVICE_MANAGER_ADDRESS=0x5FbDB2315678afecb367f032d93F642f64180aa3

# Operator private key (anvil default account 0)
OPERATOR_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Zcash network
ZCASH_NETWORK=regtest
"#;

pub const EXAMPLE_ENV_TESTNET: &str = r#"
# Sentinel AVS Configuration - Testnet
# Uses public lightwalletd endpoints

# Public testnet lightwalletd endpoint
LIGHTWALLETD_URL=https://lightwalletd.testnet.electriccoin.co:9067

# Vault viewing key (Sapling IVK)
VAULT_VIEWING_KEY=zivktestsapling1...

# Vault shielded address
VAULT_ADDRESS=ztestsapling1...

# Number of confirmations before attesting (higher for testnet)
CONFIRMATION_DEPTH=12

# Ethereum Sepolia RPC
L1_RPC_URL=https://sepolia.infura.io/v3/YOUR_INFURA_KEY

# ServiceManager contract address on Sepolia
SERVICE_MANAGER_ADDRESS=0x...

# Operator private key (KEEP SECRET!)
OPERATOR_PRIVATE_KEY=0x...

# Zcash network
ZCASH_NETWORK=testnet
"#;

pub const EXAMPLE_ENV_MAINNET: &str = r#"
# Sentinel AVS Configuration - Mainnet
# Uses public lightwalletd endpoints
# ⚠️  PRODUCTION CONFIGURATION - HANDLE WITH CARE

# Public mainnet lightwalletd endpoint
LIGHTWALLETD_URL=https://lightwalletd.zecpages.com:443

# Vault viewing key (Sapling IVK)
VAULT_VIEWING_KEY=zivksapling1...

# Vault shielded address
VAULT_ADDRESS=zs1...

# Number of confirmations before attesting (24 blocks = ~1 hour)
CONFIRMATION_DEPTH=24

# Ethereum Mainnet RPC
L1_RPC_URL=https://mainnet.infura.io/v3/YOUR_INFURA_KEY

# ServiceManager contract address on Mainnet
SERVICE_MANAGER_ADDRESS=0x...

# Operator private key (KEEP SECRET! Use hardware wallet in production)
OPERATOR_PRIVATE_KEY=0x...

# Zcash network
ZCASH_NETWORK=mainnet

# Retry configuration for reliability
MAX_RETRIES=5
RETRY_DELAY_MS=2000
"#;

/// Print available public endpoints
pub fn print_available_endpoints() {
    println!("Available Public Lightwalletd Endpoints:");
    println!();
    println!("Mainnet:");
    for endpoint in endpoints::MAINNET_ENDPOINTS {
        println!("  - {}", endpoint);
    }
    println!();
    println!("Testnet:");
    for endpoint in endpoints::TESTNET_ENDPOINTS {
        println!("  - {}", endpoint);
    }
}
