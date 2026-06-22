#!/usr/bin/env bash
# CI demo image entrypoint: app demo (gating), plasma demo (best-effort),
# benchmark (functional gate). Collects artifacts into $ARTIFACT_DIR.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
export ARTIFACT_DIR="${ARTIFACT_DIR:-/artifacts}"; mkdir -p "$ARTIFACT_DIR"
rc=0
echo "== KDE app demo =="; bash tests/e2e/demo-kde-app.sh || rc=1
echo "== Plasma demo (best-effort) =="; bash tests/e2e/demo-plasma.sh || echo "plasma demo: non-fatal failure"
echo "== benchmark =="; bash tests/e2e/ci-bench.sh || rc=1
echo "artifacts:"; ls -la "$ARTIFACT_DIR"
exit "$rc"
