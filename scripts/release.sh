#!/bin/bash

set -euo pipefail

SCRIPT_DIRECTORY="$(
    cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P
)"
readonly SCRIPT_DIRECTORY
REPOSITORY_ROOT="$(
    cd "$SCRIPT_DIRECTORY/.." && pwd -P
)"
readonly REPOSITORY_ROOT
readonly DIST_DIRECTORY="$REPOSITORY_ROOT/dist"

APP_VERSION="${APP_VERSION:-1.0.0}"
BUILD_VERSION="${BUILD_VERSION:-4}"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] ||
    fail "APP_VERSION must contain one to three dot-separated integers"
[[ "$BUILD_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] ||
    fail "BUILD_VERSION must contain one to three dot-separated integers"

artifact_stem="Caffeine-$APP_VERSION-build-$BUILD_VERSION-macOS-universal"
app_path="$DIST_DIRECTORY/Caffeine.app"
dmg_path="$DIST_DIRECTORY/$artifact_stem.dmg"
checksum_path="$dmg_path.sha256"

[[ ! -e "$dmg_path" ]] ||
    fail "release disk image already exists: $dmg_path"
[[ ! -e "$checksum_path" ]] ||
    fail "release checksum already exists: $checksum_path"

APP_VERSION="$APP_VERSION" \
BUILD_VERSION="$BUILD_VERSION" \
SIGN_IDENTITY="-" \
TEAM_ID="" \
    "$SCRIPT_DIRECTORY/build-app.sh"

APP_VERSION="$APP_VERSION" \
    "$SCRIPT_DIRECTORY/create-dmg.sh" \
    "$app_path" \
    "$dmg_path"

EXPECTED_APP_VERSION="$APP_VERSION" \
EXPECTED_BUILD_VERSION="$BUILD_VERSION" \
REQUIRE_NOTARIZATION=0 \
    "$SCRIPT_DIRECTORY/validate-dmg.sh" "$dmg_path"

(
    cd "$DIST_DIRECTORY"
    /usr/bin/shasum -a 256 "$(/usr/bin/basename "$dmg_path")"
) >"$checksum_path"
/bin/chmod 0644 "$checksum_path"

printf '\nGitHub Release artifacts are ready:\n'
printf '  %s\n' "$dmg_path" "$checksum_path"
printf '%s\n' \
    "This community release has no Developer ID signature or notarization."
