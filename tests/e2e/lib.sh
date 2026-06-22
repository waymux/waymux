#!/usr/bin/env bash
# tests/e2e/lib.sh - shared helpers for waymux end-to-end test scripts.
#
# Source this file; do NOT execute it directly. It defines helper functions
# and two counters (PASS, FAIL). No set -e or set -u at the top level so it
# is safe to source from scripts with any error-handling settings.
#
# Functions exported:
#   ok  <msg>                     record a passing assertion
#   bad <msg>                     record a failing assertion
#   jget <key-expr>               extract a field from JSON on stdin
#   luma_range <png>              full-frame luma spread (YMAX - YMIN)
#   center_contrast <png>         luma spread of a centered crop
#   assert_content <label> <png>  ok/bad based on luma checks
#   unique_frames <mkv>           count of unique (non-duplicate) frames
#   wait_window <session> <app>   wait for a window to appear, echo count
#   wmx_pick_bindir               set BINDIR and prepend it to PATH

PASS=0; FAIL=0

ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
jget(){ python3 -c "import sys,json;d=json.load(sys.stdin);print(eval('d'+sys.argv[1]))" "$1"; }

# Full-frame luma spread: 0 means a perfectly flat frame (blank).
luma_range() {
  ffprobe -v error -f lavfi -i "movie=$1,signalstats" \
    -show_entries frame_tags=lavfi.signalstats.YMIN,lavfi.signalstats.YMAX \
    -of csv=p=0 2>/dev/null | head -1 | awk -F, '{print ($2+0)-($1+0)}'
}

# Luma contrast (YMAX-YMIN) of a centered crop. This is theme-agnostic: a blank
# region (white OR black) has near-zero spread, while real content (a gradient,
# or black glyphs on a white editor body) has a large spread. Mean luma would
# falsely flag a light-themed text editor as blank, so we use spread, not mean.
center_contrast() {
  ffprobe -v error -f lavfi -i "movie=$1,crop=min(400\,iw):min(300\,ih):(iw-min(400\,iw))/2:(ih-min(300\,ih))/2,signalstats" \
    -show_entries frame_tags=lavfi.signalstats.YMIN,lavfi.signalstats.YMAX \
    -of csv=p=0 2>/dev/null | head -1 | awk -F, '{print ($2+0)-($1+0)}'
}

# A capture has real content if the frame is not flat AND its center region has
# contrast (is not a blank patch). Catches the "chrome rendered but body blank"
# false positive that a full-frame check alone would miss.
assert_content() {
  local label="$1" png="$2"
  [ -f "$png" ] || { bad "$label: no screenshot file"; return 1; }
  local dims rng cc
  dims=$(ffprobe -v error -show_entries stream=width,height -of csv=p=0 "$png" 2>/dev/null)
  rng=$(luma_range "$png"); cc=$(center_contrast "$png")
  if [ "${rng:-0}" -ge 40 ] 2>/dev/null && [ "${cc:-0}" -ge 25 ] 2>/dev/null; then
    ok "$label: non-blank content (dims=$dims frameRange=$rng centerContrast=$cc)"
  else
    bad "$label: looks blank (dims=$dims frameRange=$rng centerContrast=$cc)"
  fi
}

# Count of UNIQUE frames after dropping duplicates. Recording pads to --min-fps
# with duplicate frames; mpdecimate strips those, leaving only frames that
# actually changed. This is the honest "did motion get captured" check.
unique_frames() {
  local f="$1"
  local u="${OUT:-/tmp}/uniq-$(basename "$f").mkv"
  ffmpeg -hide_banner -loglevel error -i "$f" -vf "mpdecimate,setpts=N/FRAME_RATE/TB" -an "$u" -y >/dev/null 2>&1
  ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$u" 2>/dev/null
}

# Wait for a window to register in a session (returns the count seen).
wait_window() {
  local sess="$1" want_app="$2" n=0
  for _ in $(seq 1 150); do
    n=$(waymux --json windows "$sess" 2>/dev/null | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"]["windows"]))' 2>/dev/null || echo 0)
    [ "$n" -ge 1 ] && break
    sleep 0.2
  done
  echo "$n"
}

# Locate built binaries and prepend BINDIR to PATH.
# Priority: WAYMUX_BINDIR env var > target/debug > target/release.
# Sets and exports both BINDIR and PATH.
wmx_pick_bindir() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd))"
  BINDIR="${WAYMUX_BINDIR:-}"
  if [ -z "$BINDIR" ]; then
    if   [ -x "$root/target/debug/waymuxd" ];   then BINDIR="$root/target/debug"
    elif [ -x "$root/target/release/waymuxd" ]; then BINDIR="$root/target/release"
    else BINDIR="$root/target/debug"; fi
  fi
  export PATH="$BINDIR:$PATH"
}
