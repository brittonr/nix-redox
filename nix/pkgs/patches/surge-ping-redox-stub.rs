//! Stub: surge-ping on Redox (no raw ICMP sockets)
use std::net::IpAddr;
use std::time::Duration;

#[derive(Debug, Clone)]
pub enum SurgeError {
    NotSupported,
}
impl std::fmt::Display for SurgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "ICMP ping not supported on Redox")
    }
}
impl std::error::Error for SurgeError {}

#[derive(Debug, Clone)]
pub struct Config {
    pub kind: ICMP,
}
impl Config {
    pub fn builder() -> ConfigBuilder { ConfigBuilder { kind: ICMP::V4 } }
}

pub struct ConfigBuilder { kind: ICMP }
impl ConfigBuilder {
    pub fn kind(mut self, kind: ICMP) -> Self { self.kind = kind; self }
    pub fn build(self) -> Config { Config { kind: self.kind } }
}

#[derive(Debug, Clone)]
pub struct Client(ICMP);
impl Client {
    pub fn new(config: &Config) -> Result<Self, SurgeError> {
        Ok(Client(config.kind))
    }
    pub async fn pinger(&self, _addr: IpAddr, _ident: PingIdentifier) -> Pinger {
        Pinger
    }
}

pub struct Pinger;
impl Pinger {
    pub fn timeout(&mut self, _dur: Duration) {}
    pub async fn ping(&mut self, _seq: PingSequence, _payload: &[u8]) -> Result<(IcmpPacket, Duration), SurgeError> {
        Err(SurgeError::NotSupported)
    }
}

#[derive(Debug, Clone, Copy)]
pub enum ICMP { V4, V6 }

#[derive(Debug, Clone, Copy)]
pub struct PingIdentifier(pub u16);
impl PingIdentifier {
    pub fn from(v: u16) -> Self { PingIdentifier(v) }
}
impl From<u16> for PingIdentifier {
    fn from(v: u16) -> Self { PingIdentifier(v) }
}
impl std::fmt::Display for PingIdentifier {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

#[derive(Debug, Clone, Copy)]
pub struct PingSequence(pub u16);
impl PingSequence {
    pub fn from(v: u16) -> Self { PingSequence(v) }
}
impl From<u16> for PingSequence {
    fn from(v: u16) -> Self { PingSequence(v) }
}
impl std::fmt::Display for PingSequence {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

#[derive(Debug)]
pub enum IcmpPacket {
    V4(EchoReply),
    V6(EchoReply),
}

#[derive(Debug)]
pub struct EchoReply;
impl EchoReply {
    pub fn get_size(&self) -> usize { 0 }
    pub fn get_source(&self) -> IpAddr { IpAddr::V4(std::net::Ipv4Addr::UNSPECIFIED) }
    pub fn get_sequence(&self) -> PingSequence { PingSequence(0) }
    pub fn get_ttl(&self) -> u8 { 0 }
    pub fn get_identifier(&self) -> PingIdentifier { PingIdentifier(0) }
    pub fn get_max_hop_limit(&self) -> u8 { 0 }
}
