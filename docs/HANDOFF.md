# Handoff: cloud session to local Mac session (2026-11-13)

Read `CLAUDE.md` and `docs/PLAN.md` first; they are the source of truth. This
file only covers what happened so far and what to do next. Delete it once M0
is reported.

## State

- **Milestone: M0, not started on the camera.** Nothing has been tested on the
  Z5II. The gate (a file downloaded by a non-Nikon client) is open.
- The earlier session ran in a Linux cloud container with no access to the
  Mac, the camera or the phone, so it only did preparation.
- All work is on branch `claude/jolly-clarke-ve2fo6` (pushed). `main` has only
  the plan and `CLAUDE.md`. No PR exists; the owner has not asked for one.

## What exists on the branch

- `docs/protocol/z5ii-ptpip.md`: findings file. Section 1 holds PTP/IP packet
  types and opcodes checked against libgphoto2 `ptp.h` (master, 2026-11-13).
  Sections 2 to 6 are empty templates for the camera results.
- `scripts/m0-probe.sh`: unattended M0 probe. Runs gphoto2 summary, storage
  info, file listing, then thumbnail and full download of the newest JPEG and
  newest HEIF, with timings. Writes `m0-results/<timestamp>/report.txt`
  (git-ignored). **Syntax-checked only; never run on macOS or against the
  camera.** Expect to fix it on first run.
- `.gitignore`: ignores `m0-results/`.

## Things learned

- The plan's from-memory opcodes are right: GetLargeThumb `0x90C4`,
  GetPartialObjectEx `0x9431`. Standard opcodes match too.
- libgphoto2's `ptp.h` defines no Nikon or generic HEIF object format code and
  no NEF-specific one. Read the codes the Z5II reports from GetObjectInfo;
  the app's JPEG/HEIF filter depends on them.
- The Z5II is not in libgphoto2's USB model table (Z5 and Z50II are). Expected
  not to matter over `ptpip:`, but unconfirmed.

## The Wi-Fi problem

Joining the camera's Wi-Fi takes the Mac off the internet, so the session
loses contact with Claude while connected to the camera. The owner has no
Lightning cable at hand, so iPhone USB tethering is out for now, and there is
no known Ethernet connection. Hence the unattended script: the owner joins the
camera network, runs the script, rejoins normal Wi-Fi, and the results are
read from disk.

If a cable or Ethernet becomes available: connect it, put that service above
Wi-Fi in System Settings > Network > Set Service Order, and work
interactively instead. Untested with this camera.

## Next steps for the local session

1. Check out `claude/jolly-clarke-ve2fo6` and confirm `gphoto2` is installed
   (`brew install gphoto2` if not) while still online.
2. Give the owner numbered instructions, then wait:
   1. Card with at least one JPEG (and one HEIF if possible) in the Z5II.
   2. Start Wi-Fi from the camera's smart-device connection menu. The exact
      Z5II menu labels are unknown; ask the owner what they pressed and
      record it.
   3. Join that SSID on the Mac.
   4. Run `scripts/m0-probe.sh` (or `scripts/m0-probe.sh <ip>` if the default
      fails), watching the camera screen for any pairing prompt.
   5. Rejoin normal Wi-Fi and say so.
3. Read `m0-results/<latest>/report.txt` and the `*.debug.log` files directly
   from disk. The report contains the camera serial number; do not commit it
   or paste it into the public repo.
4. If the camera rejects gphoto2: follow M0 step 4 in the plan (capture a real
   SnapBridge download with `rvictl -s <UDID>` and Wireshark on `rvi0`, and
   document the handshake difference). That needs the phone on USB, so it
   needs a cable.
5. Fill in sections 2 to 6 of `docs/protocol/z5ii-ptpip.md` with what was
   actually observed, including the HEIF/NEF format codes and the supported
   operations list from the summary.
6. Report the gate result to the owner and stop. Do not start M1 until the
   owner has seen it.

## Standing rules from the owner

- Commit as you go; **push only when the owner asks.**
- Licence is undecided (MIT recommended); ask before adding a LICENSE file.
- Reference projects (`hurui200320/nsg` AGPL, `gkoh/furble` MIT, libgphoto2)
  are for protocol reference only; copy no code.
- No "SnapBridge", "Nikon" or Nikon logos in the app name, icon or bundle ID.
- Never state that a protocol behaviour works without a test on the real
  camera.
