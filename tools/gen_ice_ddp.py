#!/usr/bin/env python3
"""Generate a minimal valid ICE DDP (Dynamic Device Personalization) firmware package.

This creates an ice.pkg file that satisfies the Linux ice driver's DDP validation
chain so the driver does NOT enter Safe Mode. The package contains:

1. Package header with format version {1,0,0,0}
2. Metadata segment (SEGMENT_TYPE_METADATA = 0x01) with package version/name
3. ICE E810 segment (SEGMENT_TYPE_ICE_E810 = 0x10) with:
   - No device table entries (device_table_count = 0)
   - No NVM table entries (table_count = 0)
   - One 4096-byte buffer containing ICE_SID_METADATA section

The driver validation flow:
  ice_verify_pkg() -> checks pkg_format_ver == {1,0,0,0}, seg_count >= 1
  ice_init_pkg_info() -> finds ICE segment, reads ICE_SID_METADATA section
  ice_chk_pkg_version() -> checks meta->ver: major==1, minor==3
  ice_chk_pkg_compat() -> calls 0x0C43 AdminQ, checks NVM version compat
  ice_download_pkg() -> sends buffers via 0x0C40 AdminQ
  ice_get_pkg_info() -> calls 0x0C43, verifies active package matches
"""

import struct
import sys
import os

# Constants from ice_ddp.h
ICE_PKG_BUF_SIZE = 4096
ICE_PKG_NAME_SIZE = 32
ICE_META_SECT_NAME_SIZE = 28
SEGMENT_TYPE_METADATA = 0x00000001
SEGMENT_TYPE_ICE_E810 = 0x00000010
ICE_SID_METADATA = 1

PKG_NAME = b"ICE OS Default Package"
SEG_ID_METADATA = b"ICE Metadata"
SEG_ID_ICE = b"ICE Configuration Data"


def pack_pkg_ver(major, minor, update, draft):
    """Pack ice_pkg_ver: 4 bytes (major, minor, update, draft)."""
    return struct.pack("BBBB", major, minor, update, draft)


def pack_seg_hdr(seg_type, fmt_ver, seg_size, seg_id):
    """Pack ice_generic_seg_hdr: seg_type(le32) + seg_format_ver(4) + seg_size(le32) + seg_id(32)."""
    seg_id_padded = seg_id[:ICE_PKG_NAME_SIZE].ljust(ICE_PKG_NAME_SIZE, b'\x00')
    return struct.pack("<I", seg_type) + fmt_ver + struct.pack("<I", seg_size) + seg_id_padded


def build_metadata_segment():
    """Build ice_global_metadata_seg: hdr + pkg_ver(4) + rsvd(4) + pkg_name(32)."""
    pkg_ver = pack_pkg_ver(1, 3, 0, 0)
    fmt_ver = pack_pkg_ver(1, 3, 0, 0)
    pkg_name = PKG_NAME[:ICE_PKG_NAME_SIZE].ljust(ICE_PKG_NAME_SIZE, b'\x00')
    
    # Body: pkg_ver(4) + rsvd(4) + pkg_name(32) = 40 bytes
    body = pkg_ver + struct.pack("<I", 0) + pkg_name
    
    # Header: seg_type(4) + seg_format_ver(4) + seg_size(4) + seg_id(32) = 44 bytes
    seg_size = 44 + len(body)  # = 84 bytes
    hdr = pack_seg_hdr(SEGMENT_TYPE_METADATA, fmt_ver, seg_size, SEG_ID_METADATA)
    
    return hdr + body


def build_ice_buf():
    """Build a single 4096-byte ice_buf containing ICE_SID_METADATA section.
    
    Layout:
      ice_buf_hdr:
        section_count: u16 = 1
        data_end: u16 = offset_after_data  
        section_entry[0]:
          type: le32 = ICE_SID_METADATA (1)
          offset: le16 = 12 (right after the header)
          size: le16 = 36 (sizeof ice_meta_sect)
      
      ice_meta_sect at offset 12:
        ver: {1, 3, 0, 0}  (4 bytes)
        name: "ICE OS Default Package" (28 bytes)
        track_id: 0  (4 bytes)
    """
    buf = bytearray(ICE_PKG_BUF_SIZE)
    
    # ice_buf_hdr
    section_count = 1
    # section_entry starts at offset 4 (after section_count + data_end)
    # Each section_entry is 8 bytes (type:4 + offset:2 + size:2)
    # Data starts after header: 4 + 8 * section_count = 12
    data_offset = 4 + 8 * section_count  # = 12
    
    # ice_meta_sect: ver(4) + name(28) + track_id(4) = 36 bytes
    meta_sect_size = 36
    data_end = data_offset + meta_sect_size  # = 48
    
    # Pack header
    struct.pack_into("<HH", buf, 0, section_count, data_end)
    
    # Pack section_entry[0]: type(le32) + offset(le16) + size(le16)
    struct.pack_into("<IHH", buf, 4, ICE_SID_METADATA, data_offset, meta_sect_size)
    
    # Pack ice_meta_sect at data_offset
    meta_ver = pack_pkg_ver(1, 3, 0, 0)
    meta_name = PKG_NAME[:ICE_META_SECT_NAME_SIZE].ljust(ICE_META_SECT_NAME_SIZE, b'\x00')
    meta_track_id = struct.pack("<I", 0)
    
    meta_sect = meta_ver + meta_name + meta_track_id
    buf[data_offset:data_offset + len(meta_sect)] = meta_sect
    
    return bytes(buf)


def build_ice_segment():
    """Build ICE E810 segment: hdr + device_table_count + nvm_table + buf_table + buf.
    
    struct ice_seg {
        struct ice_generic_seg_hdr hdr;    // 44 bytes
        __le32 device_table_count;          // 4 bytes
        struct ice_device_id_entry device_table[];  // 0 entries
    };
    
    Followed by:
    struct ice_nvm_table {
        __le32 table_count;    // 4 bytes, = 0
        __le32 vers[];         // 0 entries
    };
    
    struct ice_buf_table {
        __le32 buf_count;      // 4 bytes, = 1
        struct ice_buf buf_array[];  // 1 * 4096 bytes
    };
    """
    fmt_ver = pack_pkg_ver(1, 3, 0, 0)
    
    # Body parts
    device_table_count = struct.pack("<I", 0)   # No device entries
    nvm_table_count = struct.pack("<I", 0)       # No NVM entries
    buf_count = struct.pack("<I", 1)             # 1 buffer
    ice_buf = build_ice_buf()                     # 4096 bytes
    
    body = device_table_count + nvm_table_count + buf_count + ice_buf
    
    # seg_size = header(44) + body
    seg_size = 44 + len(body)
    hdr = pack_seg_hdr(SEGMENT_TYPE_ICE_E810, fmt_ver, seg_size, SEG_ID_ICE)
    
    return hdr + body


def build_package():
    """Build the complete DDP package.
    
    struct ice_pkg_hdr {
        struct ice_pkg_ver pkg_format_ver;   // 4 bytes = {1,0,0,0}
        __le32 seg_count;                    // 4 bytes = 2
        __le32 seg_offset[];                 // 2 * 4 = 8 bytes
    };
    """
    metadata_seg = build_metadata_segment()
    ice_seg = build_ice_segment()
    
    # Package header: format_ver(4) + seg_count(4) + seg_offset[2](8) = 16 bytes
    pkg_hdr_size = 4 + 4 + 4 * 2  # = 16
    
    metadata_offset = pkg_hdr_size
    ice_offset = metadata_offset + len(metadata_seg)
    
    pkg_format_ver = pack_pkg_ver(1, 0, 0, 0)
    pkg_hdr = pkg_format_ver + struct.pack("<I", 2)  # seg_count = 2
    pkg_hdr += struct.pack("<I", metadata_offset)
    pkg_hdr += struct.pack("<I", ice_offset)
    
    package = pkg_hdr + metadata_seg + ice_seg
    
    return package


def validate_package(data):
    """Basic validation of the generated package."""
    # Check format version
    fmt_ver = struct.unpack("BBBB", data[0:4])
    assert fmt_ver == (1, 0, 0, 0), f"Bad format version: {fmt_ver}"
    
    # Check segment count
    seg_count = struct.unpack("<I", data[4:8])[0]
    assert seg_count == 2, f"Bad segment count: {seg_count}"
    
    # Check segment offsets
    meta_off = struct.unpack("<I", data[8:12])[0]
    ice_off = struct.unpack("<I", data[12:16])[0]
    
    # Check metadata segment
    meta_seg_type = struct.unpack("<I", data[meta_off:meta_off+4])[0]
    assert meta_seg_type == SEGMENT_TYPE_METADATA, f"Bad metadata seg type: {meta_seg_type:#x}"
    
    meta_seg_size = struct.unpack("<I", data[meta_off+8:meta_off+12])[0]
    assert meta_off + meta_seg_size <= len(data), "Metadata segment exceeds package"
    
    # Check ICE segment
    ice_seg_type = struct.unpack("<I", data[ice_off:ice_off+4])[0]
    assert ice_seg_type == SEGMENT_TYPE_ICE_E810, f"Bad ICE seg type: {ice_seg_type:#x}"
    
    ice_seg_size = struct.unpack("<I", data[ice_off+8:ice_off+12])[0]
    assert ice_off + ice_seg_size <= len(data), "ICE segment exceeds package"
    
    # Check buffer header in ICE segment
    # After ice_seg header(44) + device_table_count(4) + nvm_table_count(4) + buf_count(4)
    buf_start = ice_off + 44 + 4 + 4 + 4  # Start of buf_array[0]
    section_count = struct.unpack("<H", data[buf_start:buf_start+2])[0]
    data_end = struct.unpack("<H", data[buf_start+2:buf_start+4])[0]
    sect_type = struct.unpack("<I", data[buf_start+4:buf_start+8])[0]
    sect_offset = struct.unpack("<H", data[buf_start+8:buf_start+10])[0]
    sect_size = struct.unpack("<H", data[buf_start+10:buf_start+12])[0]
    
    assert section_count == 1, f"Bad section count: {section_count}"
    assert 12 <= data_end <= ICE_PKG_BUF_SIZE, f"Bad data_end: {data_end}"
    assert sect_type == ICE_SID_METADATA, f"Bad section type: {sect_type:#x}"
    assert sect_offset >= 12, f"Bad section offset: {sect_offset}"
    assert sect_size == 36, f"Bad section size: {sect_size}"
    assert sect_offset + sect_size <= ICE_PKG_BUF_SIZE, "Section exceeds buffer"
    
    # Check ice_meta_sect
    meta_addr = buf_start + sect_offset
    meta_ver = struct.unpack("BBBB", data[meta_addr:meta_addr+4])
    assert meta_ver == (1, 3, 0, 0), f"Bad metadata version: {meta_ver}"
    
    meta_name = data[meta_addr+4:meta_addr+4+ICE_META_SECT_NAME_SIZE]
    assert meta_name.startswith(PKG_NAME[:ICE_META_SECT_NAME_SIZE]), \
        f"Bad metadata name: {meta_name}"
    
    print(f"Package validated successfully:")
    print(f"  Total size: {len(data)} bytes")
    print(f"  Format version: {fmt_ver}")
    print(f"  Segments: {seg_count}")
    print(f"  Metadata seg at offset {meta_off}, size {meta_seg_size}")
    print(f"  ICE seg at offset {ice_off}, size {ice_seg_size}")
    print(f"  Buffer section: type={sect_type}, offset={sect_offset}, size={sect_size}")
    print(f"  Metadata: ver={meta_ver}, name={meta_name.rstrip(b'\\x00').decode()}")


def main():
    if len(sys.argv) < 2:
        output_path = "ice.pkg"
    else:
        output_path = sys.argv[1]
    
    package = build_package()
    validate_package(package)
    
    os.makedirs(os.path.dirname(output_path) if os.path.dirname(output_path) else ".", exist_ok=True)
    with open(output_path, "wb") as f:
        f.write(package)
    
    print(f"\nWritten {len(package)} bytes to {output_path}")


if __name__ == "__main__":
    main()
