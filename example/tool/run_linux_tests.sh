#!/usr/bin/env bash
# Linux checks for the example app and plugin.
#
# `flutter test integration_test/` starts the GTK app once per *_test.dart file
# inside a single tool process. On Linux desktop the second launch commonly
# fails with "Failed to load" / "Unable to start the app" (VM service log
# reader never sees the new observatory URI). This script runs each integration
# test file in its own `flutter test` process, then drives the example UI with
# flutter_driver under Xvfb.
#
# Usage (from anywhere):
#   example/tool/run_linux_tests.sh
#   FLUTTER_BIN=/path/to/flutter example/tool/run_linux_tests.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${EXAMPLE_DIR}/.." && pwd)"

if [[ -n "${FLUTTER_BIN:-}" ]]; then
  FLUTTER="${FLUTTER_BIN}"
elif command -v flutter >/dev/null 2>&1; then
  FLUTTER="$(command -v flutter)"
elif [[ -x "${HOME}/sdks/flutter/bin/flutter" ]]; then
  FLUTTER="${HOME}/sdks/flutter/bin/flutter"
else
  echo "flutter not found; set FLUTTER_BIN" >&2
  exit 1
fi

export GDK_BACKEND=x11
export LIBGL_ALWAYS_SOFTWARE=1

run_xvfb() {
  xvfb-run -a -s "-screen 0 1400x900x24" "$@"
}

echo "== flutter build linux (example) =="
(cd "${EXAMPLE_DIR}" && run_xvfb "${FLUTTER}" build linux)

echo "== plugin unit tests =="
(cd "${REPO_DIR}" && "${FLUTTER}" test)

echo "== example widget test =="
(cd "${EXAMPLE_DIR}" && "${FLUTTER}" test test/widget_test.dart)

echo "== example integration tests (one process per file) =="
shopt -s nullglob
files=("${EXAMPLE_DIR}"/integration_test/*_test.dart)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "no integration_test/*_test.dart files" >&2
  exit 1
fi
for f in "${files[@]}"; do
  echo "-- $(basename "${f}")"
  (cd "${EXAMPLE_DIR}" && run_xvfb "${FLUTTER}" test -d linux "${f}")
done

echo "== flutter_driver example UI =="
DOWNLOAD_DIR="${XDG_DOWNLOAD_DIR:-${HOME}/Downloads}/XueHuaDownloads"
mkdir -p "${DOWNLOAD_DIR}"
# Drop persisted tasks and known demo outputs so the driver starts from an
# empty dashboard and preset filenames are not renamed by uniqueName.
find "${DOWNLOAD_DIR}" -maxdepth 1 -type f -delete
(cd "${EXAMPLE_DIR}" && run_xvfb "${FLUTTER}" drive \
  --driver=test_driver/app_test.dart \
  --target=test_driver/app.dart \
  -d linux)

echo "Linux checks passed."
