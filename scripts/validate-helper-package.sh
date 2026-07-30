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
readonly VALIDATION_TEMP_ROOT="$REPOSITORY_ROOT/.build/helper-package-validation"
readonly PACKAGE_IDENTIFIER="tech.46h.caffeine.helper-installer"
readonly HELPER_IDENTIFIER="tech.46h.caffeine.helper"
readonly EXPECTED_PACKAGE_NAME="Install Caffeine Helper.pkg"
readonly PLIST_BUDDY="/usr/libexec/PlistBuddy"

# shellcheck source=scripts/validation-common.sh
source "$SCRIPT_DIRECTORY/validation-common.sh"

xml_attribute() {
    local xml="$1"
    local attribute="$2"

    /usr/bin/xmllint \
        --xpath "string(/pkg-info/@$attribute)" \
        "$xml" \
        2>/dev/null
}

xml_count() {
    local xml="$1"
    local expression="$2"

    /usr/bin/xmllint \
        --xpath "count($expression)" \
        "$xml" \
        2>/dev/null
}

require_absent_plist_key() {
    local plist="$1"
    local key_path="$2"

    if plist_value "$plist" "$key_path" >/dev/null 2>&1; then
        fail "$(/usr/bin/basename "$plist") must not contain $key_path"
    fi
}

if [[ "$#" -ne 2 ]]; then
    fail \
        "usage: validate-helper-package <path-to-Caffeine.app> <path-to-install.pkg>"
fi

app_argument="$1"
package_argument="$2"
[[ -d "$app_argument" ]] || fail "app bundle not found: $app_argument"
[[ -f "$package_argument" ]] ||
    fail "helper installer package not found: $package_argument"
[[ "$(/usr/bin/basename "$app_argument")" == "Caffeine.app" ]] ||
    fail "input app must be named Caffeine.app"
[[ "$(/usr/bin/basename "$package_argument")" \
    == "$EXPECTED_PACKAGE_NAME" ]] ||
    fail "helper package must be named $EXPECTED_PACKAGE_NAME"

app_parent="$(
    cd "$(/usr/bin/dirname "$app_argument")" && pwd -P
)"
APP_PATH="$app_parent/$(
    /usr/bin/basename "$app_argument"
)"
readonly APP_PATH
package_parent="$(
    cd "$(/usr/bin/dirname "$package_argument")" && pwd -P
)"
PACKAGE_PATH="$package_parent/$(
    /usr/bin/basename "$package_argument"
)"
readonly PACKAGE_PATH
readonly APP_INFO_PLIST="$APP_PATH/Contents/Info.plist"
readonly APP_HELPER="$APP_PATH/Contents/MacOS/CaffeineHelper"

for required_tool in \
    /bin/bash \
    /bin/chmod \
    /bin/cp \
    /bin/mkdir \
    /bin/rm \
    /usr/bin/awk \
    /usr/bin/basename \
    /usr/bin/cmp \
    /usr/bin/codesign \
    /usr/bin/find \
    /usr/bin/lipo \
    /usr/bin/pkgbuild \
    /usr/bin/plutil \
    /usr/bin/shasum \
    /usr/bin/stat \
    /usr/bin/xar \
    /usr/bin/xmllint \
    /usr/sbin/pkgutil; do
    [[ -x "$required_tool" ]] ||
        fail "required Apple tool is missing: $required_tool"
done

[[ -f "$APP_INFO_PLIST" && ! -L "$APP_INFO_PLIST" ]] ||
    fail "app Info.plist is missing or symbolic"
[[ -f "$APP_HELPER" && ! -L "$APP_HELPER" ]] ||
    fail "app embedded helper is missing or symbolic"
/usr/bin/plutil -lint "$APP_INFO_PLIST" >/dev/null
require_equal \
    "$(plist_value "$APP_INFO_PLIST" "CFBundleIdentifier")" \
    "tech.46h.caffeine" \
    "app bundle identifier"

require_equal \
    "$(/usr/bin/stat -f '%Lp' "$PACKAGE_PATH")" \
    "644" \
    "helper package file mode"

signature_output="$(
    /usr/sbin/pkgutil --check-signature "$PACKAGE_PATH" 2>&1 ||
        true
)"
[[ "$signature_output" == *"Status: no signature"* ]] ||
    fail "helper package must be unsigned"

archive_listing="$(/usr/bin/xar -tf "$PACKAGE_PATH")"
[[ "$archive_listing" == *"PackageInfo"* &&
   "$archive_listing" == *"Scripts"* ]] ||
    fail "helper package is not a flat scripts-only package"

/bin/mkdir -p "$VALIDATION_TEMP_ROOT"
work_directory="$(
    /usr/bin/mktemp \
        -d \
        "$VALIDATION_TEMP_ROOT/validation.XXXXXX"
)"
expanded_directory="$work_directory/expanded"

cleanup() {
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

/usr/sbin/pkgutil \
    --expand-full \
    "$PACKAGE_PATH" \
    "$expanded_directory"

package_info="$expanded_directory/PackageInfo"
package_scripts="$expanded_directory/Scripts"
[[ -f "$package_info" && ! -L "$package_info" ]] ||
    fail "expanded helper package has no PackageInfo"
[[ -d "$package_scripts" && ! -L "$package_scripts" ]] ||
    fail "expanded helper package has no scripts directory"
[[ ! -e "$expanded_directory/Payload" &&
   ! -L "$expanded_directory/Payload" ]] ||
    fail "helper package must not contain an automatic Installer payload"
[[ ! -e "$expanded_directory/Bom" &&
   ! -L "$expanded_directory/Bom" ]] ||
    fail "helper package must not contain an Installer payload BOM"

unexpected_top_level="$(
    /usr/bin/find \
        "$expanded_directory" \
        -mindepth 1 \
        -maxdepth 1 \
        ! -name PackageInfo \
        ! -name Scripts \
        -print \
        -quit
)"
[[ -z "$unexpected_top_level" ]] ||
    fail "helper package contains unexpected archive member: $unexpected_top_level"

require_equal \
    "$(xml_attribute "$package_info" "identifier")" \
    "$PACKAGE_IDENTIFIER" \
    "helper package identifier"
require_equal \
    "$(xml_attribute "$package_info" "install-location")" \
    "/" \
    "helper package install location"
require_equal \
    "$(xml_attribute "$package_info" "auth")" \
    "root" \
    "helper package authorization"
require_equal \
    "$(xml_attribute "$package_info" "postinstall-action")" \
    "none" \
    "helper package postinstall action"
require_equal \
    "$(xml_attribute "$package_info" "version")" \
    "$(plist_value "$APP_INFO_PLIST" "CFBundleVersion")" \
    "helper package/app build version"
require_equal \
    "$(xml_count "$package_info" "/pkg-info/scripts")" \
    "1" \
    "helper package scripts element count"
require_equal \
    "$(xml_count "$package_info" "/pkg-info/scripts/*")" \
    "2" \
    "helper package script-hook count"
require_equal \
    "$(
        xml_count \
            "$package_info" \
            "/pkg-info/scripts/preinstall[@file='./preinstall' and @timeout='600']"
    )" \
    "1" \
    "helper package preinstall hook"
require_equal \
    "$(
        xml_count \
            "$package_info" \
            "/pkg-info/scripts/postinstall[@file='./postinstall' and @timeout='600']"
    )" \
    "1" \
    "helper package postinstall hook"

preinstall="$package_scripts/preinstall"
postinstall="$package_scripts/postinstall"
package_common="$package_scripts/helper-package-common.sh"
packaged_helper="$package_scripts/CaffeineHelper"
packaged_plist="$package_scripts/$HELPER_IDENTIFIER.plist"
packaged_uninstaller="$package_scripts/uninstall-helper"
expected_script_items=(
    "$preinstall"
    "$postinstall"
    "$package_common"
    "$packaged_helper"
    "$packaged_plist"
    "$packaged_uninstaller"
)

for expected_item in "${expected_script_items[@]}"; do
    [[ -f "$expected_item" && ! -L "$expected_item" ]] ||
        fail "helper package member is missing or symbolic: $expected_item"
done
unexpected_script_item="$(
    /usr/bin/find \
        "$package_scripts" \
        -mindepth 1 \
        -maxdepth 1 \
        ! -name preinstall \
        ! -name postinstall \
        ! -name helper-package-common.sh \
        ! -name CaffeineHelper \
        ! -name "$HELPER_IDENTIFIER.plist" \
        ! -name uninstall-helper \
        -print \
        -quit
)"
[[ -z "$unexpected_script_item" ]] ||
    fail "helper package contains unexpected script member: $unexpected_script_item"
unexpected_symlink="$(
    /usr/bin/find "$expanded_directory" -type l -print -quit
)"
[[ -z "$unexpected_symlink" ]] ||
    fail "helper package contains a symbolic link: $unexpected_symlink"

for executable_script in \
    "$preinstall" \
    "$postinstall" \
    "$packaged_uninstaller"; do
    require_equal \
        "$(/usr/bin/stat -f '%Lp' "$executable_script")" \
        "755" \
        "$(/usr/bin/basename "$executable_script") mode"
done
require_equal \
    "$(/usr/bin/stat -f '%Lp' "$package_common")" \
    "644" \
    "package common-script mode"
require_equal \
    "$(/usr/bin/stat -f '%Lp' "$packaged_helper")" \
    "755" \
    "packaged helper mode"
require_equal \
    "$(/usr/bin/stat -f '%Lp' "$packaged_plist")" \
    "644" \
    "packaged LaunchDaemon plist mode"

/bin/bash -n \
    "$preinstall" \
    "$postinstall" \
    "$package_common" \
    "$packaged_uninstaller"

/usr/bin/cmp -s \
    "$preinstall" \
    "$SCRIPT_DIRECTORY/helper-package-preinstall.sh" ||
    fail "packaged preinstall does not match the reviewed source script"
/usr/bin/cmp -s \
    "$postinstall" \
    "$SCRIPT_DIRECTORY/helper-package-postinstall.sh" ||
    fail "packaged postinstall does not match the reviewed source script"
/usr/bin/cmp -s \
    "$package_common" \
    "$SCRIPT_DIRECTORY/helper-package-common.sh" ||
    fail "packaged installer runtime does not match the reviewed source script"
/usr/bin/cmp -s \
    "$packaged_uninstaller" \
    "$SCRIPT_DIRECTORY/installed-helper-uninstaller.sh" ||
    fail "packaged root uninstaller does not match the reviewed source script"
/usr/bin/cmp -s "$packaged_helper" "$APP_HELPER" ||
    fail "helper package does not carry the exact app's embedded helper"
/usr/bin/lipo \
    "$packaged_helper" \
    -verify_arch arm64 x86_64 \
    >/dev/null ||
    fail "packaged helper is not Universal 2"
/usr/bin/codesign \
    --verify \
    --strict \
    --all-architectures \
    --verbose=2 \
    "$packaged_helper" ||
    fail "packaged helper has an invalid code signature"
helper_signature="$(signature_details "$packaged_helper")"
require_equal \
    "$(signature_field "$helper_signature" "Identifier")" \
    "$HELPER_IDENTIFIER" \
    "packaged helper signing identifier"

/usr/bin/plutil -lint "$packaged_plist" >/dev/null
expected_plist="$work_directory/expected-helper.plist"
/bin/cp \
    "$REPOSITORY_ROOT/Resources/$HELPER_IDENTIFIER.legacy.plist.in" \
    "$expected_plist"
/usr/bin/cmp -s "$expected_plist" "$packaged_plist" ||
    fail \
        "packaged LaunchDaemon template differs from the reviewed exact schema"
require_equal \
    "$(plist_value "$packaged_plist" "Label")" \
    "$HELPER_IDENTIFIER" \
    "packaged LaunchDaemon label"
require_equal \
    "$(plist_value "$packaged_plist" "ProgramArguments:0")" \
    "/Library/PrivilegedHelperTools/$HELPER_IDENTIFIER" \
    "packaged LaunchDaemon program path"
require_equal \
    "$(plist_value "$packaged_plist" "MachServices:$HELPER_IDENTIFIER")" \
    "true" \
    "packaged LaunchDaemon Mach service"
require_equal \
    "$(plist_value "$packaged_plist" "KeepAlive")" \
    "true" \
    "packaged LaunchDaemon KeepAlive"
require_equal \
    "$(
        plist_value \
            "$packaged_plist" \
            "EnvironmentVariables:CAFFEINE_APP_REQUIREMENT"
    )" \
    "" \
    "unprepared app requirement"
require_absent_plist_key "$packaged_plist" "BundleProgram"
require_absent_plist_key "$packaged_plist" "Program"
require_absent_plist_key \
    "$packaged_plist" \
    "AssociatedBundleIdentifiers"
require_absent_plist_key \
    "$packaged_plist" \
    "EnvironmentVariables:CAFFEINE_TEAM_ID"
require_absent_plist_key "$packaged_plist" "RunAtLoad"
require_absent_plist_key "$packaged_plist" "UserName"

/usr/bin/grep \
    -F \
    'readonly PACKAGE_RECEIPT_ID="tech.46h.caffeine.helper-installer"' \
    "$packaged_uninstaller" \
    >/dev/null ||
    fail "root uninstaller does not own the expected package receipt"
/usr/bin/grep \
    -F \
    "readonly UNINSTALLER_PATH=\"\$HELPER_DIRECTORY/tech.46h.caffeine.uninstall-helper\"" \
    "$packaged_uninstaller" \
    >/dev/null ||
    fail "root uninstaller does not pin its installed path"

printf '%s\n' \
    "Validated unsigned, app-signature-independent helper package $PACKAGE_PATH."
