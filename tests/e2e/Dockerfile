# waymux embedded-app e2e, in a container, with NO GPU.
#
# Builds the three binaries needed to host a headless Wayland session
# (waymuxd, waymux, waymux-session), bundles Mesa software rendering
# (llvmpipe) plus ffmpeg and a couple of real GUI apps, and runs the
# software-only embedded e2e. Nothing here touches /dev/dri or needs --gpus;
# the image is meant to go green on a stock, GPU-less CI runner.
#
#   docker build -f tests/e2e/Dockerfile -t waymux-e2e .
#   docker run --rm waymux-e2e            # runs the embedded e2e
#
# Chromium wants a roomy /dev/shm; the harness passes --disable-dev-shm-usage
# so the 64 MB default is fine, but `--shm-size=512m` also works.

# --- builder ----------------------------------------------------------------
# Debian trixie: ffmpeg 7 (the session crate's Vulkan FFV1 shim needs the
# AVVkFrame fields added in ffmpeg 6.1+; bookworm's 5.1 is too old to compile).
FROM rust:1.94-trixie AS builder
WORKDIR /app
# The session crate's build.rs links gbm + avutil and compiles a small ffmpeg
# shim; wayland-server needs libwayland headers.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libwayland-dev libgbm-dev libavutil-dev libavformat-dev libavcodec-dev \
      libavfilter-dev libavdevice-dev libswscale-dev libswresample-dev \
      libvulkan-dev libxkbcommon-dev pkg-config build-essential \
      clang libclang-dev \
    && rm -rf /var/lib/apt/lists/*
# Only the inputs cargo needs, so doc/CI edits do not bust this layer. No
# Cargo.lock: the public tree ships without one and resolves fresh in CI.
COPY Cargo.toml rust-toolchain.toml ./
COPY crates/ crates/
# Release build: this image is published for adoption, and debug screenshot
# latency is far worse, so ship the optimized binaries.
RUN cargo build --release -p waymux-cli -p waymux-daemon -p waymux-session

# --- runtime ----------------------------------------------------------------
FROM debian:trixie-slim
WORKDIR /app
ENV DEBIAN_FRONTEND=noninteractive
# Software GL/EGL (llvmpipe via swrast), Wayland + xkb runtime, ffmpeg (the
# recorder shells out to it), python3 + procps (the harness uses both), dbus
# (KDE apps want a session bus), fonts, and two real clients: Chromium (web)
# and KWrite (a Qt/KDE app). foot is a lightweight Wayland-native extra.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates fonts-dejavu-core fonts-liberation \
      libwayland-server0 libwayland-client0 libwayland-cursor0 libwayland-egl1 \
      libgbm1 libdrm2 libxkbcommon0 xkb-data libvulkan1 \
      libgl1-mesa-dri libegl-mesa0 libegl1 libgles2 libglx-mesa0 libgl1 \
      ffmpeg python3 dbus procps \
      chromium kwrite foot qt6-wayland \
    && rm -rf /var/lib/apt/lists/*

# Just the three binaries the harness needs, where it looks for them.
COPY --from=builder /app/target/release/waymuxd        /app/target/release/waymuxd
COPY --from=builder /app/target/release/waymux         /app/target/release/waymux
COPY --from=builder /app/target/release/waymux-session /app/target/release/waymux-session
COPY tests/ /app/tests/
COPY scripts/waymux-run /usr/local/bin/waymux-run

ENV WAYMUX_E2E_NO_BUILD=1 \
    WAYMUX_BINDIR=/app/target/release \
    PATH=/app/target/release:/usr/local/bin:$PATH \
    LIBGL_ALWAYS_SOFTWARE=1 \
    GALLIUM_DRIVER=llvmpipe \
    WAYMUX_DISABLE_SYNCOBJ=1

# `docker run waymux-ci` runs the embedded smoke test. Drive your own app by
# overriding the entrypoint, e.g.:
#   docker run --rm --entrypoint waymux-run waymux-ci -- <command>
ENTRYPOINT ["dbus-run-session", "--", "bash", "tests/e2e/run-e2e-embedded.sh"]
