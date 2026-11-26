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

TARGET_BUILD="$CURRENT_BUILD"
if [[ "$BUMP_BUILD" -eq 1 ]]; then
  TARGET_BUILD=$((10#$CURRENT_BUILD + 1))
  echo "==> Version $CURRENT_VERSION (building as build $TARGET_BUILD, +1 on success)"
else
  echo "==> Version $CURRENT_VERSION (build $TARGET_BUILD, no bump)"
fi

echo "==> Generating CCX.xcodeproj"
xcodegen generate --spec project.yml --quiet

# Resolve a valid, unexpired signing identity matching $1 ("Developer ID Application" or "Apple Development").
# Sets RESOLVED_SIGN_HASH, RESOLVED_SIGN_NAME, and RESOLVED_TEAM_ID.
RESOLVED_SIGN_HASH=""
RESOLVED_SIGN_NAME=""
RESOLVED_TEAM_ID=""

resolve_valid_signing_identity() {
  local query="$1"
  local required_team="${2:-}"
  local identities_file pem_file line hash name cert idx cert_hash subject team
  RESOLVED_SIGN_HASH=""
  RESOLVED_SIGN_NAME=""
  RESOLVED_TEAM_ID=""

  identities_file="$(mktemp "${TMPDIR:-/tmp}/ccx-identities.XXXXXX")"
  pem_file="$(mktemp "${TMPDIR:-/tmp}/ccx-certs.XXXXXX")"
  trap 'rm -f -- "$identities_file" "$pem_file"' RETURN
  security find-identity -v -p codesigning 2>/dev/null > "$identities_file" || return 1

  while IFS= read -r line; do
    hash="$(printf '%s\n' "$line" | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+([A-Fa-f0-9]{40})[[:space:]]+"(.*)"$/\1/p')"
    name="$(printf '%s\n' "$line" | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+([A-Fa-f0-9]{40})[[:space:]]+"(.*)"$/\2/p')"
    [[ -n "$hash" && -n "$name" && "$name" == *"$query"* ]] || continue

    : > "$pem_file"
    security find-certificate -c "$name" -a -p > "$pem_file" 2>/dev/null || continue

    idx=0
    while true; do
      cert="$(awk -v target="$idx" '
        /-----BEGIN CERTIFICATE-----/ { in_cert = 1; buf = $0 "\n"; next }
        in_cert { buf = buf $0 "\n" }
        /-----END CERTIFICATE-----/ {
          if (count == target) { printf "%s", buf; exit }
          count++; in_cert = 0; buf = ""
        }
      ' "$pem_file")"
      [[ -n "$cert" ]] || break
      idx=$((idx + 1))

      if ! printf '%s' "$cert" | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
        continue
      fi
      cert_hash="$(printf '%s' "$cert" | openssl x509 -noout -fingerprint -sha1 2>/dev/null \
        | sed -E 's/^.*=//; s/://g' | tr '[:lower:]' '[:upper:]' || true)"
      [[ "$cert_hash" == "$(printf '%s' "$hash" | tr '[:lower:]' '[:upper:]')" ]] || continue

      subject="$(printf '%s' "$cert" | openssl x509 -noout -subject 2>/dev/null || true)"
      team="$(printf '%s\n' "$subject" | grep -Eo 'OU[[:space:]]*=[[:space:]]*[A-Z0-9]{10}' | head -n 1 | grep -Eo '[A-Z0-9]{10}$' || true)"
      [[ -n "$team" ]] || continue
      if [[ -n "$required_team" && "$team" != "$required_team" ]]; then
        continue
      fi
      RESOLVED_SIGN_HASH="$cert_hash"
      RESOLVED_SIGN_NAME="$name"
      RESOLVED_TEAM_ID="$team"
      return 0
    done
  done < "$identities_file"
  return 1
}

# Resolve signing settings.
# Prefer Developer ID Application when installed so local builds share the exact same
# Designated Requirement as notarized releases and in-app updates (never invalidating TCC).
SIGNING_ARGS=("CURRENT_PROJECT_VERSION=$TARGET_BUILD")
TEAM_ID="${DEVELOPMENT_TEAM:-}"
if [[ -z "$TEAM_ID" && -f "$LOCAL_SIGNING_XCCONFIG" ]]; then
  TEAM_ID="$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]{10}).*$/\1/p' "$LOCAL_SIGNING_XCCONFIG" | head -n 1 || true)"
fi

if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  echo "==> Signing with explicit CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY"
  SIGNING_ARGS+=("CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY")
  if [[ -n "$TEAM_ID" ]]; then
    SIGNING_ARGS+=("DEVELOPMENT_TEAM=$TEAM_ID")
  fi
elif resolve_valid_signing_identity "Developer ID Application:" "$TEAM_ID"; then
  echo "==> Signing with \"$RESOLVED_SIGN_NAME\" (Team ID $RESOLVED_TEAM_ID; matches release TCC identity)"
  SIGNING_ARGS+=(
    "CODE_SIGN_IDENTITY=$RESOLVED_SIGN_HASH"
    "CODE_SIGN_STYLE=Manual"
    "DEVELOPMENT_TEAM=$RESOLVED_TEAM_ID"
    "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO"
  )
elif [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "==> Signing with Apple Development (DEVELOPMENT_TEAM=$TEAM_ID from environment)"
  SIGNING_ARGS+=("DEVELOPMENT_TEAM=$TEAM_ID")
elif [[ -n "$TEAM_ID" ]]; then
  echo "==> Signing with Apple Development (DEVELOPMENT_TEAM=$TEAM_ID from $LOCAL_SIGNING_XCCONFIG)"
elif resolve_valid_signing_identity "Apple Development:"; then
  echo "==> Signing with \"$RESOLVED_SIGN_NAME\" (Team ID $RESOLVED_TEAM_ID)"
  SIGNING_ARGS+=("DEVELOPMENT_TEAM=$RESOLVED_TEAM_ID")
else
  echo "warning: no valid Developer ID or Apple Development signing identity found in the keychain." >&2
  echo "warning: falling back to ad-hoc signing (CODE_SIGN_IDENTITY=-)." >&2
  echo "warning: Screen Recording / Accessibility grants will NOT persist across rebuilds." >&2
  SIGNING_ARGS+=(
    "CODE_SIGN_IDENTITY=-"
    "CODE_SIGN_STYLE=Manual"
    "DEVELOPMENT_TEAM="
    "ENABLE_HARDENED_RUNTIME=NO"
    "OTHER_CODE_SIGN_FLAGS="
  )
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

# Persist the bumped CURRENT_PROJECT_VERSION only after xcodebuild succeeds.
if [[ "$BUMP_BUILD" -eq 1 ]]; then
  TMP_PROJECT_YML="$(mktemp "${ROOT_DIR}/project.yml.tmp.XXXXXX")"
  trap 'rm -f -- "$TMP_PROJECT_YML"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  awk -v build="$TARGET_BUILD" '
    !done && /^[[:space:]]*CURRENT_PROJECT_VERSION:/ {
      sub(/:.*/, ": " build)
      done = 1
    }
    { print }
  ' project.yml > "$TMP_PROJECT_YML"
  chmod 644 "$TMP_PROJECT_YML"
  mv -- "$TMP_PROJECT_YML" project.yml
  trap - EXIT INT TERM
  CURRENT_BUILD="$TARGET_BUILD"
  echo "==> Updated project.yml to build $CURRENT_BUILD"
fi
echo "==> Built $APP_PATH"

if [[ "$BUILD_ONLY" -eq 1 ]]; then
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -u "$ROOT_DIR/$APP_PATH" >/dev/null 2>&1 || true
  fi
  exit 0
fi

# Quit any running CCX instance owned by the current user before replacing or launching the app bundle.
CURRENT_UID="$(id -u)"
CCX_PROC_PATTERN='/CCX\.app/Contents/MacOS/CCX$'
ccx_is_running() {
  pgrep -u "$CURRENT_UID" -f "$CCX_PROC_PATTERN" >/dev/null 2>&1
}

if ccx_is_running; then
  echo "==> Quitting running CCX"
  osascript -e 'tell application id "com.lizhichaox.ccx" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ccx_is_running || break
    sleep 0.3
  done
  if ccx_is_running; then
    pkill -TERM -u "$CURRENT_UID" -f "$CCX_PROC_PATTERN" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      ccx_is_running || break
      sleep 0.2
    done
  fi
  if ccx_is_running; then
    echo "error: running CCX instance did not exit (a recording or dialog may be open); quit CCX and retry." >&2
    exit 1
  fi
fi

LAUNCH_APP="$APP_PATH"
if [[ "$INSTALL_APP" -eq 1 ]]; then
  if [[ -L "$INSTALL_DIR" ]]; then
    echo "error: install directory must not be a symlink: $INSTALL_DIR" >&2
    exit 1
  fi
  mkdir -p -- "$INSTALL_DIR"
  if [[ -L "$INSTALLED_APP" ]]; then
    echo "error: refusing to replace symlinked install target: $INSTALLED_APP" >&2
    exit 1
  fi
  STAGING_DIR="$(mktemp -d "$INSTALL_DIR/.CCX.app.staging.XXXXXX")"
  BACKUP_DIR=""
  cleanup_install() {
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR/CCX.app" && ! -e "$INSTALLED_APP" && ! -L "$INSTALLED_APP" ]]; then
      mv -- "$BACKUP_DIR/CCX.app" "$INSTALLED_APP" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$STAGING_DIR" ${BACKUP_DIR:+"$BACKUP_DIR"}
  }
  trap cleanup_install EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  STAGING_APP="$STAGING_DIR/CCX.app"
  echo "==> Installing to $INSTALLED_APP"
  ditto -- "$APP_PATH" "$STAGING_APP"

  if [[ -e "$INSTALLED_APP" || -L "$INSTALLED_APP" ]]; then
    if [[ -L "$INSTALLED_APP" ]]; then
      echo "error: refusing to replace symlinked install target: $INSTALLED_APP" >&2
      exit 1
    fi
    BACKUP_DIR="$(mktemp -d "$INSTALL_DIR/.CCX.app.backup.XXXXXX")"
    mv -- "$INSTALLED_APP" "$BACKUP_DIR/CCX.app"
  fi
  mv -- "$STAGING_APP" "$INSTALLED_APP"

  if [[ -n "$BACKUP_DIR" ]]; then
    rm -rf -- "$BACKUP_DIR"
    BACKUP_DIR=""
  fi
  rm -rf -- "$STAGING_DIR"
  trap - EXIT INT TERM

  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -u "$ROOT_DIR/$APP_PATH" >/dev/null 2>&1 || true
    "$LSREGISTER" -f "$INSTALLED_APP" >/dev/null 2>&1 || true
  fi
  LAUNCH_APP="$INSTALLED_APP"
fi

echo "==> Launching $LAUNCH_APP"
open -- "$LAUNCH_APP"
