# Z5II PTP/IP findings

Status: **M0 not run yet. Nothing in this file has been tested on the camera.**
Section 1 is reference data checked against libgphoto2 source only. Sections 2
onward are to be filled in from the real Z5II.

## 1. Reference numbers (checked against libgphoto2 `camlibs/ptp2/ptp.h`, master, 2026-11-13)

These confirm the numbers quoted from memory in `docs/PLAN.md`. They say what
libgphoto2 calls each code, not that the Z5II supports it.

PTP/IP packet types:

| Type | Value |
|---|---|
| Init Command Request | 1 |
| Init Command Ack | 2 |
| Init Event Request | 3 |
| Init Event Ack | 4 |
| Init Fail | 5 |
| Command Request | 6 |
| Command Response | 7 |
| Event | 8 |
| Start Data | 9 |
| Data | 10 |
| Cancel Transaction | 11 |
| End Data | 12 |
| Ping | 13 |
| Pong | 14 |

Standard operations:

| Operation | Code |
|---|---|
| GetDeviceInfo | 0x1001 |
| OpenSession | 0x1002 |
| CloseSession | 0x1003 |
| GetStorageIDs | 0x1004 |
| GetStorageInfo | 0x1005 |
| GetObjectHandles | 0x1007 |
| GetObjectInfo | 0x1008 |
| GetObject | 0x1009 |
| GetThumb | 0x100A |
| GetPartialObject | 0x101B |

Nikon vendor operations that may matter for download:

| Operation | Code | Notes from ptp.h |
|---|---|---|
| GetFileInfoInBlock | 0x9011 | |
| GetLargeThumb | 0x90C4 | plan's number confirmed |
| GetEvent | 0x90C7 | no params, data in |
| DeviceReady | 0x90C8 | |
| GetVendorPropCodes | 0x90CA | |
| GetDevicePTPIPInfo | 0x90E0 | |
| GetPreviewImg | 0x9200 | |
| GetVendorStorageIDs | 0x9209 | |
| GetPartialObjectHiSpeed | 0x9400 | p1 handle, p2 32-bit size, p3 terminate flag |
| GetEventEx | 0x941C | |
| GetObjectSize | 0x9421 | p1 handle; 64-bit size as data |
| GetPartialObjectEx | 0x9431 | plan's number confirmed. p1 handle, p2/p3 offset lo/hi, p4/p5 max size lo/hi |
| GetObjectsMetaData | 0x9434 | |

Object formats: EXIF/JPEG is 0x3801. `ptp.h` has no generic or Nikon HEIF
format code (only a Sony one), and no NEF-specific code, so the codes the Z5II
reports for HEIF and NEF must be read from GetObjectInfo on the camera.

The Z5II is not in libgphoto2's USB model table (`library.c` lists Z5 and
Z50II but not Z5II). That table is keyed on USB IDs, so it should not matter
for `ptpip:`, where the vendor extension comes from DeviceInfo. To confirm.

## 2. Network (to test)

- Camera Wi-Fi mode used:
- SSID pattern / security:
- Camera IP, Mac IP, DHCP range:
- Port 15740 open:

## 3. Handshake (to test)

- Does a third-party Init Command Request get an Ack, or Init Fail?
- Does the camera show a pairing/confirmation prompt?
- GUID / friendly-name requirements:

## 4. Operations that worked (to test)

| Step | Command | Result |
|---|---|---|
| Summary | `gphoto2 --port ptpip:192.168.1.1 --summary` | |
| List | `gphoto2 --port ptpip:192.168.1.1 --list-files` | |
| Thumbnail | `--get-thumbnail N` | |
| JPEG | `--get-file N` | |

Supported operation list from DeviceInfo:

## 5. Performance (to test)

- Number of objects on card:
- Listing time:
- Throughput for one JPEG (size, seconds, MB/s):

## 6. Gate

A file downloaded from the Z5II by a non-Nikon client: **not yet attempted.**
