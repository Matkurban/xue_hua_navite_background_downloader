#!/usr/bin/env bash
# Integration test (flutter drive) and UI flutter_driver on a booted iOS Simulator.
#
# Uses the same cases as macOS desktop (example/tool/run_desktop_tests.sh).
# API coverage: drive --driver=test_driver/integration_test.dart
#   --target=integration_test/download_api_verification_test.dart
# The driver does not skip steps. Phone width builds every keyed control in
# one scroll view, and the host script scrolls each target into view.
#
# Usage (from anywhere):
#   example/tool/run_ios_simulator_tests.sh
#   example/tool/run_ios_simulator_tests.sh <simulator-udid>
#   IOS_DEVICE=<simulator-udid> example/tool/run_ios_simulator_tests.sh
#   FLUTTER_BIN=/path/to/flutter example/tool/run_ios_simulator_tests.sh
#
# Boot a simulator first when none is running:
#   xcrun simctl boot "iPhone 16"
#   open -a Simulator
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

pick_ios_device() {
  if [[ -n "${1:-}" ]]; then
    printf '%s\n' "$1"
    return 0
  fi
  if [[ -n "${IOS_DEVICE:-}" ]]; then
    printf '%s\n' "${IOS_DEVICE}"
    return 0
  fi
  local json id
  if ! json="$("${FLUTTER}" devices --machine)"; then
    return 1
  fi
  if ! id="$(
    python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(1)
devices = json.loads(raw)
ios = [
    d for d in devices
    if d.get("targetPlatform") == "ios" and d.get("isSupported", True)
]
emus = [d for d in ios if d.get("emulator") is True]
choice = emus or ios
if not choice:
    sys.exit(1)
print(choice[0]["id"])
' <<<"${json}"
  )"; then
    return 1
  fi
  printf '%s\n' "${id}"
}

if ! DEVICE="$(pick_ios_device "${1:-}")" || [[ -z "${DEVICE}" ]]; then
  echo "No iOS simulator found. Boot one, then rerun:" >&2
  echo "  xcrun simctl boot \"iPhone 16\"" >&2
  echo "  open -a Simulator" >&2
  echo "  example/tool/run_ios_simulator_tests.sh" >&2
  exit 1
fi

echo "== iOS simulator ${DEVICE} =="
echo "== integration_test (flutter drive) =="
(cd "${EXAMPLE_DIR}" && "${FLUTTER}" drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/download_api_verification_test.dart \
  -d "${DEVICE}")

echo "== flutter_driver UI =="
(cd "${EXAMPLE_DIR}" && "${FLUTTER}" drive \
  --driver=test_driver/app_test.dart \
  --target=test_driver/app.dart \
  -d "${DEVICE}")

echo "iOS simulator checks passed."
