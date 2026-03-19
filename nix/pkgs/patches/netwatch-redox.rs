// Redox OS stub for netwatch network monitoring.
// Redox has no netlink or route monitoring — return empty data.

use std::collections::HashMap;
use std::net::IpAddr;
use super::actor::NetworkMessage;
use tokio::sync::mpsc;

#[derive(Debug)]
pub(super) struct RouteMonitor;

impl RouteMonitor {
    pub(super) fn new(_sender: mpsc::Sender<NetworkMessage>) -> Result<Self, Error> {
        Ok(RouteMonitor)
    }
}

#[derive(Debug)]
pub enum Error {
    NotSupported,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "network monitoring not supported on Redox")
    }
}

impl std::error::Error for Error {}

pub(super) fn is_interesting_interface(_name: &str) -> bool { true }
