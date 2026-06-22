#!/usr/bin/env bash
# tests/e2e/demo-kde-app.sh - single KDE app demo: KWrite on headless Wayland.
#
# Demonstrates the "headless Wayland desktop in a box" use case with a single,
# deterministic GUI app (KWrite) running as a direct Wayland client against a
# software-rendered waymux session (no GPU required).
#
# Steps:
#   1. Start waymuxd with llvmpipe software rendering.
#   2. Create a session and launch KWrite with a pre-filled document.
#   3. Assert the screenshot has real content (non-blank).
#   4. Record a short FFV1 clip while injecting keystrokes.
#   5. Assert codec is ffv1 and the recording has >= 2 unique frames.
#   6. Copy artifacts to ARTIFACT_DIR and print a PASS/FAIL summary.
#
# Environment:
#   ARTIFACT_DIR    destination for kde-app.png + kde-app.mkv (default: /tmp/wmx-demo-out)
#   WAYMUX_BINDIR   directory containing waymux/waymuxd (overrides auto-detect)
#   GALLIUM_DRIVER  Mesa software driver to use (default: llvmpipe)
#
# SKIP conditions: ffprobe, ffmpeg, python3, or kwrite not installed.
#
# Exit 0 = all assertions passed; non-zero = at least one assertion failed.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd))"

# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --- Dependency checks (SKIP rather than fail on a minimal CI image) --------
command -v ffprobe >/dev/null || { echo "SKIP: ffprobe not installed"; exit 0; }
command -v ffmpeg  >/dev/null || { echo "SKIP: ffmpeg not installed";  exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 not installed"; exit 0; }
command -v kwrite  >/dev/null || { echo "SKIP: kwrite not installed";  exit 0; }

# --- Force software rendering -----------------------------------------------
# LIBGL_ALWAYS_SOFTWARE + GALLIUM_DRIVER keep every layer off the GPU.
# WAYMUX_DISABLE_SYNCOBJ avoids opening a DRM node (needed on GPU-less runners).
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER="${GALLIUM_DRIVER:-llvmpipe}"
export WAYMUX_DISABLE_SYNCOBJ=1

wmx_pick_bindir

# --- Directories ------------------------------------------------------------
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/wmx-demo-out}"
mkdir -p "$ARTIFACT_DIR"

export XDG_RUNTIME_DIR=/tmp/wmx-demo-run
rm -rf "$XDG_RUNTIME_DIR"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

SOCK="$XDG_RUNTIME_DIR/waymux.sock"

# Working scratch dir (separate from ARTIFACT_DIR so it can be ephemeral).
WORK=/tmp/wmx-demo-work
rm -rf "$WORK"; mkdir -p "$WORK"
# unique_frames() in lib.sh uses OUT as a temp dir; point it here.
OUT="$WORK"

# --- Cleanup on exit --------------------------------------------------------
cleanup() {
  # Kill KWrite by its process group (it was launched under setsid), never
  # `pkill -x kwrite`, which would also kill a developer's open KWrite.
  [ -n "${KPID:-}" ] && { kill -9 -- "-$KPID" 2>/dev/null; kill -9 "$KPID" 2>/dev/null; } || true
  kill "${DPID:-0}" 2>/dev/null || true
}
trap cleanup EXIT

# --- Start waymuxd ----------------------------------------------------------
echo "=== demo-kde-app: start waymuxd (software, syncobj disabled) ==="
waymuxd >"$WORK/daemon.log" 2>&1 &
DPID=$!
for _ in $(seq 1 400); do
  [ -S "$SOCK" ] && break
  sleep 0.05
  kill -0 "$DPID" 2>/dev/null || break
done
[ -S "$SOCK" ] && ok "daemon socket up (software rendering)" || { bad "daemon socket never appeared"; exit 1; }

# --- Create session ---------------------------------------------------------
waymux --json new demo --size 1280x800 >"$WORK/new.json" 2>&1
[ "$(jget '["ok"]' <"$WORK/new.json" 2>/dev/null)" = "True" ] \
  && ok "session 'demo' created" \
  || { bad "session create failed: $(cat "$WORK/new.json")"; exit 1; }

INNER="$XDG_RUNTIME_DIR/waymux/demo/wayland.sock"

# --- Pre-fill a document so the editor body shows real content --------------
# An empty file produces a legitimately blank editor center, which would make
# the assert_content check meaningless. 50 lines of text guarantee glyphs fill
# the visible area regardless of window size.
DOCFILE="$WORK/note.txt"
: >"$DOCFILE"
for i in $(seq 1 50); do
  printf 'line %02d  waymux headless Wayland demo rendered by llvmpipe (no GPU)\n' "$i" >>"$DOCFILE"
done

# --- Launch KWrite as a direct Wayland client -------------------------------
WAYLAND_DISPLAY="$INNER" QT_QPA_PLATFORM=wayland setsid kwrite "$DOCFILE" \
  >"$WORK/kwrite.log" 2>&1 &
KPID=$!   # session leader; cleanup kills the whole process group via -$KPID

KN=$(wait_window demo kwrite)
[ "$KN" -ge 1 ] 2>/dev/null \
  && ok "KWrite registered as a direct Wayland client ($KN window(s))" \
  || bad "KWrite window never appeared (see $WORK/kwrite.log)"

# Let the compositor settle before screenshotting.
waymux idle demo --quiet-ms 700 --timeout-ms 6000 >/dev/null 2>&1 || true

# --- Screenshot and content assertion ---------------------------------------
waymux screenshot-desktop demo -o "$WORK/kde-app.png" >/dev/null 2>&1
assert_content "KWrite screenshot" "$WORK/kde-app.png"

# --- Record + inject keystrokes ---------------------------------------------
waymux --json record start demo --codec ffv1 --min-fps 15 >"$WORK/rec.json" 2>&1
RECPATH=$(jget '["data"]["path"]' <"$WORK/rec.json" 2>/dev/null || echo "")
[ -n "$RECPATH" ] && [ "$RECPATH" != "None" ] \
  && ok "recording started ($RECPATH)" \
  || bad "record start failed: $(cat "$WORK/rec.json")"

# Inject "WAYMUX" one key at a time (evdev keycodes: W=17 A=30 Y=21 M=50 U=22 X=45).
# Each keystroke re-commits the editor surface, producing distinct captured frames.
for kc in 17 30 21 50 22 45; do
  waymux key demo "$kc" >/dev/null 2>&1
  waymux idle demo --quiet-ms 250 --timeout-ms 1500 >/dev/null 2>&1 || true
done

waymux --json record stop demo >/dev/null 2>&1
waymux idle demo --quiet-ms 800 --timeout-ms 2500 >/dev/null 2>&1 || true

# --- Validate recording -----------------------------------------------------
if [ -n "$RECPATH" ] && [ -f "$RECPATH" ]; then
  CODEC=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name -of csv=p=0 "$RECPATH" 2>/dev/null)
  UNIQ=$(unique_frames "$RECPATH")
  if [ "$CODEC" = "ffv1" ] && [ "${UNIQ:-0}" -ge 2 ] 2>/dev/null; then
    ok "recording is FFV1 with $UNIQ unique frames (keystrokes captured, not duplicate padding)"
  else
    bad "recording check failed: codec=$CODEC unique_frames=${UNIQ:-?} (want ffv1, >=2)"
  fi
else
  bad "recording file missing: ${RECPATH:-<empty>}"
fi

# --- Copy artifacts ---------------------------------------------------------
if [ -f "$WORK/kde-app.png" ]; then
  cp "$WORK/kde-app.png" "$ARTIFACT_DIR/kde-app.png"
fi
if [ -n "${RECPATH:-}" ] && [ -f "$RECPATH" ]; then
  cp "$RECPATH" "$ARTIFACT_DIR/kde-app.mkv"
fi

# --- Teardown session -------------------------------------------------------
waymux --json rm demo >/dev/null 2>&1 || true

echo
echo "===== demo-kde-app: $PASS passed, $FAIL failed ====="
[ "$FAIL" -eq 0 ]
