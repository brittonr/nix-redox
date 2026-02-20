use super::NixHash;
use crate::nixbase32;
use serde::{Deserialize, Serialize};
use std::fmt::Formatter;

impl<'de> Deserialize<'de> for NixHash {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        use serde::de::{Error, Visitor};

        struct NixHashVisitor;

        impl Visitor<'_> for NixHashVisitor {
            type Value = NixHash;

            fn expecting(&self, formatter: &mut Formatter) -> std::fmt::Result {
                formatter.write_str("a string representing a Nix hash")
            }

            fn visit_str<E>(self, s: &str) -> Result<Self::Value, E>
            where
                E: Error,
            {
                NixHash::from_str(s, None).map_err(|err| Error::custom(format!("{err}: {s:?}")))
            }
        }

        deserializer.deserialize_str(NixHashVisitor)
    }
}

impl Serialize for NixHash {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let sri = self.to_sri_string();
        sri.serialize(serializer)
    }
}

/// The length of a sha256 digest, nixbase32-encoded.
const NIXBASE32_SHA256_ENCODE_LEN: usize = nixbase32::encode_len(32);

pub fn from_nix_nixbase32_or_sri<'de, D>(deserializer: D) -> Result<[u8; 32], D::Error>
where
    D: serde::Deserializer<'de>,
{
    let str: &'de str = Deserialize::deserialize(deserializer)?;
    if let Some(digest_str) = str.strip_prefix("sha256:") {
        return from_nix_nixbase32::<D>(digest_str);
    }
    if let Some(digest_str) = str.strip_prefix("sha256-") {
        return from_sri::<D>(digest_str);
    }
    Err(serde::de::Error::invalid_value(
        serde::de::Unexpected::Str(str),
        &"extected a valid nixbase32 or sri narHash",
    ))
}

pub fn from_sri<'de, D>(str: &str) -> Result<[u8; 32], D::Error>
where
    D: serde::Deserializer<'de>,
{
    let digest: [u8; 32] = data_encoding::BASE64
        .decode(str.as_bytes())
        .map_err(|_| {
            serde::de::Error::invalid_value(
                serde::de::Unexpected::Str(str),
                &"valid base64 encoded string",
            )
        })?
        .try_into()
        .map_err(|_| {
            serde::de::Error::invalid_value(serde::de::Unexpected::Str(str), &"valid digest len")
        })?;

    Ok(digest)
}

pub fn from_nix_nixbase32<'de, D>(str: &str) -> Result<[u8; 32], D::Error>
where
    D: serde::Deserializer<'de>,
{
    let digest_str: [u8; NIXBASE32_SHA256_ENCODE_LEN] =
        str.as_bytes().try_into().map_err(|_| {
            serde::de::Error::invalid_value(serde::de::Unexpected::Str(str), &"valid digest len")
        })?;

    let digest: [u8; 32] = nixbase32::decode_fixed(digest_str).map_err(|_| {
        serde::de::Error::invalid_value(serde::de::Unexpected::Str(str), &"valid nixbase32")
    })?;

    Ok(digest)
}

pub fn to_nix_nixbase32<S>(v: &[u8; 32], serializer: S) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    let string = NixHash::Sha256(*v).to_nix_nixbase32();
    string.serialize(serializer)
}
