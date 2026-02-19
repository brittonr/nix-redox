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

// Helper function to apply static network configuration
// Performs best-effort writes (continues even if one fails)
fn apply_static_config(iface: &str, address: &str, gateway: &str, dns: &str) {
    let addr_set_path = format!("/scheme/netcfg/ifaces/{}/addr/set", iface);
    let route_add_path = "/scheme/netcfg/route/add";
    let nameserver_path = "/scheme/netcfg/resolv/nameserver";

    let addr_content = format!("{}/24", address);
    let route_content = format!("default via {}", gateway);

    // Best-effort writes - continue even if one fails
    let _ = write_scheme(&addr_set_path, &addr_content);
    let _ = write_scheme(route_add_path, &route_content);
    let _ = write_scheme(nameserver_path, dns);
}

// Subcommand: auto
// Auto-configure network with DHCP and static fallback
fn cmd_auto() -> i32 {
    // Wait for eth0 to appear (30 attempts × 200ms = 6 seconds)
    if !wait_for_interface("eth0", 30, 200) {
        eprintln!("netcfg-auto: eth0 not found");
        return 0; // Not a fatal error
    }

    // Wait for DHCP (15 attempts × 500ms = 7.5 seconds)
    eprintln!("netcfg-auto: Waiting for DHCP...");
    let addr_list_path = "/scheme/netcfg/ifaces/eth0/addr/list";

    for _ in 0..15 {
        // Try to read the DHCP-assigned address
        if let Ok(content) = read_config(addr_list_path) {
            if !content.is_empty() {
                eprintln!("netcfg-auto: DHCP configured: {}", content);
                return 0;
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

    apply_static_config("eth0", &ip, &gateway, "1.1.1.1");
    eprintln!("netcfg-auto: Static config applied ({})", ip);

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

    apply_static_config(iface, address, gateway, "1.1.1.1");
    eprintln!("netcfg-static: Network ready ({})", address);

    0
}

// Subcommand: cloud
// Configure for Cloud Hypervisor (expects eth0 to exist immediately)
fn cmd_cloud() -> i32 {
    eprintln!("Configuring network for Cloud Hypervisor...");

    // Check if eth0 exists (no waiting)
    let mac_path = "/scheme/netcfg/ifaces/eth0/mac";
    if !Path::new(mac_path).exists() {
        eprintln!("Error: eth0 not found");
        return 1;
    }

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

    apply_static_config("eth0", &ip, &gateway, "1.1.1.1");
    eprintln!("Network configured: {}/24 via {}", ip, gateway);

    0
}

fn print_usage() {
    eprintln!("Usage: netcfg-setup <COMMAND> [OPTIONS]");
    eprintln!();
    eprintln!("Commands:");
    eprintln!("  auto                                      Auto-configure network (DHCP with static fallback)");
    eprintln!("  static --interface <IF> --address <ADDR> --gateway <GW>");
    eprintln!("                                            Configure static network");
    eprintln!("  cloud                                     Configure for Cloud Hypervisor");
    eprintln!();
    eprintln!("Examples:");
    eprintln!("  netcfg-setup auto");
    eprintln!("  netcfg-setup static --interface eth0 --address 10.0.0.5 --gateway 10.0.0.1");
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
