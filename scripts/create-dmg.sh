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
readonly DMG_TEMP_ROOT="$REPOSITORY_ROOT/.build/dmg-packaging"
readonly VOLUME_NAME="Caffeine"
readonly BACKGROUND_NAME="Caffeine.png"
readonly PLIST_BUDDY="/usr/libexec/PlistBuddy"

APP_VERSION="${APP_VERSION:-1.0.0}"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

if [[ "$#" -ne 2 ]]; then
    fail \
        "usage: create-dmg <path-to-Caffeine.app> <output.dmg>"
fi

[[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] ||
    fail "APP_VERSION must contain one to three dot-separated integers"

app_argument="$1"
output_argument="$2"
[[ -d "$app_argument" ]] || fail "app bundle not found: $app_argument"
[[ "$(/usr/bin/basename "$app_argument")" == "Caffeine.app" ]] ||
    fail "input app must be named Caffeine.app"
[[ "$output_argument" == *.dmg ]] || fail "output filename must end in .dmg"

app_parent="$(
    cd "$(/usr/bin/dirname "$app_argument")" && pwd -P
)"
APP_PATH="$app_parent/$(
    /usr/bin/basename "$app_argument"
)"
readonly APP_PATH
output_parent="$(
    cd "$(/usr/bin/dirname "$output_argument")" && pwd -P
)"
OUTPUT_PATH="$output_parent/$(
    /usr/bin/basename "$output_argument"
)"
readonly OUTPUT_PATH
[[ ! -e "$OUTPUT_PATH" ]] ||
    fail "refusing to overwrite existing disk image: $OUTPUT_PATH"

for required_file in \
    "$SCRIPT_DIRECTORY/generate-dmg-background.swift" \
    "$SCRIPT_DIRECTORY/layout-dmg.applescript" \
    "$SCRIPT_DIRECTORY/swift-sdk.sh" \
    "$SCRIPT_DIRECTORY/validate-app.sh"; do
    [[ -f "$required_file" ]] || fail "required file is missing: $required_file"
done

for required_tool in \
    /bin/chmod \
    /bin/ln \
    /bin/mkdir \
    /bin/mv \
    /bin/rm \
    /bin/sleep \
    /bin/sync \
    /usr/bin/codesign \
    /usr/bin/ditto \
    /usr/bin/hdiutil \
    /usr/bin/osascript \
    /usr/bin/readlink \
    /usr/bin/sips \
    /usr/bin/uname; do
    [[ -x "$required_tool" ]] || fail "required Apple tool is missing: $required_tool"
done

"$SCRIPT_DIRECTORY/validate-app.sh" "$APP_PATH"

[[ ! -e "/Volumes/$VOLUME_NAME" ]] ||
    fail "/Volumes/$VOLUME_NAME is already mounted; eject it and try again"

# shellcheck source=scripts/swift-sdk.sh
source "$SCRIPT_DIRECTORY/swift-sdk.sh"
caffeine_select_swift_sdk "$REPOSITORY_ROOT"

/bin/mkdir -p "$DMG_TEMP_ROOT"
work_directory="$(/usr/bin/mktemp -d "$DMG_TEMP_ROOT/package.XXXXXX")"
source_directory="$work_directory/source"
writable_dmg="$work_directory/Caffeine-read-write.dmg"
compressed_dmg="$work_directory/Caffeine.dmg"
attach_plist="$work_directory/attach.plist"
image_info_plist="$work_directory/image-info.plist"
background_tool="$work_directory/generate-dmg-background"
mount_point=""

cleanup() {
    if [[ -n "$mount_point" && -d "$mount_point" ]]; then
        if ! /usr/bin/hdiutil detach -quiet "$mount_point"; then
            printf 'warning: forcing detach of temporary volume %s\n' \
                "$mount_point" >&2
            /usr/bin/hdiutil detach -quiet -force "$mount_point" || true
        fi
    fi

    case "$work_directory" in
        "$DMG_TEMP_ROOT"/*)
            /bin/rm -rf -- "$work_directory"
            ;;
        *)
            printf 'warning: refusing to clean unexpected path: %s\n' \
                "$work_directory" >&2
            ;;
    esac
}
trap cleanup EXIT

/bin/mkdir -p "$source_directory/.background"
/usr/bin/ditto "$APP_PATH" "$source_directory/Caffeine.app"
/bin/ln -s /Applications "$source_directory/Applications"

caffeine_compile_host_swift_tool \
    "$SCRIPT_DIRECTORY/generate-dmg-background.swift" \
    "$background_tool" \
    dmg-background
"$background_tool" \
    "$source_directory/.background/$BACKGROUND_NAME" \
    "$APP_VERSION"

background_properties="$(
    /usr/bin/sips \
        -g format \
        -g pixelWidth \
        -g pixelHeight \
        -g dpiWidth \
        -g dpiHeight \
        "$source_directory/.background/$BACKGROUND_NAME"
)"
[[ "$background_properties" == *"format: png"* &&
    "$background_properties" == *"pixelWidth: 1320"* &&
    "$background_properties" == *"pixelHeight: 840"* &&
    "$background_properties" == *"dpiWidth: 144.000"* &&
    "$background_properties" == *"dpiHeight: 144.000"* ]] ||
    fail "generated DMG background is not a 1320-by-840, 144-DPI PNG"

/usr/bin/hdiutil create \
    -quiet \
    -fs HFS+ \
    -format UDRW \
    -volname "$VOLUME_NAME" \
    -srcfolder "$source_directory" \
    "$writable_dmg"

/usr/bin/hdiutil attach \
    -readwrite \
    -noverify \
    -noautoopen \
    -plist \
    "$writable_dmg" \
    >"$attach_plist"

entity_index=0
while [[ "$entity_index" -lt 16 ]]; do
    candidate_mount="$(
        "$PLIST_BUDDY" \
            -c "Print :system-entities:$entity_index:mount-point" \
            "$attach_plist" \
            2>/dev/null ||
            true
    )"
    if [[ -n "$candidate_mount" ]]; then
        mount_point="$candidate_mount"
        break
    fi
    entity_index=$((entity_index + 1))
done

[[ "$mount_point" == "/Volumes/$VOLUME_NAME" && -d "$mount_point" ]] ||
    fail "could not resolve the mounted Caffeine volume"

/usr/bin/osascript "$SCRIPT_DIRECTORY/layout-dmg.applescript" "$VOLUME_NAME"

metadata_attempt=0
while [[ ! -s "$mount_point/.DS_Store" && "$metadata_attempt" -lt 10 ]]; do
    /bin/sleep 1
    metadata_attempt=$((metadata_attempt + 1))
done
[[ -s "$mount_point/.DS_Store" ]] ||
    fail "Finder did not save the disk image layout metadata"
[[ -L "$mount_point/Applications" ]] ||
    fail "Applications install link is missing from the disk image"
[[ "$(/usr/bin/readlink "$mount_point/Applications")" == "/Applications" ]] ||
    fail "Applications install link has an unexpected target"
"$SCRIPT_DIRECTORY/validate-app.sh" "$mount_point/Caffeine.app"

/bin/sync
/usr/bin/hdiutil detach -quiet "$mount_point"
mount_point=""

/usr/bin/hdiutil convert \
    -quiet \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$compressed_dmg" \
    "$writable_dmg"

/usr/bin/hdiutil verify "$compressed_dmg" >/dev/null
/usr/bin/hdiutil imageinfo -plist "$compressed_dmg" >"$image_info_plist"
image_format="$(
    "$PLIST_BUDDY" -c "Print :Format" "$image_info_plist"
)"
[[ "$image_format" == "UDZO" ]] ||
    fail "final disk image format is '$image_format'; expected UDZO"

/bin/chmod 0644 "$compressed_dmg"
[[ ! -e "$OUTPUT_PATH" ]] ||
    fail "disk image appeared while packaging; refusing to overwrite it"
/bin/mv "$compressed_dmg" "$OUTPUT_PATH"

printf 'Created read-only disk image %s\n' "$OUTPUT_PATH"
