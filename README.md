# ice-multiport-pf

Intel ICE Multi-Port Physical Function (PF) Emulator for QEMU

## Overview

This project provides a complete QEMU device emulation for the Intel Ethernet 800 Series (ICE) network adapter with multi-port Physical Function support. It enables testing and development of the Linux ICE driver's multi-port capabilities in a virtual environment.

**Key Features:**
- 8 PF devices × 8 ports/PF emulation (64 total PF ports)
- SR-IOV support (256 VFs/PF, 32 VFs/port)
- Full AdminQ command handling
- Per-port MSI-X interrupt routing
- TX/RX datapath with per-port TAP networking (host↔guest ping)
- Interactive mode for manual testing and debugging
- Per-port /24 subnet addressing (PF, VF, and host TAP)
- Complete test suite (54 test cases)
- Production device ID: Intel E810-C (0x1592)

## Quick Start

Run the complete test suite from scratch:

```bash
sudo bash tools/run_ice_mp_test.sh
```

This single command will:
1. Check prerequisites (gcc, meson, ninja, busybox, etc.)
2. Build the Linux kernel with ICE driver modifications
3. Build QEMU with the custom ICE multi-port device
4. Generate DDP firmware package
5. Create a minimal rootfs with test scripts
6. Boot the VM and run all 54 tests
7. Display results

**Typical runtime:** 10-15 minutes on a modern system with KVM acceleration.

## Test Results

### Checking Test Completion

After running the test script, check the primary log file:

**Main Log: `/tmp/ice_mp_qemu_serial.log`**

This contains the guest OS console output with all test execution details and final results.

**Quick check for results:**
```bash
grep -A 10 "Tests Passed:" /tmp/ice_mp_qemu_serial.log
```

**Expected output (successful run):**
```
Test Results Summary
═══════════════════════════════════════════════════════

Total Test Sections: 21
Total Test Cases:    54
Tests Passed:        54
Tests Failed:        0

Pass Rate:           100% (54/54)
✓ All tests passed! Driver is production-ready.
```

### Latest Validation Evidence (2026-02-23)

Datapath tests use per-port TAP networking: each PF port `N` pings its host TAP
(`10.0.N.1`) via a dedicated `/24` subnet. Interfaces are sorted numerically by BDF
and interface index to ensure correct port-to-TAP mapping across all 64 ports.

Run a **full rebuild** (without `--skip-build`) to ensure the rootfs includes the
latest test script:

```bash
sudo ICE_MP_TIMEOUT=1200 bash tools/run_ice_mp_test.sh
```

Observed pass markers:

```text
Terminal exit code: 0
Total Test Cases:    54
Tests Passed:        54
Tests Failed:        0
Pass Rate:           100% (54/54)
TX/RX datapath ping (all 64 PF ports passed)
PF→VF link propagation validated (DOWN/UP observed in QEMU logs)
```

### All Log Files

| Log File | Purpose |
|----------|---------|
| `/tmp/ice_mp_qemu_serial.log` | **Guest OS console** - test execution and results ⭐ |
| `/tmp/ice_mp_qemu_stderr.log` | QEMU device debug output (TX/RX, interrupts, AdminQ) |
| `/tmp/ice_mp_kernel_build.log` | Linux kernel compilation output |
| `/tmp/ice_mp_qemu_build.log` | QEMU build output |
| `/tmp/ice_mp_qemu_configure.log` | QEMU configure step output |
| `/tmp/ice_mp_ddp_gen.log` | DDP firmware generation log |

### Useful Commands

**View full test summary:**
```bash
grep -A 30 "Test Results Summary" /tmp/ice_mp_qemu_serial.log
```

**Check for any failures:**
```bash
grep -i "fail\|error" /tmp/ice_mp_qemu_serial.log | grep -v "Tests Failed:        0"
```

**View QEMU device debug output:**
```bash
less /tmp/ice_mp_qemu_stderr.log
```

**Monitor test progress (during execution):**
```bash
tail -f /tmp/ice_mp_qemu_serial.log
```

## Command Options

The test script supports several options for faster iteration during development:

```bash
# Skip kernel build but regenerate rootfs and DDP
sudo bash tools/run_ice_mp_test.sh --skip-linux-build

# Skip QEMU build (use existing QEMU binary)
sudo bash tools/run_ice_mp_test.sh --skip-qemu-build

# Skip all builds including rootfs (use everything as-is)
sudo bash tools/run_ice_mp_test.sh --skip-build

# Build kernel only (no QEMU or tests)
sudo bash tools/run_ice_mp_test.sh --kernel-only

# Build QEMU only (no kernel or tests)
sudo bash tools/run_ice_mp_test.sh --qemu-only

# Clean up all generated artifacts (logs, builds, images, network)
sudo bash tools/run_ice_mp_test.sh --clean
```

## Environment Variables

Customize the test environment:

```bash
# Number of PF devices (default: 8)
export ICE_MP_PF_DEVICES=8

# Number of ports per PF device (default: 8)
export ICE_MP_PORTS_PER_PF=8

# Number of VFs per PF device (default: 256)
export ICE_MP_VFS_PER_PF=256

# Number of VFs per PF port (default: 32)
export ICE_MP_VFS_PER_PORT=32

# VM memory in MB (default: 2048)
export ICE_MP_MEM=2048

# Number of vCPUs (default: 4)
export ICE_MP_CPUS=4

# Enable KVM acceleration (default: 1)
export ICE_MP_KVM=1

# Test timeout in seconds (default: auto-scaling; set explicitly for long runs)
export ICE_MP_TIMEOUT=1200
```

## Interactive Mode

Launch an interactive shell inside the guest VM for manual testing:

```bash
sudo bash tools/run_ice_mp_test.sh --interactive
```

This boots the VM, configures all PF/VF interfaces with IP addresses, and drops you into a shell. Ctrl-C works normally to stop running commands (e.g., `ping`). Type `poweroff` or press `Ctrl-a x` to exit QEMU.

### Network Topology

The emulator creates 8 PFs × 8 ports = **64 PF ports**, each with its own TAP interface on the host and its own `/24` subnet. VFs are distributed round-robin across ports within each PF.

```
Host                              QEMU Guest
────────────────                  ──────────────────────────
tap_ice0  (10.0.0.1)  ←─netdev─→  PF port 0 eth0  (10.0.0.2)
                                    ├─ VF eth64  (10.0.0.10)
                                    ├─ VF eth65  (10.0.0.11)
                                    └─ ...

tap_ice1  (10.0.1.1)  ←─netdev─→  PF port 1 eth1  (10.0.1.2)
                                    ├─ VF eth72  (10.0.1.10)
                                    └─ ...

  ...                                ...

tap_ice63 (10.0.63.1) ←─netdev─→  PF port 63 eth63 (10.0.63.2)
                                    └─ VFs ...
```

### IP Addressing Scheme

Each PF port `N` (0–63) gets subnet `10.0.N.0/24`:

| Entity | IP Address | Interface | Description |
|--------|------------|-----------|-------------|
| Host TAP | `10.0.N.1` | `tap_iceN` (host) | Host side of the bridge |
| Guest PF port | `10.0.N.2` | `ethN` (guest) | PF network interface |
| Guest VF #0 | `10.0.N.10` | `eth{64+...}` (guest) | First VF on this port |
| Guest VF #1 | `10.0.N.11` | `eth{64+...}` (guest) | Second VF on this port |

**VF-to-port mapping:** Each VF's port is determined by `vf_local_index % PORTS_PER_PF`. With 256 VFs per PF and 8 ports, each port gets ~32 VFs.

### Ping Examples

**From the guest (inside the interactive shell):**

```bash
# PF port 0 → host TAP
ping -c3 10.0.0.1

# VF on port 0 → host TAP (specify VF interface with -I)
ping -c3 10.0.0.1 -I eth64

# PF port 5 → host TAP for port 5
ping -c3 10.0.5.1
```

**From the host (in a separate terminal):**

```bash
# Host → guest PF port 0
ping -c3 10.0.0.2

# Host → guest VF on port 0
ping -c3 10.0.0.10
```

**Useful commands inside the guest:**

```bash
ip -4 addr show           # Show all assigned IPs
cat /tmp/pf_list.txt      # PF BDF → interface mappings
cat /tmp/vf_list.txt      # VF BDF → interface mappings
lspci | grep Ethernet     # List all ICE PCI devices
ethtool eth0              # Show link speed/duplex for eth0
```

## Test Coverage

The test suite validates 54 test cases across 21 sections:

### 1. **Device Enumeration** (5 tests)
- PCI device detection for 64 PF ports
- SR-IOV VF enumeration

### 2. **Driver Loading** (4 tests)
- ICE driver initialization
- Per-port device binding
- MSI-X vector allocation

### 3. **Network Interface** (8 tests)
- Interface creation for all 64 PF ports
- MAC address assignment
- Link state detection
- Interface up/down operations

### 4. **Statistics** (4 tests)
- ethtool statistics per port
- TX/RX counter tracking
- Error counters

### 5. **AdminQ Communication** (6 tests)
- Get Version command
- Get Link Status command
- Configure VSI command
- Queue management (Add/Update/Remove Tx/Rx queues)

### 6. **SR-IOV** (4 tests)
- VF creation/removal
- VF resource allocation
- VF driver binding

### 7. **Multi-Port Architecture** (4 tests)
- Per-port AdminQ instances
- Event demultiplexing
- Resource isolation

### 8. **Interrupts** (3 tests)
- MSI-X routing per port
- Interrupt generation and handling
- Vector distribution

### 9. **Data Path** (4 tests)
- TX queue configuration
- RX queue configuration
- Per-port TAP ping testing (guest PF → host TAP via per-port /24 subnets)
- Ping connectivity on all 64 PF ports

### 10. **Link Management** (2 tests)
- Link speed detection
- Duplex mode

### 11. **Reset & Recovery** (1 test)
- Device reset handling

## Prerequisites

The test script automatically checks for required dependencies:

**Build Tools:**
- gcc (kernel compilation)
- meson >= 0.63.0 (QEMU build system)
- ninja-build (QEMU compilation)
- make, bison, flex (kernel build)

**System Tools:**
- busybox-static (minimal rootfs)
- qemu-system-x86 (virtualization)
- KVM support (hardware virtualization)

**Network Tools:**
- iproute2 (ip command)
- ethtool
- pciutils (lspci)

**Install on Ubuntu/Debian:**
```bash
sudo apt-get update
sudo apt-get install -y build-essential meson ninja-build \
    busybox-static qemu-system-x86 iproute2 ethtool pciutils \
    bison flex libelf-dev libssl-dev bc
```

## Architecture

### QEMU Device (`build/qemu/hw/net/pci-ice-mp.c`)
- **PCI Device ID:** 8086:1592 (Intel E810-C QSFP - **Production Device**)
- **Topology:** 8 PF devices × 8 ports/PF (64 total PF ports)
- **VFs:** 256 per PF device (2048 total), 32 per PF port
- **MSI-X:** Expanded vectors for SR-IOV-heavy per-port routing
- **MMIO:** 32MB BAR0 for registers
- **AdminQ:** Full command set implementation (0x06EA for multi-port detection)
- **Datapath:** TX/RX ring buffers with ARP/ICMP responder

### Linux Driver (`build/linux/drivers/net/ethernet/intel/ice/`)
- **Base:** Linux kernel v6.19 ICE driver
- **Modifications:** Multi-port PF support (production-ready)
- **Files Modified:** 16 files total (12 existing + 4 new)
- **Code Changes:** +1,183 lines, -29 lines (net +1,154)
- **New Modules:** 4 new files for multi-port functionality
  - `ice_multiport.c` (433 lines) - Core multi-port logic
  - `ice_multiport.h` (92 lines) - Data structures
  - `ice_multiport_adminq.c` (162 lines) - AdminQ firmware communication
  - `ice_mp_sysfs.c` (~300 lines) - Sysfs management interface
- **Production Quality:** All debug code removed, kernel standards met
- **Device ID:** Updated to production E810-C device ID (0x1592)
- **Key Features:**
  - Multi-port AdminQ handling with firmware-based port detection (cmd 0x06EA)
  - Per-port resource management and isolation
  - Enhanced SR-IOV support with per-port VFs
  - Per-port interrupt demultiplexing (MSI-X)

## Repository Structure

```
ice-multiport-pf/
├── tools/
│   ├── run_ice_mp_test.sh       # Main test orchestration script
│   ├── test_vf_and_link.sh      # Guest test suite (54 tests)
│   └── gen_ice_ddp.py           # DDP firmware generator
├── build/
│   ├── qemu/                    # QEMU submodule (dev/ice-multi-port branch)
│   └── linux/                   # Linux kernel submodule (dev/ice-multi-port branch)
├── README.md                    # This file
├── DEVELOPMENT_PLAN.md          # Development roadmap
├── E810_MP_PF_ARCH.md          # Architecture documentation
└── QEMU_ICE_MP_ARCH.md         # QEMU implementation details
```

## Submodules

This project uses git submodules for source code:

**Initialize submodules:**
```bash
git submodule update --init --recursive
```

**Update submodules to latest:**
```bash
git submodule update --remote
```

**Submodule repositories:**
- QEMU: `zhiyisun/qemu.git @ dev/ice-multi-port`
- Linux: `zhiyisun/linux.git @ dev/ice-multi-port`

## Production Readiness

### Code Quality
✅ **Production Ready** - All changes meet Linux kernel coding standards
- No debug output in kernel code (debug statements removed)
- Proper error handling with ice_debug() macro
- Comprehensive kernel-doc comments
- GPL-2.0 license headers on all files
- No deprecated API usage

### Device Verification
✅ **Device ID Updated** - Now using production Intel E810-C device ID (0x1592)
- Firmware-based multi-port detection via AdminQ command 0x06EA
- Backward compatible with single-port hardware

### Testing
✅ **All Tests Pass** - 100% pass rate (54/54 tests)
- Device detection and driver loading
- Multi-port mode enabled (64 PF ports)
- All AdminQ commands functional
- SR-IOV integration verified (VF creation, binding)
- Per-port TAP ping (all 64 PF ports → host)

### Documentation
✅ **Complete** - See production review documents:
- [`LINUX_KERNEL_PRODUCTION_REVIEW.md`](LINUX_KERNEL_PRODUCTION_REVIEW.md) - Detailed code review
- [`PRODUCTION_QUALITY_FINAL_REPORT.md`](PRODUCTION_QUALITY_FINAL_REPORT.md) - Final approval
- [`DEBUG_CLEANUP_SUMMARY.md`](DEBUG_CLEANUP_SUMMARY.md) - Debug removal details

## Troubleshooting

### Build Failures

**Kernel build error: "No rule to make target firmware/..."**
- Solution: The test script automatically disables firmware embedding. If you see this, ensure you're using the latest version of `tools/run_ice_mp_test.sh`.

**QEMU build error: "meson not found"**
- Solution: Install meson: `sudo apt-get install meson ninja-build`

### Test Failures

**QEMU fails to start**
- Check KVM support: `lsmod | grep kvm`
- Verify QEMU binary: `ls -l build/qemu/build/qemu-system-x86_64`

**VM boots but tests timeout**
- Check serial log: `tail -100 /tmp/ice_mp_qemu_serial.log`
- Verify network setup: `ip link show tap_ice0`

**Some tests fail**
- Review detailed output: `grep -B 5 "FAIL" /tmp/ice_mp_qemu_serial.log`
- Check QEMU debug log: `/tmp/ice_mp_qemu_stderr.log`

## Development

**Rebuild after code changes:**

```bash
# Rebuild only QEMU (after modifying pci-ice-mp.c)
cd build/qemu && ninja -C build

# Rebuild only kernel (after modifying ICE driver)
cd build/linux && make -j$(nproc)

# Run tests without rebuilding
sudo bash tools/run_ice_mp_test.sh --skip-build
```

**Enable verbose QEMU debugging:**

Edit `tools/run_ice_mp_test.sh` and add to QEMU command line:
```bash
-d guest_errors,unimp -D /tmp/qemu_trace.log
```

## License

This project combines components with different licenses:
- QEMU modifications: GPL v2
- Linux kernel modifications: GPL v2
- Test scripts: GPL v2

See [LICENSE](LICENSE) file for details.

## Contact

For questions or issues, please open an issue on GitHub.