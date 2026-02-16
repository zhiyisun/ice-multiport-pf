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
#   ICE_MP_PORTS       Number of ports (default: 4)
#   ICE_MP_VFS         Number of VFs total (default: 8)
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

QEMU_PORTS="${ICE_MP_PORTS:-4}"
QEMU_VFS="${ICE_MP_VFS:-8}"
QEMU_MEM="${ICE_MP_MEM:-2048}"
QEMU_CPUS="${ICE_MP_CPUS:-4}"

TAP_DEVICE="${ICE_MP_NET_TAP:-tap0}"
TAP_IP="${ICE_MP_NET_IP:-192.168.100.1}"
GUEST_IP="${ICE_MP_GUEST_IP:-192.168.100.2}"
TEST_TIMEOUT="${ICE_MP_TIMEOUT:-300}"

# Logging
QEMU_LOG="/tmp/ice_mp_qemu_serial.log"
QEMU_PID_FILE="/tmp/ice_mp_qemu.pid"
TEST_RESULTS="/tmp/ice_mp_test_results.txt"

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
    
    # Remove QEMU build directory for clean rebuild
    if [ -d "$QEMU_BUILD_BINDIR" ]; then
        rm -rf "$QEMU_BUILD_BINDIR"
        log_info "  Removed QEMU build directory"
    fi
    
    # Remove old logs
    rm -f "$QEMU_LOG" "$QEMU_PID_FILE" "$TEST_RESULTS"
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

log "Network interfaces:"
ip link show

# Check if ICE devices are present
ice_count=$(ip link show 2>/dev/null | grep -c "^[0-9]*: eth[0-3]:" 2>/dev/null || true)
ice_count=${ice_count:-0}
log "Found $ice_count ICE network interfaces"

# Datapath test configuration injected by host script
export ICE_MP_TEST_PEER_IP="__ICE_MP_TEST_PEER_IP__"
export ICE_MP_TEST_GUEST_IP="__ICE_MP_TEST_GUEST_IP__"
export ICE_MP_EXPECTED_VFS="__ICE_MP_EXPECTED_VFS__"

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
        -e "s|__ICE_MP_EXPECTED_VFS__|$QEMU_VFS|g" \
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
    log_info "Setting up network for QEMU (all 4 ports)..."
    
    # Create TAP device for each port (netdev0-3)
    TAP_DEVICES=()
    TAP_IPS=()
    
    for port in 0 1 2 3; do
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
    for port in 0 1 2 3; do
        if ! ip link show "${TAP_DEVICES[$port]}" > /dev/null 2>&1; then
            log_error "TAP device ${TAP_DEVICES[$port]} not available; datapath test cannot run"
            exit 1
        fi
    done
    
    # Enable IP forwarding
    sudo sysctl net.ipv4.ip_forward=1 > /dev/null 2>&1 || true
    
    log_success "Network setup complete (4 TAP devices: ${TAP_DEVICES[*]})"
}

cleanup_network() {
    log_info "Cleaning up network configuration..."
    
    for port in 0 1 2 3; do
        local tap_dev="tap_ice$port"
        if ip link show "$tap_dev" > /dev/null 2>&1; then
            sudo ip link del "$tap_dev" 2>/dev/null || log_warn "Failed to delete TAP device $tap_dev"
        fi
    done
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
        "-netdev" "tap,id=ice0,ifname=tap_ice0,script=no,downscript=no"
        "-netdev" "tap,id=ice1,ifname=tap_ice1,script=no,downscript=no"
        "-netdev" "tap,id=ice2,ifname=tap_ice2,script=no,downscript=no"
        "-netdev" "tap,id=ice3,ifname=tap_ice3,script=no,downscript=no"
        "-device" "pcie-root-port,id=rp1,slot=2,chassis=1"
        "-device" "pci-ice-mp,bus=rp1,ports=$QEMU_PORTS,vfs=$QEMU_VFS,netdev0=ice0,netdev1=ice1,netdev2=ice2,netdev3=ice3"
        "-m" "$QEMU_MEM"
        "-smp" "$QEMU_CPUS"
        "-nographic"
        "-monitor" "none"
        "-serial" "file:$QEMU_LOG"
        "-append" "root=/dev/ram console=ttyS0"
        "-no-reboot"
    )
    
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
    
    # Clear previous QEMU log
    rm -f "$QEMU_LOG"
    
    log_info "QEMU command:"
    log_info "${qemu_cmd[*]}"
    
    # Launch QEMU in background (output goes directly to serial file)
    "${qemu_cmd[@]}" 2>/tmp/ice_mp_qemu_stderr.log &
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
    while [ $elapsed -lt "$TEST_TIMEOUT" ]; do
        if ! kill -0 "$qemu_pid" 2>/dev/null; then
            log_success "QEMU test execution completed"
            break
        fi
        sleep 1
        ((elapsed++))
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
    
    if [ ! -f "$QEMU_LOG" ]; then
        log_error "QEMU serial log not found"
        return 1
    fi
    
    log_info ""
    log_info "================ TEST RESULTS ================"
    cat "$QEMU_LOG"
    log_info "=============================================="
    
    # Parse and summarize results
    if grep -q "All tests passed" "$QEMU_LOG"; then
        log_success "All tests PASSED!"
        return 0
    elif grep -q "Pass Rate:" "$QEMU_LOG"; then
        log_warn "Some tests may have failed. Check output above."
        return 1
    else
        log_error "Test results not found in QEMU log - tests may not have completed"
        return 1
    fi
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
    log_info "QEMU Ports: $QEMU_PORTS, VFs: $QEMU_VFS"
    log_info "Memory: ${QEMU_MEM}MB, CPUs: $QEMU_CPUS"
    log_info "======================================================="
    
    # Cleanup old artifacts to ensure fresh build (only when building)
    if [ $SKIP_BUILD -eq 0 ]; then
        cleanup_old_artifacts
    else
        # Just clean logs and stray processes
        rm -f "$QEMU_LOG" "$QEMU_PID_FILE" "$TEST_RESULTS"
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
    
    log_info "Logs preserved at: $QEMU_LOG, /tmp/ice_mp_qemu_stderr.log"
    log_success "Test script completed"
}

# Run main
main "$@"
