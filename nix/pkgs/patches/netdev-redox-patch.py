#!/usr/bin/env python3
"""Patch netdev crate for Redox OS — replace with stubs."""
import os

os.makedirs("src/interface", exist_ok=True)

with open("src/lib.rs", "w") as f:
    f.write("""pub mod device;
pub mod interface;
pub mod mac;
pub use device::NetworkDevice;
pub use interface::{get_default_interface, get_interfaces, get_local_ipaddr, Interface, InterfaceType};
pub use mac::MacAddr;
pub use ipnet;
pub mod gateway {
    pub fn get_default_gateway() -> Result<super::NetworkDevice, String> {
        Err("not supported on Redox".into())
    }
}
""")

with open("src/interface/mod.rs", "w") as f:
    f.write("""use std::net::IpAddr;
pub use ipnet::{Ipv4Net, Ipv6Net};
use crate::device::NetworkDevice;
use crate::mac::MacAddr;
mod types;
pub use types::InterfaceType;

#[derive(Debug, Clone)]
pub struct Interface {
    pub index: u32,
    pub name: String,
    pub friendly_name: Option<String>,
    pub description: Option<String>,
    pub if_type: InterfaceType,
    pub mac_addr: Option<MacAddr>,
    pub ipv4: Vec<Ipv4Net>,
    pub ipv6: Vec<Ipv6Net>,
    pub flags: u32,
    pub transmit_speed: Option<u64>,
    pub receive_speed: Option<u64>,
    pub gateway: Option<NetworkDevice>,
    pub dns_servers: Vec<IpAddr>,
    pub default: bool,
}
impl Interface {
    pub fn is_up(&self) -> bool { false }
    pub fn is_running(&self) -> bool { false }
    pub fn is_loopback(&self) -> bool { false }
    pub fn is_point_to_point(&self) -> bool { false }
    pub fn is_multicast(&self) -> bool { false }
    pub fn is_broadcast(&self) -> bool { false }
    pub fn is_tun_tap(&self) -> bool { false }
    pub fn is_physical_interface(&self) -> bool { false }
}
pub fn get_default_interface() -> Result<Interface, String> {
    Err("not supported on Redox".into())
}
pub fn get_interfaces() -> Vec<Interface> {
    Vec::new()
}
pub fn get_local_ipaddr() -> Option<IpAddr> {
    None
}
""")

with open("src/interface/types.rs", "w") as f:
    f.write("""#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InterfaceType {
    Unknown, Ethernet, TokenRing, Fddi, BasicIsdn, PrimaryIsdn,
    Ppp, Loopback, Ethernet3Megabit, Slip, Atm, GenericModem,
    FastEthernetT, Isdn, FastEthernetFx, Wireless80211,
    AsymmetricDsl, RateAdaptDsl, SymmetricDsl, VeryHighSpeedDsl,
    IPOverAtm, GigabitEthernet, Tunnel, MultiRateSymmetricDsl,
    HighPerformanceSerialBus, Wman, Wwanpp, Wwanpp2,
}
impl Default for InterfaceType {
    fn default() -> Self { InterfaceType::Unknown }
}
""")

# Remove platform-specific modules
import shutil
for d in ["src/sys", "src/db", "src/gateway"]:
    if os.path.exists(d):
        shutil.rmtree(d)

with open("src/device.rs", "w") as f:
    f.write("""use std::net::{Ipv4Addr, Ipv6Addr};
use crate::mac::MacAddr;
#[derive(Debug, Clone)]
pub struct NetworkDevice {
    pub mac_addr: MacAddr,
    pub ipv4: Vec<Ipv4Addr>,
    pub ipv6: Vec<Ipv6Addr>,
}
impl NetworkDevice {
    pub fn new() -> Self {
        NetworkDevice { mac_addr: MacAddr::zero(), ipv4: Vec::new(), ipv6: Vec::new() }
    }
}
impl Default for NetworkDevice { fn default() -> Self { Self::new() } }
""")

with open("src/mac.rs", "w") as f:
    f.write("""#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct MacAddr(pub u8, pub u8, pub u8, pub u8, pub u8, pub u8);
impl MacAddr {
    pub fn new(a: u8, b: u8, c: u8, d: u8, e: u8, f: u8) -> Self { MacAddr(a,b,c,d,e,f) }
    pub fn zero() -> Self { MacAddr(0,0,0,0,0,0) }
    pub fn octets(&self) -> [u8; 6] { [self.0, self.1, self.2, self.3, self.4, self.5] }
}
impl std::fmt::Display for MacAddr {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "{:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}", self.0, self.1, self.2, self.3, self.4, self.5)
    }
}
""")
