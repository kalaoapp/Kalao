//! ed25519 package signatures for repositories (EXTENSIONS.md §7). Keys and
//! signatures are written `ed25519:<base64>`; a signature covers the exact
//! package bytes.

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use kalao_core::lower_hex;
use sha2::{Digest, Sha256};

const PREFIX: &str = "ed25519:";
const SECRET_PREFIX: &str = "ed25519-secret:";

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum SigningError {
    #[error("invalid public key: {0}")]
    PublicKey(String),
    #[error("invalid signature: {0}")]
    Signature(String),
    #[error("invalid secret key: {0}")]
    SecretKey(String),
    #[error("signature does not match the repository key")]
    Mismatch,
}

fn decode(value: &str, prefix: &str) -> Option<Vec<u8>> {
    STANDARD.decode(value.trim().strip_prefix(prefix)?).ok()
}

pub fn parse_public_key(value: &str) -> Result<VerifyingKey, SigningError> {
    let bytes = decode(value, PREFIX)
        .ok_or_else(|| SigningError::PublicKey("expected ed25519:<base64>".into()))?;
    let bytes: [u8; 32] = bytes
        .try_into()
        .map_err(|_| SigningError::PublicKey("expected 32 bytes".into()))?;
    VerifyingKey::from_bytes(&bytes).map_err(|error| SigningError::PublicKey(error.to_string()))
}

pub fn verify(public_key: &str, signature: &str, bytes: &[u8]) -> Result<(), SigningError> {
    let key = parse_public_key(public_key)?;
    let raw = decode(signature, PREFIX)
        .ok_or_else(|| SigningError::Signature("expected ed25519:<base64>".into()))?;
    let signature =
        Signature::from_slice(&raw).map_err(|error| SigningError::Signature(error.to_string()))?;
    key.verify(bytes, &signature)
        .map_err(|_| SigningError::Mismatch)
}

/// A short, readable key fingerprint for the trust prompt.
pub fn key_fingerprint(public_key: &str) -> Result<String, SigningError> {
    let key = parse_public_key(public_key)?;
    let hex = lower_hex(&Sha256::digest(key.as_bytes()));
    Ok(hex.as_bytes()[..32]
        .chunks(4)
        .map(|chunk| String::from_utf8_lossy(chunk).into_owned())
        .collect::<Vec<_>>()
        .join(":"))
}

/// A new key pair: `(secret, public)`, for `kalao-ext keygen`.
pub fn generate() -> Result<(String, String), SigningError> {
    let mut seed = [0u8; 32];
    getrandom::fill(&mut seed).map_err(|error| SigningError::SecretKey(error.to_string()))?;
    let key = SigningKey::from_bytes(&seed);
    Ok((
        format!("{SECRET_PREFIX}{}", STANDARD.encode(seed)),
        public_key_of(&key),
    ))
}

fn public_key_of(key: &SigningKey) -> String {
    format!(
        "{PREFIX}{}",
        STANDARD.encode(key.verifying_key().as_bytes())
    )
}

fn parse_secret(secret: &str) -> Result<SigningKey, SigningError> {
    let bytes = decode(secret, SECRET_PREFIX)
        .ok_or_else(|| SigningError::SecretKey("expected ed25519-secret:<base64>".into()))?;
    let seed: [u8; 32] = bytes
        .try_into()
        .map_err(|_| SigningError::SecretKey("expected 32 bytes".into()))?;
    Ok(SigningKey::from_bytes(&seed))
}

/// The public key of a secret key file.
pub fn public_key(secret: &str) -> Result<String, SigningError> {
    Ok(public_key_of(&parse_secret(secret)?))
}

pub fn sign(secret: &str, bytes: &[u8]) -> Result<String, SigningError> {
    let key = parse_secret(secret)?;
    Ok(format!(
        "{PREFIX}{}",
        STANDARD.encode(key.sign(bytes).to_bytes())
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signs_and_verifies() {
        let (secret, public) = generate().unwrap();
        assert_eq!(public_key(&secret).unwrap(), public);
        let signature = sign(&secret, b"package").unwrap();
        assert_eq!(verify(&public, &signature, b"package"), Ok(()));
        assert_eq!(
            verify(&public, &signature, b"tampered"),
            Err(SigningError::Mismatch)
        );
        let (_, other) = generate().unwrap();
        assert_eq!(
            verify(&other, &signature, b"package"),
            Err(SigningError::Mismatch)
        );
        assert_eq!(key_fingerprint(&public).unwrap().len(), 39);
    }

    #[test]
    fn rejects_malformed_values() {
        assert!(parse_public_key("rsa:abc").is_err());
        assert!(parse_public_key("ed25519:AAAA").is_err());
        let (_, public) = generate().unwrap();
        assert!(matches!(
            verify(&public, "ed25519:AAAA", b"x"),
            Err(SigningError::Signature(_))
        ));
    }
}
