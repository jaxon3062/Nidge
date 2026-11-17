# Nidge implementation plan

Nidge is an open-source iPhone app that downloads photos from a Nikon camera
faster and more pleasantly than Nikon's own app. It does one thing: browse the
card, pick shots, download them to Apple Photos. No camera control.

## 1. Requirements (confirmed with the owner)

| Area | Decision |
|---|---|
| Scope | Photo download only. No remote shutter, live view, GPS sync, firmware, cloud. |
| Camera | Nikon Z5II (only body available for testing). |
| Phone | iPhone 13 Pro (Lightning), iOS 26. The app requires iOS 26. |
| File types | JPEG and HEIF originals. NEF and video are hidden, not downloaded. |
| Selection | Browse a thumbnail grid and pick. No "import all", no auto-transfer while shooting. |
| Destination | Apple Photos library, original files with metadata intact. |
| Connection | Automatic, like SnapBridge: pair once, then the app brings up the camera's Wi-Fi itself. |
| Background | Downloads must continue after the user leaves the app. This is the top pain point. |
| Other pain points | Slow/fiddly connecting, clunky browsing and selecting, slow or failing transfers. |
| Developer account | Free Apple ID for now; paid membership and App Store release later if the app works out. |
| Equipment | Mac with Xcode, the iPhone, the Z5II. No Android device. |

## 2. What is known and what is not

Known, from public sources:

- Nikon Z cameras speak PTP/IP over Wi-Fi (TCP port 15740, camera usually at
  `192.168.1.1` in access-point mode). gphoto2/libgphoto2 implements it and is
  the reference for opcodes, including Nikon vendor extensions.
- Bluetooth pairing in "smart device" mode has been reverse engineered:
  `hurui200320/nsg` (AGPL-3.0, includes an iOS app) and `gkoh/furble` (MIT).

Not known; each must be verified on the Z5II before code depends on it:

1. Whether the Z5II accepts a third-party PTP/IP client in its smart-device
   Wi-Fi mode without extra authentication.
2. How SnapBridge tells the camera over Bluetooth to turn Wi-Fi on, and how it
   learns the SSID and password. No public documentation was found.
3. Whether an iOS 26 continued-processing task keeps a local TCP transfer alive
   with the screen locked for the length of a real import.
4. Exact opcode numbers below are from memory. Check them against libgphoto2's
   `ptp.h` before use.

Do not present any of these as working until tested on the real camera.

## 3. Constraints that shape the design

- **Free Apple ID.** Builds expire after 7 days. The Hotspot Configuration
  capability (`NEHotspotConfiguration`, used to join the camera's Wi-Fi from
  code) is believed to be unavailable to free personal teams; confirm in Xcode.
  Until the account is paid, the user joins the camera network once in iOS
  Settings and iOS re-joins the saved network afterwards. Put Wi-Fi joining
  behind a protocol so the paid path is a drop-in.
- **No Android device.** Capture SnapBridge traffic from the iPhone instead:
  Bluetooth with Apple's Bluetooth logging profile plus PacketLogger (Additional
  Tools for Xcode); Wi-Fi with `rvictl -s <UDID>` and Wireshark on `rvi0`.
- **Simulator cannot do Bluetooth or reach the camera.** Keep the protocol code
  in a Swift package with a macOS command-line tool, so most work is tested
  from the Mac against the real camera and against a mock server.
- **Licensing.** Recommended licence: MIT. Use nsg and furble as protocol
  references only; do not copy nsg source (AGPL) into the project. The owner
  has not confirmed the licence; ask before adding a LICENSE file.
- **Branding.** Never use "SnapBridge", "Nikon" or Nikon logos in the app name,
  icon or bundle ID. "Works with Nikon Z cameras" in descriptive text is fine.

## 4. Architecture

```
Nidge.xcodeproj            iOS app, SwiftUI, iOS 26 minimum
Packages/NidgeKit/         Swift package, no UIKit dependency
  PTPIP/                   Transport on Network.framework: init handshake,
                           command/data and event connections, packet codec
  PTP/                     Sessions, operations, dataset parsing
  Camera/                  High-level API: list storages, list objects,
                           thumbnail, ranged download
  Pairing/                 Bluetooth pairing and Wi-Fi wake (CoreBluetooth)
  Tests/                   Codec tests plus an in-process mock PTP/IP server
Tools/nidge-cli/           macOS executable using NidgeKit: summary, ls,
                           thumb, get. The main test harness.
docs/protocol/             Findings and captures notes from the Z5II
```

App layers: `ConnectionManager` (state machine: idle, waking, joining,
connected, lost) -> `CameraLibrary` (object index and thumbnail cache) ->
`DownloadQueue` (actor; persistent, resumable) -> `PhotosWriter`.

PTP operations expected: OpenSession, GetDeviceInfo, GetStorageIDs,
GetObjectHandles, GetObjectInfo, GetThumb, GetPartialObject, CloseSession.
Nikon vendor candidates if needed: GetLargeThumb (0x90C4), GetPartialObjectEx
(0x9431), and Nikon's object-list operations for faster listing.

## 5. Milestones

Each milestone ends with a gate. Stop and report to the owner if a gate fails.

### M0. Feasibility on the Mac (no app code)

1. On the camera, start Wi-Fi manually from the smart-device connection menu.
   Join that network from the Mac.
2. `gphoto2 --port ptpip:192.168.1.1 --summary`, then list files, fetch one
   thumbnail and one JPEG.
3. If the camera refuses: capture a real SnapBridge download session with
   `rvictl` + Wireshark and document the handshake difference.
4. Record results in `docs/protocol/z5ii-ptpip.md`: IP, handshake, working
   opcodes, listing speed on a full card, throughput.

Gate: a file is downloaded from the Z5II by a non-Nikon client.

### M1. NidgeKit and nidge-cli

- PTP/IP codec and transport, with unit tests against recorded packets.
- Mock PTP/IP server for tests.
- Camera API: lazy object listing, thumbnails, ranged download with resume.
- `nidge-cli` reproduces everything from M0.

Gate: `nidge-cli get` downloads a JPEG and a HEIF byte-identical to the card
copy, and resumes after the connection is cut mid-file.

### M2. iOS app with manual Wi-Fi

- Onboarding: local-network and Photos add-only permissions; instructions to
  start camera Wi-Fi and join it in Settings.
- Grid: newest first, grouped by shooting day, JPEG/HEIF only, thumbnails
  loaded lazily and cached on disk keyed by filename + size + capture date.
- Selection: tap, drag-to-select, select a whole day; "already imported" badge.
- Download queue: persistent, per-file resume with GetPartialObject, automatic
  retry, clear per-file and overall progress, cancel.
- Save to Photos with `PHAssetCreationRequest` from the original file so EXIF
  and capture date survive. Record imported items to skip duplicates.

Gate: 100 selected photos import correctly with the app in the foreground,
including one forced Wi-Fi drop mid-import.

### M3. Background downloads

- Start imports as an iOS 26 continued-processing task
  (`BGContinuedProcessingTaskRequest`), reporting progress so the system shows
  it and does not expire the task.
- Handle expiry: persist queue state, notify the user, resume on next launch.
- Test on the device: switch apps, lock the screen, let the camera idle.
  Check the camera's own Wi-Fi/standby timers too.

Gate: a 100-photo import completes while the user is in other apps or the
phone is locked. If the system cuts it short, measure how far it gets and
report options to the owner before investing in workarounds.

### M4. Automatic connection

1. Pair over Bluetooth using the handshake documented by nsg/furble.
2. Capture SnapBridge on the iPhone with PacketLogger while it switches the
   camera to Wi-Fi. Identify the characteristic writes that wake Wi-Fi and
   carry SSID/password. Document in `docs/protocol/z5ii-ble.md`.
3. Implement wake-over-Bluetooth; state restoration so reconnect is fast.
4. Wi-Fi join: on a free account rely on the saved network; on a paid account
   use `NEHotspotConfiguration` for a one-tap join.

Gate: from a cold start with the camera on, the grid appears without touching
the camera menus. If step 2 fails after a time-boxed effort (suggest two
weeks), keep manual Wi-Fi start and report.

### M5. Polish and release (only after a paid account)

Error copy, empty states, accessibility, app icon, README, licence, TestFlight,
App Store review notes, wider camera testing through volunteers.

## 6. Open decisions for the owner

Requests from the owner after first using the M2 build (2026-11-17), not yet
scheduled or designed:

- **Camera page.** A main page listing cameras: remember ones used before,
  pick one to connect, and ideally find new ones without a trip to Wi-Fi
  settings. iOS apps cannot scan for Wi-Fi networks, and joining one from code
  needs `NEHotspotConfiguration` (paid account), so discovery has to come from
  Bluetooth. Do this with M4.
- **Download size and format.** Choose a smaller size instead of the
  original, and RAW when a shot has both. This changes section 1 (originals
  only, NEF hidden). The camera advertises GetLargeThumb (0x90C4) and
  GetFhdPicture (0x920F) but neither is tested, so the sizes it can produce
  are unknown; other sizes would mean downloading the original and shrinking
  it on the phone. Whether Photos accepts Z5II NEF files is untested.


- Licence (MIT recommended).
- Whether imported photos go into a dedicated "Nidge" album as well as the
  library.
- When to pay for the developer programme; M4's one-tap Wi-Fi join and any
  distribution depend on it.
