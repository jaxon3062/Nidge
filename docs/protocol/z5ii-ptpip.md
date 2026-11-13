# Z5II PTP/IP findings

Status: **M0 run on the real Z5II on 2026-11-13 (firmware 1.20). Gate passed.**
Section 1 is reference data from libgphoto2 source. Sections 2 to 6 are what
was observed with gphoto2 2.5.32 / libgphoto2 2.5.34 on macOS 26.6, read from a
tcpdump capture of the session. Anything not observed is marked as such.

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

## 2. Network (observed)

- Camera Wi-Fi mode used: started by hand on the camera from Settings >
  Network menu > Connect to smart device > Wi-Fi connection (AP), as the owner
  reported it. The network is password-protected; the password shown by the
  camera is typed on the Mac. SSID is `NIKON_Z5_2_<5 digits>`; security is
  WPA2-PSK/WPA3-SAE (both read off the camera by the owner).
- Camera is the access point and DHCP server at `192.168.1.1`; the Mac got
  `192.168.1.2`, mask `255.255.255.0`. The camera answers ping. Its MAC
  address starts `3c:be:e1`.
- TCP port 15740 open. Nothing else was probed.
- `192.168.1.1` is also a common home-router address (it is the owner's), so
  the IP alone does not prove the phone is on the camera's network.
- **The camera's Wi-Fi goes away without warning.** In two of four later runs
  the access point stopped answering about 2 s after a CloseSession (once
  after a listing session, once after a download session): the next SYN got
  no reply and the Mac fell back to the home network within about 10 s. The
  camera sent no event first and closed both TCP connections normally. The
  owner's reading is that the camera shuts Wi-Fi down early. Other runs did
  five and seven sessions in a row without a drop, so the trigger is unknown.
  Two failed attempts before the very first run are probably the same thing.
- Consequences for the client: connect with retries, treat "port 15740
  refused" as "wrong network", and prefer one long session over many short
  ones. Whether a session that stays open keeps the Wi-Fi up is untested.

## 3. Handshake (observed)

- A third-party Init Command Request gets an **Init Command Ack** within about
  5 ms. No Init Fail was seen in any session, over five runs.
- No extra authentication on the wire: Init Command Request/Ack on the first
  TCP connection, Init Event Request/Ack on a second one, then OpenSession.
- The camera showed no pairing or confirmation prompt (owner's observation).
  Joining the Wi-Fi with its password was the only gate.
- GUID / friendly name: gphoto2 sent its own stored 16-byte GUID and the Mac's
  hostname, protocol version 1.0 (`0x00010000`). Whether the camera would
  accept a different or new GUID was not tested.
- The Ack carries a 16-byte camera GUID, the name `Z5_2_<7 digits>` and
  version 1.0. The connection number goes up by one per session (1 to 5).
- CloseSession usually takes 500 to 600 ms to answer, sometimes 30 to 200 ms.
  A new session 2 s later usually worked; see the Wi-Fi drops in section 2.
  Both drops followed a fast CloseSession (27 and 48 ms), but fast ones also
  occurred without a drop.
- No Ping/Pong was seen; the longest session was 25 s. Idle timeout unknown.
- The event connection delivered two DevicePropChanged (0x4006) events for
  property 0x5007 during the download session, with transaction ID
  0xFFFFFFFF.

## 4. Operations that worked (observed)

| Step | Command | Result |
|---|---|---|
| Summary | `gphoto2 --port ptpip:192.168.1.1 --summary` | OK, 6.0 s (330 GetDevicePropDesc calls) |
| Storage | `--storage-info` | OK, 0.8 s |
| List | `--list-files` | OK, 1211 objects, 25.6 s |
| Thumbnail | `--get-thumbnail 1210` | OK, 9558-byte 160x120 JPEG |
| JPEG | `--get-file 1210` | OK, 9,881,243 bytes, valid JPEG with EXIF |
| HEIF thumbnail | `--get-thumbnail 1212` | OK, 7986-byte 160x120 JPEG |
| HEIF | `--get-file 1212` | OK, 2,762,328 bytes, valid HEIF (HEVC Main 10) |

Operations seen on the wire, all answered 0x2001 OK unless noted:

| Operation | Code | Notes |
|---|---|---|
| OpenSession | 0x1002 | session ID 1 |
| GetDeviceInfo | 0x1001 | 605 bytes |
| GetStorageIDs | 0x1004 | `0x00010001` (slot 1, card in) and `0x00020000` (slot 2; low word 0 means no card by PTP convention, and gphoto2 skipped it) |
| GetStorageInfo | 0x1005 | slot 1 only |
| GetObjectHandles | 0x1007 | params storage, 0, parent. Parent 0xFFFFFFFF gives the root (`DCIM`). 1211 handles came back in 28 ms |
| GetObjectInfo | 0x1008 | one call per object, median 9 to 15 ms |
| GetThumb | 0x100A | 22 ms |
| GetPartialObject | 0x101B | params handle, offset, max bytes; 1 MiB chunks; the response parameter is the byte count |
| GetDevicePropDesc | 0x1014 | 0x200A DevicePropNotSupported for some Nikon properties gphoto2 guesses |
| NIKON_GetVendorCodes | 0x9439 | param 0xD, 1240 bytes, not decoded |
| NIKON_EndLiveView | 0x9202 | sent by gphoto2 on exit |
| CloseSession | 0x1003 | slow, see section 3 |

Not exercised: GetObject (0x1009), GetLargeThumb (0x90C4), GetPartialObjectEx
(0x9431), GetObjectSize (0x9421), GetObjectsMetaData (0x9434),
GetPartialObjectHiSpeed (0x9400). All are in the supported list below but
untested.

### DeviceInfo

- StandardVersion 100, VendorExtensionID `0xFFFFFFFF` on the wire,
  VendorExtensionVersion 110, description `Microsoft.com/DeviceServices: 1.0`.
  libgphoto2 rewrites the ID to Nikon's 0xA from the manufacturer string, so
  the client must not rely on the ID to enable Nikon operations.
- Manufacturer `Nikon Corporation`, model `Z5_2`, version `V1.20`.
- Not in the supported list: GetFileInfoInBlock (0x9011), GetVendorPropCodes
  (0x90CA), GetDevicePTPIPInfo (0x90E0).

Supported operations (130). Names are libgphoto2's:

```
0x1001 GetDeviceInfo
0x1002 OpenSession
0x1003 CloseSession
0x1004 GetStorageIDs
0x1005 GetStorageInfo
0x1006 GetNumObjects
0x1007 GetObjectHandles
0x1008 GetObjectInfo
0x1009 GetObject
0x100A GetThumb
0x100B DeleteObject
0x100E InitiateCapture
0x100F FormatStore
0x1012 SetObjectProtection
0x1014 GetDevicePropDesc
0x1015 GetDevicePropValue
0x1016 SetDevicePropValue
0x101B GetPartialObject
0x90C0 NIKON_InitiateCaptureRecInSdram
0x90C1 NIKON_AfDrive
0x90C2 NIKON_ChangeCameraMode
0x90C3 NIKON_DelImageSDRAM
0x90C4 NIKON_GetLargeThumb
0x90C7 NIKON_GetEvent
0x90C8 NIKON_DeviceReady
0x90C9 NIKON_SetPreWBData
0x90CB NIKON_AfCaptureSDRAM
0x90CC NIKON_GetPictCtrlData
0x90CD NIKON_SetPictCtrlData
0x90CE NIKON_DelCstPicCtrl
0x90CF NIKON_GetPicCtrlCapability
0x9201 NIKON_StartLiveView
0x9202 NIKON_EndLiveView
0x9203 NIKON_GetLiveViewImg
0x9204 NIKON_MfDrive
0x9205 NIKON_ChangeAfArea
0x9206 NIKON_AfDriveCancel
0x9207 NIKON_InitiateCaptureRecInMedia
0x9209 NIKON_GetVendorStorageIDs
0x920A NIKON_StartMovieRecInCard
0x920B NIKON_EndMovieRec
0x920C NIKON_TerminateCapture
0x920F NIKON_GetFhdPicture
0x9400 NIKON_GetPartialObjectHiSpeed
0x9402 NIKON_StartSpotWb
0x9403 NIKON_EndSpotWb
0x9404 NIKON_ChangeSpotWbArea
0x9405 NIKON_MeasureSpotWb
0x9406 NIKON_EndSpotWbResultDisp
0x940C NIKON_CancelImagesInSDRAM
0x941C NIKON_GetEventEx
0x9420 NIKON_SaveCameraSetting
0x9421 NIKON_GetObjectSize
0x9422 NIKON_ChangeMonitorOff
0x9423 NIKON_GetLiveViewCompressedSize
0x9424 NIKON_StartTracking
0x9425 NIKON_EndTracking
0x9426 NIKON_ChangeAELock
0x9428 NIKON_GetLiveViewImageEx
0x9431 NIKON_GetPartialObjectEx
0x9433 NIKON_InitiatePixelMapping
0x9434 NIKON_GetObjectsMetaData
0x9435 NIKON_ChangeApplicationMode
0x9436 NIKON_ResetMenu
0x9439 NIKON_GetVendorCodes
```

Supported but not named in libgphoto2's `ptp.h` (65):

```
0x9401 0x9412 0x9413 0x942E 0x942F 0x943A 0x943B 0x943C 0x943D 0x943E
0x943F 0x9440 0x9441 0x9442 0x9443 0x9444 0x9445 0x9446 0x9447 0x944C
0x944D 0x944E 0x944F 0x9450 0x9451 0x9452 0x9453 0x9454 0x9455 0x9456
0x9457 0x9458 0x9459 0x945A 0x9461 0x9463 0x9464 0x9465 0x9466 0x9467
0x9468 0x9469 0x946A 0x946B 0x946D 0x946E 0x946F 0x9470 0x948B 0x948C
0x948D 0x948E 0x9520 0x9521 0x9522 0x9523 0x9527 0x9528 0x9529 0x952A
0x9530 0x9531 0x9532 0x9533 0x9535
```

Supported events (26): 0x4001 to 0x400A, 0x400C, 0x400D, 0xC101, 0xC102,
0xC105, 0xC108, 0xC10A to 0xC10E, 0xC125 to 0xC128, 0xC700.

### Object format codes

Read from GetObjectInfo for every object on the card (1213 after a HEIF+NEF
shot was added for the second set of runs):

| Kind | ObjectFormat | ThumbFormat | Count |
|---|---|---|---|
| JPEG (`.JPG`) | 0x3801 | 0x3808, 160x120 | 727 |
| NEF (`.NEF`) | 0x3000 (Undefined) | 0x3808, 160x120 | 475 |
| Video (`.MOV`) | 0x300D | 0x3808, 160x120 | 10 |
| Folder | 0x3001 | none | 2 |
| HEIF (`.HIF`) | **0xB200** | 0x3808, 160x120 | 1 |

- The download filter is "ObjectFormat is 0x3801 or 0xB200". NEF has no code
  of its own (0x3000 is "Undefined"), so do not filter by excluding a NEF
  code. HEIF was seen on one file only.
- DeviceInfo's image formats are 0x3801, 0x3000, 0x3001, 0x3008, 0x380D,
  0x3002, 0x300D, 0xB200, 0xB201, 0xB982. 0xB200 and 0xB201 are not in
  `ptp.h`. 0xB201 was not seen on any object.
- Layout: `DCIM` (handle 0x11004000) > `100NZ5_2` (0x11190000) > files.
  Handles for the same shot share the low 28 bits and differ in the top
  nibble: 0x2 JPEG, 0x0 NEF, 0x6 HEIF, 0x5 MOV (for example 0x691909B8
  `DSC_2488.HIF` and 0x091909B8 `DSC_2488.NEF`). Seen on this card only; do
  not rely on it.
- Dates are local camera time, `YYYYMMDDThhmmss`, no time zone.

## 5. Performance (observed, one run)

- Objects on card: 1211 (727 JPEG, 474 NEF, 10 MOV), 128 GB card in slot 1.
- Handle list: one GetObjectHandles call, 28 ms for 1211 handles.
- Full listing the gphoto2 way (one GetObjectInfo per object): 24.8 s in the
  first session, 12.8 s and 13.9 s in the next two; median 9 to 15 ms per
  call, occasional calls of 200 to 500 ms. About 10 to 20 ms per object.
- Thumbnail: 9558 bytes in 22 ms.
- JPEG download: 9,881,243 bytes in about 5.9 s with GetPartialObject in
  1 MiB chunks, **1.4 to 1.8 MB/s** per chunk (about 1.7 MB/s overall), the
  same in two later runs. Wi-Fi band and distance were not recorded.
- HEIF download: 2,762,328 bytes in 1.7 s, 1.6 to 1.8 MB/s per chunk.
- The probe script's "0.47 MB/s" is wrong as a throughput figure: it includes
  the 14 s gphoto2 spent re-listing the card before the download.

## 6. Gate

A file downloaded from the Z5II by a non-Nikon client: **passed, 2026-11-13.**
gphoto2 downloaded `DSC_2487.JPG` (9,881,243 bytes, equal to the size the
camera reported) over PTP/IP. It was not compared byte for byte with the card
copy. A later run also downloaded `DSC_2488.HIF` (2,762,328 bytes, equal to
the reported size), and the JPEG's SHA-256 was identical across three runs.

Open after M0:

- Why the camera's Wi-Fi drops, and whether one long-lived session avoids it.
- Whether a fresh GUID is accepted, and the idle timeout.
- The faster Nikon operations (GetPartialObjectEx, GetObjectsMetaData,
  GetLargeThumb) are advertised but untested.
