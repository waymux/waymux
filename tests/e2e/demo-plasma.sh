#!/usr/bin/env bash
# tests/e2e/demo-plasma.sh - full nested Plasma 6 desktop demo (best-effort).
#
# Demonstrates Plasma 6 (KWin + plasmashell) running inside a waymux session
# with pure software rendering (Mesa llvmpipe, no GPU required). The nested
# compositor connects to the waymux Wayland socket; KDE services are activated
# inside a dbus session so they inherit the wayland Qt platform plugin.
#
# Steps:
#   1. Start waymuxd with llvmpipe software rendering.
#   2. Create a session (1280x800) and launch nested Plasma via the recipe:
#      dbus-run-session -> kwin_wayland --socket wayland-kwin + plasmashell,
#      with dbus-update-activation-environment --all before plasmashell.
#   3. Wait up to 60s for a desktop window, idle-settle, screenshot plasma.png.
#   4. Launch dolphin into the nested desktop (best-effort; skip on failure).
#   5. Record a ~6s whole-desktop FFV1 clip to plasma.mkv.
#   6. Assert plasma.png has real content; exit non-zero on failure.
#
# Environment:
#   ARTIFACT_DIR    destination for plasma.png, plasma-app.png, plasma.mkv
#                   (default: /tmp/wmx-plasma-out)
#   WAYMUX_BINDIR   directory containing waymux/waymuxd (overrides auto-detect)
#   GALLIUM_DRIVER  Mesa software driver (default: llvmpipe)
#
# SKIP conditions: kwin_wayland or plasmashell not installed.
#
# Exit 0 = assertions passed; non-zero = at least one assertion failed.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd))"

# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --- Dependency checks (SKIP on images lacking Plasma) ----------------------
command -v kwin_wayland  >/dev/null || { echo "SKIP: kwin_wayland not installed";  exit 0; }
command -v plasmashell   >/dev/null || { echo "SKIP: plasmashell not installed";   exit 0; }
command -v dbus-run-session >/dev/null || { echo "SKIP: dbus-run-session not installed"; exit 0; }
command -v ffprobe       >/dev/null || { echo "SKIP: ffprobe not installed";       exit 0; }
command -v ffmpeg        >/dev/null || { echo "SKIP: ffmpeg not installed";        exit 0; }
command -v python3       >/dev/null || { echo "SKIP: python3 not installed";       exit 0; }

# --- Force software rendering -----------------------------------------------
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER="${GALLIUM_DRIVER:-llvmpipe}"
export WAYMUX_DISABLE_SYNCOBJ=1

wmx_pick_bindir

# --- Directories ------------------------------------------------------------
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/wmx-plasma-out}"
mkdir -p "$ARTIFACT_DIR"

export XDG_RUNTIME_DIR=/tmp/wmx-plasma-run
rm -rf "$XDG_RUNTIME_DIR"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

SOCK="$XDG_RUNTIME_DIR/waymux.sock"

WORK=/tmp/wmx-plasma-work
rm -rf "$WORK"; mkdir -p "$WORK"

# Plasma PID for cleanup (the dbus-run-session process group leader).
PPID_PLASMA=0
DPID=0
DOLPHIN_PID=0

# --- Cleanup on exit --------------------------------------------------------
cleanup() {
  # Kill the Plasma launcher process group (setsid covers kwin + plasmashell).
  [ "$PPID_PLASMA" -ne 0 ] && \
    { kill -9 -- "-$PPID_PLASMA" 2>/dev/null; kill -9 "$PPID_PLASMA" 2>/dev/null; } || true
  # Kill dolphin by its tracked process group (launched under setsid).
  [ "${DOLPHIN_PID:-0}" -ne 0 ] && \
    { kill -9 -- "-$DOLPHIN_PID" 2>/dev/null; kill -9 "$DOLPHIN_PID" 2>/dev/null; } || true
  # Belt-and-braces: reap any stray nested compositor from this run via its
  # unique socket name (this pattern cannot match an unrelated process).
  pkill -f "kwin_wayland.*wayland-kwin" 2>/dev/null || true
  # Stop the daemon.
  kill "$DPID" 2>/dev/null || true
}
trap cleanup EXIT

# --- Start waymuxd ----------------------------------------------------------
echo "=== demo-plasma: start waymuxd (software rendering, syncobj disabled) ==="
waymuxd >"$WORK/daemon.log" 2>&1 &
DPID=$!
for _ in $(seq 1 400); do
  [ -S "$SOCK" ] && break
  sleep 0.05
  kill -0 "$DPID" 2>/dev/null || break
done
[ -S "$SOCK" ] && ok "daemon socket up (software rendering)" \
               || { bad "daemon socket never appeared"; exit 1; }

# --- Create session ---------------------------------------------------------
waymux --json new plasma --size 1280x800 >"$WORK/new.json" 2>&1
[ "$(jget '["ok"]' <"$WORK/new.json" 2>/dev/null)" = "True" ] \
  && ok "session 'plasma' created" \
  || { bad "session create failed: $(cat "$WORK/new.json")"; exit 1; }

INNER="$XDG_RUNTIME_DIR/waymux/plasma/wayland.sock"

# --- Launch nested Plasma ---------------------------------------------------
# The full recipe (from the spike note):
#   1. dbus-run-session provides a fresh D-Bus session bus.
#   2. kwin_wayland listens on INNER (from waymux) and exposes its own nested
#      socket at $XDG_RUNTIME_DIR/wayland-kwin.
#   3. After wayland-kwin exists, dbus-update-activation-environment --all
#      pushes WAYLAND_DISPLAY=wayland-kwin + QT_QPA_PLATFORM=wayland into the
#      bus so KDE D-Bus-activated services (kactivitymanagerd, kded6, etc.)
#      inherit the Wayland platform and do not abort trying to open xcb.
#   4. plasmashell starts; kwin_wayland's exit drives the wait.
echo "=== demo-plasma: launching nested Plasma (dbus-run-session + kwin + plasmashell) ==="
setsid dbus-run-session -- env \
  WAYLAND_DISPLAY="$INNER" \
  KWIN_WAYLAND_NO_PERMISSION_CHECKS=1 \
  XDG_CURRENT_DESKTOP=KDE \
  QT_QPA_PLATFORM=wayland \
  bash -c '
    kwin_wayland --socket wayland-kwin --no-lockscreen >"$XDG_RUNTIME_DIR/kwin.log" 2>&1 &
    KW=$!
    for _ in $(seq 1 300); do
      [ -S "$XDG_RUNTIME_DIR/wayland-kwin" ] && break
      sleep 0.1
    done
    export WAYLAND_DISPLAY=wayland-kwin QT_QPA_PLATFORM=wayland
    dbus-update-activation-environment --all 2>/dev/null || true
    plasmashell >"$XDG_RUNTIME_DIR/plasmashell.log" 2>&1 &
    wait $KW
  ' >"$WORK/plasma-launcher.log" 2>&1 &
PPID_PLASMA=$!

# --- Wait for Plasma to present a window (up to 60s) -----------------------
echo "=== demo-plasma: waiting for desktop window (up to 60s) ==="
WN=0
for _ in $(seq 1 300); do
  WN=$(waymux --json windows plasma 2>/dev/null \
       | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"]["windows"]))' \
       2>/dev/null || echo 0)
  [ "$WN" -ge 1 ] && break
  sleep 0.2
done
[ "$WN" -ge 1 ] \
  && ok "Plasma desktop window appeared ($WN window(s))" \
  || bad "Plasma window never appeared (check $WORK/plasma-launcher.log)"

# Settle: wait for the desktop to go quiet before screenshotting.
waymux idle plasma --quiet-ms 3000 --timeout-ms 30000 >/dev/null 2>&1 || true

# --- Screenshot: full desktop (retry if the first paint has not landed) -----
echo "=== demo-plasma: taking desktop screenshot ==="
# Plasma's first paint under llvmpipe can lag the window-mapped event, so retry
# until the frame has real content (or give up after a few tries; the job is
# allow-failure either way).
for _ in $(seq 1 5); do
  waymux screenshot-desktop plasma -o "$WORK/plasma.png" >/dev/null 2>&1
  [ "$(luma_range "$WORK/plasma.png" 2>/dev/null || echo 0)" -gt 20 ] 2>/dev/null && break
  waymux idle plasma --quiet-ms 1500 --timeout-ms 6000 >/dev/null 2>&1 || true
done

# --- Open dolphin (best-effort) ---------------------------------------------
# Launch dolphin against the wayland-kwin socket inside the session's dbus env.
# We do not fail the run if dolphin never appears.
echo "=== demo-plasma: launching dolphin (best-effort) ==="
if command -v dolphin >/dev/null 2>&1; then
  WAYLAND_DISPLAY="$XDG_RUNTIME_DIR/wayland-kwin" \
  QT_QPA_PLATFORM=wayland \
  setsid dolphin >"$WORK/dolphin.log" 2>&1 &
  DOLPHIN_PID=$!
  # Wait briefly for dolphin to present (up to 8s).
  for _ in $(seq 1 40); do
    DN=$(waymux --json windows plasma 2>/dev/null \
         | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"]["windows"]))' \
         2>/dev/null || echo 0)
    [ "$DN" -ge 2 ] && break
    sleep 0.2
  done
  waymux idle plasma --quiet-ms 1000 --timeout-ms 8000 >/dev/null 2>&1 || true
  waymux screenshot-desktop plasma -o "$WORK/plasma-app.png" >/dev/null 2>&1
  if [ -f "$WORK/plasma-app.png" ]; then
    ok "dolphin screenshot taken"
    cp "$WORK/plasma-app.png" "$ARTIFACT_DIR/plasma-app.png"
  else
    echo "INFO: dolphin screenshot not captured (best-effort; continuing)"
  fi
  kill "$DOLPHIN_PID" 2>/dev/null || true
else
  echo "INFO: dolphin not installed; skipping app screenshot"
fi

# --- Record ~6s whole-desktop FFV1 clip ------------------------------------
echo "=== demo-plasma: recording whole-desktop FFV1 clip (~6s) ==="
waymux --json record start plasma --codec ffv1 --min-fps 15 --mode whole-desktop \
  >"$WORK/rec.json" 2>&1
RECPATH=$(jget '["data"]["path"]' <"$WORK/rec.json" 2>/dev/null || echo "")
[ -n "$RECPATH" ] && [ "$RECPATH" != "None" ] \
  && ok "recording started ($RECPATH)" \
  || bad "record start failed: $(cat "$WORK/rec.json")"

sleep 6

waymux --json record stop plasma >/dev/null 2>&1
waymux idle plasma --quiet-ms 800 --timeout-ms 5000 >/dev/null 2>&1 || true

# Validate recording if it was produced.
if [ -n "${RECPATH:-}" ] && [ -f "$RECPATH" ]; then
  CODEC=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name -of csv=p=0 "$RECPATH" 2>/dev/null)
  if [ "$CODEC" = "ffv1" ]; then
    ok "recording codec is ffv1"
    cp "$RECPATH" "$ARTIFACT_DIR/plasma.mkv"
  else
    bad "recording codec is '$CODEC' (expected ffv1)"
    cp "$RECPATH" "$ARTIFACT_DIR/plasma.mkv" 2>/dev/null || true
  fi
else
  bad "recording file missing: ${RECPATH:-<empty>}"
fi

# --- Final assertion: non-blank Plasma screenshot ---------------------------
cp "$WORK/plasma.png" "$ARTIFACT_DIR/plasma.png" 2>/dev/null || true
assert_content "Plasma desktop" "$ARTIFACT_DIR/plasma.png"

# --- Teardown session -------------------------------------------------------
waymux --json rm plasma >/dev/null 2>&1 || true

echo
echo "===== demo-plasma: $PASS passed, $FAIL failed ====="
[ "$FAIL" -eq 0 ]
