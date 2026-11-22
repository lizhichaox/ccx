#!/usr/bin/env bash
# Generates CCX.xcodeproj, builds CCX.app with a stable signing identity,
# replaces /Applications/CCX.app, and launches it through LaunchServices so
# TCC grants are tracked cleanly by bundle ID.
#
# Usage: scripts/build-and-run.sh [--build-only] [--no-install] [--no-bump] [--release]
#
# Versioning:
#   Automatically increments CURRENT_PROJECT_VERSION in project.yml by +1 before
#   each build (pass --no-bump to keep the current build number). Use
#   scripts/bump-version.sh <patch|minor|major|X.Y.Z> to update MARKETING_VERSION.
#
# Signing (first match wins):
#   1. DEVELOPMENT_TEAM environment variable.
#   2. Config/LocalSigning.xcconfig (untracked) when it defines DEVELOPMENT_TEAM.
#   3. The OU (Team ID) of the installed "Apple Development" certificate.
#   4. Ad-hoc signing ("-") with a warning: TCC grants will not persist.
#
# Host note: Keychain signing, /Applications install, and `open` require an unsandboxed shell.

set -euo pipefail

usage() {
  awk 'NR>1 { if (/^#/) { sub(/^# ?/, ""); print } else exit }' "$0"
}

BUILD_ONLY=0
INSTALL_APP=1
BUMP_BUILD=1
CONFIGURATION=Debug
for arg in "$@"; do
  case "$arg" in
    --build-only) BUILD_ONLY=1 ;;
    --no-install) INSTALL_APP=0 ;;
    --no-bump) BUMP_BUILD=0 ;;
    --release) CONFIGURATION=Release ;;
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
DERIVED_DATA_PATH=".build/xcode"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/CCX.app"
INSTALL_DIR="${CCX_INSTALL_DIR:-/Applications}"
INSTALLED_APP="$INSTALL_DIR/CCX.app"
LOCAL_SIGNING_XCCONFIG="Config/LocalSigning.xcconfig"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
ARCH="$(uname -m)"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

CURRENT_VERSION="$(awk -F: '/^[[:space:]]*MARKETING_VERSION:/ { gsub(/["'\''[:space:]]/, "", $2); print $2; exit }' project.yml)"
CURRENT_BUILD="$(awk -F: '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ { gsub(/["'\''[:space:]]/, "", $2); print $2; exit }' project.yml)"
if [[ ! "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
  echo "error: invalid CURRENT_PROJECT_VERSION in project.yml: '$CURRENT_BUILD'" >&2
  exit 1
fi

if [[ "$BUMP_BUILD" -eq 1 ]]; then
  NEXT_BUILD=$((CURRENT_BUILD + 1))
  TMP_PROJECT_YML="project.yml.tmp.$$"
  trap 'rm -f "$TMP_PROJECT_YML"' EXIT
  awk -v build="$NEXT_BUILD" '
    !done && /^[[:space:]]*CURRENT_PROJECT_VERSION:/ {
      sub(/:.*/, ": " build)
      done = 1
    }
    { print }
  ' project.yml > "$TMP_PROJECT_YML"
  mv "$TMP_PROJECT_YML" project.yml
  trap - EXIT
  CURRENT_BUILD="$NEXT_BUILD"
  echo "==> Version $CURRENT_VERSION (build $CURRENT_BUILD, +1)"
else
  echo "==> Version $CURRENT_VERSION (build $CURRENT_BUILD, no bump)"
fi

echo "==> Generating CCX.xcodeproj"
xcodegen generate --spec project.yml --quiet

# Resolve signing settings.
SIGNING_ARGS=()
TEAM_ID="${DEVELOPMENT_TEAM:-}"
if [[ -n "$TEAM_ID" ]]; then
  echo "==> Signing with DEVELOPMENT_TEAM=$TEAM_ID (environment)"
  SIGNING_ARGS+=("DEVELOPMENT_TEAM=$TEAM_ID")
elif [[ -f "$LOCAL_SIGNING_XCCONFIG" ]] && grep -Eq '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}' "$LOCAL_SIGNING_XCCONFIG"; then
  echo "==> Signing with DEVELOPMENT_TEAM from $LOCAL_SIGNING_XCCONFIG"
else
  CERT_SUBJECT="$(security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)"
  # Handles both LibreSSL ("/OU=ABCDE12345/") and OpenSSL ("OU = ABCDE12345,") formats.
  TEAM_ID="$(printf '%s\n' "$CERT_SUBJECT" | grep -Eo 'OU[[:space:]]*=[[:space:]]*[A-Z0-9]{10}' | head -n 1 | grep -Eo '[A-Z0-9]{10}$' || true)"
  if [[ -n "$TEAM_ID" ]]; then
    echo "==> Signing with Apple Development certificate (Team ID $TEAM_ID)"
    SIGNING_ARGS+=("DEVELOPMENT_TEAM=$TEAM_ID")
  else
    echo "warning: no \"Apple Development\" certificate found in the keychain." >&2
    echo "warning: falling back to ad-hoc signing (CODE_SIGN_IDENTITY=-)." >&2
    echo "warning: Screen Recording / Accessibility grants will NOT persist across rebuilds." >&2
    SIGNING_ARGS+=("CODE_SIGN_IDENTITY=-" "CODE_SIGN_STYLE=Manual" "DEVELOPMENT_TEAM=")
  fi
fi

echo "==> Building CCX ($CONFIGURATION, $ARCH)"
xcodebuild \
  -project CCX.xcodeproj \
  -scheme CCX \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,arch=$ARCH" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  ${SIGNING_ARGS[@]+"${SIGNING_ARGS[@]}"} \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: build succeeded but $APP_PATH is missing" >&2
  exit 1
fi
echo "==> Built $APP_PATH"

if [[ "$BUILD_ONLY" -eq 1 ]]; then
  exit 0
fi

# Quit any running instance before replacing or launching the app bundle.
if pgrep -x CCX >/dev/null 2>&1; then
  echo "==> Quitting running CCX"
  osascript -e 'tell application id "com.lizhichaox.ccx" to quit' >/dev/null 2>&1 || pkill -x CCX || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x CCX >/dev/null 2>&1 || break
    sleep 0.3
  done
fi

LAUNCH_APP="$APP_PATH"
if [[ "$INSTALL_APP" -eq 1 ]]; then
  mkdir -p "$INSTALL_DIR"
  STAGING_APP="$INSTALL_DIR/.CCX.app.staging.$$"
  trap 'rm -rf "$STAGING_APP"' EXIT
  rm -rf "$STAGING_APP"
  echo "==> Installing to $INSTALLED_APP"
  ditto "$APP_PATH" "$STAGING_APP"
  rm -rf "$INSTALLED_APP"
  mv "$STAGING_APP" "$INSTALLED_APP"
  trap - EXIT
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$INSTALLED_APP" >/dev/null 2>&1 || true
  fi
  LAUNCH_APP="$INSTALLED_APP"
fi

echo "==> Launching $LAUNCH_APP"
open "$LAUNCH_APP"
