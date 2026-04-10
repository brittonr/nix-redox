#!/usr/bin/env python3
"""Move smolnetd's daemon.ready() call until after netcfg registration.

smolnetd currently reports readiness before Smolnetd::new(), but
Smolnetd::new() is the step that registers the netcfg: scheme. Init can start
netcfg-setup immediately after the readiness signal, so boot-time network
configuration races the scheme registration and fails with ENODEV.

Usage: python3 patch-smolnetd-ready-order.py <path-to-netstack-main.rs>
"""
import sys
from pathlib import Path


def main() -> None:
    path = Path(sys.argv[1])
    content = path.read_text()

    old = """    daemon.ready();

    event_queue
        .subscribe(network_fd.raw(), EventSource::Network, EventFlags::READ)
"""
    new = """    event_queue
        .subscribe(network_fd.raw(), EventSource::Network, EventFlags::READ)
"""

    if old in content:
        content = content.replace(old, new, 1)
    elif "daemon.ready();" not in content:
        print("WARNING: daemon.ready() not found, skipping")
        return

    marker = """    let mut smolnetd = Smolnetd::new(
        network_fd,
        hardware_addr,
        ip_fd,
        udp_fd,
        tcp_fd,
        icmp_fd,
        time_fd,
        netcfg_fd,
    )
    .context("smolnetd: failed to initialize smolnetd")?;

    libredox::call::setrens(0, 0).context("smolnetd: failed to enter null namespace")?;
"""
    replacement = """    let mut smolnetd = Smolnetd::new(
        network_fd,
        hardware_addr,
        ip_fd,
        udp_fd,
        tcp_fd,
        icmp_fd,
        time_fd,
        netcfg_fd,
    )
    .context("smolnetd: failed to initialize smolnetd")?;

    daemon.ready();

    libredox::call::setrens(0, 0).context("smolnetd: failed to enter null namespace")?;
"""

    if marker in content:
        content = content.replace(marker, replacement, 1)
    elif replacement in content:
        print("smolnetd ready-order patch already applied")
        return
    else:
        print("WARNING: smolnetd init block not found, skipping")
        return

    path.write_text(content)
    print("smolnetd ready-order patch applied")


if __name__ == "__main__":
    main()
