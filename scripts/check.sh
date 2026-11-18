#!/usr/bin/env bash
# One command for every automatic check in this repository (paved-road L1): the project adapter for the
# app-check kernel. Checks are declared in checks.json; this script only resolves the kernel and the folders.
#
#   scripts/check.sh [--fast]      --fast skips checks marked "slow"
#
# Kernel lookup: $APP_CHECK_RUNNER, then scripts/lib/run_checks.py (vendored by `paved-road init` so CI needs no
# network or token), then ~/.claude/skills/app-check/scripts/run_checks.py. Receipts land in docs/receipts/checks:
# commit the JSON, ignore the log copies (.gitignore: `docs/receipts/checks/*/` and `.checks-memo/`).
# Exit code = number of failed checks.
set -u
cd "$(dirname "$0")/.." || exit 2
kernel="${APP_CHECK_RUNNER:-}"
[ -n "$kernel" ] || { [ -f scripts/lib/run_checks.py ] && kernel=scripts/lib/run_checks.py; }
[ -n "$kernel" ] || kernel="$HOME/.claude/skills/app-check/scripts/run_checks.py"
[ -f "$kernel" ] || { echo "app-check kernel not found ($kernel): run paved-road init or set APP_CHECK_RUNNER" >&2; exit 2; }
exec python3 "$kernel" checks.json "$@" --memo .checks-memo --receipts docs/receipts/checks
