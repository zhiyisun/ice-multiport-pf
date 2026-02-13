# Development Plan: Multi-Port PF ICE Driver

This document outlines the development plan for implementing the multi-port per-PF (Physical Function) feature for the Intel E810 ICE driver, with a test-driven development approach using a custom QEMU device.

## Phase 1: Environment Setup

- [x] Create a directory for intermediate build files (e.g., `build`).
- [x] Clone the Linux kernel repository from `git@github.com:zhiyisun/linux.git`.
- [x] Identify the latest kernel release branch and create a `dev/ice-multi-port` branch.
- [x] Configure and build the Linux kernel.
- [x] Clone the QEMU repository from `git@github.com:zhiyisun/qemu.git`.
- [x] Identify the latest QEMU release branch and create a `dev/ice-multi-port` branch.
- [x] Configure and build QEMU.

## Phase 2: QEMU `pci-ice-mp` Device Implementation

- [x] Create a new PCI device named `pci-ice-mp` in the QEMU source tree.
- [x] Implement the PCI configuration space with Vendor/Device ID and SR-IOV capabilities.
- [x] Implement the BAR0 register layout as specified in `QEMU_ICE_MP_ARCH.md`.
- [x] Implement MSI-X interrupts and the event injection mechanism via the `EVENT_DOORBELL` register.
- [x] Add QEMU command-line options to configure the number of ports and VFs for the device.

## Phase 3: ICE Driver Multi-Port Framework (in Linux Kernel)

- [x] Add the new `pci-ice-mp` device ID to the `ice` driver's PCI ID table.
- [x] Modify the driver's probe function to detect and handle the multi-port capability.
- [x] Implement port discovery logic to create `net_device` instances for each port.
- [ ] Implement event handling to demultiplex events from `EVENT_DOORBELL` based on `port_id`.
- [ ] Update SR-IOV logic to map VFs to ports using the `VF_PORT_MAP` register.
- [ ] Implement multi-port reset and recovery logic.

## Phase 4: Event Demultiplexing & SR-IOV Integration

- [ ] Implement MSI-X interrupt routing for multi-port events
- [ ] Hook into existing interrupt handlers to demultiplex port-specific events
- [ ] Implement link change event handling per port
- [ ] Update SR-IOV VF initialization to use ice_mp_get_vf_port_id()
- [ ] Implement VF mailbox event routing by port
- [ ] Test functional equivalence with single-port mode

## Phase 4: Test-Driven Development and Validation

- [ ] **Test 1: Probe and Netdev Creation:** Launch the custom QEMU with the `pci-ice-mp` device and the modified kernel. Verify that the correct number of `net_device` interfaces are created.
- [ ] **Test 2: Event Handling:** Use QEMU to inject link-change events and verify that the correct `net_device` reflects the status change.
- [ ] **Test 3: SR-IOV:** Enable SR-IOV, create VFs, and verify they are correctly mapped to their parent ports. Test VF mailbox event routing.
- [ ] **Test 4: Reset:** Trigger a device reset from QEMU and verify that the driver correctly re-initializes all ports.
