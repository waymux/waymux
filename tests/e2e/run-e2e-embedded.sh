#!/usr/bin/env bash
# waymux embedded-app end-to-end test, SOFTWARE-ONLY (no GPU).
#
# Proves the "headless Wayland desktop in a box" use case: with Mesa software
# rendering (llvmpipe) and no GPU, waymux hosts real GUI apps as direct Wayland
# clients, and you can drive + observe them entirely from the CLI:
#
#   launch app  ->  inject input  ->  screenshot + assert content  ->  record
#
# Two clients exercise the two important worlds:
#   * Chromium (Ozone Wayland, --app mode) -> embedded web content
#   * KWrite   (Qt on Wayland)             -> embedded toolkit/desktop app
#
# Everything here runs with zero GPU access, so it is green on a stock CI shared
# runner. Each scenario SKIPs cleanly when its app is not installed.
#
#   tests/e2e/run-e2e-embedded.sh        # build + run
#   WAYMUX_E2E_NO_BUILD=1 ...            # skip the build (binaries already on PATH)
#
# Exit 0 = all present scenarios passed; non-zero = a check failed.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd))"

# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v ffprobe >/dev/null || { echo "SKIP: ffprobe not installed"; exit 0; }
command -v ffmpeg  >/dev/null || { echo "SKIP: ffmpeg not installed";  exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 not installed"; exit 0; }

# Force software rendering for every layer that might reach for a GPU. This is
# the whole point: prove the stack on a machine that has none.
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER="${GALLIUM_DRIVER:-llvmpipe}"
# No /dev/dri on a GPU-less runner means no explicit-sync device; fall back to
# implicit sync so the compositor never tries to open a DRM node.
export WAYMUX_DISABLE_SYNCOBJ=1

if [ "${WAYMUX_E2E_NO_BUILD:-0}" != "1" ]; then
  echo "=== build ==="
  CARGO_TERM_COLOR=never cargo build -p waymux-cli -p waymux-daemon -p waymux-session 2>&1 | tail -1
fi
wmx_pick_bindir

export XDG_RUNTIME_DIR=/tmp/wmx-emb-run
rm -rf "$XDG_RUNTIME_DIR"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
SOCK="$XDG_RUNTIME_DIR/waymux.sock"
OUT=/tmp/wmx-emb-out; rm -rf "$OUT"; mkdir -p "$OUT"

cleanup() {
  pkill -9 -f 'wmx-emb-out/prof' 2>/dev/null
  # Kill the KWrite process GROUP by pid (it was launched under setsid), never
  # `pkill -x kwrite`, which would also kill a developer's own open KWrite.
  [ -n "${KPID:-}" ] && { kill -9 -- "-$KPID" 2>/dev/null; kill -9 "$KPID" 2>/dev/null; }
  kill "${DPID:-0}" 2>/dev/null
}
trap cleanup EXIT

echo "=== start waymuxd (software, syncobj disabled) ==="
waymuxd >/tmp/wmx-emb-daemon.log 2>&1 &
DPID=$!
for _ in $(seq 1 400); do [ -S "$SOCK" ] && break; sleep 0.05; kill -0 "$DPID" 2>/dev/null || break; done
[ -S "$SOCK" ] && ok "daemon socket up (no GPU)" || { bad "daemon socket"; exit 1; }

# =====================================================================
# Scenario 1: embedded Chromium (Ozone Wayland, software, --app mode)
# =====================================================================
CHROMIUM=$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)
if [ -n "$CHROMIUM" ]; then
  echo "=== embedded Chromium (software, llvmpipe) ==="
  # An --app window makes the page the toplevel surface, so the captured frame
  # is exactly the web content (and a clean visual-diff target). A CSS
  # animation keeps the page committing real frames for the recording.
  cat >"$OUT/page.html" <<'HTML'
<!doctype html><meta charset=utf-8><title>waymux</title>
<style>
  html,body{margin:0;height:100%;overflow:hidden}
  body{background:linear-gradient(135deg,#e1004b,#0a84ff);
       display:flex;align-items:center;justify-content:center}
  .t{font:bold 84px/1.15 sans-serif;color:#fff;text-align:center;
     text-shadow:0 6px 30px rgba(0,0,0,.6);z-index:2}
  .b{position:absolute;top:42%;left:0;width:170px;height:170px;border-radius:24px;
     background:#000;opacity:.85;animation:m 2s linear infinite alternate}
  @keyframes m{from{left:4%}to{left:78%}}
</style>
<div class=b></div><div class=t>WAYMUX<br>CPU / llvmpipe</div>
HTML
  waymux --json new chrome --size 1280x800 >"$OUT/c-new.json" 2>&1
  [ "$(jget '["ok"]' <"$OUT/c-new.json" 2>/dev/null)" = "True" ] && ok "chrome session created" || bad "chrome new: $(cat "$OUT/c-new.json")"
  CINNER="$XDG_RUNTIME_DIR/waymux/chrome/wayland.sock"
  # --disable-dev-shm-usage keeps Chromium off the small default /dev/shm in a
  # container; --no-sandbox is required running as root without user namespaces.
  WAYLAND_DISPLAY="$CINNER" setsid "$CHROMIUM" \
    --ozone-platform=wayland --no-sandbox --no-first-run \
    --disable-gpu --disable-gpu-compositing --in-process-gpu \
    --disable-dev-shm-usage \
    --user-data-dir="$OUT/prof-chrome" --window-size=1280,800 \
    --app="file://$OUT/page.html" >"$OUT/chrome-app.log" 2>&1 &
  CN=$(wait_window chrome chromium)
  [ "$CN" -ge 1 ] 2>/dev/null && ok "Chromium registered as a direct Wayland client" || bad "Chromium window never appeared (see $OUT/chrome-app.log)"

  waymux idle chrome --quiet-ms 600 --timeout-ms 6000 >/dev/null 2>&1 || true
  waymux screenshot-desktop chrome -o "$OUT/chrome.png" >/dev/null 2>&1
  assert_content "Chromium screenshot" "$OUT/chrome.png"

  # Record the animating page to a lossless FFV1 MKV, CPU-encoded.
  waymux --json record start chrome --codec ffv1 --min-fps 15 >"$OUT/c-rec.json" 2>&1
  CREC=$(jget '["data"]["path"]' <"$OUT/c-rec.json" 2>/dev/null || echo "")
  [ -n "$CREC" ] && [ "$CREC" != "None" ] && ok "Chromium record started ($CREC)" || bad "chrome record start: $(cat "$OUT/c-rec.json")"
  # let the CSS animation run for a real wall-clock window
  timeout 5 tail -f /dev/null >/dev/null 2>&1
  waymux --json record stop chrome >/dev/null 2>&1
  waymux idle chrome --quiet-ms 800 --timeout-ms 2500 >/dev/null 2>&1 || true
  if [ -n "$CREC" ] && [ -f "$CREC" ]; then
    CCODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$CREC" 2>/dev/null)
    CUNIQ=$(unique_frames "$CREC")
    if [ "$CCODEC" = "ffv1" ] && [ "${CUNIQ:-0}" -ge 2 ] 2>/dev/null; then
      ok "Chromium recording is FFV1 with $CUNIQ unique frames (CPU-encoded, real motion)"
    else
      bad "Chromium recording weak: codec=$CCODEC unique_frames=$CUNIQ (want ffv1, >=2)"
    fi
  else bad "Chromium recording file missing: $CREC"; fi
  cp "$OUT/chrome.png" /tmp/emb-chrome.png 2>/dev/null || true
  waymux --json rm chrome >/dev/null 2>&1
  pkill -9 -f 'prof-chrome' 2>/dev/null || true
else
  echo "SKIP: embedded Chromium scenario (no chromium/chromium-browser/google-chrome)"
fi

# =====================================================================
# Scenario 2: embedded KDE/Qt app (KWrite on Wayland, software)
#   Focus: input injection produces real content change, captured in a
#   lossless recording with genuine (non-padded) unique frames.
# =====================================================================
KWRITE=$(command -v kwrite || true)
if [ -n "$KWRITE" ]; then
  echo "=== embedded KDE app: KWrite (software, llvmpipe) ==="
  # Pre-fill the document with a full screen of text so the editor body (and its
  # center, where we assert content) shows real glyphs. An empty editor has a
  # legitimately blank white center, which is not what we are testing.
  : >"$OUT/note.txt"
  for i in $(seq 1 50); do
    printf 'line %02d  waymux headless Wayland test harness rendered by llvmpipe with no GPU\n' "$i" >>"$OUT/note.txt"
  done
  waymux --json new kde --size 1280x800 >"$OUT/k-new.json" 2>&1
  [ "$(jget '["ok"]' <"$OUT/k-new.json" 2>/dev/null)" = "True" ] && ok "kde session created" || bad "kde new: $(cat "$OUT/k-new.json")"
  KINNER="$XDG_RUNTIME_DIR/waymux/kde/wayland.sock"
  WAYLAND_DISPLAY="$KINNER" QT_QPA_PLATFORM=wayland setsid "$KWRITE" "$OUT/note.txt" \
    >"$OUT/kwrite.log" 2>&1 &
  KPID=$!   # session leader; kill its process group by pid, never `pkill -x kwrite`
  KN=$(wait_window kde kwrite)
  [ "$KN" -ge 1 ] 2>/dev/null && ok "KWrite registered as a direct Wayland client" || bad "KWrite window never appeared (see $OUT/kwrite.log)"
  waymux idle kde --quiet-ms 700 --timeout-ms 6000 >/dev/null 2>&1 || true
  waymux screenshot-desktop kde -o "$OUT/kde-before.png" >/dev/null 2>&1
  assert_content "KWrite screenshot" "$OUT/kde-before.png"

  # Start recording, then type. Each keystroke re-commits the editor with new
  # text, so the recording should contain several genuinely distinct frames.
  waymux --json record start kde --codec ffv1 --min-fps 15 >"$OUT/k-rec.json" 2>&1
  KREC=$(jget '["data"]["path"]' <"$OUT/k-rec.json" 2>/dev/null || echo "")
  [ -n "$KREC" ] && [ "$KREC" != "None" ] && ok "KWrite record started ($KREC)" || bad "kde record start: $(cat "$OUT/k-rec.json")"
  # Type "WAYMUX" one key at a time with a settle between, forcing distinct
  # commits. Keycodes (evdev): W=17 A=30 Y=21 M=50 U=22 X=45.
  for kc in 17 30 21 50 22 45; do
    waymux key kde "$kc" >/dev/null 2>&1
    waymux idle kde --quiet-ms 250 --timeout-ms 1500 >/dev/null 2>&1 || true
  done
  waymux --json record stop kde >/dev/null 2>&1
  waymux idle kde --quiet-ms 800 --timeout-ms 2500 >/dev/null 2>&1 || true

  # The injected typing must have changed the visible content. Difference the
  # two frames pixel-for-pixel: identical frames diff to all-black (YMAX=0), so
  # a non-trivial YMAX proves the keystrokes actually altered the capture.
  waymux screenshot-desktop kde -o "$OUT/kde-after.png" >/dev/null 2>&1
  DIFFMAX=$(ffprobe -v error -f lavfi \
    -i "movie=$OUT/kde-before.png[a];movie=$OUT/kde-after.png[b];[a][b]blend=all_mode=difference,signalstats" \
    -show_entries frame_tags=lavfi.signalstats.YMAX -of csv=p=0 2>/dev/null | head -1 | awk -F, '{print int($1+0)}')
  if [ -f "$OUT/kde-after.png" ] && [ "${DIFFMAX:-0}" -ge 20 ] 2>/dev/null; then
    ok "injected keystrokes changed the captured content (frame-diff YMAX=$DIFFMAX)"
  else
    bad "injected keystrokes did not change content (frame-diff YMAX=$DIFFMAX, want >=20)"
  fi

  if [ -n "$KREC" ] && [ -f "$KREC" ]; then
    KCODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$KREC" 2>/dev/null)
    KUNIQ=$(unique_frames "$KREC")
    if [ "$KCODEC" = "ffv1" ] && [ "${KUNIQ:-0}" -ge 3 ] 2>/dev/null; then
      ok "KWrite recording is FFV1 with $KUNIQ unique frames (typing captured, not duplicate padding)"
    else
      bad "KWrite recording weak: codec=$KCODEC unique_frames=$KUNIQ (want ffv1, >=3)"
    fi
  else bad "KWrite recording file missing: $KREC"; fi
  cp "$OUT/kde-after.png" /tmp/emb-kde.png 2>/dev/null || true
  waymux --json rm kde >/dev/null 2>&1
  [ -n "${KPID:-}" ] && { kill -9 -- "-$KPID" 2>/dev/null; kill -9 "$KPID" 2>/dev/null; } || true
else
  echo "SKIP: embedded KDE app scenario (kwrite not installed)"
fi

echo
echo "===== embedded e2e: $PASS passed, $FAIL failed ====="
[ "$FAIL" -eq 0 ]
