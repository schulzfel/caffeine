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
readonly APP_IDENTIFIER="tech.46h.caffeine"
readonly HELPER_IDENTIFIER="tech.46h.caffeine.helper"
readonly HELPER_RELATIVE_PATH="Contents/MacOS/CaffeineHelper"
readonly PLIST_BUDDY="/usr/libexec/PlistBuddy"
readonly REQUIRE_DISTRIBUTION_SIGNATURE="${REQUIRE_DISTRIBUTION_SIGNATURE:-0}"

# shellcheck source=scripts/validation-common.sh
source "$SCRIPT_DIRECTORY/validation-common.sh"

signature_has_flag() {
    local details="$1"
    local expected_flag="$2"

    printf '%s\n' "$details" |
        /usr/bin/awk -v expected_flag="$expected_flag" '
            /^CodeDirectory / {
                for (field_index = 1; field_index <= NF; field_index += 1) {
                    if ($field_index !~ /^flags=/) {
                        continue
                    }

                    flag_field = $field_index
                    opening = index(flag_field, "(")
                    closing = index(flag_field, ")")
                    if (opening == 0 || closing <= opening) {
                        continue
                    }

                    names = substr(flag_field, opening + 1, closing - opening - 1)
                    name_count = split(names, flag_names, ",")
                    for (name_index = 1;
                         name_index <= name_count;
                         name_index += 1) {
                        if (flag_names[name_index] == expected_flag) {
                            found = 1
                        }
                    }
                }
            }
            END {
                exit found ? 0 : 1
            }
        '
}

validate_binary() {
    local binary="$1"
    local expected_identifier="$2"
    local label="$3"
    local details
    local architectures
    local architecture_count
    local signature_identifier
    local signature_team
    local signature_authority
    local signature_timestamp

    [[ -f "$binary" ]] || fail "$label is missing: $binary"
    [[ -x "$binary" ]] || fail "$label is not executable: $binary"

    architectures="$(/usr/bin/lipo -archs "$binary")"
    architecture_count="$(
        printf '%s\n' "$architectures" |
            /usr/bin/awk '{ print NF }'
    )"
    require_equal "$architecture_count" "2" "$label architecture count"
    /usr/bin/lipo "$binary" -verify_arch arm64 x86_64 >/dev/null ||
        fail "$label is not a Universal 2 binary: $architectures"

    /usr/bin/codesign --verify --strict --verbose=2 "$binary"
    details="$(signature_details "$binary")"
    signature_identifier="$(signature_field "$details" "Identifier")"
    require_equal "$signature_identifier" "$expected_identifier" "$label signing identifier"
    signature_has_flag "$details" "runtime" ||
        fail "$label is not signed with the hardened runtime"

    signature_team="$(signature_field "$details" "TeamIdentifier")"
    if [[ -n "$declared_team_identifier" ]]; then
        require_equal "$signature_team" "$declared_team_identifier" "$label Team ID"
        signature_authority="$(signature_field "$details" "Authority")"
        [[ "$signature_authority" == "Developer ID Application:"* ]] ||
            fail "$label is not signed by a Developer ID Application certificate"
        signature_timestamp="$(signature_field "$details" "Timestamp")"
        [[ -n "$signature_timestamp" && "$signature_timestamp" != "none" ]] ||
            fail "$label signature has no trusted timestamp"
    else
        [[ -z "$signature_team" || "$signature_team" == "not set" ]] ||
            fail "$label unexpectedly has Team ID '$signature_team'"
    fi

    local dependencies
    dependencies="$(
        /usr/bin/otool -L "$binary" |
            /usr/bin/awk '/^[[:space:]]/ { print }'
    )"
    [[ "$dependencies" != *"$REPOSITORY_ROOT"* ]] ||
        fail "$label contains a development-path dynamic dependency"
    [[ "$dependencies" != *"/System/Library/PrivateFrameworks/"* ]] ||
        fail "$label directly links a private Apple framework"

    local undefined_symbols direct_sls_imports
    undefined_symbols="$(/usr/bin/nm -u "$binary")"
    direct_sls_imports="$(
        /usr/bin/printf '%s\n' "$undefined_symbols" |
            /usr/bin/awk '$NF ~ /^_SLS/ { print }'
    )"
    [[ -z "$direct_sls_imports" ]] ||
        fail "$label directly imports private SLS display symbols"

    if [[ "$label" == "CaffeineHelper" ]]; then
        local private_power_imports
        private_power_imports="$(
            /usr/bin/printf '%s\n' "$undefined_symbols" |
                /usr/bin/awk '
                    $1 == "_IOPMCopySystemPowerSettings" ||
                    $1 == "_IOPMSetSystemPowerSetting" {
                        print
                    }
                '
        )"
        [[ -z "$private_power_imports" ]] ||
            fail "CaffeineHelper directly links private IOKit power symbols"
    fi
}

if [[ "$#" -ne 1 ]]; then
    fail "usage: validate-app <path-to-Caffeine.app>"
fi
[[ "$REQUIRE_DISTRIBUTION_SIGNATURE" == "0" ||
    "$REQUIRE_DISTRIBUTION_SIGNATURE" == "1" ]] ||
    fail "REQUIRE_DISTRIBUTION_SIGNATURE must be 0 or 1"

app_argument="$1"
[[ -d "$app_argument" ]] || fail "app bundle not found: $app_argument"

APP_DIRECTORY="$(
    cd "$(/usr/bin/dirname "$app_argument")" && pwd -P
)"
readonly APP_DIRECTORY
APP_PATH="$APP_DIRECTORY/$(/usr/bin/basename "$app_argument")"
readonly APP_PATH
readonly INFO_PLIST="$APP_PATH/Contents/Info.plist"
readonly APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Caffeine"
readonly HELPER_EXECUTABLE="$APP_PATH/$HELPER_RELATIVE_PATH"
readonly INSTALL_HELPER_SCRIPT="$APP_PATH/Contents/Resources/install-helper.sh"
readonly UNINSTALL_HELPER_SCRIPT="$APP_PATH/Contents/Resources/uninstall-helper.sh"
readonly HELPER_COMMON_SCRIPT="$APP_PATH/Contents/Resources/local-helper-common.sh"
readonly DAEMON_TEMPLATE="$APP_PATH/Contents/Resources/$HELPER_IDENTIFIER.legacy.plist.in"
readonly APP_ICON="$APP_PATH/Contents/Resources/Caffeine.icns"
readonly ACTIVE_STATUS_ICON="$APP_PATH/Contents/Resources/CaffeineStatusActiveTemplate.png"
readonly INACTIVE_STATUS_ICON="$APP_PATH/Contents/Resources/CaffeineStatusInactiveTemplate.png"
readonly BUNDLED_LICENSE="$APP_PATH/Contents/Resources/LICENSE"
readonly BUNDLED_THIRD_PARTY_NOTICES="$APP_PATH/Contents/Resources/THIRD_PARTY_NOTICES.md"
readonly EMBEDDED_HELPER_PACKAGE="$APP_PATH/Contents/Resources/Install Caffeine Helper.pkg"
STATUS_ICONS=("$ACTIVE_STATUS_ICON" "$INACTIVE_STATUS_ICON")
readonly -a STATUS_ICONS

[[ -f "$INFO_PLIST" ]] || fail "Info.plist is missing"
[[ -s "$APP_ICON" ]] || fail "Caffeine.icns is missing or empty"
[[ -s "$BUNDLED_LICENSE" ]] || fail "bundled MIT license is missing or empty"
[[ -s "$BUNDLED_THIRD_PARTY_NOTICES" ]] ||
    fail "bundled third-party notices are missing or empty"
[[ -f "$EMBEDDED_HELPER_PACKAGE" &&
   ! -L "$EMBEDDED_HELPER_PACKAGE" ]] ||
    fail "embedded helper installer is missing or symbolic"
/usr/bin/cmp -s "$REPOSITORY_ROOT/LICENSE" "$BUNDLED_LICENSE" ||
    fail "bundled MIT license does not match the reviewed repository license"
/usr/bin/cmp -s \
    "$REPOSITORY_ROOT/THIRD_PARTY_NOTICES.md" \
    "$BUNDLED_THIRD_PARTY_NOTICES" ||
    fail "bundled third-party notices do not match the reviewed source"
for forbidden_helper_resource in \
    "$INSTALL_HELPER_SCRIPT" \
    "$UNINSTALL_HELPER_SCRIPT" \
    "$HELPER_COMMON_SCRIPT" \
    "$DAEMON_TEMPLATE"; do
    [[ ! -e "$forbidden_helper_resource" &&
       ! -L "$forbidden_helper_resource" ]] ||
        fail \
            "app must not bundle privileged installer resource: $forbidden_helper_resource"
done

icon_properties="$(/usr/bin/sips -g format -g pixelWidth -g pixelHeight "$APP_ICON")"
[[ "$icon_properties" == *"format: icns"* ]] ||
    fail "Caffeine.icns is not a valid ICNS file"
[[ "$icon_properties" == *"pixelWidth: 1024"* ]] ||
    fail "Caffeine.icns has no 1024-pixel representation"
[[ "$icon_properties" == *"pixelHeight: 1024"* ]] ||
    fail "Caffeine.icns has no square 1024-pixel representation"

for status_icon in "${STATUS_ICONS[@]}"; do
    status_icon_name="$(/usr/bin/basename "$status_icon")"
    [[ -s "$status_icon" ]] ||
        fail "$status_icon_name is missing or empty"
    status_icon_properties="$(
        /usr/bin/sips \
            -g format \
            -g pixelWidth \
            -g pixelHeight \
            -g hasAlpha \
            "$status_icon"
    )"
    [[ "$status_icon_properties" == *"format: png"* ]] ||
        fail "$status_icon_name is not a PNG"
    [[ "$status_icon_properties" == *"pixelWidth: 32"* ]] ||
        fail "$status_icon_name must be 32 pixels wide"
    [[ "$status_icon_properties" == *"pixelHeight: 32"* ]] ||
        fail "$status_icon_name must be 32 pixels high"
    [[ "$status_icon_properties" == *"hasAlpha: yes"* ]] ||
        fail "$status_icon_name must have transparency"
done

/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null

require_equal \
    "$(plist_value "$INFO_PLIST" "CFBundleExecutable")" \
    "Caffeine" \
    "CFBundleExecutable"
require_equal \
    "$(plist_value "$INFO_PLIST" "CFBundleIdentifier")" \
    "$APP_IDENTIFIER" \
    "CFBundleIdentifier"
require_equal \
    "$(plist_value "$INFO_PLIST" "CFBundlePackageType")" \
    "APPL" \
    "CFBundlePackageType"
require_equal \
    "$(plist_value "$INFO_PLIST" "LSMinimumSystemVersion")" \
    "14.0" \
    "LSMinimumSystemVersion"
require_equal \
    "$(plist_value "$INFO_PLIST" "LSUIElement")" \
    "true" \
    "LSUIElement"

short_version="$(plist_value "$INFO_PLIST" "CFBundleShortVersionString")"
build_version="$(plist_value "$INFO_PLIST" "CFBundleVersion")"
[[ "$short_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] ||
    fail "CFBundleShortVersionString is invalid: $short_version"
[[ "$build_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] ||
    fail "CFBundleVersion is invalid: $build_version"

declared_team_identifier="$(
    plist_value "$INFO_PLIST" "CaffeineTeamIdentifier"
)"
if [[ -n "$declared_team_identifier" ]]; then
    [[ "$declared_team_identifier" =~ ^[A-Z0-9]{10}$ ]] ||
        fail "CaffeineTeamIdentifier must be ten uppercase ASCII letters or digits"
fi
if [[ "$REQUIRE_DISTRIBUTION_SIGNATURE" == "1" ]]; then
    [[ -n "$declared_team_identifier" ]] ||
        fail "customer releases must contain a nonempty Developer ID Team ID"
fi
if [[ -n "${EXPECTED_TEAM_ID+x}" ]]; then
    require_equal \
        "$declared_team_identifier" \
        "$EXPECTED_TEAM_ID" \
        "embedded Team ID"
fi

[[ "$(/usr/bin/stat -f '%Lp' "$APP_EXECUTABLE")" == "755" ]] ||
    fail "Caffeine executable mode must be 0755"
[[ "$(/usr/bin/stat -f '%Lp' "$HELPER_EXECUTABLE")" == "755" ]] ||
    fail "CaffeineHelper executable mode must be 0755"
[[ "$(/usr/bin/stat -f '%Lp' "$INFO_PLIST")" == "644" ]] ||
    fail "Info.plist mode must be 0644"
for notice in "$BUNDLED_LICENSE" "$BUNDLED_THIRD_PARTY_NOTICES"; do
    [[ "$(/usr/bin/stat -f '%Lp' "$notice")" == "644" ]] ||
        fail "$(/usr/bin/basename "$notice") mode must be 0644"
done
[[ "$(/usr/bin/stat -f '%Lp' "$EMBEDDED_HELPER_PACKAGE")" == "644" ]] ||
    fail "embedded helper installer mode must be 0644"
for status_icon in "${STATUS_ICONS[@]}"; do
    [[ "$(/usr/bin/stat -f '%Lp' "$status_icon")" == "644" ]] ||
        fail "$(/usr/bin/basename "$status_icon") mode must be 0644"
done

unexpected_symlink="$(
    /usr/bin/find "$APP_PATH" -type l -print -quit
)"
[[ -z "$unexpected_symlink" ]] ||
    fail "app bundle contains an unexpected symbolic link: $unexpected_symlink"
[[ ! -e "$APP_PATH/Contents/Library/LaunchDaemons" ]] ||
    fail "app must not embed an SMAppService LaunchDaemon"

validate_binary "$HELPER_EXECUTABLE" "$HELPER_IDENTIFIER" "CaffeineHelper"
validate_binary "$APP_EXECUTABLE" "$APP_IDENTIFIER" "Caffeine"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

[[ -x "$SCRIPT_DIRECTORY/validate-helper-package.sh" ]] ||
    fail "helper package validator is missing or not executable"
"$SCRIPT_DIRECTORY/validate-helper-package.sh" \
    "$APP_PATH" \
    "$EMBEDDED_HELPER_PACKAGE"

printf 'Validated %s (%s, build %s, Universal 2).\n' \
    "$APP_PATH" \
    "$short_version" \
    "$build_version"
