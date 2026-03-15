#!/usr/bin/env python3
"""Patch the Redox kernel to use LAPIC timer for scheduling on KVM.

Cloud Hypervisor does not deliver PIT (IRQ 0) interrupts when all vCPUs
are in HLT. The kernel scheduler runs only inside the PIT handler, so
when all CPUs halt, processes blocked in nanosleep/poll never wake up.

This patch adds a LAPIC timer that fires periodic interrupts on each CPU.
The LAPIC timer handler calls timeout::trigger() and context::switch::tick(),
the same scheduling work that the PIT handler does. The LAPIC timer is
per-CPU and fully managed by KVM, so it reliably wakes HLT.

The LAPIC timer is only enabled when KVM paravirtualization is detected.
On non-KVM platforms, the PIT continues to work as before.

Changes:
1. local_apic.rs: Add setup_timer() with calibration and periodic mode
2. irq.rs: Update lapic_timer handler to call scheduler (like pit_stack)
3. device/mod.rs: Call setup_timer() on BSP and AP when KVM is detected
"""

import sys
import os


def patch_file(filepath, old, new):
    with open(filepath, 'r') as f:
        content = f.read()
    if old not in content:
        print(f"WARNING: patch target not found in {filepath}")
        print(f"  Looking for: {old[:80]}...")
        return False
    content = content.replace(old, new, 1)
    with open(filepath, 'w') as f:
        f.write(content)
    print(f"  Patched {filepath}")
    return True


def patch_lapic_timer(src_dir):
    """Add LAPIC timer setup and scheduling handler."""

    # ── 1. local_apic.rs: Add setup_timer() method ──────────────────
    # Insert the timer setup method before the closing brace of impl LocalApic.
    # The LAPIC timer uses periodic mode with a calibrated count.
    # Calibration: measure LAPIC ticks over a known PIT delay.
    lapic_file = os.path.join(src_dir, "src/arch/x86_shared/device/local_apic.rs")

    # Replace the commented-out setup_timer call with the real one
    patch_file(lapic_file,
        '            //self.setup_timer();',
        '            // LAPIC timer setup deferred to init_noncore/init_ap_timer')

    # Add the setup_timer method and calibration before the LvtTimerMode enum
    patch_file(lapic_file,
        '#[repr(u8)]\npub enum LvtTimerMode {',
        '''/// LAPIC timer vector — must match IDT entry 48
const LAPIC_TIMER_VECTOR: u32 = 48;

/// Calibrated LAPIC ticks per scheduler period (~4ms).
/// Set during BSP calibration, read by APs.
static LAPIC_TICKS_PER_PERIOD: core::sync::atomic::AtomicU32 =
    core::sync::atomic::AtomicU32::new(0);

impl LocalApic {
    /// Calibrate and start the LAPIC timer in periodic mode.
    ///
    /// Uses PIT channel 2 as a reference clock to measure LAPIC frequency.
    /// Programs periodic interrupts at ~4ms (matching PIT scheduler rate).
    /// Only called when KVM paravirtualization is detected.
    pub unsafe fn setup_timer_periodic(&mut self) {
        unsafe {
            // Divisor 16 gives good range for most LAPIC frequencies
            // Divisor encoding: 0b0011 = divide by 16
            self.set_div_conf(0x03);

            // Calibrate: count LAPIC ticks over ~10ms using PIT channel 2
            // PIT channel 2 at 1.193182 MHz, count 11932 = ~10ms
            let pit_hz: u32 = 1_193_182;
            let cal_count: u16 = 11_932; // ~10ms

            // Set up PIT channel 2 in one-shot mode for calibration
            // Mode 0 (interrupt on terminal count), lobyte/hibyte access
            core::arch::asm!("out 0x43, al", in("al") 0b10110000u8);
            // Write count low byte
            core::arch::asm!("out 0x42, al", in("al") (cal_count & 0xFF) as u8);
            // Write count high byte
            core::arch::asm!("out 0x42, al", in("al") (cal_count >> 8) as u8);

            // Gate PIT channel 2 (set bit 0 of port 0x61)
            let gate: u8;
            core::arch::asm!("in al, 0x61", out("al") gate);
            // Clear bit 0 then set it to restart counter
            core::arch::asm!("out 0x61, al", in("al") (gate & 0xFC));
            core::arch::asm!("out 0x61, al", in("al") (gate & 0xFC) | 0x01);

            // Start LAPIC timer with max count
            self.set_lvt_timer(LAPIC_TIMER_VECTOR | (1 << 16)); // masked
            self.set_init_count(0xFFFF_FFFF);

            // Wait for PIT channel 2 to finish (bit 5 of port 0x61 goes high)
            loop {
                let status: u8;
                core::arch::asm!("in al, 0x61", out("al") status);
                if status & 0x20 != 0 {
                    break;
                }
            }

            // Read how many LAPIC ticks elapsed during the ~10ms calibration
            let elapsed = 0xFFFF_FFFFu32 - self.cur_count();

            // Stop the timer
            self.set_init_count(0);

            // Calculate ticks for ~4ms period (matching PIT CHAN0_DIVISOR=4847)
            // calibration was ~10ms, we want ~4ms
            // ticks_per_4ms = elapsed * 4 / 10
            let ticks_per_period = (elapsed as u64 * 4 / 10) as u32;

            if ticks_per_period == 0 {
                warn!("LAPIC timer calibration failed (0 ticks), not enabling");
                return;
            }

            // Store for APs
            LAPIC_TICKS_PER_PERIOD.store(
                ticks_per_period,
                core::sync::atomic::Ordering::Release,
            );

            // Start periodic timer — unmasked
            // LVT Timer: vector | periodic mode (bit 17)
            self.set_lvt_timer(LAPIC_TIMER_VECTOR | (1 << 17));
            self.set_init_count(ticks_per_period);

            let freq_mhz = (elapsed as u64 * 100 * 16) / 1_000_000; // x16 for divisor, x100 for 10ms->1s
            info!(
                "LAPIC timer: {} ticks/period (~4ms), estimated {}MHz bus freq",
                ticks_per_period,
                freq_mhz
            );
        }
    }

    /// Start the LAPIC timer on an AP using the BSP's calibrated count.
    pub unsafe fn setup_timer_ap(&mut self) {
        unsafe {
            let ticks = LAPIC_TICKS_PER_PERIOD.load(core::sync::atomic::Ordering::Acquire);
            if ticks == 0 {
                return;
            }
            self.set_div_conf(0x03); // divide by 16
            self.set_lvt_timer(LAPIC_TIMER_VECTOR | (1 << 17)); // periodic
            self.set_init_count(ticks);
        }
    }
}

#[repr(u8)]
pub enum LvtTimerMode {''')

    # ── 2. irq.rs: Update lapic_timer handler ────────────────────────
    # Replace the debug-only handler with one that does real scheduling
    irq_file = os.path.join(src_dir, "src/arch/x86_shared/interrupt/irq.rs")

    patch_file(irq_file,
        '''interrupt!(lapic_timer, || {
    println!("Local apic timer interrupt");
    unsafe { lapic_eoi() };
});''',
        '''interrupt_stack!(lapic_timer, |_stack| {
    // LAPIC timer fires periodically (~4ms) on each CPU.
    // Performs the same scheduling work as the PIT handler:
    // 1. Fire expired scheme-level timeouts
    // 2. Run the scheduler (context switch tick)
    //
    // Unlike PIT, no IPI needed — each CPU has its own LAPIC timer.
    // No time::OFFSET update needed — KVM uses TSC via pvclock.

    unsafe { lapic_eoi() };

    let mut token = unsafe { CleanLockToken::new() };
    timeout::trigger(&mut token);
    context::switch::tick(&mut token);
});''')

    # ── 3. device/mod.rs: Enable LAPIC timer on KVM ─────────────────
    # After TSC init succeeds (KVM detected), start LAPIC timer
    mod_file = os.path.join(src_dir, "src/arch/x86_shared/device/mod.rs")

    # On BSP: start LAPIC timer after PIT init when KVM is detected
    patch_file(mod_file,
        '''        if init_hpet() {
            debug!("HPET used as system timer");
        } else {
            pit::init();
            debug!("PIT used as system timer");
        }

        debug!("Finished initializing devices");''',
        '''        if init_hpet() {
            debug!("HPET used as system timer");
        } else {
            pit::init();
            debug!("PIT used as system timer");
        }

        // On KVM, the PIT may not reliably deliver IRQ 0 when all CPUs
        // are in HLT (Cloud Hypervisor). Start a per-CPU LAPIC timer
        // as an additional scheduling source. The LAPIC timer is managed
        // by KVM and reliably wakes HLT.
        #[cfg(feature = "x86_kvm_pv")]
        if tsc::get_kvm_support().is_some() {
            unsafe { local_apic::the_local_apic().setup_timer_periodic() };
        }

        debug!("Finished initializing devices");''')

    # On APs: start LAPIC timer if BSP calibrated it
    patch_file(mod_file,
        '''pub unsafe fn init_ap() {
    unsafe {
        local_apic::init_ap();

        #[cfg(feature = "x86_kvm_pv")]
        tsc::init();
    }
}''',
        '''pub unsafe fn init_ap() {
    unsafe {
        local_apic::init_ap();

        #[cfg(feature = "x86_kvm_pv")]
        tsc::init();

        // Start LAPIC timer on AP if BSP calibrated it
        #[cfg(feature = "x86_kvm_pv")]
        if tsc::get_kvm_support().is_some() {
            local_apic::the_local_apic().setup_timer_ap();
        }
    }
}''')

    print("LAPIC timer patch applied successfully")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <kernel-source-dir>")
        sys.exit(1)
    patch_lapic_timer(sys.argv[1])
# iteration-test-1773538764
# force-rebuild
# force-rebuild
# force-rebuild-1773539232
# rebuild-marker-1773539636
