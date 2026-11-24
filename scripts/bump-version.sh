#!/usr/bin/env bash
# Updates MARKETING_VERSION (SemVer MAJOR.MINOR.PATCH) in project.yml.
#
# Usage: scripts/bump-version.sh <patch|minor|major|X.Y.Z>
#   patch  Increment PATCH for bug fixes, UI polish, and performance tweaks.
#   minor  Increment MINOR (reset PATCH to 0) for new features/capabilities.
#   major  Increment MAJOR (reset MINOR and PATCH to 0) for major milestones.
#   X.Y.Z  Set an explicit three-part SemVer version.

set -euo pipefail

usage() {
  awk 'NR>1 { if (/^#/) { sub(/^# ?/, ""); print } else exit }' "$0"
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_YML="$ROOT_DIR/project.yml"

if [[ ! -f "$PROJECT_YML" ]]; then
  echo "error: project.yml not found at $PROJECT_YML" >&2
  exit 1
fi

CURRENT_VERSION="$(awk -F: '/^[[:space:]]*MARKETING_VERSION:/ { gsub(/["'\''[:space:]]/, "", $2); print $2; exit }' "$PROJECT_YML")"
if [[ ! "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: invalid current MARKETING_VERSION in project.yml: '$CURRENT_VERSION'" >&2
  exit 1
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

case "$1" in
  patch)
    NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
    ;;
  minor)
    NEW_VERSION="$MAJOR.$((MINOR + 1)).0"
    ;;
  major)
    NEW_VERSION="$((MAJOR + 1)).0.0"
    ;;
  *)
    if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      NEW_VERSION="$1"
    else
      echo "error: expected patch, minor, major, or X.Y.Z (got '$1')" >&2
      usage >&2
      exit 2
    fi
    ;;
esac

TMP_FILE="$(mktemp "${PROJECT_YML}.tmp.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT
awk -v ver="$NEW_VERSION" '
  !done && /^[[:space:]]*MARKETING_VERSION:/ {
    sub(/:.*/, ": \"" ver "\"")
    done = 1
  }
  { print }
' "$PROJECT_YML" > "$TMP_FILE"
mv "$TMP_FILE" "$PROJECT_YML"
trap - EXIT

echo "==> MARKETING_VERSION: $CURRENT_VERSION -> $NEW_VERSION"
