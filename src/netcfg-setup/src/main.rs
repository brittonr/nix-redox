use std::fs;
use std::io;
use std::path::Path;
use std::thread;
use std::time::Duration;

// Helper function to wait for a network interface to appear
// Polls /scheme/netcfg/ifaces/{iface}/mac for existence
fn wait_for_interface(iface: &str, attempts: u32, interval_ms: u64) -> bool {
    let mac_path = format!("/scheme/netcfg/ifaces/{}/mac", iface);
    let interval = Duration::from_millis(interval_ms);

    for _ in 0..attempts {
        if Path::new(&mac_path).exists() {
            return true;
        }
        thread::sleep(interval);
    }
    false
}

// Discover the first network interface by listing /scheme/netcfg/ifaces/.
// Skips "lo" (loopback). Returns None if the directory doesn't exist or is empty.
fn discover_first_interface() -> Option<String> {
    let entries = fs::read_dir("/scheme/netcfg/ifaces").ok()?;
    for entry in entries {
        if let Ok(entry) = entry {
            let name = entry.file_name().to_string_lossy().to_string();
            if name != "lo" {
                return Some(name);
            }
        }
    }
    None
}

// Wait for any non-loopback interface to appear.
// Polls /scheme/netcfg/ifaces/ directory, returns the first interface found.
fn wait_for_any_interface(attempts: u32, interval_ms: u64) -> Option<String> {
    let interval = Duration::from_millis(interval_ms);

    for _ in 0..attempts {
        if let Some(name) = discover_first_interface() {
            return Some(name);
        }
        thread::sleep(interval);
    }
    None
}

// Helper function to write to a scheme path with error handling
// Prints error to stderr but returns Result for caller to decide how to proceed
fn write_scheme(path: &str, content: &str) -> Result<(), io::Error> {
    match fs::write(path, content) {
        Ok(_) => Ok(()),
        Err(e) => {
            eprintln!("Error writing to {}: {}", path, e);
            Err(e)
        }
    }
}

// Helper function to read a config file and trim whitespace
fn read_config(path: &str) -> Result<String, io::Error> {
    fs::read_to_string(path).map(|s| s.trim().to_string())
}

// Read the DNS server from /etc/net/dns (first line).
// Falls back to "1.1.1.1" if the file is missing or empty.
fn read_dns_config() -> String {
    read_config("/etc/net/dns")
        .ok()
        .and_then(|s| s.lines().next().map(|l| l.trim().to_string()))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "1.1.1.1".to_string())
}

// Read the netmask for an interface from /etc/net/{iface}/netmask.
// Falls back to "24" if the file is missing or empty.
// Accepts either CIDR prefix ("24") or dotted decimal ("255.255.255.0")
// and converts dotted decimal to CIDR prefix for smolnetd.
fn read_netmask_config(iface: &str) -> String {
    let raw = read_config(&format!("/etc/net/{}/netmask", iface))
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "24".to_string());

    // Convert dotted decimal to CIDR if needed
    if raw.contains('.') {
        dotted_to_cidr(&raw).unwrap_or_else(|| "24".to_string())
    } else {
        raw
    }
}

// Convert dotted-decimal netmask (e.g. "255.255.255.0") to CIDR prefix (e.g. "24").
fn dotted_to_cidr(mask: &str) -> Option<String> {
    let octets: Vec<u8> = mask
        .split('.')
        .filter_map(|s| s.parse().ok())
        .collect();
    if octets.len() != 4 {
        return None;
    }
    let bits: u32 = ((octets[0] as u32) << 24)
        | ((octets[1] as u32) << 16)
        | ((octets[2] as u32) << 8)
        | (octets[3] as u32);
    Some(bits.count_ones().to_string())
}

// Helper function to apply static network configuration
// Reads DNS from /etc/net/dns and netmask from /etc/net/{iface}/netmask.
// Performs best-effort writes (continues even if one fails).
fn apply_static_config(iface: &str, address: &str, gateway: &str) {
    let addr_set_path = format!("/scheme/netcfg/ifaces/{}/addr/set", iface);
    let route_add_path = "/scheme/netcfg/route/add";
    let nameserver_path = "/scheme/netcfg/resolv/nameserver";

    let prefix = read_netmask_config(iface);
    let dns = read_dns_config();
    let addr_content = format!("{}/{}", address, prefix);
    let route_content = format!("default via {}", gateway);

    // Best-effort writes - continue even if one fails
    let _ = write_scheme(&addr_set_path, &addr_content);
    let _ = write_scheme(route_add_path, &route_content);
    let _ = write_scheme(nameserver_path, &dns);
}

// Subcommand: auto
// Auto-configure network with DHCP and static fallback.
// Discovers the first available interface at runtime (PCI-path names like
// "pci-0000-00-04.0_e1000") instead of assuming "eth0".
fn cmd_auto() -> i32 {
    // Wait for any interface to appear (30 attempts × 200ms = 6 seconds)
    let iface = match wait_for_any_interface(30, 200) {
        Some(name) => name,
        None => {
            eprintln!("netcfg-auto: no network interface found");
            return 0; // Not a fatal error
        }
    };
    eprintln!("netcfg-auto: found interface '{}'", iface);

    // Wait for DHCP (30 attempts × 500ms = 15 seconds)
    eprintln!("netcfg-auto: Waiting for DHCP...");
    let addr_list_path = format!("/scheme/netcfg/ifaces/{}/addr/list", iface);

    for attempt in 0..30 {
        // Try to read the DHCP-assigned address
        if let Ok(content) = read_config(&addr_list_path) {
            // smolnetd returns "Not configured" before DHCP completes.
            // Only accept responses that look like an IP address (contain a dot).
            if !content.is_empty() && content.contains('.') {
                eprintln!("netcfg-auto: DHCP configured on {}: {}", iface, content);
                return 0;
            }
            if attempt == 0 || attempt % 10 == 0 {
                eprintln!("netcfg-auto: addr/list = '{}' (attempt {})", content, attempt);
            }
        }
        thread::sleep(Duration::from_millis(500));
    }

    // DHCP timed out, try static fallback
    let ip_path = "/etc/net/cloud-hypervisor/ip";
    let gateway_path = "/etc/net/cloud-hypervisor/gateway";

    if !Path::new(ip_path).exists() {
        eprintln!("netcfg-auto: No static config available");
        return 0;
    }

    let ip = match read_config(ip_path) {
        Ok(ip) => ip,
        Err(e) => {
            eprintln!("netcfg-auto: Failed to read IP: {}", e);
            return 0;
        }
    };

    let gateway = match read_config(gateway_path) {
        Ok(gw) => gw,
        Err(e) => {
            eprintln!("netcfg-auto: Failed to read gateway: {}", e);
            return 0;
        }
    };

    apply_static_config(&iface, &ip, &gateway);
    eprintln!("netcfg-auto: Static config applied on {} ({})", iface, ip);

    0
}

// Subcommand: static
// Configure static network with explicit parameters
fn cmd_static(iface: &str, address: &str, gateway: &str) -> i32 {
    eprintln!("netcfg-static: Configuring interface {}...", iface);

    // Wait for interface to appear (30 attempts × 200ms = 6 seconds)
    if !wait_for_interface(iface, 30, 200) {
        eprintln!("netcfg-static: {} not found", iface);
        return 1;
    }

    apply_static_config(iface, address, gateway);
    eprintln!("netcfg-static: Network ready ({})", address);

    0
}

// Subcommand: cloud
// Configure for Cloud Hypervisor. Discovers the interface at runtime.
fn cmd_cloud() -> i32 {
    eprintln!("Configuring network for Cloud Hypervisor...");

    // Discover the interface (no retries — CHV driver should be ready)
    let iface = match discover_first_interface() {
        Some(name) => name,
        None => {
            eprintln!("Error: no network interface found");
            return 1;
        }
    };
    eprintln!("cloud: found interface '{}'", iface);

    // Read IP and gateway from config files
    let ip = match read_config("/etc/net/cloud-hypervisor/ip") {
        Ok(ip) => ip,
        Err(e) => {
            eprintln!("Error reading IP: {}", e);
            return 1;
        }
    };

    let gateway = match read_config("/etc/net/cloud-hypervisor/gateway") {
        Ok(gw) => gw,
        Err(e) => {
            eprintln!("Error reading gateway: {}", e);
            return 1;
        }
    };

    apply_static_config(&iface, &ip, &gateway);
    eprintln!("Network configured on {}: {} via {}", iface, ip, gateway);

    0
}

// Subcommand: dhcpd
// Discover first interface, then exec dhcpd with it.
// Used by the dhcpd-quiet wrapper to avoid hardcoding interface names.
fn cmd_dhcpd() -> i32 {
    let iface = match wait_for_any_interface(30, 200) {
        Some(name) => name,
        None => {
            eprintln!("netcfg-dhcpd: no network interface found");
            return 1;
        }
    };
    eprintln!("netcfg-dhcpd: starting dhcpd on '{}'", iface);

    // exec dhcpd — replaces this process
    use std::os::unix::process::CommandExt;
    let err = std::process::Command::new("/bin/dhcpd")
        .args(["-v", &iface])
        .exec();
    eprintln!("netcfg-dhcpd: exec dhcpd failed: {}", err);
    1
}

// Subcommand: static-auto
// Discover first interface, then apply static config.
// Like "static" but without requiring --interface.
fn cmd_static_auto(address: &str, gateway: &str) -> i32 {
    let iface = match wait_for_any_interface(30, 200) {
        Some(name) => name,
        None => {
            eprintln!("netcfg-static-auto: no network interface found");
            return 1;
        }
    };
    eprintln!("netcfg-static-auto: found interface '{}'", iface);

    apply_static_config(&iface, address, gateway);
    eprintln!("netcfg-static-auto: Network ready on {} ({})", iface, address);

    0
}

fn print_usage() {
    eprintln!("Usage: netcfg-setup <COMMAND> [OPTIONS]");
    eprintln!();
    eprintln!("Commands:");
    eprintln!("  auto                                      Auto-configure network (DHCP with static fallback)");
    eprintln!("  static --interface <IF> --address <ADDR> --gateway <GW>");
    eprintln!("                                            Configure static network on a named interface");
    eprintln!("  static-auto --address <ADDR> --gateway <GW>");
    eprintln!("                                            Discover first interface, apply static config");
    eprintln!("  dhcpd                                     Discover first interface, exec dhcpd on it");
    eprintln!("  cloud                                     Configure for Cloud Hypervisor");
    eprintln!();
    eprintln!("All commands auto-discover PCI-path interface names (e.g. pci-0000-00-04.0_e1000).");
    eprintln!();
    eprintln!("Examples:");
    eprintln!("  netcfg-setup auto");
    eprintln!("  netcfg-setup static-auto --address 10.0.0.5 --gateway 10.0.0.1");
    eprintln!("  netcfg-setup dhcpd");
    eprintln!("  netcfg-setup cloud");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 2 {
        print_usage();
        std::process::exit(1);
    }

    let exit_code = match args[1].as_str() {
        "auto" => cmd_auto(),

        "static" => {
            // Parse --interface, --address, --gateway flags
            let mut iface = None;
            let mut address = None;
            let mut gateway = None;

            let mut i = 2;
            while i < args.len() {
                match args[i].as_str() {
                    "--interface" => {
                        if i + 1 < args.len() {
                            iface = Some(args[i + 1].clone());
                            i += 2;
                        } else {
                            eprintln!("Error: --interface requires a value");
                            print_usage();
                            std::process::exit(1);
                        }
                    }
                    "--address" => {
                        if i + 1 < args.len() {
                            address = Some(args[i + 1].clone());
                            i += 2;
                        } else {
                            eprintln!("Error: --address requires a value");
                            print_usage();
                            std::process::exit(1);
                        }
                    }
                    "--gateway" => {
                        if i + 1 < args.len() {
                            gateway = Some(args[i + 1].clone());
                            i += 2;
                        } else {
                            eprintln!("Error: --gateway requires a value");
                            print_usage();
                            std::process::exit(1);
                        }
                    }
                    _ => {
                        eprintln!("Error: Unknown option '{}'", args[i]);
                        print_usage();
                        std::process::exit(1);
                    }
                }
            }

            match (iface, address, gateway) {
                (Some(i), Some(a), Some(g)) => cmd_static(&i, &a, &g),
                _ => {
                    eprintln!(
                        "Error: static command requires --interface, --address, and --gateway"
                    );
                    print_usage();
                    1
                }
            }
        }

        "static-auto" => {
            // Parse --address, --gateway flags (interface is auto-discovered)
            let mut address = None;
            let mut gateway = None;

            let mut i = 2;
            while i < args.len() {
                match args[i].as_str() {
                    "--address" => {
                        if i + 1 < args.len() {
                            address = Some(args[i + 1].clone());
                            i += 2;
                        } else {
                            eprintln!("Error: --address requires a value");
                            print_usage();
                            std::process::exit(1);
                        }
                    }
                    "--gateway" => {
                        if i + 1 < args.len() {
                            gateway = Some(args[i + 1].clone());
                            i += 2;
                        } else {
                            eprintln!("Error: --gateway requires a value");
                            print_usage();
                            std::process::exit(1);
                        }
                    }
                    _ => {
                        eprintln!("Error: Unknown option '{}'", args[i]);
                        print_usage();
                        std::process::exit(1);
                    }
                }
            }

            match (address, gateway) {
                (Some(a), Some(g)) => cmd_static_auto(&a, &g),
                _ => {
                    eprintln!(
                        "Error: static-auto command requires --address and --gateway"
                    );
                    print_usage();
                    1
                }
            }
        }

        "dhcpd" => cmd_dhcpd(),

        "cloud" => cmd_cloud(),

        "-h" | "--help" => {
            print_usage();
            0
        }

        _ => {
            eprintln!("Error: Unknown command '{}'", args[1]);
            print_usage();
            1
        }
    };

    std::process::exit(exit_code);
}
