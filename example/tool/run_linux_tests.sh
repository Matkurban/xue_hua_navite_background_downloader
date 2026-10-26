#!/usr/bin/env bash
# Compatibility wrapper. Prefer example/tool/run_desktop_tests.sh,
# which selects linux, macos, or windows from the host OS.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run_desktop_tests.sh" "$@"
