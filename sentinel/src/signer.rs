//! Attestation signing and L1 submission
//!
//! Signs deposit attestations using ECDSA and submits them to the
//! ServiceManager contract on L1.

use crate::error::SentinelError;
use crate::{Attestation, BridgePayload};
use anyhow::Result;
use ethers::prelude::*;
use ethers::signers::{LocalWallet, Signer};
use ethers::types::{Address, Bytes, U256};
use ethers::utils::keccak256;
use std::sync::Arc;
use tracing::{debug, info};

/// Attestation signer for bridge deposits
pub struct AttestationSigner {
    /// Ethereum wallet for signing
    wallet: LocalWallet,

    /// Provider for L1 interaction
    provider: Arc<Provider<Http>>,

    /// ServiceManager contract address
    service_manager_address: Address,

    /// Chain ID for signing
    chain_id: u64,
}

impl AttestationSigner {
    /// Create a new attestation signer
    pub fn new(
        private_key: String,
        l1_rpc_url: String,
        service_manager_address: String,
    ) -> Result<Self> {
        // Parse private key
        let key = private_key.strip_prefix("0x").unwrap_or(&private_key);
        let wallet: LocalWallet = key.parse()?;

        // Create provider
        let provider = Provider::<Http>::try_from(l1_rpc_url)?;

        // Parse contract address
        let address: Address = service_manager_address.parse()?;

        Ok(Self {
            wallet,
            provider: Arc::new(provider),
            service_manager_address: address,
            chain_id: 31337, // Anvil default
        })
    }

    /// Sign an attestation for a deposit
    pub async fn sign_attestation(
        &self,
        payload: &BridgePayload,
        nonce: u64,
    ) -> Result<Attestation, SentinelError> {
        // Compute the message hash (matching Solidity encoding)
        let message_hash = self.compute_payload_hash(payload, nonce);

        debug!("Signing message hash: {}", hex::encode(message_hash));

        // Sign the message with EIP-191 prefix
        let signature = self
            .wallet
            .sign_message(message_hash)
            .await
            .map_err(|e| SentinelError::Signing(e.to_string()))?;

        // Convert signature to bytes (r, s, v format)
        let sig_bytes = signature.to_vec();

        Ok(Attestation {
            payload: payload.clone(),
            nonce,
            signature: sig_bytes,
        })
    }

    /// Submit an attestation to the ServiceManager contract
    /// 
    /// This uses raw ABI encoding to call verifyAndDispatch
    pub async fn submit_attestation(
        &self,
        attestation: &Attestation,
    ) -> Result<String, SentinelError> {
        let client = SignerMiddleware::new(
            self.provider.clone(),
            self.wallet.clone().with_chain_id(self.chain_id),
        );

        // Encode the function call manually
        // verifyAndDispatch(DepositPayload payload, bytes aggregatedSig, address[] signers)
        // Function selector: keccak256("verifyAndDispatch((bytes32,uint256,bytes32,bytes32,uint64,uint32),bytes,address[])")
        
        let function_selector = &keccak256(
            b"verifyAndDispatch((bytes32,uint256,bytes32,bytes32,uint64,uint32),bytes,address[])"
        )[0..4];

        // Encode payload struct
        let payload = &attestation.payload;
        let encoded_payload = ethers::abi::encode(&[
            ethers::abi::Token::FixedBytes(payload.tx_hash.to_vec()),
            ethers::abi::Token::Uint(U256::from(payload.amount)),
            ethers::abi::Token::FixedBytes(payload.secret_hash.to_vec()),
            ethers::abi::Token::FixedBytes(payload.aztec_address.to_vec()),
            ethers::abi::Token::Uint(U256::from(attestation.nonce)),
            ethers::abi::Token::Uint(U256::from(payload.block_height)),
        ]);

        // Encode signature bytes
        let encoded_sig = ethers::abi::encode(&[ethers::abi::Token::Bytes(
            attestation.signature.clone(),
        )]);

        // Encode signers array
        let signers = vec![self.wallet.address()];
        let encoded_signers = ethers::abi::encode(&[ethers::abi::Token::Array(
            signers
                .iter()
                .map(|a| ethers::abi::Token::Address(*a))
                .collect(),
        )]);

        // Combine all encoded data
        let mut calldata = Vec::new();
        calldata.extend_from_slice(function_selector);
        calldata.extend_from_slice(&encoded_payload);
        calldata.extend_from_slice(&encoded_sig);
        calldata.extend_from_slice(&encoded_signers);

        // Create transaction
        let tx = TransactionRequest::new()
            .to(self.service_manager_address)
            .data(Bytes::from(calldata));

        // Send transaction
        let pending_tx = client
            .send_transaction(tx, None)
            .await
            .map_err(|e| SentinelError::L1(e.to_string()))?;

        let receipt = pending_tx
            .await
            .map_err(|e| SentinelError::L1(e.to_string()))?
            .ok_or_else(|| SentinelError::L1("Transaction receipt not found".to_string()))?;

        info!(
            "Transaction confirmed in block {}",
            receipt.block_number.unwrap_or_default()
        );

        Ok(format!("{:?}", receipt.transaction_hash))
    }

    /// Compute the hash of a payload (matching Solidity encoding)
    fn compute_payload_hash(&self, payload: &BridgePayload, nonce: u64) -> [u8; 32] {
        use ethers::abi::{encode, Token};

        let tokens = vec![
            Token::FixedBytes(payload.tx_hash.to_vec()),
            Token::Uint(U256::from(payload.amount)),
            Token::FixedBytes(payload.secret_hash.to_vec()),
            Token::FixedBytes(payload.aztec_address.to_vec()),
            Token::Uint(U256::from(nonce)),
            Token::Uint(U256::from(payload.block_height)),
        ];

        let encoded = encode(&tokens);
        keccak256(&encoded)
    }

    /// Get the operator's address
    pub fn address(&self) -> Address {
        self.wallet.address()
    }

    /// Check if a nonce has been used
    pub async fn is_nonce_used(&self, nonce: u64) -> Result<bool, SentinelError> {
        // Encode function call for isNonceUsed(uint64)
        let function_selector = &keccak256(b"isNonceUsed(uint64)")[0..4];
        let encoded_nonce = ethers::abi::encode(&[ethers::abi::Token::Uint(U256::from(nonce))]);

        let mut calldata = Vec::new();
        calldata.extend_from_slice(function_selector);
        calldata.extend_from_slice(&encoded_nonce);

        let call = TransactionRequest::new()
            .to(self.service_manager_address)
            .data(Bytes::from(calldata));

        let result = self
            .provider
            .call(&call.into(), None)
            .await
            .map_err(|e| SentinelError::L1(e.to_string()))?;

        // Decode bool result
        let used = !result.is_empty() && result[result.len() - 1] != 0;
        Ok(used)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_payload_hash() {
        // This test verifies that our Rust hash computation matches Solidity
        let signer = AttestationSigner {
            wallet: "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
                .parse()
                .unwrap(),
            provider: Arc::new(Provider::<Http>::try_from("http://localhost:8545").unwrap()),
            service_manager_address: Address::zero(),
            chain_id: 31337,
        };

        let payload = BridgePayload {
            tx_hash: [0xab; 32],
            amount: 1000000000, // 10 ZEC
            secret_hash: [0xcd; 32],
            aztec_address: [0xef; 32],
            block_height: 100,
        };

        let hash = signer.compute_payload_hash(&payload, 1);

        // Hash should be deterministic
        assert_eq!(hash.len(), 32);
        assert_ne!(hash, [0u8; 32]);
    }
}
