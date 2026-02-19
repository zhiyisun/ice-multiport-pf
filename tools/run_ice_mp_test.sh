#!/bin/bash

################################################################################
# ICE Multi-Port PF Driver - Comprehensive QEMU Testing Script
#
# This script automates the complete testing workflow:
# 1. Builds QEMU with custom pci-ice-mp device (if needed)
# 2. Generates DDP firmware package for driver initialization (if needed)
# 3. Creates rootfs with test dependencies including firmware directory (if needed)
# 4. Builds Linux kernel with multi-port driver support (if needed)
# 5. Sets up QEMU networking (tap device, bridge)
# 6. Boots QEMU with the custom pci-ice-mp device
# 7. Runs the comprehensive test suite inside the guest
# 8. Collects and reports test results
#
# Usage:
#   ./tools/run_ice_mp_test.sh [options]
#
# Options:
#   --kernel-only      Only build the kernel, don't run tests
#   --skip-build       Skip all builds (QEMU, DDP, rootfs, kernel), use existing artifacts
#   --skip-qemu-build  Skip QEMU build, use existing binary
#   --skip-test        Skip running tests after boot
#   --keep-vm          Keep VM running after test (for debugging)
#   --clean            Clean all generated artifacts (logs, builds, images) and exit
#   --help             Show this help message
#
# Environment Variables:
#   ICE_MP_QEMU_BIN    Path to custom qemu-system-x86_64 (default: ./build/qemu/build/qemu-system-x86_64)
#   ICE_MP_KERNEL      Path to Linux kernel (default: ./build/linux/arch/x86_64/boot/bzImage)
#   ICE_MP_ROOTFS      Path to rootfs (default: ./build/rootfs.cpio)
#   ICE_MP_DDP         Path to DDP package (default: ./build/ice.pkg)
#   ICE_MP_PF_DEVICES  Number of PF devices (default: 8)
#   ICE_MP_PORTS_PER_PF Number of ports per PF device (default: 8)
#   ICE_MP_VFS_PER_PF  Number of VFs per PF device (default: 256)
#   ICE_MP_VFS_PER_PORT Number of VFs per PF port (default: 32)
#   ICE_MP_PORTS       Optional override for total PF ports (derived by default)
#   ICE_MP_VFS         Optional override for total VFs (derived by default)
#   ICE_MP_MEM         QEMU memory in MB (default: 2048)
#   ICE_MP_CPUS        QEMU CPU count (default: 4)
#   ICE_MP_NET_TAP     TAP device name (default: tap0)
#   ICE_MP_NET_IP      TAP device IP (default: 192.168.100.1)
#   ICE_MP_GUEST_IP    Guest IP (default: 192.168.100.2)
#   ICE_MP_TIMEOUT     Test timeout in seconds (default: 300)
#
################################################################################

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$WORKSPACE_ROOT/build"

# Ensure meson from miniforge/user install is available (system meson may be too old)
for _meson_dir in "$HOME/miniforge3/bin" "$HOME/.local/bin" "/home/zhiyis/miniforge3/bin"; do
    if [ -x "$_meson_dir/meson" ]; then
        export PATH="$_meson_dir:$PATH"
        break
    fi
done

# Default configuration
KERNEL_ONLY=0
SKIP_BUILD=0
SKIP_QEMU_BUILD=0
SKIP_TEST=0
KEEP_VM=0
CLEAN_ONLY=0
HELP=0

QEMU_BIN="${ICE_MP_QEMU_BIN:-$BUILD_DIR/qemu/build/qemu-system-x86_64}"
KERNEL_PATH="${ICE_MP_KERNEL:-$BUILD_DIR/linux/arch/x86_64/boot/bzImage}"
ROOTFS_PATH="${ICE_MP_ROOTFS:-$BUILD_DIR/rootfs.cpio}"
DDP_PATH="${ICE_MP_DDP:-$BUILD_DIR/ice.pkg}"
LINUX_BUILD_DIR="$BUILD_DIR/linux"
QEMU_BUILD_DIR="$BUILD_DIR/qemu"
QEMU_BUILD_BINDIR="$QEMU_BUILD_DIR/build"

QEMU_PF_DEVICES="${ICE_MP_PF_DEVICES:-8}"
QEMU_PORTS_PER_DEVICE="${ICE_MP_PORTS_PER_PF:-8}"
QEMU_VFS_PER_DEVICE="${ICE_MP_VFS_PER_PF:-256}"
QEMU_VFS_PER_PORT="${ICE_MP_VFS_PER_PORT:-32}"
QEMU_MEM="${ICE_MP_MEM:-2048}"
QEMU_CPUS="${ICE_MP_CPUS:-4}"

QEMU_PORTS=$((QEMU_PF_DEVICES * QEMU_PORTS_PER_DEVICE))
QEMU_VFS=$((QEMU_PF_DEVICES * QEMU_VFS_PER_DEVICE))

TAP_DEVICE="${ICE_MP_NET_TAP:-tap0}"
TAP_IP="${ICE_MP_NET_IP:-192.168.100.1}"
GUEST_IP="${ICE_MP_GUEST_IP:-192.168.100.2}"
TEST_TIMEOUT="${ICE_MP_TIMEOUT:-300}"

# Logging
QEMU_LOG="/tmp/ice_mp_qemu_serial.log"
QEMU_STDERR_LOG="/tmp/ice_mp_qemu_stderr.log"
QEMU_QMP_SOCK="/tmp/ice_mp_qmp.sock"
QEMU_PID_FILE="/tmp/ice_mp_qemu.pid"
TEST_RESULTS="/tmp/ice_mp_test_results.txt"
VERIFY_VF_LINK_PROPAGATION="${ICE_MP_VERIFY_VF_LINK_PROPAGATION:-1}"

LINK_PROP_TEST_TRIGGERED=0
LINK_PROP_TEST_PORT=0

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters
TOTAL_TESTS=0
PASS_COUNT=0
FAIL_COUNT=0

################################################################################
# Utility Functions
################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $*"
}

check_file() {
    if [ ! -f "$1" ]; then
        log_error "File not found: $1"
        exit 1
    fi
}

check_dir() {
    if [ ! -d "$1" ]; then
        log_error "Directory not found: $1"
        exit 1
    fi
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "Required command not found: $1"
        exit 1
    fi
}

check_prerequisites() {
    log_info "Checking build prerequisites..."
    local missing=()

    # Build tools
    for cmd in gcc make cpio find python3; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    # QEMU build needs meson and ninja
    if [ $SKIP_BUILD -eq 0 ] && [ $SKIP_QEMU_BUILD -eq 0 ]; then
        command -v meson &>/dev/null || missing+=("meson")
        command -v ninja &>/dev/null || missing+=("ninja-build")
    fi

    # Rootfs creation needs busybox, ethtool, lspci, bash
    if [ $SKIP_BUILD -eq 0 ]; then
        command -v busybox &>/dev/null || missing+=("busybox-static")
        [ -x /usr/sbin/ethtool ] || command -v ethtool &>/dev/null || missing+=("ethtool")
        [ -x /usr/bin/lspci ] || command -v lspci &>/dev/null || missing+=("pciutils (lspci)")
    fi

    # Network setup needs ip and sudo
    command -v ip &>/dev/null || missing+=("iproute2 (ip)")
    command -v sudo &>/dev/null || missing+=("sudo")

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing prerequisites: ${missing[*]}"
        log_error "Install with: sudo apt-get install ${missing[*]}"
        exit 1
    fi

    log_success "All prerequisites found"
}

################################################################################
# Cleanup Functions
################################################################################

cleanup_old_artifacts() {
    log_info "Cleaning up ALL build artifacts for clean rebuild..."
    
    # Remove old rootfs
    if [ -f "$ROOTFS_PATH" ]; then
        rm -f "$ROOTFS_PATH"
        log_info "  Removed old rootfs"
    fi
    
    # Remove old kernel image
    if [ -f "$KERNEL_PATH" ]; then
        rm -f "$KERNEL_PATH"
        log_info "  Removed old kernel image"
    fi
    
    # Remove old DDP package
    if [ -f "$DDP_PATH" ]; then
        rm -f "$DDP_PATH"
        log_info "  Removed old DDP package"
    fi
    
    # Remove QEMU build directory for clean rebuild (only if not skipping QEMU build)
    if [ $SKIP_QEMU_BUILD -eq 0 ] && [ -d "$QEMU_BUILD_BINDIR" ]; then
        rm -rf "$QEMU_BUILD_BINDIR"
        log_info "  Removed QEMU build directory"
    fi
    
    # Remove old logs
    rm -f "$QEMU_LOG" "$QEMU_STDERR_LOG" "$QEMU_QMP_SOCK" "$QEMU_PID_FILE" "$TEST_RESULTS"
    rm -f /tmp/ice_mp_*.log
    log_info "  Removed old logs"
    
    # Kill any stray QEMU processes
    if pgrep -f "qemu-system.*ice-mp" > /dev/null 2>&1; then
        pkill -9 -f "qemu-system.*ice-mp"
        log_info "  Killed stray QEMU processes"
    fi
    
    log_success "Cleanup complete"
}

################################################################################
# Build Functions
################################################################################

build_qemu() {
    log_info "Building QEMU with pci-ice-mp device..."
    
    check_dir "$QEMU_BUILD_DIR"
    
    # Get number of CPU cores for parallel build
    local num_cores=$(nproc 2>/dev/null || echo 4)
    
    log_info "Configuring QEMU build in $QEMU_BUILD_BINDIR..."
    if ! cd "$QEMU_BUILD_DIR"; then
        log_error "Failed to enter QEMU build directory"
        return 1
    fi
    
    # QEMU requires ./configure to generate config-host.mak before meson/ninja
    # Ensure build directory is clean for ./configure
    rm -rf build
    if ! ./configure --target-list=x86_64-softmmu 2>&1 | tee /tmp/ice_mp_qemu_configure.log > /dev/null; then
        log_error "QEMU configuration failed. Check /tmp/ice_mp_qemu_configure.log"
        cd - > /dev/null
        return 1
    fi
    
    log_info "Compiling QEMU with $num_cores cores..."
    if ! ninja -C build 2>&1 | tee /tmp/ice_mp_qemu_build.log > /dev/null; then
        log_error "QEMU build failed. Check /tmp/ice_mp_qemu_build.log"
        cd - > /dev/null
        return 1
    fi
    
    cd - > /dev/null
    
    if [ -f "$QEMU_BIN" ]; then
        log_success "QEMU built successfully"
        log_info "Binary: $(ls -lh $QEMU_BIN | awk '{print $5}')"
        return 0
    else
        log_error "QEMU binary not found after build"
        return 1
    fi
}

generate_ddp_package() {
    log_info "Generating DDP firmware package..."
    
    # Always regenerate DDP package for clean builds
    
    local ddp_gen_script="$SCRIPT_DIR/gen_ice_ddp.py"
    if [ ! -f "$ddp_gen_script" ]; then
        log_error "DDP generator script not found: $ddp_gen_script"
        return 1
    fi
    
    check_command "python3"
    
    log_info "Running: python3 $ddp_gen_script $DDP_PATH"
    if ! python3 "$ddp_gen_script" "$DDP_PATH" 2>&1 | tee /tmp/ice_mp_ddp_gen.log > /dev/null; then
        log_error "DDP package generation failed. Check /tmp/ice_mp_ddp_gen.log"
        return 1
    fi
    
    if [ -f "$DDP_PATH" ]; then
        log_success "DDP package generated: $(ls -lh $DDP_PATH | awk '{print $5}')"
        return 0
    else
        log_error "DDP package not generated"
        return 1
    fi
}

show_help() {
    head -50 "$0" | grep "^# " | sed 's/^# //'
}

validate_topology() {
    local expected_vfs_per_pf

    if ! [[ "$QEMU_PF_DEVICES" =~ ^[0-9]+$ ]] || [ "$QEMU_PF_DEVICES" -le 0 ]; then
        log_error "ICE_MP_PF_DEVICES must be a positive integer (current: $QEMU_PF_DEVICES)"
        exit 1
    fi

    if ! [[ "$QEMU_PORTS_PER_DEVICE" =~ ^[0-9]+$ ]] || [ "$QEMU_PORTS_PER_DEVICE" -le 0 ]; then
        log_error "ICE_MP_PORTS_PER_PF must be a positive integer (current: $QEMU_PORTS_PER_DEVICE)"
        exit 1
    fi

    if ! [[ "$QEMU_VFS_PER_DEVICE" =~ ^[0-9]+$ ]] || [ "$QEMU_VFS_PER_DEVICE" -le 0 ]; then
        log_error "ICE_MP_VFS_PER_PF must be a positive integer (current: $QEMU_VFS_PER_DEVICE)"
        exit 1
    fi

    if ! [[ "$QEMU_VFS_PER_PORT" =~ ^[0-9]+$ ]] || [ "$QEMU_VFS_PER_PORT" -le 0 ]; then
        log_error "ICE_MP_VFS_PER_PORT must be a positive integer (current: $QEMU_VFS_PER_PORT)"
        exit 1
    fi

    expected_vfs_per_pf=$((QEMU_PORTS_PER_DEVICE * QEMU_VFS_PER_PORT))
    if [ "$QEMU_VFS_PER_DEVICE" -ne "$expected_vfs_per_pf" ]; then
        log_error "Topology mismatch: ICE_MP_VFS_PER_PF ($QEMU_VFS_PER_DEVICE) must equal ICE_MP_PORTS_PER_PF x ICE_MP_VFS_PER_PORT ($QEMU_PORTS_PER_DEVICE x $QEMU_VFS_PER_PORT = $expected_vfs_per_pf)"
        exit 1
    fi

    if [ "$QEMU_PORTS_PER_DEVICE" -gt 16 ]; then
        log_error "ICE_MP_PORTS_PER_PF must be <= 16 for current emulation limits (current: $QEMU_PORTS_PER_DEVICE)"
        exit 1
    fi

    QEMU_PORTS=$((QEMU_PF_DEVICES * QEMU_PORTS_PER_DEVICE))
    QEMU_VFS=$((QEMU_PF_DEVICES * QEMU_VFS_PER_DEVICE))

    log_info "Topology target: ${QEMU_PF_DEVICES} PF device(s), ${QEMU_PORTS_PER_DEVICE} ports/PF, ${QEMU_VFS_PER_DEVICE} VFs/PF, ${QEMU_VFS_PER_PORT} VFs/port"
    log_info "Derived totals: ${QEMU_PORTS} ports, ${QEMU_VFS} VFs"
}

################################################################################
# Build and Setup Functions
################################################################################

ensure_kernel_config() {
    if [ -f "$LINUX_BUILD_DIR/.config" ]; then
        log_info "Kernel .config already exists"
        return 0
    fi

    log_info "Generating kernel .config (defconfig + ICE driver)..."
    cd "$LINUX_BUILD_DIR"

    make defconfig > /dev/null 2>&1

    # Enable ICE multi-port driver and dependencies (built-in)
    ./scripts/config --enable CONFIG_PCI_IOV
    ./scripts/config --enable CONFIG_NET_VENDOR_INTEL
    ./scripts/config --enable CONFIG_ICE
    ./scripts/config --enable CONFIG_I40EVF
    ./scripts/config --enable CONFIG_VLAN_8021Q
    ./scripts/config --enable CONFIG_BRIDGE
    ./scripts/config --enable CONFIG_TUN
    ./scripts/config --enable CONFIG_VIRTIO_NET
    ./scripts/config --enable CONFIG_DEVTMPFS
    ./scripts/config --enable CONFIG_DEVTMPFS_MOUNT
    ./scripts/config --enable CONFIG_TMPFS
    ./scripts/config --enable CONFIG_BLK_DEV_INITRD
    ./scripts/config --enable CONFIG_PRINTK
    ./scripts/config --enable CONFIG_SERIAL_8250
    ./scripts/config --enable CONFIG_SERIAL_8250_CONSOLE

    # Firmware loading: enable runtime loading, disable embedding
    ./scripts/config --enable CONFIG_FW_LOADER
    ./scripts/config --set-str CONFIG_EXTRA_FIRMWARE ""
    ./scripts/config --set-str CONFIG_EXTRA_FIRMWARE_DIR ""

    # Resolve new dependencies
    make olddefconfig > /dev/null 2>&1

    cd - > /dev/null
    log_success "Kernel .config generated"
}

build_kernel() {
    log_info "Building Linux kernel..."
    
    if ! [ -d "$LINUX_BUILD_DIR" ]; then
        log_error "Linux build directory not found: $LINUX_BUILD_DIR"
        return 1
    fi
    
    # Ensure .config exists (generate if missing)
    ensure_kernel_config
    
    cd "$LINUX_BUILD_DIR"
    
    # Determine number of CPU cores for parallel build
    local num_cores
    num_cores=$(nproc 2>/dev/null || echo 1)
    
    # Clean old build artifacts first
    log_info "Cleaning kernel build artifacts..."
    make clean > /dev/null 2>&1 || true
    
    log_info "Compiling kernel with $num_cores cores..."
    if make -j"$num_cores" > /tmp/ice_mp_kernel_build.log 2>&1; then
        log_success "Kernel built successfully"
        log_info "Kernel: $(ls -lh $KERNEL_PATH | awk '{print $5}')"
        return 0
    else
        log_error "Kernel build failed. Check /tmp/ice_mp_kernel_build.log"
        return 1
    fi
}

# Helper function to copy a binary and all its library dependencies
copy_with_libs() {
    local binary="$1"
    local rootfs_dir="$2"
    
    if [ ! -f "$binary" ]; then
        return 1
    fi
    
    # Copy the binary itself
    local dest_dir="$rootfs_dir/bin"
    [ "$(basename $(dirname $binary))" = "sbin" ] && dest_dir="$rootfs_dir/sbin"
    mkdir -p "$dest_dir"
    cp "$binary" "$dest_dir/" 2>/dev/null || return 1
    
    # Copy all library dependencies (avoid subshell by using temp file)
    local tmpfile="/tmp/ldd_output_$$"
    ldd "$binary" 2>/dev/null > "$tmpfile"
    
    while IFS= read -r line; do
        local lib=$(echo "$line" | grep -o '/[^ ]*' | grep '\.so' | head -1)
        if [ -n "$lib" ] && [ -f "$lib" ]; then
            # Determine target directory based on source path
            if echo "$lib" | grep -q '/lib64/'; then
                mkdir -p "$rootfs_dir/lib64"
                cp -P "$lib" "$rootfs_dir/lib64/" 2>/dev/null || true
                # Also copy the realpath if it's a symlink
                if [ -L "$lib" ]; then
                    local reallib=$(readlink -f "$lib")
                    [ -f "$reallib" ] && cp "$reallib" "$rootfs_dir/lib64/" 2>/dev/null || true
                fi
            else
                mkdir -p "$rootfs_dir/lib/x86_64-linux-gnu"
                cp -P "$lib" "$rootfs_dir/lib/x86_64-linux-gnu/" 2>/dev/null || true
                if [ -L "$lib" ]; then
                    local reallib=$(readlink -f "$lib")
                    [ -f "$reallib" ] && cp "$reallib" "$rootfs_dir/lib/x86_64-linux-gnu/" 2>/dev/null || true
                fi
            fi
        fi
    done < "$tmpfile"
    
    rm -f "$tmpfile"
    return 0
}

create_rootfs() {
    log_info "Creating BusyBox-based minimal rootfs..."
    
    # Always recreate rootfs for clean builds
    
    # Ensure DDP package exists
    if [ ! -f "$DDP_PATH" ]; then
        log_error "DDP package required for rootfs creation: $DDP_PATH"
        return 1
    fi
    
    local rootfs_dir="/tmp/ice_mp_rootfs_$$"
    
    # Create minimal rootfs structure
    log_info "Creating rootfs directory structure..."
    mkdir -p "$rootfs_dir"/{bin,sbin,lib,lib64,etc,proc,sys,dev,tmp,home,root}
    mkdir -p "$rootfs_dir/lib/firmware/intel/ice/ddp"
    mkdir -p "$rootfs_dir/lib/modules"
    mkdir -p "$rootfs_dir/lib/x86_64-linux-gnu"
    
    # Use BusyBox for most utilities (single static binary)
    log_info "Installing BusyBox..."
    if command -v busybox &>/dev/null; then
        cp "$(which busybox)" "$rootfs_dir/bin/busybox"
        chmod +x "$rootfs_dir/bin/busybox"
        
        # Create symlinks for all BusyBox applets needed by test script
        cd "$rootfs_dir/bin"
        for applet in sh ash ls cat mkdir mount grep sed awk ip ping sleep chmod find wc tr head tail cut sort uniq dmesg modprobe lsmod ifconfig route xargs devmem; do
            ln -sf busybox "$applet" 2>/dev/null || true
        done
        cd - > /dev/null
        log_info "  BusyBox installed with symlinks"
    else
        log_error "BusyBox not found! Please install: apt-get install busybox-static"
        rm -rf "$rootfs_dir"
        return 1
    fi
    
    # Copy ethtool and lspci (not in BusyBox) with their libraries
    log_info "Copying additional utilities..."
    copy_with_libs /usr/sbin/ethtool "$rootfs_dir"
    copy_with_libs /usr/bin/lspci "$rootfs_dir"
    
    # Copy bash for the test script compatibility
    copy_with_libs /bin/bash "$rootfs_dir"
    
    # Ensure the dynamic linker is available (critical for C programs)
    if [ -f /lib64/ld-linux-x86-64.so.2 ]; then
        cp /lib64/ld-linux-x86-64.so.2 "$rootfs_dir/lib64/" 2>/dev/null || true
    fi
    
    # Also ensure ld-linux-x86-64.so.2 is in lib/x86_64-linux-gnu for good measure
    if [ -f /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 ]; then
        mkdir -p "$rootfs_dir/lib/x86_64-linux-gnu"
        cp /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 "$rootfs_dir/lib/x86_64-linux-gnu/" 2>/dev/null || true
    fi
    
    # Copy kernel modules from custom build
    log_info "Copying kernel modules..."
    if [ -d "$LINUX_BUILD_DIR/lib/modules" ]; then
        cp -r "$LINUX_BUILD_DIR/lib/modules"/* "$rootfs_dir/lib/modules/" 2>/dev/null || true
        log_info "  Kernel modules copied"
    fi
    
    # Install DDP firmware package
    log_info "Installing DDP firmware..."
    cp "$DDP_PATH" "$rootfs_dir/lib/firmware/intel/ice/ddp/ice.pkg"
    log_info "  DDP: $(ls -lh $DDP_PATH | awk '{print $5}')"
    
    # Copy test script
    log_info "Copying test script..."
    cp "$SCRIPT_DIR/test_vf_and_link.sh" "$rootfs_dir/root/"
    chmod +x "$rootfs_dir/root/test_vf_and_link.sh"
    
    # Create init script
    log_info "Creating init script..."
    cat > "$rootfs_dir/init" << 'INITEOF'
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export LD_LIBRARY_PATH=/lib64:/lib:/lib/x86_64-linux-gnu

log() { echo "[INIT] $*"; }

log "===== ICE Multi-Port Test Environment ====="

# Mount filesystems
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mount -t tmpfs tmpfs /tmp 2>/dev/null

# Setup loopback
ip link set lo up 2>/dev/null

# Wait for ICE driver (built-in, no modprobe needed)
log "Waiting for ICE driver initialization..."
sleep 2

# List PCI devices and network interfaces
log "PCI Devices:"
if command -v lspci >/dev/null 2>&1; then
    lspci | grep -i "network\|Ethernet" || log "No network devices in lspci"
else
    log "lspci not available"
fi

log "Network interfaces (PF only):"
ip link show

# Check if ICE devices are present
ice_count=$(for n in /sys/class/net/*; do \
    [ -e "$n" ] || continue; \
    drv=$(readlink -f "$n/device/driver" 2>/dev/null || true); \
    [ "${drv##*/}" = "ice" ] && echo "${n##*/}"; \
done | wc -l)
ice_count=${ice_count:-0}
log "Found $ice_count ICE PF network interfaces"

# Wait for iavf VF interfaces to appear (driver built-in)
# VFs are auto-created by SR-IOV, iavf driver probes them
EXPECTED_VFS="__ICE_MP_EXPECTED_VFS__"
if [ "$EXPECTED_VFS" -gt 0 ] 2>/dev/null; then
    log "Waiting for $EXPECTED_VFS VF interfaces (iavf driver)..."
    VF_WAIT=0
    while [ "$VF_WAIT" -lt 90 ]; do
        # Count all eth interfaces excluding ICE PF interfaces (VF interfaces)
        vf_count=$(ls -d /sys/class/net/eth* 2>/dev/null | wc -l)
        vf_count=$((vf_count - ice_count))
        if [ "$vf_count" -ge "$EXPECTED_VFS" ]; then
            log "Found $vf_count VF interfaces"
            break
        fi
        sleep 1
        VF_WAIT=$((VF_WAIT + 1))
    done
    if [ "$VF_WAIT" -ge 90 ]; then
        log "WARNING: Timeout waiting for VF interfaces (found $vf_count, expected $EXPECTED_VFS)"
    fi
fi

log "All network interfaces (PF + VF):"
ip link show

# Datapath test configuration injected by host script
export ICE_MP_TEST_PEER_IP="__ICE_MP_TEST_PEER_IP__"
export ICE_MP_TEST_GUEST_IP="__ICE_MP_TEST_GUEST_IP__"
export ICE_MP_EXPECTED_PORTS="__ICE_MP_EXPECTED_PORTS__"
export ICE_MP_EXPECTED_VFS="__ICE_MP_EXPECTED_VFS__"
export ICE_MP_EXPECTED_VFS_PER_PORT="__ICE_MP_EXPECTED_VFS_PER_PORT__"
export ICE_MP_EXPECTED_PF_DEVICES="__ICE_MP_EXPECTED_PF_DEVICES__"
export ICE_MP_EXPECTED_VFS_PER_PF="__ICE_MP_EXPECTED_VFS_PER_PF__"

# Run test suite
if [ -f /root/test_vf_and_link.sh ]; then
    log "Starting test suite..."
    # Dump interrupt info for debugging
    log "=== /proc/interrupts ==="
    cat /proc/interrupts 2>/dev/null | head -30
    log "=== ICE interfaces ==="
    ip -4 addr show 2>/dev/null
    # Try bash directly - it should be in /bin/bash
    /bin/bash /root/test_vf_and_link.sh 2>&1
    log "Test complete (exit code: $?)"
    # Post-test interrupt dump
    log "=== /proc/interrupts (after test) ==="
    cat /proc/interrupts 2>/dev/null | head -30
else
    log "ERROR: Test script not found at /root/test_vf_and_link.sh"
fi

log "Shutting down VM..."
sync
echo o > /proc/sysrq-trigger
sleep 2
poweroff -f
# Fallback: force reboot if poweroff didn't work
sleep 3
reboot -f
INITEOF

    # Inject host-provided datapath test settings
    # Use first TAP device IP (tap_ice0 at 192.168.100.100) as the peer IP
    sed -i \
        -e "s|__ICE_MP_TEST_PEER_IP__|192.168.100.100|g" \
        -e "s|__ICE_MP_TEST_GUEST_IP__|$GUEST_IP/24|g" \
        -e "s|__ICE_MP_EXPECTED_PORTS__|$QEMU_PORTS|g" \
        -e "s|__ICE_MP_EXPECTED_VFS__|$QEMU_VFS|g" \
        -e "s|__ICE_MP_EXPECTED_VFS_PER_PORT__|$QEMU_VFS_PER_PORT|g" \
        -e "s|__ICE_MP_EXPECTED_PF_DEVICES__|$QEMU_PF_DEVICES|g" \
        -e "s|__ICE_MP_EXPECTED_VFS_PER_PF__|$QEMU_VFS_PER_DEVICE|g" \
        "$rootfs_dir/init"
    
    chmod +x "$rootfs_dir/init"
    
    # Create cpio archive
    log_info "Creating cpio initramfs..."
    cd "$rootfs_dir"
    find . | cpio -o -H newc > "$ROOTFS_PATH" 2>/dev/null
    cd - > /dev/null
    
    # Cleanup
    rm -rf "$rootfs_dir"
    
    log_success "Rootfs created: $(ls -lh $ROOTFS_PATH | awk '{print $5}')"
}

setup_network() {
    log_info "Setting up network for QEMU (${QEMU_PORTS} PF ports)..."
    
    # Create TAP device for each port
    TAP_DEVICES=()
    TAP_IPS=()
    
    local port
    for ((port=0; port<QEMU_PORTS; port++)); do
        local tap_dev="tap_ice$port"
        local tap_ip="192.168.100.$((100 + port))"
        
        TAP_DEVICES+=("$tap_dev")
        TAP_IPS+=("$tap_ip")
        
        # Skip creation if already exists
        if ip link show "$tap_dev" > /dev/null 2>&1; then
            log_warn "TAP device $tap_dev already exists, reusing"
            continue
        fi
        
        log_info "Creating TAP device: $tap_dev with IP $tap_ip"
        
        # Create tap device
        if ! sudo ip tuntap add dev "$tap_dev" mode tap 2>/dev/null; then
            if ! sudo ip link add name "$tap_dev" type tap 2>/dev/null; then
                log_error "Failed to create TAP device $tap_dev"
                exit 1
            fi
        fi
        
        # Configure tap device with unique IP
        sudo ip addr add "$tap_ip/24" dev "$tap_dev" 2>/dev/null || log_error "Failed to set IP on $tap_dev"
        sudo ip link set "$tap_dev" up 2>/dev/null || log_error "Failed to bring up $tap_dev"
    done
    
    # Verify all TAP devices exist
    for ((port=0; port<QEMU_PORTS; port++)); do
        if ! ip link show "${TAP_DEVICES[$port]}" > /dev/null 2>&1; then
            log_error "TAP device ${TAP_DEVICES[$port]} not available; datapath test cannot run"
            exit 1
        fi
    done
    
    # Enable IP forwarding
    sudo sysctl net.ipv4.ip_forward=1 > /dev/null 2>&1 || true
    
    log_success "Network setup complete (${QEMU_PORTS} TAP devices: ${TAP_DEVICES[*]})"
}

cleanup_network() {
    log_info "Cleaning up network configuration..."

    local port
    for ((port=0; port<QEMU_PORTS; port++)); do
        local tap_dev="tap_ice$port"
        if ip link show "$tap_dev" > /dev/null 2>&1; then
            sudo ip link del "$tap_dev" 2>/dev/null || log_warn "Failed to delete TAP device $tap_dev"
        fi
    done
}

run_pf_vf_link_propagation_test() {
    local tap_dev="tap_ice${LINK_PROP_TEST_PORT}"
    local down_pf_pat="ice-mp: Propagated PF port ${LINK_PROP_TEST_PORT} link DOWN to [1-9][0-9]* mapped VFs"
    local up_pf_pat="ice-mp: Propagated PF port ${LINK_PROP_TEST_PORT} link UP to [1-9][0-9]* mapped VFs"
    local attempt

    propagation_markers_observed() {
        [ -f "$QEMU_STDERR_LOG" ] &&
        grep -Eq "$down_pf_pat" "$QEMU_STDERR_LOG" &&
        grep -Eq "$up_pf_pat" "$QEMU_STDERR_LOG"
    }

    qmp_set_link_state() {
        local net_id="$1"
        local up_state="$2"
        python3 - <<'PY' "$QEMU_QMP_SOCK" "$net_id" "$up_state"
import json
import socket
import sys

sock_path = sys.argv[1]
net_id = sys.argv[2]
up_state = sys.argv[3].lower() in ("1", "true", "yes", "on")

def recv_msg(sock):
    data = b""
    while b"\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("QMP socket closed")
        data += chunk
    line, _ = data.split(b"\n", 1)
    return json.loads(line.decode("utf-8", errors="ignore"))

def send_msg(sock, payload):
    sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))
    return recv_msg(sock)

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(5)
sock.connect(sock_path)

recv_msg(sock)
resp = send_msg(sock, {"execute": "qmp_capabilities"})
if "error" in resp:
    raise RuntimeError(f"qmp_capabilities failed: {resp}")

resp = send_msg(sock, {
    "execute": "set_link",
    "arguments": {"name": net_id, "up": up_state}
})
if "error" in resp:
    raise RuntimeError(f"set_link failed: {resp}")

print("ok")
PY
    }

    if [ -S "$QEMU_QMP_SOCK" ]; then
        log_info "Running PF→VF link propagation trigger via QMP set_link (ice${LINK_PROP_TEST_PORT})"
        for attempt in $(seq 1 12); do
            if qmp_set_link_state "ice${LINK_PROP_TEST_PORT}" false 2>/dev/null; then
                sleep 1
                if qmp_set_link_state "ice${LINK_PROP_TEST_PORT}" true 2>/dev/null; then
                    sleep 1
                    LINK_PROP_TEST_TRIGGERED=1
                    if propagation_markers_observed; then
                        log_success "PF→VF link propagation trigger sent via QMP (markers observed, attempt ${attempt})"
                        return 0
                    fi
                    sleep 3
                    continue
                fi
            fi
            break
        done

        if [ "$LINK_PROP_TEST_TRIGGERED" -eq 1 ] 2>/dev/null; then
            log_warn "QMP link trigger sent but propagation markers not yet observed; falling back to TAP toggle retries"
        fi
        log_warn "QMP set_link trigger failed; falling back to TAP link toggle"
    fi

    if ! ip link show "$tap_dev" > /dev/null 2>&1; then
        log_error "PF→VF link propagation test failed: TAP device $tap_dev not found"
        return 1
    fi

    log_info "Running PF→VF link propagation trigger on host ($tap_dev down/up)"

    for attempt in $(seq 1 12); do
        if ! sudo ip link set "$tap_dev" down 2>/dev/null; then
            log_error "PF→VF link propagation test failed: could not set $tap_dev down"
            return 1
        fi
        sleep 1

        if ! sudo ip link set "$tap_dev" up 2>/dev/null; then
            log_error "PF→VF link propagation test failed: could not set $tap_dev up"
            return 1
        fi
        sleep 1

        LINK_PROP_TEST_TRIGGERED=1
        if propagation_markers_observed; then
            log_success "PF→VF link propagation trigger sent on $tap_dev (markers observed, attempt ${attempt})"
            return 0
        fi

        sleep 3
    done

    log_error "PF→VF link propagation test failed: trigger attempts completed without mapped-VF DOWN/UP markers"
    log_info "Searched in: $QEMU_STDERR_LOG"
    log_info "Expected markers:"
    log_info "  $down_pf_pat"
    log_info "  $up_pf_pat"
    return 1
}

validate_pf_vf_link_propagation_logs() {
    local down_link_pat='ice-mp: link_status_changed port=[0-9]+ link_up=0'
    local down_pf_pat='ice-mp: Propagated PF port [0-9]+ link DOWN to [1-9][0-9]* mapped VFs'
    local up_link_pat='ice-mp: link_status_changed port=[0-9]+ link_up=1'
    local up_pf_pat='ice-mp: Propagated PF port [0-9]+ link UP to [1-9][0-9]* mapped VFs'

    if [ "$VERIFY_VF_LINK_PROPAGATION" -ne 1 ] 2>/dev/null; then
        log_info "Skipping PF→VF link propagation validation (ICE_MP_VERIFY_VF_LINK_PROPAGATION=$VERIFY_VF_LINK_PROPAGATION)"
        return 0
    fi

    if [ "$LINK_PROP_TEST_TRIGGERED" -ne 1 ] 2>/dev/null; then
        log_error "PF→VF link propagation validation failed: trigger was not executed"
        return 1
    fi

    if [ ! -f "$QEMU_STDERR_LOG" ]; then
        log_error "PF→VF link propagation validation failed: $QEMU_STDERR_LOG not found"
        return 1
    fi

    if grep -Eq "$down_link_pat" "$QEMU_STDERR_LOG" &&
       grep -Eq "$down_pf_pat" "$QEMU_STDERR_LOG" &&
       grep -Eq "$up_link_pat" "$QEMU_STDERR_LOG" &&
       grep -Eq "$up_pf_pat" "$QEMU_STDERR_LOG"; then
        log_success "PF→VF link propagation validated (DOWN/UP observed in QEMU logs)"
        return 0
    fi

    log_error "PF→VF link propagation validation failed: expected DOWN/UP propagation markers not found"
    log_info "Searched in: $QEMU_STDERR_LOG"
    log_info "Expected patterns:"
    log_info "  $down_link_pat"
    log_info "  $down_pf_pat"
    log_info "  $up_link_pat"
    log_info "  $up_pf_pat"
    return 1
}

################################################################################
# QEMU Functions
################################################################################

boot_qemu() {
    log_info "Booting QEMU with pci-ice-mp device..."
    
    check_file "$QEMU_BIN"
    check_file "$KERNEL_PATH"
    check_file "$ROOTFS_PATH"
    
    # Prepare QEMU command
    local qemu_cmd=(
        "$QEMU_BIN"
        "-machine" "q35"
        "-kernel" "$KERNEL_PATH"
        "-initrd" "$ROOTFS_PATH"
        "-m" "$QEMU_MEM"
        "-smp" "$QEMU_CPUS"
        "-nographic"
        "-monitor" "none"
        "-qmp" "unix:${QEMU_QMP_SOCK},server=on,wait=off"
        "-serial" "file:$QEMU_LOG"
        "-append" "root=/dev/ram console=ttyS0"
        "-no-reboot"
    )

    local port
    for ((port=0; port<QEMU_PORTS; port++)); do
        qemu_cmd+=("-netdev" "tap,id=ice${port},ifname=tap_ice${port},script=no,downscript=no")
    done

    local pf_idx
    local netdev_idx
    local root_slot
    local rp_id
    local device_opts
    local mac_octet
    for ((pf_idx=0; pf_idx<QEMU_PF_DEVICES; pf_idx++)); do
        root_slot=$((2 + pf_idx))
        rp_id="rp$((pf_idx + 1))"
        qemu_cmd+=("-device" "pcie-root-port,id=${rp_id},slot=${root_slot},chassis=$((pf_idx + 1)),bus-reserve=32,mem-reserve=64M,pref64-reserve=512M")

        device_opts="pci-ice-mp,bus=${rp_id},ports=$QEMU_PORTS_PER_DEVICE,vfs=$QEMU_VFS_PER_DEVICE"
        for ((port=0; port<QEMU_PORTS_PER_DEVICE; port++)); do
            netdev_idx=$((pf_idx * QEMU_PORTS_PER_DEVICE + port))
            device_opts+=",netdev${port}=ice${netdev_idx}"
            printf -v mac_octet "%02x" $((0x56 + netdev_idx))
            device_opts+=",mac${port}=52:54:00:12:34:${mac_octet}"
        done
        qemu_cmd+=("-device" "$device_opts")
    done
    
    # Additional QEMU options for better performance
    # Try to use KVM if available, otherwise fall back to TCG
    if [ -r /dev/kvm ] 2>/dev/null; then
        qemu_cmd+=(
            "-enable-kvm"          # Use KVM if available
            "-cpu" "host,kvm=on"   # Near-native CPU mode
        )
    else
        qemu_cmd+=(
            "-machine" "accel=tcg" # Fall back to TCG software emulation
            "-cpu" "qemu64"        # Standard QEMU CPU
        )
    fi
    
    # Clear previous QEMU logs
    rm -f "$QEMU_LOG"
    rm -f "$QEMU_STDERR_LOG"
    rm -f "$QEMU_QMP_SOCK"
    
    log_info "QEMU command:"
    log_info "${qemu_cmd[*]}"
    
    # Launch QEMU in background (output goes directly to serial file)
    "${qemu_cmd[@]}" 2>"$QEMU_STDERR_LOG" &
    local qemu_pid=$!
    echo "$qemu_pid" > "$QEMU_PID_FILE"
    
    log_info "QEMU started with PID $qemu_pid"
    log_info "Serial output: $QEMU_LOG"
    
    # Give QEMU a moment to initialize and start logging
    sleep 2
    
    # Show initial boot messages if they exist
    if [ -f "$QEMU_LOG" ] && [ -s "$QEMU_LOG" ]; then
        log_info "Initial boot output:"
        head -20 "$QEMU_LOG"
        log_info "..."
        log_info "(Full output will be available in $QEMU_LOG)"
    fi
    
    # Wait for QEMU to finish or timeout
    local elapsed=0
    local propagation_attempted=0
    local propagation_gate_seen=0
    while [ $elapsed -lt "$TEST_TIMEOUT" ]; do
        if [ "$VERIFY_VF_LINK_PROPAGATION" -eq 1 ] 2>/dev/null && [ $propagation_attempted -eq 0 ]; then
            if [ -f "$QEMU_LOG" ] && grep -q "Section 3: SR-IOV Configuration" "$QEMU_LOG"; then
                propagation_gate_seen=1
                if run_pf_vf_link_propagation_test; then
                    propagation_attempted=1
                else
                    propagation_attempted=1
                fi
            elif [ $elapsed -ge 120 ] && [ $propagation_gate_seen -eq 0 ]; then
                log_warn "SR-IOV section marker not seen by 120s; triggering PF→VF propagation test anyway"
                if run_pf_vf_link_propagation_test; then
                    propagation_attempted=1
                else
                    propagation_attempted=1
                fi
            fi
        fi

        if ! kill -0 "$qemu_pid" 2>/dev/null; then
            log_success "QEMU test execution completed"
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    
    # If QEMU is still running after timeout, kill it
    if kill -0 "$qemu_pid" 2>/dev/null; then
        log_warn "Test execution timed out (${TEST_TIMEOUT}s), terminating QEMU"
        kill -9 "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
    fi
    
    # Collect results from serial log
    collect_test_results
}

collect_test_results() {
    log_info "Collecting test results..."
    local guest_result=1
    local propagation_result=0
    
    if [ ! -f "$QEMU_LOG" ]; then
        log_error "QEMU serial log not found"
        return 1
    fi
    
    log_info ""
    log_info "================ TEST RESULTS ================"
    cat "$QEMU_LOG"
    log_info "=============================================="
    
    # Parse and summarize guest test results
    if grep -q "All tests passed" "$QEMU_LOG"; then
        log_success "All tests PASSED!"
        guest_result=0
    elif grep -q "Pass Rate:" "$QEMU_LOG"; then
        log_warn "Some tests may have failed. Check output above."
        guest_result=1
    else
        log_error "Test results not found in QEMU log - tests may not have completed"
        guest_result=1
    fi

    if ! validate_pf_vf_link_propagation_logs; then
        propagation_result=1
    fi

    if [ "$guest_result" -eq 0 ] && [ "$propagation_result" -eq 0 ]; then
        return 0
    fi

    return 1
}

################################################################################
# Main Execution
################################################################################

main() {
    # Parse command-line arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --kernel-only)
                KERNEL_ONLY=1
                shift
                ;;
            --skip-build)
                SKIP_BUILD=1
                shift
                ;;
            --skip-qemu-build)
                SKIP_QEMU_BUILD=1
                shift
                ;;
            --skip-test)
                SKIP_TEST=1
                shift
                ;;
            --keep-vm)
                KEEP_VM=1
                shift
                ;;
            --clean)
                CLEAN_ONLY=1
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Check topology variables and prerequisites
    validate_topology

    # Check prerequisites
    check_prerequisites
    
    # Handle cleanup-only mode
    if [ $CLEAN_ONLY -eq 1 ]; then
        log_info "========== Cleanup Mode =========="
        cleanup_old_artifacts
        cleanup_network
        log_success "All temporary files and network configuration cleaned up"
        exit 0
    fi
    
    log_info "========== ICE Multi-Port Driver Test Suite =========="
    log_info "Workspace: $WORKSPACE_ROOT"
    log_info "QEMU Binary: $QEMU_BIN"
    log_info "Kernel: $KERNEL_PATH"
    log_info "Rootfs: $ROOTFS_PATH"
    log_info "DDP Package: $DDP_PATH"
    log_info "Topology: PF devices=$QEMU_PF_DEVICES, ports/PF=$QEMU_PORTS_PER_DEVICE, VFs/PF=$QEMU_VFS_PER_DEVICE, VFs/port=$QEMU_VFS_PER_PORT"
    log_info "Totals: ports=$QEMU_PORTS, VFs=$QEMU_VFS"
    log_info "Memory: ${QEMU_MEM}MB, CPUs: $QEMU_CPUS"
    log_info "======================================================="
    
    # Cleanup old artifacts to ensure fresh build (only when building)
    if [ $SKIP_BUILD -eq 0 ]; then
        cleanup_old_artifacts
    else
        # Just clean logs and stray processes
        rm -f "$QEMU_LOG" "$QEMU_STDERR_LOG" "$QEMU_QMP_SOCK" "$QEMU_PID_FILE" "$TEST_RESULTS"
        if pgrep -f "qemu-system.*ice-mp" > /dev/null 2>&1; then
            pkill -9 -f "qemu-system.*ice-mp"
            sleep 1
        fi
    fi
    
    # Build phase - Correct order: QEMU -> DDP -> Rootfs -> Kernel
    if [ $SKIP_BUILD -eq 0 ]; then
        # Build QEMU first (if not skipped)
        if [ $SKIP_QEMU_BUILD -eq 0 ]; then
            build_qemu || {
                log_error "Failed to build QEMU. Use --skip-qemu-build to skip."
                exit 1
            }
        else
            log_info "Skipping QEMU build (--skip-qemu-build)"
            if [ ! -f "$QEMU_BIN" ]; then
                log_error "QEMU binary not found: $QEMU_BIN"
                exit 1
            fi
        fi
        
        # Generate DDP package (required for rootfs)
        generate_ddp_package || {
            log_error "Failed to generate DDP package"
            exit 1
        }
        
        # Create rootfs with firmware
        create_rootfs || {
            log_error "Failed to create rootfs"
            exit 1
        }
        
        # Build kernel
        build_kernel || {
            log_error "Failed to build kernel"
            exit 1
        }
        
        if [ $KERNEL_ONLY -eq 1 ]; then
            log_success "Build complete. To run tests, use --skip-build"
            exit 0
        fi
    else
        log_info "Skipping all builds (--skip-build)"
        # Verify artifacts exist
        if [ ! -f "$QEMU_BIN" ]; then
            log_error "QEMU binary not found: $QEMU_BIN"
            exit 1
        fi
        if [ ! -f "$KERNEL_PATH" ]; then
            log_error "Kernel not found: $KERNEL_PATH"
            exit 1
        fi
        if [ ! -f "$ROOTFS_PATH" ]; then
            log_error "Rootfs not found: $ROOTFS_PATH"
            exit 1
        fi
    fi
    
    # Setup network
    setup_network
    
    # Boot and test
    if [ $SKIP_TEST -eq 0 ]; then
        boot_qemu
    fi
    
    # Cleanup - preserve logs for debugging
    if [ $KEEP_VM -eq 0 ]; then
        cleanup_network
    fi
    
    log_info "Logs preserved at: $QEMU_LOG, $QEMU_STDERR_LOG"
    log_success "Test script completed"
}

# Run main
main "$@"
