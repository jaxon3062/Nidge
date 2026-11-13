#!/bin/bash
# M1 gate probe: run nidge-cli against the Z5II. Run on the Mac while it is joined to the
# camera's Wi-Fi. Needs the card to still hold DSC_2487.JPG and DSC_2488.HIF, and the gphoto2
# copies of them from the M0 run for comparison.
#
#   scripts/m1-probe.sh [camera-ip]
#
# Results go to m1-results/<timestamp>/ (git-ignored); report.txt is the summary.

cd "$(dirname "$0")/.." || exit 1
IP="${1:-192.168.1.1}"
JPG=DSC_2487.JPG
HIF=DSC_2488.HIF
REF=m0-results/20261113-180033

OUT="m1-results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT/a" "$OUT/b"
REPORT="$OUT/report.txt"
say() { echo "$@" | tee -a "$REPORT"; }
section() { say; say "=== $* ==="; }
sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

# Built before the capture starts; needs no network.
(cd Tools/nidge-cli && swift build -c release 2>&1 | tail -1) | tee -a "$REPORT"
CLI="$(cd Tools/nidge-cli && swift build -c release --show-bin-path)/nidge-cli"
[ -x "$CLI" ] || { say "nidge-cli did not build"; exit 1; }
cli() { say "\$ nidge-cli $*"; "$CLI" --host "$IP" "$@" 2>&1 | tee -a "$REPORT"; }

section "Network"
say "date: $(date)"
say "arp: $(arp -n "$IP" 2>&1 | sed -E 's/(([0-9a-f]{1,2}:){3})[0-9a-f:]+/\1xx:xx:xx/')"
nc -z -G 5 "$IP" 15740 >/dev/null 2>&1 && say "tcp 15740: open" || say "tcp 15740: NOT reachable. Is the Mac on the camera's Wi-Fi?"

PCAP="$OUT/capture.pcap"
echo "Enter your Mac password so tcpdump can record the packets:"
if sudo -v; then
  # sleep 2 in the trap: tcpdump drops packets still buffered when killed at once
  sudo tcpdump -i "$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2; exit}')" \
    -s 0 -U -w "$PCAP" host "$IP" and tcp port 15740 >"$OUT/tcpdump.log" 2>&1 &
  trap 'sleep 2; sudo -n pkill -f "$PCAP" 2>/dev/null || sudo pkill -f "$PCAP"; sleep 1; say "capture: $(wc -c <"$PCAP" 2>/dev/null || echo 0) bytes"' EXIT
  sleep 2
else
  say "capture: NOT started (sudo failed); continuing without it"
fi

section "Session 1: summary, handle queries, listing, thumbnails, downloads, 60 s hold"
# The handle queries after the first are untested on the camera: all objects (parent 0),
# JPEG only, HEIF only, folders only. A refusal is a result, not a failure of the run.
cli summary \
  + handles 0x10001 \
  + handles 0x10001 0 \
  + handles 0x10001 0 0x3801 \
  + handles 0x10001 0 0xB200 \
  + handles 0x10001 0 0x3001 \
  + ls --last 6 \
  + thumb "$JPG" "$OUT/a" + thumb "$HIF" "$OUT/a" \
  + get "$JPG" "$OUT/a" + get "$HIF" "$OUT/a" \
  + hold 60

section "Byte comparison with the gphoto2 copies from M0"
for pair in "$JPG:jpeg-file-$JPG" "$HIF:heif-file-$HIF"; do
  new="$OUT/a/${pair%%:*}"; old="$REF/${pair##*:}"
  if [ -f "$new" ] && cmp -s "$new" "$old"; then say "${pair%%:*}: IDENTICAL ($(sha "$new"))"
  else say "${pair%%:*}: DIFFERENT OR MISSING (new $(sha "$new"), reference $(sha "$old"))"; fi
done

section "Session 2: full listing in one session"
say "\$ nidge-cli ls > ls.out"
"$CLI" --host "$IP" ls >"$OUT/ls.out" 2>"$OUT/ls.err"; say "exit=$? lines=$(wc -l <"$OUT/ls.out" | tr -d ' ') $(tail -1 "$OUT/ls.err")"
say "formats: $(cut -f3 "$OUT/ls.out" | sort | uniq -c | tr '\n' ' ')"

section "Sessions 3 and 4: kill the client mid-download, then resume"
"$CLI" --host "$IP" get "$JPG" "$OUT/b" >"$OUT/killed.out" 2>&1 &
PID=$!
for _ in $(seq 60); do [ -s "$OUT/b/$JPG.part" ] && break; sleep 0.5; done
sleep 1.5
kill -9 $PID 2>/dev/null; wait $PID 2>/dev/null
say "killed with $(stat -f %z "$OUT/b/$JPG.part" 2>/dev/null || echo 0) bytes in $JPG.part"
sleep 2
cli get "$JPG" "$OUT/b"
if cmp -s "$OUT/b/$JPG" "$REF/jpeg-file-$JPG"; then say "resumed $JPG: IDENTICAL"; else say "resumed $JPG: DIFFERENT OR MISSING"; fi

section "Done"
nc -z -G 5 "$IP" 15740 >/dev/null 2>&1 && say "tcp 15740 at the end: open" || say "tcp 15740 at the end: NOT reachable"
say "Report: $REPORT"
say "Rejoin your normal Wi-Fi and tell Claude you are back."
