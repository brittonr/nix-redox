#!/usr/bin/env python3
"""Patch usbhidd main loop for resilient interrupt transfer handling.

Problems fixed:
1. transfer_read errors crash the process (? operator propagates).
   On real xHCI hardware (Intel N100), interrupt transfers can fail
   with stall/error after the first successful transfer. When usbhidd
   exits, no more TRBs are submitted, the xHC stops polling, and
   JetKVM hidg0 writes block.

2. Usage 0x0 on keyboard page (0x07) logs a warning. This is normal:
   empty key slots in boot protocol reports contain 0x00 ("Reserved/No Event").
   The ReportHandler generates a phantom press for it on the first report.

Fix:
- Wrap transfer_read in error handling: log error, sleep, retry.
  If endpoint is stalled, attempt reset before retry.
- Map usage 0x00 on page 0x07 to a no-op (skip without warning).
- Add diagnostic eprintln! to serial for tracing transfer flow on hw.

Usage: python3 patch-usbhidd-resilient-loop.py <path-to-usbhidd-main.rs>
"""
import sys
import re


def main():
    path = sys.argv[1]

    with open(path, "r") as f:
        content = f.read()

    # 1. Add usage 0x00 handling: skip silently (no warning)
    # Insert a 0x00 => return arm before the catch-all
    old_catchall = """\
            _ => {
                log::warn!("unknown usage_page {:#x} usage {:#x}", usage_page, usage);
                return;
            }
        },"""

    new_catchall = """\
            0x00 => {
                // Reserved (No Event) - normal for empty key slots in boot protocol.
                // The ReportHandler generates this for zero-valued array entries.
                return;
            }
            _ => {
                log::warn!("unknown usage_page {:#x} usage {:#x}", usage_page, usage);
                return;
            }
        },"""

    if old_catchall not in content:
        print("WARNING: catch-all pattern not found in send_key_event, skipping usage 0x00 fix")
    else:
        content = content.replace(old_catchall, new_catchall, 1)
        print("Applied usage 0x00 silent skip")

    # 1b. Skip non-keyboard HID interfaces.
    # The JetKVM presents 3 HID interfaces (keyboard, mouse, pointer).
    # Each usbhidd instance does blocking transfer_read via xhcid's
    # single-threaded scheme loop. Mouse/pointer transfers block forever
    # (no data), starving the keyboard. Exit early for non-keyboard.
    old_set_idle_call = """\
    //TODO: do we need to set protocol to report? It fails for mice.

    //TODO: dynamically create good values, fix xhcid so it does not block on each request
    // This sets all reports to a duration of 4ms
    reqs::set_idle(&handle, 1, 0, interface_num as u16).context("Failed to set idle")?;"""

    new_set_idle_call = """\
    // Skip non-keyboard interfaces to avoid blocking xhcid's single-threaded
    // scheme loop. Mouse/pointer transfer_read calls block forever with no data.
    // protocol: 0=none/generic, 1=keyboard, 2=mouse
    eprintln!("usbhidd[{}]: interface class={} subclass={} protocol={}", interface_num, if_desc.class, if_desc.sub_class, if_desc.protocol);
    if if_desc.protocol == 2 {
        eprintln!("usbhidd[{}]: skipping mouse interface", interface_num);
        return Ok(());
    }

    //TODO: do we need to set protocol to report? It fails for mice.

    //TODO: dynamically create good values, fix xhcid so it does not block on each request
    // This sets all reports to a duration of 4ms
    eprintln!("usbhidd[{}]: set_idle...", interface_num);
    match reqs::set_idle(&handle, 1, 0, interface_num as u16) {
        Ok(()) => eprintln!("usbhidd[{}]: set_idle OK", interface_num),
        Err(e) => {
            eprintln!("usbhidd[{}]: set_idle failed: {}, continuing anyway", interface_num, e);
        }
    }"""

    if old_set_idle_call not in content:
        print("WARNING: set_idle_call pattern not found, skipping non-keyboard filter")
    else:
        content = content.replace(old_set_idle_call, new_set_idle_call, 1)
        print("Applied non-keyboard interface filter")

    # 2. Add diagnostic after ProducerHandle and before the main loop
    old_display = """\
    let mut display = ProducerHandle::new().context("Failed to open input socket")?;"""

    new_display = """\
    eprintln!("usbhidd[{}]: opening input socket...", interface_num);
    let mut display = ProducerHandle::new().context("Failed to open input socket")?;
    eprintln!("usbhidd[{}]: input socket OK", interface_num);"""

    if old_display not in content:
        print("WARNING: ProducerHandle pattern not found, skipping display diagnostic")
    else:
        content = content.replace(old_display, new_display, 1)
        print("Applied ProducerHandle diagnostic")

    # 2c. Save endpoint number for reopen + diagnostic
    old_endpoint_opt = """\
    let mut endpoint_opt = match endp_desc_opt {
        Some((endp_num, _endp_desc)) => match handle.open_endpoint(endp_num as u8) {
            Ok(ok) => Some(ok),"""

    new_endpoint_opt = """\
    eprintln!("usbhidd[{}]: opening endpoint...", interface_num);
    let mut reopen_ep: u8 = 0;
    let mut endpoint_opt = match endp_desc_opt {
        Some((endp_num, _endp_desc)) => {
            reopen_ep = endp_num as u8;
            match handle.open_endpoint(endp_num as u8) {
            Ok(ok) => Some(ok),"""

    if old_endpoint_opt not in content:
        print("WARNING: endpoint_opt pattern not found, skipping")
    else:
        content = content.replace(old_endpoint_opt, new_endpoint_opt, 1)
        print("Applied endpoint open with reopen_ep")

    # 2d. Close the extra brace from the added block
    old_endp_none = """\
        },
        None => None,
    };"""

    new_endp_none = """\
        }
        },
        None => None,
    };"""

    if old_endp_none not in content:
        print("WARNING: endpoint None arm not found, skipping brace fix")
    else:
        content = content.replace(old_endp_none, new_endp_none, 1)
        print("Applied closing brace fix")

    # 3. Replace the transfer_read + process section of the main loop
    # with error-resilient version that retries on failure.

    old_loop_body = """\
    loop {
        //TODO: get frequency from device
        //TODO: use sleeps when accuracy is better: thread::sleep(time::Duration::from_millis(10));
        let timer = time::Instant::now();
        while timer.elapsed() < time::Duration::from_millis(1) {
            thread::yield_now();
        }

        if let Some(endpoint) = &mut endpoint_opt {
            // interrupt transfer
            endpoint
                .transfer_read(&mut report_buffer)
                .context("failed to get report")?;
        } else {
            // control transfer
            reqs::get_report(
                &handle,
                report_ty,
                report_id,
                //TODO: should this be an index into interface_descs?
                interface_num as u16,
                &mut report_buffer,
            )
            .context("failed to get report")?;
        }"""

    new_loop_body = """\
    eprintln!("usbhidd[{}]: entering main loop, endpoint={}", interface_num,
        if endpoint_opt.is_some() { "interrupt" } else { "control" });
    let mut transfer_errors: u32 = 0;
    let mut transfer_count: u64 = 0;
    loop {
        //TODO: get frequency from device
        //TODO: use sleeps when accuracy is better: thread::sleep(time::Duration::from_millis(10));
        let timer = time::Instant::now();
        while timer.elapsed() < time::Duration::from_millis(1) {
            thread::yield_now();
        }

        let transfer_result = if let Some(endpoint) = &mut endpoint_opt {
            // interrupt transfer
            endpoint.transfer_read(&mut report_buffer)
        } else {
            // control transfer - wrap in compatible Result type
            match reqs::get_report(
                &handle,
                report_ty,
                report_id,
                //TODO: should this be an index into interface_descs?
                interface_num as u16,
                &mut report_buffer,
            ) {
                Ok(()) => Ok(xhcid_interface::PortTransferStatus::default()),
                Err(e) => Err(e),
            }
        };

        match transfer_result {
            Ok(status) => {
                transfer_count += 1;
                if transfer_count <= 3 {
                    eprintln!("usbhidd[{}]: transfer #{} OK ({:?})", interface_num, transfer_count, status.kind);
                }
                if transfer_errors > 0 {
                    eprintln!("usbhidd[{}]: transfer recovered after {} errors", interface_num, transfer_errors);
                    transfer_errors = 0;
                }
                // Check for stall/error status and attempt endpoint reset
                match status.kind {
                    xhcid_interface::PortTransferStatusKind::Stalled => {
                        log::warn!("endpoint stalled, attempting reset");
                        if let Some(endpoint) = &mut endpoint_opt {
                            let _ = endpoint.reset(false);
                        }
                        thread::sleep(time::Duration::from_millis(50));
                        continue;
                    }
                    xhcid_interface::PortTransferStatusKind::Unknown => {
                        log::warn!("unknown transfer status, retrying");
                        thread::sleep(time::Duration::from_millis(10));
                        continue;
                    }
                    _ => {
                        // Intel N100 xHCI workaround: reopen endpoint after each
                        // successful transfer. The xHC stops polling after ~3 transfers.
                        if reopen_ep > 0 {
                            drop(endpoint_opt.take());
                            endpoint_opt = handle.open_endpoint(reopen_ep).ok();
                        }
                    }
                }
            }
            Err(err) => {
                transfer_errors += 1;
                if transfer_errors <= 3 || transfer_errors % 100 == 0 {
                    log::warn!("transfer_read error #{}: {}", transfer_errors, err);
                }
                // Back off: short sleep then retry
                thread::sleep(time::Duration::from_millis(
                    if transfer_errors < 10 { 50 } else { 200 }
                ));
                continue;
            }
        }"""

    if old_loop_body not in content:
        print("WARNING: main loop body pattern not found, skipping resilient loop fix")
    else:
        content = content.replace(old_loop_body, new_loop_body, 1)
        print("Applied resilient transfer_read loop")

    with open(path, "w") as f:
        f.write(content)

    print("usbhidd resilient loop patch applied")


if __name__ == "__main__":
    main()
