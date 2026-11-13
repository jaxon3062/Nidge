#!/bin/bash
# M0 feasibility probe: talk to the Z5II over PTP/IP with gphoto2 and record
# what happens. Run on the Mac while it is joined to the camera's Wi-Fi.
# Needs no internet once gphoto2 is installed.
#
#   scripts/m0-probe.sh            # camera IP taken from the Wi-Fi router address
#   scripts/m0-probe.sh 192.168.1.1
#
# Results go to m0-results/<timestamp>/ (git-ignored). report.txt is the file
# to share; the packet capture and downloaded images stay on the Mac.
#
# Asks for the Mac password once, to record the packets with tcpdump. Homebrew's
# libgphoto2 is built with --disable-debug, so gphoto2 --debug logs nothing and
# the capture is the only wire-level record.

cd "$(dirname "$0")/.." || exit 1

if ! command -v gphoto2 >/dev/null; then
  echo "gphoto2 is not installed. While still on your normal Wi-Fi, run:"
  echo "  brew install gphoto2"
  exit 1
fi

OUT="m0-results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
REPORT="$OUT/report.txt"

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
say() { echo "$@" | tee -a "$REPORT"; }
section() { say; say "=== $* ==="; }

# Run a gphoto2 command, keep its output, exit code and duration.
run() {
  local name="$1"; shift
  local t0 t1 rc
  say "\$ gphoto2 $*"
  sleep 2  # let the camera settle after the previous session closed; not timed
  t0=$(now)
  gphoto2 "$@" >"$OUT/$name.out" 2>&1
  rc=$?
  t1=$(now)
  LAST_SECS=$(perl -e "printf '%.2f', $t1 - $t0")
  say "exit=$rc time=${LAST_SECS}s (output: $name.out)"
  return $rc
}

section "Environment"
say "date: $(date)"
say "macOS: $(sw_vers -productVersion)"
say "gphoto2: $(gphoto2 --version 2>/dev/null | grep -E '^(gphoto2|libgphoto2) +[0-9]' | tr -s ' ' | tr '\n' ';')"

section "Network"
WIFI_IF=$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2; exit}')
say "wifi interface: $WIFI_IF"
# macOS redacts the SSID from command-line tools; note it by hand.
say "mac ip: $(ipconfig getifaddr "$WIFI_IF" 2>&1)"
ROUTER=$(ipconfig getoption "$WIFI_IF" router 2>/dev/null)
say "router: $ROUTER"
say "subnet mask: $(ipconfig getoption "$WIFI_IF" subnet_mask 2>&1)"

IP="${1:-${ROUTER:-192.168.1.1}}"
say "camera ip used: $IP"

if ping -c 3 -t 5 "$IP" >"$OUT/ping.out" 2>&1; then
  say "ping: ok ($(tail -1 "$OUT/ping.out"))"
else
  say "ping: FAILED (continuing; the camera may not answer ping)"
fi
# The MAC address tells the camera apart from a home router on the same IP.
say "arp: $(arp -n "$IP" 2>&1)"
if nc -z -G 5 "$IP" 15740 >/dev/null 2>&1; then
  say "tcp 15740: open"
else
  say "tcp 15740: NOT reachable. Is the Mac really on the camera's Wi-Fi?"
fi

section "Packet capture"
PCAP="$OUT/capture.pcap"
echo "Enter your Mac password so tcpdump can record the packets:"
if sudo -v; then
  sudo tcpdump -i "$WIFI_IF" -s 0 -U -w "$PCAP" host "$IP" >"$OUT/tcpdump.log" 2>&1 &
  trap 'sudo -n pkill -f "$PCAP" 2>/dev/null || sudo pkill -f "$PCAP"; sleep 1; say "capture: $(wc -c <"$PCAP" 2>/dev/null || echo 0) bytes"' EXIT
  sleep 2
  say "capture: started ($PCAP)"
else
  say "capture: NOT started (sudo failed); continuing without it"
fi

PORT="ptpip:$IP"

section "Summary (handshake, DeviceInfo)"
if run summary --port "$PORT" --summary; then
  cat "$OUT/summary.out" >>"$REPORT"
else
  say "SUMMARY FAILED. Output:"
  cat "$OUT/summary.out" | tee -a "$REPORT"
  say
  say "Note anything the camera screen showed, then share $REPORT"
  exit 2
fi

section "Storage info"
run storage --port "$PORT" --storage-info && cat "$OUT/storage.out" >>"$REPORT"

section "File listing"
run list --port "$PORT" --list-files
COUNT=$(grep -c '^#' "$OUT/list.out")
say "objects listed: $COUNT in ${LAST_SECS}s"
say "by extension:"
grep '^#' "$OUT/list.out" | awk '{print $2}' | sed 's/.*\.//' | sort | uniq -c | tee -a "$REPORT"
say "first 5 and last 5 lines:"
grep '^#' "$OUT/list.out" | head -5 | tee -a "$REPORT"
grep '^#' "$OUT/list.out" | tail -5 | tee -a "$REPORT"

# Pick the last JPEG (newest) and, if present, the last HEIF.
pick() { grep '^#' "$OUT/list.out" | grep -iE "\.($1)[[:space:]]" | tail -1 | sed -E 's/^#([0-9]+).*/\1/'; }
JPG=$(pick 'jpg|jpeg')
HIF=$(pick 'hif|heic|heif')
say "chosen JPEG index: ${JPG:-none}; HEIF index: ${HIF:-none}"

fetch() {
  local label="$1" idx="$2" f bytes
  [ -z "$idx" ] && { say "$label: no such file on card, skipped"; return; }

  section "$label thumbnail (#$idx)"
  run "$label-thumb" --port "$PORT" --get-thumbnail "$idx" \
    --filename "$OUT/$label-thumb-%f.%C" --force-overwrite
  ls -l "$OUT" | grep "$label-thumb-" | tee -a "$REPORT"

  section "$label full file (#$idx)"
  run "$label-file" --port "$PORT" --get-file "$idx" \
    --filename "$OUT/$label-file-%f.%C" --force-overwrite
  f=$(ls "$OUT"/"$label"-file-* 2>/dev/null | grep -v -e '\.out$' -e '\.log$' | head -1)
  if [ -n "$f" ]; then
    bytes=$(stat -f %z "$f")
    say "downloaded: $(basename "$f") $bytes bytes in ${LAST_SECS}s (includes connect time)"
    say "throughput: $(perl -e "printf '%.2f', $bytes / 1048576 / $LAST_SECS") MB/s"
    say "file type: $(file -b "$f")"
    say "sha256: $(shasum -a 256 "$f" | cut -d' ' -f1)"
  else
    say "NO FILE DOWNLOADED. Output:"
    cat "$OUT/$label-file.out" | tee -a "$REPORT"
  fi
}

fetch jpeg "$JPG"
fetch heif "$HIF"

section "Done"
say "Report: $REPORT"
say "Rejoin your normal Wi-Fi and share the contents of that file."
