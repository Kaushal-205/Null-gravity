//! Error types for the Sentinel AVS

use thiserror::Error;

/// Sentinel error types
#[derive(Error, Debug)]
pub enum SentinelError {
    /// Configuration error
    #[error("Configuration error: {0}")]
    Config(String),

    /// Scanner error
    #[error("Scanner error: {0}")]
    Scanner(String),

    /// Memo parsing error
    #[error("Memo parsing error: {0}")]
    MemoParse(String),

    /// Signing error
    #[error("Signing error: {0}")]
    Signing(String),

    /// L1 interaction error
    #[error("L1 error: {0}")]
    L1(String),

    /// gRPC error
    #[error("gRPC error: {0}")]
    Grpc(#[from] tonic::Status),

    /// Zcash decryption error
    #[error("Decryption error: {0}")]
    Decryption(String),

    /// Invalid payload error
    #[error("Invalid payload: {0}")]
    InvalidPayload(String),

    /// Network error
    #[error("Network error: {0}")]
    Network(String),
}

impl From<ethers::providers::ProviderError> for SentinelError {
    fn from(err: ethers::providers::ProviderError) -> Self {
        SentinelError::L1(err.to_string())
    }
}

impl From<ethers::signers::WalletError> for SentinelError {
    fn from(err: ethers::signers::WalletError) -> Self {
        SentinelError::Signing(err.to_string())
    }
}

impl From<serde_json::Error> for SentinelError {
    fn from(err: serde_json::Error) -> Self {
        SentinelError::MemoParse(err.to_string())
    }
}

impl From<hex::FromHexError> for SentinelError {
    fn from(err: hex::FromHexError) -> Self {
        SentinelError::InvalidPayload(err.to_string())
    }
}

