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
readonly VALIDATION_TEMP_ROOT="$REPOSITORY_ROOT/.build/dmg-validation"
readonly PLIST_BUDDY="/usr/libexec/PlistBuddy"
readonly EXPECTED_DMG_IDENTIFIER="${EXPECTED_DMG_IDENTIFIER:-tech.46h.caffeine.dmg}"
readonly EXPECTED_VOLUME_NAME="${EXPECTED_VOLUME_NAME:-Caffeine}"
readonly REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-0}"
readonly EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-}"
readonly EXPECTED_APP_VERSION="${EXPECTED_APP_VERSION:-}"
readonly EXPECTED_BUILD_VERSION="${EXPECTED_BUILD_VERSION:-}"

# shellcheck source=scripts/validation-common.sh
source "$SCRIPT_DIRECTORY/validation-common.sh"

if [[ "$#" -ne 1 ]]; then
    fail "usage: validate-dmg <path-to-Caffeine.dmg>"
fi
[[ "$REQUIRE_NOTARIZATION" == "0" || "$REQUIRE_NOTARIZATION" == "1" ]] ||
    fail "REQUIRE_NOTARIZATION must be 0 or 1"
[[ "$EXPECTED_DMG_IDENTIFIER" =~ ^[A-Za-z0-9.-]+$ ]] ||
    fail "EXPECTED_DMG_IDENTIFIER contains invalid characters"
if [[ -n "$EXPECTED_TEAM_ID" ]]; then
    [[ "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] ||
        fail "EXPECTED_TEAM_ID must be ten uppercase ASCII letters or digits"
fi
if [[ -n "$EXPECTED_APP_VERSION" ]]; then
    [[ "$EXPECTED_APP_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] ||
        fail "EXPECTED_APP_VERSION must contain one to three dot-separated integers"
fi
if [[ -n "$EXPECTED_BUILD_VERSION" ]]; then
    [[ "$EXPECTED_BUILD_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] ||
        fail "EXPECTED_BUILD_VERSION must contain one to three dot-separated integers"
fi

dmg_argument="$1"
[[ -f "$dmg_argument" ]] || fail "disk image not found: $dmg_argument"
[[ "$dmg_argument" == *.dmg ]] || fail "disk image filename must end in .dmg"
dmg_parent="$(
    cd "$(/usr/bin/dirname "$dmg_argument")" && pwd -P
)"
DMG_PATH="$dmg_parent/$(
    /usr/bin/basename "$dmg_argument"
)"
readonly DMG_PATH

required_validator="$SCRIPT_DIRECTORY/validate-app.sh"
[[ -f "$required_validator" ]] ||
    fail "required file is missing: $required_validator"
for required_tool in \
    /bin/mkdir \
    /bin/rm \
    /usr/bin/awk \
    /usr/bin/basename \
    /usr/bin/codesign \
    /usr/bin/find \
    /usr/bin/hdiutil \
    /usr/bin/readlink \
    /usr/bin/sips \
    /usr/bin/stat \
    /usr/bin/xcrun \
    /usr/sbin/diskutil \
    /usr/sbin/spctl; do
    [[ -x "$required_tool" ]] || fail "required Apple tool is missing: $required_tool"
done
/usr/bin/xcrun --find stapler >/dev/null ||
    fail "Apple stapler tool is unavailable"

/bin/mkdir -p "$VALIDATION_TEMP_ROOT"
work_directory="$(
    /usr/bin/mktemp -d "$VALIDATION_TEMP_ROOT/validation.XXXXXX"
)"
image_info_plist="$work_directory/image-info.plist"
attach_plist="$work_directory/attach.plist"
disk_info_plist="$work_directory/disk-info.plist"
mount_point=""

cleanup() {
    if [[ -n "$mount_point" && -d "$mount_point" ]]; then
        if ! /usr/bin/hdiutil detach -quiet "$mount_point"; then
            printf 'warning: forcing detach of validation volume %s\n' \
                "$mount_point" >&2
            /usr/bin/hdiutil detach -quiet -force "$mount_point" || true
        fi
    fi

    case "$work_directory" in
        "$VALIDATION_TEMP_ROOT"/*)
            /bin/rm -rf -- "$work_directory"
            ;;
        *)
            printf 'warning: refusing to clean unexpected path: %s\n' \
                "$work_directory" >&2
            ;;
    esac
}
trap cleanup EXIT

/usr/bin/hdiutil verify "$DMG_PATH" >/dev/null
/usr/bin/hdiutil imageinfo -plist "$DMG_PATH" >"$image_info_plist"
require_equal \
    "$(/usr/bin/stat -f '%Lp' "$DMG_PATH")" \
    "644" \
    "disk image file mode"
require_equal \
    "$(plist_value "$image_info_plist" "Format")" \
    "UDZO" \
    "disk image format"

if [[ "$REQUIRE_NOTARIZATION" == "1" || -n "$EXPECTED_TEAM_ID" ]]; then
    /usr/bin/codesign --verify --strict --verbose=2 "$DMG_PATH"
    dmg_signature="$(signature_details "$DMG_PATH")"
    require_equal \
        "$(signature_field "$dmg_signature" "Format")" \
        "disk image" \
        "signed object format"
    require_equal \
        "$(signature_field "$dmg_signature" "Identifier")" \
        "$EXPECTED_DMG_IDENTIFIER" \
        "disk image signing identifier"

    dmg_team_id="$(signature_field "$dmg_signature" "TeamIdentifier")"
    [[ "$dmg_team_id" =~ ^[A-Z0-9]{10}$ ]] ||
        fail "disk image signature has no valid Developer ID Team ID"
    if [[ -n "$EXPECTED_TEAM_ID" ]]; then
        require_equal "$dmg_team_id" "$EXPECTED_TEAM_ID" "disk image Team ID"
    fi

    dmg_authority="$(signature_field "$dmg_signature" "Authority")"
    [[ "$dmg_authority" == "Developer ID Application:"* ]] ||
        fail "disk image is not signed by a Developer ID Application certificate"
    dmg_timestamp="$(signature_field "$dmg_signature" "Timestamp")"
    [[ -n "$dmg_timestamp" && "$dmg_timestamp" != "none" ]] ||
        fail "disk image signature has no trusted timestamp"
else
    dmg_team_id=""
    if /usr/bin/codesign --verify --strict "$DMG_PATH" >/dev/null 2>&1; then
        fail "community disk image must not carry a distribution signature"
    fi
fi

if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
    /usr/bin/xcrun stapler validate "$DMG_PATH"
    /usr/sbin/spctl \
        --assess \
        --type open \
        --context context:primary-signature \
        --verbose=4 \
        "$DMG_PATH"
fi

/usr/bin/hdiutil attach \
    -readonly \
    -nobrowse \
    -noautoopen \
    -plist \
    "$DMG_PATH" \
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

[[ "$mount_point" == /Volumes/* && -d "$mount_point" ]] ||
    fail "could not resolve the mounted disk image volume"

/usr/sbin/diskutil info -plist "$mount_point" >"$disk_info_plist"
require_equal \
    "$(plist_value "$disk_info_plist" "VolumeName")" \
    "$EXPECTED_VOLUME_NAME" \
    "disk image volume name"

mounted_app="$mount_point/Caffeine.app"
mounted_link="$mount_point/Applications"
mounted_background="$mount_point/.background/Caffeine.png"
mounted_info_plist="$mounted_app/Contents/Info.plist"

[[ -d "$mounted_app" ]] || fail "Caffeine.app is missing from the disk image"
[[ -L "$mounted_link" ]] ||
    fail "Applications install link is missing from the disk image"
require_equal \
    "$(/usr/bin/readlink "$mounted_link")" \
    "/Applications" \
    "Applications install link target"
[[ -s "$mount_point/.DS_Store" ]] ||
    fail "Finder layout metadata is missing from the disk image"
[[ -s "$mounted_background" ]] ||
    fail "Finder background is missing from the disk image"

background_properties="$(
    /usr/bin/sips \
        -g format \
        -g pixelWidth \
        -g pixelHeight \
        -g dpiWidth \
        -g dpiHeight \
        "$mounted_background"
)"
[[ "$background_properties" == *"format: png"* &&
    "$background_properties" == *"pixelWidth: 1320"* &&
    "$background_properties" == *"pixelHeight: 840"* &&
    "$background_properties" == *"dpiWidth: 144.000"* &&
    "$background_properties" == *"dpiHeight: 144.000"* ]] ||
    fail "Finder background is not a 1320-by-840, 144-DPI PNG"

unexpected_background_file="$(
    /usr/bin/find \
        "$mount_point/.background" \
        -mindepth 1 \
        -maxdepth 1 \
        ! -name "Caffeine.png" \
        -print \
        -quit
)"
[[ -z "$unexpected_background_file" ]] ||
    fail "disk image background directory contains an unexpected file"

unexpected_visible_item="$(
    /usr/bin/find \
        "$mount_point" \
        -mindepth 1 \
        -maxdepth 1 \
        ! -name "Caffeine.app" \
        ! -name "Applications" \
        ! -name ".background" \
        ! -name ".DS_Store" \
        ! -name ".DocumentRevisions-V100" \
        ! -name ".fseventsd" \
        ! -name ".Spotlight-V100" \
        ! -name ".Trashes" \
        -print \
        -quit
)"
[[ -z "$unexpected_visible_item" ]] ||
    fail "disk image contains an unexpected top-level item: $unexpected_visible_item"

/usr/bin/env \
    EXPECTED_TEAM_ID="$dmg_team_id" \
    REQUIRE_DISTRIBUTION_SIGNATURE="$REQUIRE_NOTARIZATION" \
    "$SCRIPT_DIRECTORY/validate-app.sh" "$mounted_app"
app_team_id="$(plist_value "$mounted_info_plist" "CaffeineTeamIdentifier")"
require_equal "$app_team_id" "$dmg_team_id" "app/disk image Team ID"
if [[ -n "$EXPECTED_APP_VERSION" ]]; then
    require_equal \
        "$(plist_value "$mounted_info_plist" "CFBundleShortVersionString")" \
        "$EXPECTED_APP_VERSION" \
        "app version"
fi
if [[ -n "$EXPECTED_BUILD_VERSION" ]]; then
    require_equal \
        "$(plist_value "$mounted_info_plist" "CFBundleVersion")" \
        "$EXPECTED_BUILD_VERSION" \
        "app build version"
fi

/usr/bin/hdiutil detach -quiet "$mount_point"
mount_point=""

if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
    printf 'Validated notarized disk image %s (version %s, build %s, Team ID %s).\n' \
        "$DMG_PATH" \
        "${EXPECTED_APP_VERSION:-embedded}" \
        "${EXPECTED_BUILD_VERSION:-embedded}" \
        "$dmg_team_id"
else
    printf 'Validated community disk image %s (version %s, build %s, no Developer ID).\n' \
        "$DMG_PATH" \
        "${EXPECTED_APP_VERSION:-embedded}" \
        "${EXPECTED_BUILD_VERSION:-embedded}"
fi
