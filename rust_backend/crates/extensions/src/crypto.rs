//! `kalao.crypto`: digests, HMAC, AES-GCM and base64, run in Rust.

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes128Gcm, Aes256Gcm, Nonce};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use hmac::{Hmac, Mac};
use kalao_core::lower_hex;
use md5::Md5;
use serde_json::{Value, json};
use sha1::Sha1;
use sha2::{Digest, Sha256};

/// Input bytes: text (UTF-8, the default), `base64` or `hex`.
pub fn input(data: &Value, encoding: Option<&str>) -> Result<Vec<u8>, String> {
    let text = data.as_str().ok_or("data must be a string")?;
    match encoding.unwrap_or("utf8") {
        "utf8" | "utf-8" | "text" => Ok(text.as_bytes().to_vec()),
        "base64" => STANDARD.decode(text).map_err(|error| error.to_string()),
        "hex" => decode_hex(text),
        other => Err(format!("unknown encoding '{other}'")),
    }
}

fn decode_hex(text: &str) -> Result<Vec<u8>, String> {
    if !text.len().is_multiple_of(2) {
        return Err("hex input has an odd length".into());
    }
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).map_err(|error| error.to_string()))
        .collect()
}

pub fn digest(algorithm: &str, bytes: &[u8]) -> Result<String, String> {
    Ok(match algorithm {
        "sha1" => lower_hex(&Sha1::digest(bytes)),
        "sha256" => lower_hex(&Sha256::digest(bytes)),
        "md5" => lower_hex(&Md5::digest(bytes)),
        other => return Err(format!("unknown digest '{other}'")),
    })
}

pub fn hmac(algorithm: &str, key: &[u8], bytes: &[u8]) -> Result<String, String> {
    fn run<M: Mac + hmac::KeyInit>(key: &[u8], bytes: &[u8]) -> Result<String, String> {
        let mut mac =
            <M as hmac::KeyInit>::new_from_slice(key).map_err(|error| error.to_string())?;
        mac.update(bytes);
        Ok(lower_hex(&mac.finalize().into_bytes()))
    }
    match algorithm {
        "sha1" => run::<Hmac<Sha1>>(key, bytes),
        "sha256" => run::<Hmac<Sha256>>(key, bytes),
        "md5" => run::<Hmac<Md5>>(key, bytes),
        other => Err(format!("unknown HMAC digest '{other}'")),
    }
}

/// AES-GCM with a 128- or 256-bit key and a 12-byte IV; data and result in
/// base64 (the tag is appended to the ciphertext).
pub fn aes_gcm(encrypt: bool, args: &Value) -> Result<Value, String> {
    let field = |name: &str| -> Result<Vec<u8>, String> {
        STANDARD
            .decode(
                args[name]
                    .as_str()
                    .ok_or_else(|| format!("{name} (base64) is required"))?,
            )
            .map_err(|error| format!("{name}: {error}"))
    };
    let (key, iv, data) = (field("key")?, field("iv")?, field("data")?);
    let aad = match args["aad"].as_str() {
        Some(aad) => STANDARD.decode(aad).map_err(|error| error.to_string())?,
        None => Vec::new(),
    };
    if iv.len() != 12 {
        return Err("iv must be 12 bytes".into());
    }
    let nonce = Nonce::try_from(iv.as_slice()).map_err(|_| "iv must be 12 bytes".to_owned())?;
    let nonce = &nonce;
    let payload = Payload {
        msg: &data,
        aad: &aad,
    };
    let result = match key.len() {
        16 => {
            let cipher = Aes128Gcm::new_from_slice(&key).map_err(|error| error.to_string())?;
            if encrypt {
                cipher.encrypt(nonce, payload)
            } else {
                cipher.decrypt(nonce, payload)
            }
        }
        32 => {
            let cipher = Aes256Gcm::new_from_slice(&key).map_err(|error| error.to_string())?;
            if encrypt {
                cipher.encrypt(nonce, payload)
            } else {
                cipher.decrypt(nonce, payload)
            }
        }
        _ => return Err("key must be 16 or 32 bytes".into()),
    }
    .map_err(|_| "AES-GCM failed (wrong key, IV or tag)".to_owned())?;
    Ok(json!(STANDARD.encode(result)))
}

pub fn base64_encode(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

pub fn base64_decode_text(text: &str) -> Result<String, String> {
    let bytes = STANDARD
        .decode(text.trim())
        .map_err(|error| error.to_string())?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn digests_and_hmac_match_known_values() {
        assert_eq!(
            digest("sha256", b"abc").unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            digest("md5", b"").unwrap(),
            "d41d8cd98f00b204e9800998ecf8427e"
        );
        assert_eq!(
            digest("sha1", b"abc").unwrap(),
            "a9993e364706816aba3e25717850c26c9cd0d89d"
        );
        assert_eq!(
            hmac(
                "sha256",
                b"key",
                b"The quick brown fox jumps over the lazy dog"
            )
            .unwrap(),
            "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
        );
        assert!(digest("sha3", b"").is_err());
        assert_eq!(input(&json!("616263"), Some("hex")).unwrap(), b"abc");
    }

    #[test]
    fn aes_gcm_round_trips() {
        let key = STANDARD.encode([7u8; 32]);
        let iv = STANDARD.encode([1u8; 12]);
        let sealed = aes_gcm(
            true,
            &json!({"key": key, "iv": iv, "data": STANDARD.encode("hello")}),
        )
        .unwrap();
        let opened = aes_gcm(false, &json!({"key": key, "iv": iv, "data": sealed})).unwrap();
        assert_eq!(
            base64_decode_text(opened.as_str().unwrap()).unwrap(),
            "hello"
        );
        let wrong = STANDARD.encode([8u8; 32]);
        assert!(aes_gcm(false, &json!({"key": wrong, "iv": iv, "data": sealed})).is_err());
    }
}
