#!/usr/bin/env bash
# Set the app version everywhere it is written down:
#   android/pubspec.yaml               version: X.Y.Z[-pre]+N  (Android versionName / versionCode)
#   android/lib/constants/app_info.dart AppInfo.version          (shown in the app)
# Tests read AppInfo.version, and release.yml checks the tag matches both files.
#
# Usage: bash scripts/bump_version.sh 0.2.1-alpha [build-number]
# The build number (versionCode) defaults to the current one plus one; it must
# keep rising or Android refuses to install the update over the old APK.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PUBSPEC="$REPO_DIR/android/pubspec.yaml"
APP_INFO="$REPO_DIR/android/lib/constants/app_info.dart"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <version, e.g. 0.2.1-alpha> [build-number]" >&2
  exit 1
fi

version="${1#v}"
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; then
  echo "Error: '$version' is not strict semver X.Y.Z[-pre] (no leading zeros)" >&2
  exit 1
fi

current_build="$(sed -n 's/^version: [^+]*+\([0-9]*\)$/\1/p' "$PUBSPEC")"
if [[ -z "$current_build" ]]; then
  echo "Error: no 'version: X.Y.Z+N' line in $PUBSPEC" >&2
  exit 1
fi
build="${2:-$((current_build + 1))}"
if [[ ! "$build" =~ ^[0-9]+$ ]] || (( build <= current_build )); then
  echo "Error: build number must be an integer above the current $current_build" >&2
  exit 1
fi

if ! grep -q "static const String version = '[^']*';" "$APP_INFO"; then
  echo "Error: no AppInfo.version constant in $APP_INFO" >&2
  exit 1
fi

sed -i "s/^version: .*/version: $version+$build/" "$PUBSPEC"
sed -i "s/static const String version = '[^']*';/static const String version = '$version';/" "$APP_INFO"

echo "Version set to $version (build $build) in:"
echo "  android/pubspec.yaml"
echo "  android/lib/constants/app_info.dart"
echo "Release: commit, then tag and push v$version"
