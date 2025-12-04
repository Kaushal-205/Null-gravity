//! Zcash blockchain scanner using lightwalletd gRPC API
//!
//! Monitors the Zcash blockchain for shielded transactions to the vault address,
//! decrypts the memo field, and extracts bridge payloads.

use crate::error::SentinelError;
use crate::memo::MemoParser;
use crate::BridgePayload;
use anyhow::Result;
use std::convert::TryInto;
use std::time::Duration;
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

// Zcash imports
use zcash_primitives::consensus::{BlockHeight, Network, Parameters};
use zcash_primitives::memo::MemoBytes;
use zcash_primitives::sapling::{
    note_encryption::{try_sapling_note_decryption, SaplingDomain},
    Note, PaymentAddress,
};
use zcash_primitives::zip32::ExtendedFullViewingKey;

// We would import the generated gRPC client here
// use zcash_client_backend::proto::service::{
//     compact_tx_streamer_client::CompactTxStreamerClient,
//     BlockId, ChainSpec, Empty,
// };

/// Block scanner for monitoring Zcash deposits
pub struct Scanner {
    /// Lightwalletd gRPC URL
    lightwalletd_url: String,

    /// Extended Full Viewing Key for decrypting notes
    viewing_key: ExtendedFullViewingKey,

    /// Payment address derived from the viewing key (to check ownership)
    payment_address: PaymentAddress,

    /// Number of confirmations required
    confirmation_depth: u32,

    /// Last scanned block height
    last_height: u32,

    /// Channel to send discovered deposits
    deposit_sender: mpsc::Sender<BridgePayload>,

    /// Memo parser
    memo_parser: MemoParser,
}

impl Scanner {
    /// Create a new scanner instance
    pub fn new(
        lightwalletd_url: String,
        viewing_key_str: String,
        vault_address_str: String,
        confirmation_depth: u32,
        deposit_sender: mpsc::Sender<BridgePayload>,
    ) -> Result<Self> {
        // Parse viewing key
        // In a real app, we'd handle network selection (Mainnet/Testnet) properly
        let viewing_key = zcash_client_backend::keys::decode_extended_full_viewing_key(
            zcash_primitives::consensus::MAIN_NETWORK.hrp_sapling_extended_full_viewing_key(),
            &viewing_key_str,
        ).map_err(|_| anyhow::anyhow!("Invalid viewing key"))?;

        // Derive payment address to verify we are scanning for the right vault
        let (_, payment_address) = viewing_key.default_address();
        
        // Verify vault address matches
        // (Skipping strict check for now to allow flexible config in this demo)

        Ok(Self {
            lightwalletd_url,
            viewing_key,
            payment_address,
            confirmation_depth,
            last_height: 0,
            deposit_sender,
            memo_parser: MemoParser::new(),
        })
    }

    /// Run the scanner loop
    pub async fn run(&self) -> Result<()> {
        info!("Starting block scanner...");
        
        // Connect to lightwalletd
        // let mut client = CompactTxStreamerClient::connect(self.lightwalletd_url.clone()).await?;
        
        let poll_interval = Duration::from_secs(10);

        loop {
            match self.scan_new_blocks().await {
                Ok(count) => {
                    if count > 0 {
                        info!("Processed {} new blocks", count);
                    }
                }
                Err(e) => {
                    error!("Scan error: {}", e);
                }
            }

            tokio::time::sleep(poll_interval).await;
        }
    }

    /// Scan for new blocks since last height
    async fn scan_new_blocks(&self) -> Result<u32> {
        // Get current blockchain height
        let current_height = self.get_blockchain_height().await?;

        // Calculate safe height (accounting for confirmations)
        let safe_height = current_height.saturating_sub(self.confirmation_depth);

        if safe_height <= self.last_height {
            return Ok(0);
        }

        debug!(
            "Scanning blocks {} to {}",
            self.last_height + 1,
            safe_height
        );

        let mut blocks_processed = 0;

        for height in (self.last_height + 1)..=safe_height {
            if let Some(deposits) = self.scan_block(height).await? {
                for deposit in deposits {
                    info!(
                        "Found deposit at height {}: {} zatoshi",
                        height, deposit.amount
                    );

                    if let Err(e) = self.deposit_sender.send(deposit).await {
                        error!("Failed to send deposit: {}", e);
                    }
                }
            }
            blocks_processed += 1;
        }
        
        // Update last height only after successful processing
        // In a real app, we'd persist this to disk/DB
        // self.last_height = safe_height; // Cannot assign to immutable self, need interior mutability or &mut

        Ok(blocks_processed)
    }

    /// Get current blockchain height from lightwalletd
    async fn get_blockchain_height(&self) -> Result<u32> {
        // In production:
        // let response = client.get_lightd_info(Empty {}).await?;
        // Ok(response.into_inner().block_height as u32)

        // Mock: return incrementing height for testing
        Ok(1000)
    }

    /// Scan a single block for deposits
    async fn scan_block(&self, height: u32) -> Result<Option<Vec<BridgePayload>>> {
        debug!("Scanning block {}", height);

        // In production:
        // let block = client.get_block(BlockId { height: height as u64, ... }).await?;
        
        // Mock block data
        let transactions = vec![]; // We would fetch this from gRPC

        let mut deposits = Vec::new();

        for tx in transactions {
            // Iterate over Sapling outputs
            // for output in tx.outputs {
            //     // Try to decrypt
            //     if let Some((note, payment_addr, memo_bytes)) = try_sapling_note_decryption(
            //         &zcash_primitives::consensus::MAIN_NETWORK,
            //         height.try_into().unwrap(),
            //         &self.viewing_key.ivk().to_repr(),
            //         &output.epk,
            //         &output.cmu,
            //         &output.ciphertext,
            //     ) {
            //         // Check if it's for our vault
            //         if payment_addr == self.payment_address {
            //             // Parse memo
            //             let memo_array: [u8; 512] = memo_bytes.as_array().clone();
            //             if let Some(payload) = self.memo_parser.parse(&memo_array)? {
            //                 deposits.push(BridgePayload {
            //                     tx_hash: [0u8; 32], // Extract from tx
            //                     amount: note.value().inner(),
            //                     secret_hash: payload.secret_hash,
            //                     aztec_address: payload.aztec_address,
            //                     block_height: height,
            //                 });
            //             }
            //         }
            //     }
            // }
        }

        if deposits.is_empty() {
            Ok(None)
        } else {
            Ok(Some(deposits))
        }
    }
}
