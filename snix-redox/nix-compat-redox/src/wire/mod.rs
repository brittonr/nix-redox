//! Module parsing and emitting the wire format used by Nix, both in the
//! nix-daemon protocol as well as in the NAR format.

mod bytes;
pub use bytes::*;

mod protocol_version;
pub use protocol_version::ProtocolVersion;

pub mod de;
pub mod ser;
