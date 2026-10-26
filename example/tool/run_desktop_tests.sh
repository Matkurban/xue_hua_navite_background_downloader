#!/usr/bin/env bash
# Desktop checks for the example app and plugin.
#
# Works on Linux (Xvfb), macOS, and Windows Git Bash / MSYS. Device ids,
# build targets, and the download directory come from the host OS. Override
# the Flutter binary with FLUTTER_BIN and the download folder with
# XUEHUA_DOWNLOAD_DIR when the OS default is not the one the plugin uses.
#
# `flutter test integration_test/` starts the desktop app once per *_test.dart
# inside a single tool process. The second launch commonly fails with
# "Failed to load" / "Unable to start the app". This script runs each file in
# its own process, then drives the example UI.
#
# Usage (from anywhere):
#   example/tool/run_desktop_tests.sh
#   FLUTTER_BIN=/path/to/flutter example/tool/run_desktop_tests.sh
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

uname_s="$(uname -s)"
case "${uname_s}" in
  Linux)
    DEVICE="linux"
    ;;
  Darwin)
    DEVICE="macos"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    DEVICE="windows"
    ;;
  *)
    echo "unsupported host: ${uname_s}" >&2
    exit 1
    ;;
esac

download_dir() {
  if [[ -n "${XUEHUA_DOWNLOAD_DIR:-}" ]]; then
    printf '%s\n' "${XUEHUA_DOWNLOAD_DIR}"
    return
  fi
  case "${uname_s}" in
    Linux)
      printf '%s\n' "${XDG_DOWNLOAD_DIR:-${HOME}/Downloads}/XueHuaDownloads"
      ;;
    Darwin)
      printf '%s\n' "${HOME}/Downloads/XueHuaDownloads"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      local base="${USERPROFILE:-${HOME}}"
      if command -v cygpath >/dev/null 2>&1; then
        base="$(cygpath -u "${base}")"
      fi
      printf '%s\n' "${base}/Downloads/XueHuaDownloads"
      ;;
  esac
}

run_gui() {
  if [[ "${DEVICE}" == "linux" ]]; then
    export GDK_BACKEND=x11
    export LIBGL_ALWAYS_SOFTWARE=1
    xvfb-run -a -s "-screen 0 1400x900x24" "$@"
  else
    "$@"
  fi
}

echo "== flutter analyze =="
(cd "${REPO_DIR}" && "${FLUTTER}" analyze)
(cd "${EXAMPLE_DIR}" && "${FLUTTER}" analyze)

echo "== flutter build ${DEVICE} (example) =="
(cd "${EXAMPLE_DIR}" && run_gui "${FLUTTER}" build "${DEVICE}")

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
  (cd "${EXAMPLE_DIR}" && run_gui "${FLUTTER}" test -d "${DEVICE}" "${f}")
done

echo "== flutter_driver example UI =="
DOWNLOAD_DIR="$(download_dir)"
mkdir -p "${DOWNLOAD_DIR}"
# Drop persisted tasks and demo outputs so preset filenames stay stable.
find "${DOWNLOAD_DIR}" -maxdepth 1 -type f -delete
(cd "${EXAMPLE_DIR}" && run_gui "${FLUTTER}" drive \
  --driver=test_driver/app_test.dart \
  --target=test_driver/app.dart \
  -d "${DEVICE}")

echo "${DEVICE} checks passed."
