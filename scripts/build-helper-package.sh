#!/bin/bash

set -euo pipefail
umask 022

SCRIPT_DIRECTORY="$(
    cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P
)"
readonly SCRIPT_DIRECTORY
REPOSITORY_ROOT="$(
    cd "$SCRIPT_DIRECTORY/.." && pwd -P
)"
readonly REPOSITORY_ROOT
readonly APP_NAME="Caffeine.app"
readonly HELPER_NAME="CaffeineHelper"
readonly HELPER_IDENTIFIER="tech.46h.caffeine.helper"
readonly PACKAGE_NAME="Install Caffeine Helper.pkg"
readonly PACKAGE_IDENTIFIER="tech.46h.caffeine.helper-installer"
readonly PLIST_NAME="$HELPER_IDENTIFIER.plist"
readonly PLIST_TEMPLATE_NAME="$HELPER_IDENTIFIER.legacy.plist.in"

BUILD_VERSION="${BUILD_VERSION:-4}"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

if [[ "$#" -ne 2 ]]; then
    fail \
        "usage: build-helper-package <path-to-Caffeine.app> <path-to-Install Caffeine Helper.pkg>"
fi

[[ "$BUILD_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] ||
    fail "BUILD_VERSION must contain one to three dot-separated integers"

app_argument="$1"
output_argument="$2"
[[ -d "$app_argument" ]] || fail "app bundle not found: $app_argument"
[[ "$(/usr/bin/basename "$app_argument")" == "$APP_NAME" ]] ||
    fail "input app must be named $APP_NAME"
[[ "$(/usr/bin/basename "$output_argument")" == "$PACKAGE_NAME" ]] ||
    fail "output package must be named $PACKAGE_NAME"

app_parent="$(
    cd "$(/usr/bin/dirname "$app_argument")" && pwd -P
)"
APP_PATH="$app_parent/$APP_NAME"
readonly APP_PATH
output_parent="$(
    cd "$(/usr/bin/dirname "$output_argument")" && pwd -P
)"
OUTPUT_PATH="$output_parent/$PACKAGE_NAME"
readonly OUTPUT_PATH
readonly APP_HELPER="$APP_PATH/Contents/MacOS/$HELPER_NAME"

[[ ! -e "$OUTPUT_PATH" && ! -L "$OUTPUT_PATH" ]] ||
    fail "refusing to overwrite existing helper package: $OUTPUT_PATH"

for required_file in \
    "$SCRIPT_DIRECTORY/helper-package-preinstall.sh" \
    "$SCRIPT_DIRECTORY/helper-package-postinstall.sh" \
    "$SCRIPT_DIRECTORY/helper-package-common.sh" \
    "$SCRIPT_DIRECTORY/installed-helper-uninstaller.sh" \
    "$SCRIPT_DIRECTORY/validate-helper-package.sh" \
    "$REPOSITORY_ROOT/Resources/$PLIST_TEMPLATE_NAME"; do
    [[ -f "$required_file" && ! -L "$required_file" ]] ||
        fail "required package input is missing or symbolic: $required_file"
done

for required_tool in \
    /bin/chmod \
    /bin/mkdir \
    /bin/mv \
    /bin/rm \
    /usr/bin/awk \
    /usr/bin/basename \
    /usr/bin/codesign \
    /usr/bin/dirname \
    /usr/bin/install \
    /usr/bin/lipo \
    /usr/bin/mktemp \
    /usr/bin/pkgbuild \
    /usr/bin/plutil; do
    [[ -x "$required_tool" ]] ||
        fail "required Apple tool is unavailable: $required_tool"
done

[[ -x "$APP_HELPER" && ! -L "$APP_HELPER" ]] ||
    fail "embedded helper is missing or symbolic: $APP_HELPER"
/usr/bin/lipo "$APP_HELPER" -verify_arch arm64 x86_64 >/dev/null ||
    fail "embedded CaffeineHelper is not Universal 2"
/usr/bin/codesign \
    --verify \
    --strict \
    --all-architectures \
    --verbose=2 \
    "$APP_HELPER"

work_directory="$(
    /usr/bin/mktemp -d "$output_parent/.caffeine-helper-package.XXXXXX"
)"
scripts_directory="$work_directory/scripts"
staged_package="$work_directory/$PACKAGE_NAME"

cleanup() {
    case "$work_directory" in
        "$output_parent"/.caffeine-helper-package.*)
            /bin/rm -rf -- "$work_directory"
            ;;
        *)
            printf 'warning: refusing to clean unexpected path: %s\n' \
                "$work_directory" >&2
            ;;
    esac
}
trap cleanup EXIT

/usr/bin/install -d -m 0755 "$scripts_directory"
/usr/bin/install -m 0755 \
    "$SCRIPT_DIRECTORY/helper-package-preinstall.sh" \
    "$scripts_directory/preinstall"
/usr/bin/install -m 0755 \
    "$SCRIPT_DIRECTORY/helper-package-postinstall.sh" \
    "$scripts_directory/postinstall"
/usr/bin/install -m 0644 \
    "$SCRIPT_DIRECTORY/helper-package-common.sh" \
    "$scripts_directory/helper-package-common.sh"
/usr/bin/install -m 0755 \
    "$SCRIPT_DIRECTORY/installed-helper-uninstaller.sh" \
    "$scripts_directory/uninstall-helper"
/usr/bin/install -m 0755 \
    "$APP_HELPER" \
    "$scripts_directory/$HELPER_NAME"
/usr/bin/install -m 0644 \
    "$REPOSITORY_ROOT/Resources/$PLIST_TEMPLATE_NAME" \
    "$scripts_directory/$PLIST_NAME"

/usr/bin/plutil -lint "$scripts_directory/$PLIST_NAME" >/dev/null

/usr/bin/pkgbuild \
    --nopayload \
    --scripts "$scripts_directory" \
    --identifier "$PACKAGE_IDENTIFIER" \
    --version "$BUILD_VERSION" \
    --install-location / \
    "$staged_package"
/bin/chmod 0644 "$staged_package"

/bin/bash "$SCRIPT_DIRECTORY/validate-helper-package.sh" \
    "$APP_PATH" \
    "$staged_package"

[[ ! -e "$OUTPUT_PATH" && ! -L "$OUTPUT_PATH" ]] ||
    fail "helper package appeared while building; refusing to overwrite it"
/bin/mv "$staged_package" "$OUTPUT_PATH"

printf 'Built unsigned helper package %s\n' "$OUTPUT_PATH"
