## 1. Serial Console Investigation (Linux Pre-boot)

- [ ] 1.1 Boot a Linux live USB on the LattePanda Mu + Carrier Lite
- [ ] 1.2 Run `dmesg | grep -i uart` and `cat /proc/ioports | grep -i serial` to identify UART routing (legacy COM1 at 0x3F8 vs PCI HSUART vs alternative I/O port)
- [ ] 1.3 Run `lspci -nn` to capture all PCI device IDs (NIC, HDA, xHCI, SDHCI, HSUART) for the pcid registry
- [ ] 1.4 If HSUART: note the PCI device ID and BAR address. If alternative I/O port: note the address.
- [ ] 1.5 Test kernel serial output by configuring the correct port address or adding HSUART support
- [ ] 1.6 Document UART findings in `docs/bare-metal-lattepanda-mu.md`

## 2. AML Match Opcode Implementation

- [ ] 2.1 Study the ACPI spec section 20.2.5.4 (DefMatch) for argument format and semantics
- [ ] 2.2 Design the multi-phase parsing approach: read SearchPkg TermArg, then read MatchOp1 byte in retirement handler, start next TermArg, etc.
- [ ] 2.3 Add `ResolveBehaviour::ByteData` or use `OpInFlight::new_with` with pre-loaded byte args to handle the interleaved byte/TermArg pattern
- [ ] 2.4 Implement the six match operators (MTR, MEQ, MLE, MLT, MGE, MGT) as a comparison function
- [ ] 2.5 Implement the Match retirement handler: iterate SearchPkg from StartIndex, apply both conditions, return index or ONES
- [ ] 2.6 Test in QEMU with a synthetic DSDT containing Match opcodes
- [ ] 2.7 Test on LattePanda Mu — verify acpid loads DSDT/SSDT without errors and populates the ACPI namespace

## 3. Post-Switchroot Hang Debug

- [ ] 3.1 Enable kernel syscall debug tracing (`kernelSyscallDebug = true`) with process filter for pcid, xhcid, vesad, nvmed, rtl8168d
- [ ] 3.2 Boot with acpid (using Match stub or full implementation) and capture serial/HDMI trace output
- [ ] 3.3 Identify which process is blocking and on which syscall (futex, open, read, etc.)
- [ ] 3.4 Determine if the hang is caused by: (a) incomplete AML namespace, (b) IRQ routing failure, (c) BAR mapping issue, or (d) driver-specific init blocking
- [ ] 3.5 Fix the identified blocking issue

## 4. vesad Framebuffer Mapping

- [ ] 4.1 Verify vesad receives FRAMEBUFFER_* environment variables via `inherit_envs` (add debug logging)
- [ ] 4.2 Debug the physmap failure — check if the kernel rejects the GOP physical address mapping without ACPI memory region tables
- [ ] 4.3 If physmap fails: investigate whether the kernel needs UEFI memory map entries (not ACPI) to validate the framebuffer region
- [ ] 4.4 Test vesad with working ACPI (after Match implementation) to confirm framebuffer mapping succeeds with proper memory maps

## 5. USB Input Chain

- [ ] 5.1 Add a timeout (5 seconds) to usbhidd's `ProducerHandle::new()` — if `/scheme/input/producer` doesn't open, exit with error instead of blocking
- [ ] 5.2 Fix xhcid sub-driver paths: use a PATH-based lookup that works in both initfs and rootfs, or set PATH in xhcid's environment before spawning sub-drivers
- [ ] 5.3 Verify the full input chain: vesad (display:) → inputd (input:) → usbhidd (keyboard) → fbcond (console) → getty (login)
- [ ] 5.4 Test keyboard input at the `redox login:` prompt via JetKVM and physical USB keyboard

## 6. Integration Verification

- [ ] 6.1 Boot LattePanda Mu with full ACPI support (Match implemented, vesad working, input chain complete)
- [ ] 6.2 Verify login via USB keyboard on HDMI console
- [ ] 6.3 Verify serial console login via UART
- [ ] 6.4 Verify Ethernet networking (rtl8168d loads, DHCP lease acquired)
- [ ] 6.5 Verify NVMe detection (if M.2 SSD installed)
- [ ] 6.6 Update `examples/lattepanda-mu/configuration.nix` to re-enable acpid and remove workarounds
- [ ] 6.7 Document all findings and remaining issues in `docs/bare-metal-lattepanda-mu.md`
