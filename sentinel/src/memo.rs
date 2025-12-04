//! Memo field parsing for bridge payloads
//!
//! Bridge deposits include a JSON payload in the Zcash memo field:
//! {
//!     "type": "bridge_deposit",
//!     "aztec_address": "0x...",
//!     "secret_hash": "0x...",
//!     "version": 1
//! }

use crate::error::SentinelError;
use serde::{Deserialize, Serialize};
use tracing::{debug, warn};

/// Parser for bridge memo payloads
pub struct MemoParser {
    /// Expected memo version
    expected_version: u8,
}

/// Raw memo payload structure
#[derive(Debug, Serialize, Deserialize)]
pub struct MemoPayload {
    /// Message type identifier
    #[serde(rename = "type")]
    pub msg_type: String,

    /// Recipient's Aztec address (hex encoded)
    pub aztec_address: String,

    /// Hash of the claim secret (hex encoded)
    pub secret_hash: String,

    /// Protocol version
    pub version: u8,
}

/// Parsed bridge payload from memo
#[derive(Debug, Clone)]
pub struct ParsedPayload {
    /// Aztec address as bytes
    pub aztec_address: [u8; 32],

    /// Secret hash as bytes
    pub secret_hash: [u8; 32],
}

impl MemoParser {
    /// Create a new memo parser
    pub fn new() -> Self {
        Self {
            expected_version: 1,
        }
    }

    /// Parse a memo field into a bridge payload
    pub fn parse(&self, memo: &[u8; 512]) -> Result<Option<ParsedPayload>, SentinelError> {
        // Find the end of the JSON (null terminator or end of memo)
        let json_end = memo
            .iter()
            .position(|&b| b == 0)
            .unwrap_or(512);

        let json_bytes = &memo[..json_end];

        // Try to parse as UTF-8
        let json_str = match std::str::from_utf8(json_bytes) {
            Ok(s) => s.trim(),
            Err(_) => {
                debug!("Memo is not valid UTF-8, skipping");
                return Ok(None);
            }
        };

        // Skip empty memos
        if json_str.is_empty() {
            return Ok(None);
        }

        // Try to parse as JSON
        let payload: MemoPayload = match serde_json::from_str(json_str) {
            Ok(p) => p,
            Err(_) => {
                debug!("Memo is not valid JSON, skipping");
                return Ok(None);
            }
        };

        // Validate message type
        if payload.msg_type != "bridge_deposit" {
            debug!("Memo type is not bridge_deposit: {}", payload.msg_type);
            return Ok(None);
        }

        // Validate version
        if payload.version != self.expected_version {
            warn!(
                "Unexpected memo version: {} (expected {})",
                payload.version, self.expected_version
            );
            return Ok(None);
        }

        // Parse Aztec address
        let aztec_address = self.parse_hex_address(&payload.aztec_address)?;

        // Parse secret hash
        let secret_hash = self.parse_hex_address(&payload.secret_hash)?;

        Ok(Some(ParsedPayload {
            aztec_address,
            secret_hash,
        }))
    }

    /// Parse a hex-encoded address into bytes
    fn parse_hex_address(&self, hex_str: &str) -> Result<[u8; 32], SentinelError> {
        let hex_str = hex_str.strip_prefix("0x").unwrap_or(hex_str);

        if hex_str.len() != 64 {
            return Err(SentinelError::InvalidPayload(format!(
                "Invalid hex length: expected 64, got {}",
                hex_str.len()
            )));
        }

        let bytes = hex::decode(hex_str)?;
        let mut result = [0u8; 32];
        result.copy_from_slice(&bytes);

        Ok(result)
    }

    /// Create a memo payload for a deposit
    pub fn create_memo(
        aztec_address: &[u8; 32],
        secret_hash: &[u8; 32],
    ) -> Result<[u8; 512], SentinelError> {
        let payload = MemoPayload {
            msg_type: "bridge_deposit".to_string(),
            aztec_address: format!("0x{}", hex::encode(aztec_address)),
            secret_hash: format!("0x{}", hex::encode(secret_hash)),
            version: 1,
        };

        let json = serde_json::to_string(&payload)?;

        if json.len() > 512 {
            return Err(SentinelError::InvalidPayload(
                "Memo payload too large".to_string(),
            ));
        }

        let mut memo = [0u8; 512];
        memo[..json.len()].copy_from_slice(json.as_bytes());

        Ok(memo)
    }
}

impl Default for MemoParser {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_valid_memo() {
        let parser = MemoParser::new();

        let json = r#"{"type":"bridge_deposit","aztec_address":"0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef","secret_hash":"0xfedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321","version":1}"#;

        let mut memo = [0u8; 512];
        memo[..json.len()].copy_from_slice(json.as_bytes());

        let result = parser.parse(&memo).unwrap();
        assert!(result.is_some());

        let payload = result.unwrap();
        assert_eq!(
            hex::encode(payload.aztec_address),
            "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        );
    }

    #[test]
    fn test_parse_invalid_type() {
        let parser = MemoParser::new();

        let json = r#"{"type":"other","aztec_address":"0x1234","secret_hash":"0x5678","version":1}"#;

        let mut memo = [0u8; 512];
        memo[..json.len()].copy_from_slice(json.as_bytes());

        let result = parser.parse(&memo).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_create_memo() {
        let aztec_address = [0x12u8; 32];
        let secret_hash = [0x34u8; 32];

        let memo = MemoParser::create_memo(&aztec_address, &secret_hash).unwrap();

        // Parse it back
        let parser = MemoParser::new();
        let result = parser.parse(&memo).unwrap();
        assert!(result.is_some());

        let payload = result.unwrap();
        assert_eq!(payload.aztec_address, aztec_address);
        assert_eq!(payload.secret_hash, secret_hash);
    }
}
