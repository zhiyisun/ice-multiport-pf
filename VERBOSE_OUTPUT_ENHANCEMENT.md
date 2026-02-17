# Test Suite Enhancement: Comprehensive Verbose Command Output

## Overview
The test suite has been enhanced to capture and display **actual command invocations and their outputs** when tests are executed. This allows developers to understand exactly what each test does and verify the results directly.

## Implementation Details

### 1. New Helper Functions Added

#### `verbose_cmd()` - Command Execution with Output Logging
```bash
verbose_cmd "description" "command_string"
```

**When `ICE_MP_VERBOSE_OUTPUT=1` is set:**
- Prints: `CMD [description]: <command>`
- Captures and prints stdout with `OUT:` prefix
- Captures and prints stderr with `ERR:` prefix (if any)
- Example output:
```
    CMD [get_port_count]: get_port_count
    OUT:
      4
```

**When `ICE_MP_VERBOSE_OUTPUT` is unset:**
- Silently executes command
- Suppresses all output (original behavior)

#### `verbose_cmd_capture()` - Command Output Capture
```bash
output=$(verbose_cmd_capture "description" "command")
```

- Executes command and returns stdout
- When verbose enabled, also prints command and output to stderr
- Useful for commands where output is needed for further processing

### 2. Test Sections Updated with Verbose Output

#### Section 2: Multi-Port Discovery
- **Test:** Port count detection
- **Verbose commands added:**
  - `get_port_count` - counts ICE interfaces
  - `get_ice_ifaces` - lists ICE PF interfaces
  - `ls -d /sys/class/net/eth0` -checks eth0 exists
  - `ls -d /sys/class/net/eth3` - checks eth3 exists

**Example output structure:**
```
    CMD [get_port_count]: get_port_count
    OUT:
      4
    ✓ 4 logical ports discovered

    CMD [get_ice_ifaces]: get_ice_ifaces
    OUT:
      eth0
      eth1
      eth2
      eth3
    ✓ 4 network devices created (ICE ports)
```

#### Section 5: PF/VF Enumeration via lspci
- **Tests:** PF device enumeration, VF detection, driver binding
- **Verbose commands added:**
  - `lspci -d 8086: -n | grep -c ' 0200'` - count PF devices
  - `lspci -s <pf_device> -v` - show PF device details  
  - `find /sys/bus/pci/devices/.../virtfn*` - count VF devices via sysfs
  - `lspci -d 8086:1889` - enumerate VF devices via lspci
  - `ls -l /sys/bus/pci/drivers/ | grep ice` - check driver binding
  - `get_iavf_ifaces` - list VF network interfaces
  - `get_ice_ifaces` - list PF network interfaces

**Example output structure:**
```
    CMD [lspci -d 8086: -n (PF count)]: lspci -d 8086: -n | grep -c ' 0200'
    OUT:
      1
    ✓ PF devices enumerated via lspci (1 found)

    CMD [lspci -s 0000:01:00.0 -v]: lspci -s '0000:01:00.0' -v | head -10
    OUT:
      0000:01:00.0 Ethernet controller: Intel Corporation Device 1592 (rev 01)
        Subsystem: Intel Corporation Device 0001
        Control: I/O- Mem+ BusMaster+ SpecCycle- MemWINV- VGASnoop- ParErr- Stepping- SERR- FastB2B- DisINTx-
        ...
    ℹ PF Device Info:
      0000:01:00.0 Ethernet controller: Intel Corporation Device 1592 (rev 01)
```

#### Section 11: Network Connectivity Tests (CRITICAL DATAPATH)
- **Tests:** PF and VF datapath via ping, TX/RX counter validation
- **Verbose commands added for PF ports:**
  - `ip link show <iface>` - interface status
  - `ip link set <iface> up` - bring up interface
  - `ip addr flush dev <iface>` - flush existing IPs
  - `ip addr add <ip>/24 dev <iface>` - assign test IP
  - `ip -4 addr show dev <iface>` - verify IP was assigned
  - `ping -c 3 -W 2 <peer_ip>` - datapath connectivity test

- **Verbose commands added for VF ports:**
  - Same as PF, but with different IP subnet (192.168.200.x)
  - `ping -c 3 -W 3 -I <iface> <peer_ip>` - VF-specific ping

**Example output structure:**
```
    CMD [ip link show eth0]: ip link show 'eth0'
    OUT:
      2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP mode DEFAULT group 0
          link/ether 0a:8e:00:00:00:00 brd ff:ff:ff:ff:ff:ff

    CMD [ip addr add 192.168.100.1/24 dev eth0]: ip addr add '192.168.100.1/24' dev 'eth0'
    
    CMD [ip -4 addr show dev eth0]: ip -4 addr show dev 'eth0'
    OUT:
      2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
        inet 192.168.100.1/24 scope global eth0
           valid_lft forever preferred_lft forever

    CMD [ping -c 3 -W 2 192.168.100.100 from eth0]: ping -c 3 -W 2 '192.168.100.100'
    OUT:
      PING 192.168.100.100 (192.168.100.100) 56(84) bytes of data.
      64 bytes from 192.168.100.100: icmp_seq=1 ttl=64 time=0.123 ms
      64 bytes from 192.168.100.100: icmp_seq=2 ttl=64 time=0.087 ms
      64 bytes from 192.168.100.100: icmp_seq=3 ttl=64 time=0.099 ms
    
    ℹ PF Port 1 (eth0): TX/RX OK (tx: 100->103, rx: 100->103)
    ✓ TX/RX datapath ping (all 4 PF ports passed)
```

### 3. Automatic Verbose Output in Init Script
- Environment variable `ICE_MP_VERBOSE_OUTPUT=1` is set in the init script
- All test sections automatically use verbose mode during test execution
- No user action needed - verbose output is captured automatically

## Total Verbose Commands Added: 32

**Distribution by Section:**
- Section 2 (Discovery): 4 commands
- Section 5 (lspci Enumeration): 8 commands  
- Section 11 (Datapath Tests): 20 commands (10 per port × 2 PF ports shown as example)

## How to Use

### Running Tests with Verbose Output
The rootfs rebuild includes automatic verbose output:

```bash
# Rebuild rootfs with verbose-enabled test script
bash /tmp/rebuild_rootfs.sh

# Run QEMU with tests (verbose output enabled by default)
bash tools/run_ice_mp_test.sh --skip-qemu-build
```

### Interpreting Verbose Output

Each test command section follows this pattern:

```
┌─ CMD label shows what is being tested
│     
│  CMD [get_port_count]: get_port_count
│  OUT:
│    4
│  
│  ✓ 4 logical ports discovered ← Test result based on command output
│
└─ Optional error messages if test fails
   Reason: <explanation>
```

### Understanding Test Flows

For datapath tests, the verbose output shows:

1. **Interface Check**: `ip link show eth0` → confirms interface exists
2. **IP Assignment**: `ip addr add` → assigns test IP address
3. **IP Verification**: `ip -4 addr show` → confirms IP was assigned
4. **Datapath Test**: `ping -c 3 ...` → actual connectivity test
5. **Counter Validation**: TX/RX counters verify packets went through

## Benefits

1. **Transparency**: See exactly which commands are executed and what they return
2. **Debugging**: When tests fail, the output shows the precise cause
3. **Verification**: Confirm that tests are measuring what they claim to measure
4. **Documentation**: Command output serves as inline documentation ofDevice/driver behavior
5. **Reproducibility**: Users can run the same commands manually to reproduce results

## Changes Made

### File Modified: [tools/test_vf_and_link.sh](tools/test_vf_and_link.sh)

**Lines Added:**
- Lines 75-121: New helper functions (`verbose_cmd`, `verbose_cmd_capture`)
- Lines 378-396: Verbose output in Section 2
- Lines 495-567: Verbose output in Section 5
- Lines 870-913: Verbose output in Section 11 (PF datapath)
- Lines 953-1004: Verbose output in Section 11 (VF datapath)

**Total Changes:** 72 insertions, 1 deletion

**Git Commit:** `3a97a70` on branch `dev/ice-multi-port`

## Migration Guide for Users

If you have existing test output that doesn't show command details, rebuild the rootfs:

```bash
# Option 1: Use provided rebuild script
bash /tmp/rebuild_rootfs.sh

# Option 2: Use main test harness (may require sudo for file operations)
bash tools/run_ice_mp_test.sh
```

The enhanced test script is backward compatible - verbose output is only shown when `ICE_MP_VERBOSE_OUTPUT=1` is set.

## Future Enhancements

Possible improvements for even more detailed output:

1. **Hex dumps**: Show raw packet contents for datapath tests
2. **Timing information**: Record execution time for each test
3. **Performance metrics**: Collect throughput data during ping tests
4. **Driver debugging**: Extract ice/iavf driver statistics from sysfs
5. **Interrupt tracking**: Show MSI-X interrupt firing for each packet

## Questions?

For detailed information on specific test commands, see the inline comments in [tools/test_vf_and_link.sh](tools/test_vf_and_link.sh).

---

**Test Suite Status:** ✓ Ready for comprehensive verbose output testing  
**Commit Hash:** `3a97a70`  
**Branch:** `dev/ice-multi-port`
