#!/usr/bin/env bash
# Builds, signs, verifies, and packages a public macOS release of CCX
# (Universal Binary arm64 + x86_64 by default, Hardened Runtime + secure timestamp).
#
# Usage:
#   scripts/package-release.sh [options]
#
# Options:
#   --arch <universal|arm64|x86_64>  Target architecture(s) (default: universal)
#   --sign-identity "<id>"           Code-signing identity name or SHA-1 hash
#                                    (default: auto-detect valid "Developer ID Application")
#   --adhoc                          Ad-hoc sign ("-") for local packaging only (no Gatekeeper)
#   --notarize <keychain-profile>    Submit to Apple notary service and staple .app/.dmg
#   --out-dir <dir>                  Output directory for release artifacts (default: dist)
#   --no-dmg                         Skip DMG creation
#   --no-zip                         Skip ZIP creation
#   -h, --help                       Show this help text
#
# Host note: Keychain signing, hdiutil DMG creation, spctl, and notarization require an
# unsandboxed macOS host shell. Zero Team IDs or credentials are stored in this script.

set -euo pipefail

usage() {
  awk 'NR>1 { if (/^#/) { sub(/^# ?/, ""); print } else exit }' "$0"
}

ARCH_MODE="universal"
SIGN_IDENTITY_OVERRIDE=""
ADHOC=0
NOTARIZE_PROFILE=""
OUT_DIR="dist"
BUILD_DMG=1
BUILD_ZIP=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      if [[ $# -lt 2 ]]; then
        echo "error: --arch requires a value (universal|arm64|x86_64)" >&2
        exit 2
      fi
      ARCH_MODE="$2"
      shift 2
      ;;
    --sign-identity)
      if [[ $# -lt 2 ]]; then
        echo "error: --sign-identity requires a value" >&2
        exit 2
      fi
      SIGN_IDENTITY_OVERRIDE="$2"
      shift 2
      ;;
    --adhoc)
      ADHOC=1
      shift
      ;;
    --notarize)
      if [[ $# -lt 2 ]]; then
        echo "error: --notarize requires a notarytool keychain profile name" >&2
        exit 2
      fi
      NOTARIZE_PROFILE="$2"
      shift 2
      ;;
    --out-dir)
      if [[ $# -lt 2 ]]; then
        echo "error: --out-dir requires a directory path" >&2
        exit 2
      fi
      OUT_DIR="$2"
      shift 2
      ;;
    --no-dmg)
      BUILD_DMG=0
      shift
      ;;
    --no-zip)
      BUILD_ZIP=0
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$ARCH_MODE" in
  universal)
    XCODE_ARCHS="arm64 x86_64"
    XCODE_DESTINATION="generic/platform=macOS"
    ;;
  arm64)
    XCODE_ARCHS="arm64"
    XCODE_DESTINATION="platform=macOS,arch=arm64"
    ;;
  x86_64)
    XCODE_ARCHS="x86_64"
    XCODE_DESTINATION="platform=macOS,arch=x86_64"
    ;;
  *)
    echo "error: unsupported --arch '$ARCH_MODE' (expected universal, arm64, or x86_64)" >&2
    exit 2
    ;;
esac

if [[ "$ADHOC" -eq 1 && -n "$NOTARIZE_PROFILE" ]]; then
  echo "error: --notarize cannot be combined with --adhoc signing" >&2
  exit 2
fi

if [[ "$ADHOC" -eq 1 && -n "$SIGN_IDENTITY_OVERRIDE" ]]; then
  echo "error: --sign-identity cannot be combined with --adhoc" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

VERSION="$(awk -F: '/^[[:space:]]*MARKETING_VERSION:/ { gsub(/["'\''[:space:]]/, "", $2); print $2; exit }' project.yml)"
BUILD_NUMBER="$(awk -F: '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ { gsub(/["'\''[:space:]]/, "", $2); print $2; exit }' project.yml)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: invalid MARKETING_VERSION in project.yml: '$VERSION'" >&2
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "error: invalid CURRENT_PROJECT_VERSION in project.yml: '$BUILD_NUMBER'" >&2
  exit 1
fi

CLEANUP_PATHS=()
cleanup() {
  local p
  for p in ${CLEANUP_PATHS[@]+"${CLEANUP_PATHS[@]}"}; do
    if [[ -n "$p" && -e "$p" ]]; then
      rm -rf "$p"
    fi
  done
}
trap cleanup EXIT

# Resolves a valid, unexpired codesigning identity matching $1 (prefix/substring or SHA-1 hash).
# Sets global RESOLVED_SIGN_HASH, RESOLVED_SIGN_NAME, and RESOLVED_TEAM_ID.
RESOLVED_SIGN_HASH=""
RESOLVED_SIGN_NAME=""
RESOLVED_TEAM_ID=""

resolve_codesign_identity() {
  local query="$1"
  local identities_file pem_file line hash name cert idx cert_hash subject team

  identities_file="$(mktemp "${TMPDIR:-/tmp}/ccx-identities.XXXXXX")"
  CLEANUP_PATHS+=("$identities_file")
  security find-identity -v -p codesigning 2>/dev/null > "$identities_file" || true

  pem_file="$(mktemp "${TMPDIR:-/tmp}/ccx-certs.XXXXXX")"
  CLEANUP_PATHS+=("$pem_file")

  local query_upper hash_upper
  query_upper="$(printf '%s' "$query" | tr '[:lower:]' '[:upper:]')"

  while IFS= read -r line; do
    # Lines look like:  1) ABCDEF0123... "Developer ID Application: Name (TEAMID)"
    hash="$(printf '%s\n' "$line" | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+([A-Fa-f0-9]{40})[[:space:]]+"(.*)"$/\1/p')"
    name="$(printf '%s\n' "$line" | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+([A-Fa-f0-9]{40})[[:space:]]+"(.*)"$/\2/p')"
    [[ -n "$hash" && -n "$name" ]] || continue

    hash_upper="$(printf '%s' "$hash" | tr '[:lower:]' '[:upper:]')"
    if [[ "$hash_upper" != "$query_upper" && "$name" != *"$query"* ]]; then
      continue
    fi

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
      if [[ "$cert_hash" != "$(printf '%s' "$hash" | tr '[:lower:]' '[:upper:]')" ]]; then
        continue
      fi

      subject="$(printf '%s' "$cert" | openssl x509 -noout -subject 2>/dev/null || true)"
      team="$(printf '%s\n' "$subject" | grep -Eo 'OU[[:space:]]*=[[:space:]]*[A-Z0-9]{10}' | head -n 1 | grep -Eo '[A-Z0-9]{10}$' || true)"
      if [[ -n "$team" ]]; then
        RESOLVED_SIGN_HASH="$cert_hash"
        RESOLVED_SIGN_NAME="$name"
        RESOLVED_TEAM_ID="$team"
        return 0
      fi
    done
  done < "$identities_file"

  return 1
}

SIGN_IDENTITY=""
TEAM_ID="${DEVELOPMENT_TEAM:-}"
SIGN_ARGS=()

if [[ "$ADHOC" -eq 1 ]]; then
  echo "warning: using ad-hoc signing (--adhoc); output is for local testing only and will NOT pass Gatekeeper." >&2
  SIGN_IDENTITY="-"
  SIGN_ARGS+=(
    "CODE_SIGN_STYLE=Manual"
    "CODE_SIGN_IDENTITY=-"
    "DEVELOPMENT_TEAM="
    "ENABLE_HARDENED_RUNTIME=NO"
    "OTHER_CODE_SIGN_FLAGS="
  )
else
  IDENTITY_QUERY="${SIGN_IDENTITY_OVERRIDE:-Developer ID Application:}"
  if resolve_codesign_identity "$IDENTITY_QUERY"; then
    SIGN_IDENTITY="$RESOLVED_SIGN_HASH"
    if [[ -z "$TEAM_ID" ]]; then
      TEAM_ID="$RESOLVED_TEAM_ID"
    fi
    echo "==> Signing with \"$RESOLVED_SIGN_NAME\" (Team ID $TEAM_ID)"
  else
    if [[ -n "$SIGN_IDENTITY_OVERRIDE" ]]; then
      echo "error: signing identity '$SIGN_IDENTITY_OVERRIDE' not found or expired in Keychain." >&2
    else
      echo "error: no valid, unexpired \"Developer ID Application\" identity found in Keychain." >&2
      echo "       Install a Developer ID Application certificate, pass --sign-identity \"<id>\", or pass --adhoc for local packaging." >&2
    fi
    exit 1
  fi

  SIGN_ARGS+=(
    "CODE_SIGN_STYLE=Manual"
    "CODE_SIGN_IDENTITY=$SIGN_IDENTITY"
    "DEVELOPMENT_TEAM=$TEAM_ID"
    "ENABLE_HARDENED_RUNTIME=YES"
    "OTHER_CODE_SIGN_FLAGS=--timestamp"
  )
fi

echo "==> Packaging CCX v${VERSION} (${BUILD_NUMBER}) for ${ARCH_MODE}"
echo "==> Generating CCX.xcodeproj"
xcodegen generate --spec project.yml --quiet

DERIVED_DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ccx-release-build.XXXXXX")"
CLEANUP_PATHS+=("$DERIVED_DATA_DIR")

echo "==> Building Release (${XCODE_ARCHS})"
xcodebuild \
  -project CCX.xcodeproj \
  -scheme CCX \
  -configuration Release \
  -destination "$XCODE_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  "ARCHS=$XCODE_ARCHS" \
  "ONLY_ACTIVE_ARCH=NO" \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
  build

BUILT_APP="$DERIVED_DATA_DIR/Build/Products/Release/CCX.app"
APP_BIN="$BUILT_APP/Contents/MacOS/CCX"
INFO_PLIST="$BUILT_APP/Contents/Info.plist"

if [[ ! -d "$BUILT_APP" || ! -x "$APP_BIN" ]]; then
  echo "error: Release build succeeded but $BUILT_APP is missing or incomplete" >&2
  exit 1
fi

echo "==> Verifying built bundle"

# (a) Validate Info.plist syntax.
plutil -lint "$INFO_PLIST" >/dev/null
echo "    [ok] Info.plist valid"

# (b) Verify requested architecture(s).
FILE_INFO="$(file "$APP_BIN")"
LIPO_ARCHS="$(lipo -archs "$APP_BIN")"
echo "    [info] Binary: $FILE_INFO"
case "$ARCH_MODE" in
  universal)
    if [[ " $LIPO_ARCHS " != *" arm64 "* || " $LIPO_ARCHS " != *" x86_64 "* ]]; then
      echo "error: expected universal binary (arm64 + x86_64), got: $LIPO_ARCHS" >&2
      exit 1
    fi
    ;;
  arm64)
    if [[ " $LIPO_ARCHS " != *" arm64 "* ]]; then
      echo "error: expected arm64 binary, got: $LIPO_ARCHS" >&2
      exit 1
    fi
    ;;
  x86_64)
    if [[ " $LIPO_ARCHS " != *" x86_64 "* ]]; then
      echo "error: expected x86_64 binary, got: $LIPO_ARCHS" >&2
      exit 1
    fi
    ;;
esac
echo "    [ok] Architectures verified: $LIPO_ARCHS"

# (c) Verify zero non-Apple / third-party local dylib dependencies across all slices.
BAD_DYLIBS="$(otool -L -arch all "$APP_BIN" \
  | sed -nE 's/^[[:space:]]+(.*)[[:space:]]+\(compatibility version.*$/\1/p' \
  | sort -u \
  | while IFS= read -r lib; do
      case "$lib" in
        /System/Library/* | /usr/lib/* | @rpath/* | @executable_path/* | @loader_path/*)
          ;;
        *)
          printf '%s\n' "$lib"
          ;;
      esac
    done)"
if [[ -n "$BAD_DYLIBS" ]]; then
  echo "error: found non-Apple dynamic library dependencies in $APP_BIN:" >&2
  printf '%s\n' "$BAD_DYLIBS" >&2
  exit 1
fi
echo "    [ok] No non-Apple dylib dependencies"

# (d) Verify code signature strictly.
codesign --verify --deep --strict --verbose=2 "$BUILT_APP"
echo "    [ok] codesign --verify --deep --strict passed"

# (e) Verify entitlements and Hardened Runtime flag.
ENTITLEMENTS_OUT="$(codesign -d --entitlements :- "$BUILT_APP" 2>&1 || codesign -d --entitlements - "$BUILT_APP" 2>&1)"
if ! printf '%s\n' "$ENTITLEMENTS_OUT" | grep -q 'com.apple.security.device.audio-input'; then
  echo "error: missing com.apple.security.device.audio-input entitlement in $BUILT_APP" >&2
  exit 1
fi
echo "    [ok] com.apple.security.device.audio-input entitlement present"

if [[ "$ADHOC" -eq 0 ]]; then
  CODESIGN_INFO="$(codesign -dvv "$BUILT_APP" 2>&1)"
  if ! printf '%s\n' "$CODESIGN_INFO" | grep -Eq 'flags=.*runtime'; then
    echo "error: Hardened Runtime flag not present in code signature" >&2
    printf '%s\n' "$CODESIGN_INFO" >&2
    exit 1
  fi
  if ! printf '%s\n' "$CODESIGN_INFO" | grep -q 'Timestamp='; then
    echo "error: secure timestamp missing from code signature" >&2
    printf '%s\n' "$CODESIGN_INFO" >&2
    exit 1
  fi
  echo "    [ok] Hardened Runtime & secure timestamp verified"
fi

# Resolve output directory path and copy verified CCX.app cleanly.
mkdir -p "$OUT_DIR"
OUT_DIR_ABS="$(cd "$OUT_DIR" && pwd)"
DIST_APP="$OUT_DIR_ABS/CCX.app"

APP_STAGE_DIR="$(mktemp -d "${OUT_DIR_ABS}/.CCX.app.stage.XXXXXX")"
CLEANUP_PATHS+=("$APP_STAGE_DIR")
ditto "$BUILT_APP" "$APP_STAGE_DIR/CCX.app"
rm -rf "$DIST_APP"
mv "$APP_STAGE_DIR/CCX.app" "$DIST_APP"

if [[ -n "$NOTARIZE_PROFILE" ]]; then
  echo "==> Submitting CCX.app for notarization (profile: $NOTARIZE_PROFILE)"
  NOTARY_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ccx-notary.XXXXXX")"
  CLEANUP_PATHS+=("$NOTARY_STAGE")
  NOTARY_APP_ZIP="$NOTARY_STAGE/CCX.zip"
  ditto -c -k --keepParent "$DIST_APP" "$NOTARY_APP_ZIP"
  xcrun notarytool submit "$NOTARY_APP_ZIP" --keychain-profile "$NOTARIZE_PROFILE" --wait
  xcrun stapler staple "$DIST_APP"
  xcrun stapler validate "$DIST_APP"
  echo "    [ok] CCX.app notarized and stapled"
fi

ARTIFACT_BASENAMES=()

if [[ "$BUILD_ZIP" -eq 1 ]]; then
  ZIP_NAME="CCX-${VERSION}-macOS-${ARCH_MODE}.zip"
  ZIP_PATH="$OUT_DIR_ABS/$ZIP_NAME"
  rm -f "$ZIP_PATH"
  echo "==> Creating $ZIP_NAME"
  ditto -c -k --keepParent "$DIST_APP" "$ZIP_PATH"
  ARTIFACT_BASENAMES+=("$ZIP_NAME")
fi

if [[ "$BUILD_DMG" -eq 1 ]]; then
  DMG_NAME="CCX-${VERSION}-macOS-${ARCH_MODE}.dmg"
  DMG_PATH="$OUT_DIR_ABS/$DMG_NAME"
  DMG_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ccx-dmg-stage.XXXXXX")"
  CLEANUP_PATHS+=("$DMG_STAGE")

  ditto "$DIST_APP" "$DMG_STAGE/CCX.app"
  ln -s /Applications "$DMG_STAGE/Applications"

  rm -f "$DMG_PATH"
  echo "==> Creating $DMG_NAME"
  hdiutil create \
    -volname "CCX ${VERSION}" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH" >/dev/null

  if [[ "$ADHOC" -eq 0 ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
  fi

  if [[ -n "$NOTARIZE_PROFILE" ]]; then
    echo "==> Submitting $DMG_NAME for notarization (profile: $NOTARIZE_PROFILE)"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARIZE_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    echo "    [ok] $DMG_NAME notarized and stapled"
  fi
  ARTIFACT_BASENAMES+=("$DMG_NAME")
fi

if [[ "${#ARTIFACT_BASENAMES[@]}" -gt 0 ]]; then
  echo "==> Generating SHA256SUMS.txt"
  (
    cd "$OUT_DIR_ABS"
    shasum -a 256 ${ARTIFACT_BASENAMES[@]+"${ARTIFACT_BASENAMES[@]}"} > SHA256SUMS.txt
  )
fi

echo "==> Gatekeeper assessment (spctl)"
spctl -a -t exec -vv "$DIST_APP" 2>&1 || true

echo ""
echo "==> Release artifacts ready in $OUT_DIR_ABS:"
ls -lh "$OUT_DIR_ABS"
if [[ -f "$OUT_DIR_ABS/SHA256SUMS.txt" ]]; then
  echo ""
  cat "$OUT_DIR_ABS/SHA256SUMS.txt"
fi

if [[ "$ADHOC" -eq 0 && -z "$NOTARIZE_PROFILE" ]]; then
  echo ""
  echo "Note: Bundle is Developer ID signed with Hardened Runtime, but NOT YET NOTARIZED."
  echo "To notarize and staple for zero-warning Gatekeeper installs on external Macs:"
  echo "  1. Store notarytool credentials once:"
  echo "     xcrun notarytool store-credentials \"CCX-Notary\" --apple-id \"<apple-id>\" --team-id \"$TEAM_ID\" --password \"<app-specific-password>\""
  echo "  2. Re-run packaging with notarization:"
  echo "     ./scripts/package-release.sh --arch ${ARCH_MODE} --notarize \"CCX-Notary\""
fi
