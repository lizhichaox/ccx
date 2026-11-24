#!/usr/bin/env bash
# Runs local verification checks: secret audit, shell lint, git diff whitespace
# check, all 5 SwiftPM package unit test suites, and an optional Release build.
#
# Usage: scripts/verify-all.sh [--build]
#   --build     Also run ./scripts/build-and-run.sh --build-only --no-bump --release.
#   -h, --help  Show this help message.
#
# Environment:
#   DEVELOPER_DIR    Defaults to /Applications/Xcode.app/Contents/Developer.
#   SWIFT_TEST_ARGS  Optional extra flags forwarded to `swift test` (word-split).

set -euo pipefail

usage() {
  awk 'NR>1 { if (/^#/) { sub(/^# ?/, ""); print } else exit }' "$0"
}

RUN_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --build) RUN_BUILD=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ -t 1 ]]; then
  C_GREEN=$'\033[32m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""
  C_BOLD=""
  C_DIM=""
  C_RESET=""
fi

SECONDS=0
PACKAGES=(CCXCore CCXAnnotate CCXCapture CCXPin CCXRecord)
TOTAL_STEPS=4
if [[ "$RUN_BUILD" -eq 1 ]]; then
  TOTAL_STEPS=5
fi

EXTRA_SWIFT_TEST_ARGS=()
if [[ -n "${SWIFT_TEST_ARGS:-}" ]]; then
  read -r -a EXTRA_SWIFT_TEST_ARGS <<< "$SWIFT_TEST_ARGS"
fi

echo "==> [1/$TOTAL_STEPS] Secret & local-config audit"
./scripts/check-secrets.sh --all

echo "==> [2/$TOTAL_STEPS] Shell syntax check (bash -n)"
bash -n scripts/*.sh .githooks/*
echo "Shell syntax check passed."

echo "==> [3/$TOTAL_STEPS] Whitespace & conflict marker check (git diff --check)"
git diff --check
git diff --cached --check
echo "Git diff check passed."

echo "==> [4/$TOTAL_STEPS] SwiftPM unit tests (${#PACKAGES[@]} packages)"
for pkg in "${PACKAGES[@]}"; do
  echo "  -> Testing Packages/$pkg"
  swift test --package-path "Packages/$pkg" ${EXTRA_SWIFT_TEST_ARGS[@]+"${EXTRA_SWIFT_TEST_ARGS[@]}"}
done

if [[ "$RUN_BUILD" -eq 1 ]]; then
  echo "==> [5/$TOTAL_STEPS] Release build check"
  ./scripts/build-and-run.sh --build-only --no-bump --release
fi

echo ""
echo "${C_GREEN}${C_BOLD}==> ALL CHECKS PASSED (${SECONDS}s)${C_RESET}"
echo "  ${C_GREEN}PASS${C_RESET}  Secrets audit (./scripts/check-secrets.sh --all)"
echo "  ${C_GREEN}PASS${C_RESET}  Shell lint (bash -n scripts/*.sh .githooks/*)"
echo "  ${C_GREEN}PASS${C_RESET}  Git diff check (git diff --check)"
echo "  ${C_GREEN}PASS${C_RESET}  SwiftPM tests (${#PACKAGES[@]}/${#PACKAGES[@]} packages: ${PACKAGES[*]})"
if [[ "$RUN_BUILD" -eq 1 ]]; then
  echo "  ${C_GREEN}PASS${C_RESET}  Release build (./scripts/build-and-run.sh --build-only --no-bump --release)"
else
  echo "  ${C_DIM}SKIP${C_RESET}  Release build (pass --build to include)"
fi
