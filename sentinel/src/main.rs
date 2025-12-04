//! Sentinel AVS - Zcash chain watcher and attestation signer
//!
//! This service monitors the Zcash blockchain for deposits to the bridge vault,
//! decrypts memo fields to extract bridge payloads, and signs attestations
//! for submission to the L1 ServiceManager contract.

mod config;
mod error;
mod memo;
mod scanner;
mod signer;

use anyhow::Result;
use config::SentinelConfig;
use scanner::Scanner;
use signer::AttestationSigner;
use std::sync::Arc;
use tokio::sync::mpsc;
use tracing::{error, info, warn};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

/// Bridge payload extracted from Zcash memo
#[derive(Debug, Clone)]
pub struct BridgePayload {
    /// Zcash transaction hash
    pub tx_hash: [u8; 32],
    /// Amount in zatoshi
    pub amount: u64,
    /// Hash of the claim secret
    pub secret_hash: [u8; 32],
    /// Recipient's Aztec address
    pub aztec_address: [u8; 32],
    /// Block height where deposit was confirmed
    pub block_height: u32,
}

/// Attestation signed by the operator
#[derive(Debug, Clone)]
pub struct Attestation {
    /// The deposit payload being attested
    pub payload: BridgePayload,
    /// Unique nonce for replay protection
    pub nonce: u64,
    /// ECDSA signature
    pub signature: Vec<u8>,
}

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::new(
            std::env::var("RUST_LOG").unwrap_or_else(|_| "sentinel=info".into()),
        ))
        .with(tracing_subscriber::fmt::layer())
        .init();

    info!("Starting Sentinel AVS...");

    // Load configuration
    let config = SentinelConfig::load()?;
    info!("Configuration loaded successfully");
    info!("  Lightwalletd URL: {}", config.lightwalletd_url);
    info!("  L1 RPC URL: {}", config.l1_rpc_url);
    info!("  Confirmation depth: {} blocks", config.confirmation_depth);

    // Create channel for deposit notifications
    let (deposit_tx, mut deposit_rx) = mpsc::channel::<BridgePayload>(100);

    // Initialize scanner
    let scanner = Scanner::new(
        config.lightwalletd_url.clone(),
        config.viewing_key.clone(),
        config.vault_address.clone(),
        config.confirmation_depth,
        deposit_tx,
    )?;

    // Initialize signer
    let signer = Arc::new(AttestationSigner::new(
        config.operator_private_key.clone(),
        config.l1_rpc_url.clone(),
        config.service_manager_address.clone(),
    )?);

    // Spawn scanner task
    let scanner_handle = tokio::spawn(async move {
        if let Err(e) = scanner.run().await {
            error!("Scanner error: {}", e);
        }
    });

    // Process deposits and sign attestations
    let signer_clone = signer.clone();
    let attestation_handle = tokio::spawn(async move {
        let mut nonce: u64 = 0;

        while let Some(payload) = deposit_rx.recv().await {
            info!(
                "Processing deposit: {} zatoshi from tx {}",
                payload.amount,
                hex::encode(&payload.tx_hash[..8])
            );

            // Sign attestation
            match signer_clone.sign_attestation(&payload, nonce).await {
                Ok(attestation) => {
                    info!("Attestation signed successfully");

                    // Submit to L1
                    match signer_clone.submit_attestation(&attestation).await {
                        Ok(tx_hash) => {
                            info!("Attestation submitted to L1: {}", tx_hash);
                            nonce += 1;
                        }
                        Err(e) => {
                            error!("Failed to submit attestation: {}", e);
                        }
                    }
                }
                Err(e) => {
                    error!("Failed to sign attestation: {}", e);
                }
            }
        }
    });

    // Handle shutdown
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {
            info!("Received shutdown signal");
        }
        result = scanner_handle => {
            if let Err(e) = result {
                error!("Scanner task panicked: {}", e);
            }
        }
        result = attestation_handle => {
            if let Err(e) = result {
                error!("Attestation task panicked: {}", e);
            }
        }
    }

    info!("Sentinel shutting down...");
    Ok(())
}
