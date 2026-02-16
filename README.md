# ice-multiport-pf

Intel ICE Multi-Port Physical Function (PF) Emulator for QEMU

## Overview

This project provides a complete QEMU device emulation for the Intel Ethernet 800 Series (ICE) network adapter with multi-port Physical Function support. It enables testing and development of the Linux ICE driver's multi-port capabilities in a virtual environment.

**Key Features:**
- 4-port Physical Function emulation
- SR-IOV support (8 Virtual Functions)
- Full AdminQ command handling
- Per-port MSI-X interrupt routing
- TX/RX datapath with ARP/ICMP loopback
- Complete test suite (45 test cases, 100% coverage)

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
6. Boot the VM and run all 45 tests
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
Total Test Cases:    45
Tests Passed:        45
Tests Failed:        0

Pass Rate:           100% (45/45)
✓ All tests passed! Driver is production-ready.
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
# Skip kernel build (use existing kernel image)
sudo bash tools/run_ice_mp_test.sh --skip-linux-build

# Skip QEMU build (use existing QEMU binary)
sudo bash tools/run_ice_mp_test.sh --skip-qemu-build

# Skip both builds (only run tests)
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
# Number of ports (default: 4)
export ICE_MP_PORTS=4

# Number of VFs per port (default: 2, max: 8 total)
export ICE_MP_VFS=2

# VM memory in MB (default: 2048)
export ICE_MP_MEM=2048

# Number of vCPUs (default: 4)
export ICE_MP_CPUS=4

# Enable KVM acceleration (default: 1)
export ICE_MP_KVM=1
```

## Test Coverage

The test suite validates 45 different aspects across 13 categories:

### 1. **Device Enumeration** (5 tests)
- PCI device detection for 4 PF ports
- SR-IOV VF enumeration

### 2. **Driver Loading** (4 tests)
- ICE driver initialization
- Per-port device binding
- MSI-X vector allocation

### 3. **Network Interface** (8 tests)
- Interface creation for all 4 ports
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
- ARP/ICMP loopback testing
- Ping connectivity on all 4 ports

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
- **PCI Device ID:** 8086:1592 (Intel E810 variant)
- **Ports:** 4 independent network functions
- **VFs:** Up to 8 total across all ports
- **MSI-X:** 64 vectors with per-port routing
- **MMIO:** 32MB BAR0 for registers
- **AdminQ:** Full command set implementation
- **Datapath:** TX/RX ring buffers with ARP/ICMP responder

### Linux Driver (`build/linux/drivers/net/ethernet/intel/ice/`)
- **Base:** Linux kernel v6.19 ICE driver
- **Modifications:** Multi-port PF support
- **Files Modified:** 16 files, +1231 lines
- **Key Features:** 
  - Multi-port AdminQ handling
  - Per-port resource management
  - Enhanced SR-IOV support

## Repository Structure

```
ice-multiport-pf/
├── tools/
│   ├── run_ice_mp_test.sh       # Main test orchestration script
│   ├── test_vf_and_link.sh      # Guest test suite (45 tests)
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