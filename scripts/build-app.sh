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
readonly APP_NAME="Caffeine"
readonly HELPER_NAME="CaffeineHelper"
readonly HELPER_IDENTIFIER="tech.46h.caffeine.helper"
readonly DIST_DIRECTORY="$REPOSITORY_ROOT/dist"
readonly FINAL_APP="$DIST_DIRECTORY/$APP_NAME.app"
readonly PACKAGE_TEMP_ROOT="$REPOSITORY_ROOT/.build/app-packaging"

APP_VERSION="${APP_VERSION:-1.0.0}"
BUILD_VERSION="${BUILD_VERSION:-4}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
TEAM_ID="${TEAM_ID:-}"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

safe_remove_tree() {
    local target="$1"
    case "$target" in
        "$PACKAGE_TEMP_ROOT"/*|"$DIST_DIRECTORY"/.*."$$")
            /bin/rm -rf -- "$target"
            ;;
        *)
            fail "refusing to remove an unexpected path: $target"
            ;;
    esac
}

[[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] ||
    fail "APP_VERSION must contain one to three dot-separated integers"
[[ "$BUILD_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] ||
    fail "BUILD_VERSION must contain one to three dot-separated integers"
[[ "$SIGN_IDENTITY" != *$'\n'* ]] ||
    fail "SIGN_IDENTITY must be a single line"

[[ "$SIGN_IDENTITY" == "-" ]] ||
    fail "community builds do not accept a Developer ID signing identity"
[[ -z "$TEAM_ID" ]] ||
    fail "community builds do not accept a Developer Team ID"

for required_file in \
    "$REPOSITORY_ROOT/LICENSE" \
    "$REPOSITORY_ROOT/Package.swift" \
    "$REPOSITORY_ROOT/Resources/Info.plist.in" \
    "$REPOSITORY_ROOT/THIRD_PARTY_NOTICES.md" \
    "$SCRIPT_DIRECTORY/build-helper-package.sh" \
    "$SCRIPT_DIRECTORY/generate-icon.swift" \
    "$SCRIPT_DIRECTORY/validate-app.sh"; do
    [[ -f "$required_file" ]] || fail "required file is missing: $required_file"
done

# shellcheck source=scripts/swift-sdk.sh
source "$SCRIPT_DIRECTORY/swift-sdk.sh"
caffeine_select_swift_sdk "$REPOSITORY_ROOT"

/bin/mkdir -p "$DIST_DIRECTORY" "$PACKAGE_TEMP_ROOT"
package_directory="$(/usr/bin/mktemp -d "$PACKAGE_TEMP_ROOT/package.XXXXXX")"
stage_app="$package_directory/$APP_NAME.app"
new_app="$DIST_DIRECTORY/.$APP_NAME.app.new.$$"
backup_app="$DIST_DIRECTORY/.$APP_NAME.app.previous.$$"

cleanup() {
    if [[ -d "$package_directory" ]]; then
        safe_remove_tree "$package_directory"
    fi
    if [[ -e "$new_app" ]]; then
        safe_remove_tree "$new_app"
    fi
}
trap cleanup EXIT

cd "$REPOSITORY_ROOT"

universal_architectures=(arm64 x86_64)
main_binary_slices=()
helper_binary_slices=()

for architecture in "${universal_architectures[@]}"; do
    architecture_scratch="$CAFFEINE_SCRATCH_PATH-$architecture"
    architecture_module_cache="$CAFFEINE_MODULE_CACHE-$architecture"
    architecture_clang_cache="$CAFFEINE_CLANG_MODULE_CACHE-$architecture"
    /bin/mkdir -p \
        "$architecture_scratch" \
        "$architecture_module_cache" \
        "$architecture_clang_cache"

    swift_build_arguments=(
        --configuration release
        --sdk "$SDKROOT"
        --arch "$architecture"
        --scratch-path "$architecture_scratch"
        --disable-sandbox
        --cache-path "$CAFFEINE_SWIFTPM_CACHE"
        --config-path "$CAFFEINE_SWIFTPM_CONFIG"
        --security-path "$CAFFEINE_SWIFTPM_SECURITY"
        --manifest-cache local
        -Xswiftc -module-cache-path
        -Xswiftc "$architecture_module_cache"
        -Xcc "-fmodules-cache-path=$architecture_clang_cache"
    )

    printf 'Building native %s release slices…\n' "$architecture"
    "$CAFFEINE_SWIFT" build "${swift_build_arguments[@]}"

    binary_directory="$(
        "$CAFFEINE_SWIFT" build \
            "${swift_build_arguments[@]}" \
            --show-bin-path
    )"
    main_slice="$binary_directory/$APP_NAME"
    helper_slice="$binary_directory/$HELPER_NAME"
    [[ -x "$main_slice" ]] ||
        fail "SwiftPM did not produce $architecture $APP_NAME"
    [[ -x "$helper_slice" ]] ||
        fail "SwiftPM did not produce $architecture $HELPER_NAME"
    [[ "$(/usr/bin/lipo -archs "$main_slice")" == "$architecture" ]] ||
        fail "$APP_NAME output is not a thin $architecture binary"
    [[ "$(/usr/bin/lipo -archs "$helper_slice")" == "$architecture" ]] ||
        fail "$HELPER_NAME output is not a thin $architecture binary"

    main_binary_slices+=("$main_slice")
    helper_binary_slices+=("$helper_slice")
done

/usr/bin/install -d -m 0755 \
    "$stage_app/Contents/MacOS" \
    "$stage_app/Contents/Resources"
/usr/bin/lipo \
    -create \
    "${main_binary_slices[@]}" \
    -output "$stage_app/Contents/MacOS/$APP_NAME"
/usr/bin/lipo \
    -create \
    "${helper_binary_slices[@]}" \
    -output "$stage_app/Contents/MacOS/$HELPER_NAME"
/bin/chmod 0755 \
    "$stage_app/Contents/MacOS/$APP_NAME" \
    "$stage_app/Contents/MacOS/$HELPER_NAME"
/usr/bin/lipo \
    "$stage_app/Contents/MacOS/$APP_NAME" \
    -verify_arch arm64 x86_64 \
    >/dev/null ||
    fail "$APP_NAME could not be assembled as Universal 2"
/usr/bin/lipo \
    "$stage_app/Contents/MacOS/$HELPER_NAME" \
    -verify_arch arm64 x86_64 \
    >/dev/null ||
    fail "$HELPER_NAME could not be assembled as Universal 2"
/usr/bin/install -m 0644 \
    "$REPOSITORY_ROOT/Resources/Info.plist.in" \
    "$stage_app/Contents/Info.plist"
/usr/bin/install -m 0644 \
    "$REPOSITORY_ROOT/LICENSE" \
    "$stage_app/Contents/Resources/LICENSE"
/usr/bin/install -m 0644 \
    "$REPOSITORY_ROOT/THIRD_PARTY_NOTICES.md" \
    "$stage_app/Contents/Resources/THIRD_PARTY_NOTICES.md"

/usr/bin/plutil \
    -replace CFBundleShortVersionString \
    -string "$APP_VERSION" \
    "$stage_app/Contents/Info.plist"
/usr/bin/plutil \
    -replace CFBundleVersion \
    -string "$BUILD_VERSION" \
    "$stage_app/Contents/Info.plist"
/usr/bin/plutil \
    -replace CaffeineTeamIdentifier \
    -string "$TEAM_ID" \
    "$stage_app/Contents/Info.plist"
/usr/bin/plutil -lint "$stage_app/Contents/Info.plist" >/dev/null

icon_tool="$package_directory/generate-icon"
master_icon="$package_directory/Caffeine-1024.png"
app_icon="$stage_app/Contents/Resources/Caffeine.icns"
active_status_icon="$stage_app/Contents/Resources/CaffeineStatusActiveTemplate.png"
inactive_status_icon="$stage_app/Contents/Resources/CaffeineStatusInactiveTemplate.png"
embedded_helper_package="$stage_app/Contents/Resources/Install Caffeine Helper.pkg"

caffeine_compile_host_swift_tool \
    "$SCRIPT_DIRECTORY/generate-icon.swift" \
    "$icon_tool" \
    icon
"$icon_tool" \
    "$master_icon" \
    "$app_icon" \
    "$active_status_icon" \
    "$inactive_status_icon"
/bin/chmod 0644 \
    "$app_icon" \
    "$active_status_icon" \
    "$inactive_status_icon"

signing_arguments=(--force --sign - --options runtime)

# Nested code must be signed before its containing app. --deep signing is
# intentionally avoided because it is deprecated and obscures this ordering.
/usr/bin/codesign \
    "${signing_arguments[@]}" \
    --identifier "$HELPER_IDENTIFIER" \
    "$stage_app/Contents/MacOS/$HELPER_NAME"

# The package derives the exact outer app requirement only after macOS
# Installer has staged it. That removes the signature cycle and lets the outer
# app signature cryptographically seal the exact installer bytes.
BUILD_VERSION="$BUILD_VERSION" \
    "$SCRIPT_DIRECTORY/build-helper-package.sh" \
    "$stage_app" \
    "$embedded_helper_package"
/bin/chmod 0644 "$embedded_helper_package"

/usr/bin/codesign \
    "${signing_arguments[@]}" \
    "$stage_app"

EXPECTED_TEAM_ID="$TEAM_ID" \
REQUIRE_DISTRIBUTION_SIGNATURE=0 \
    "$SCRIPT_DIRECTORY/validate-app.sh" "$stage_app"

# Publish the already-validated bundle with a same-volume rename. Preserve an
# existing artifact until the new bundle is in place.
/bin/mv "$stage_app" "$new_app"
if [[ -e "$FINAL_APP" ]]; then
    /bin/mv "$FINAL_APP" "$backup_app"
fi
if /bin/mv "$new_app" "$FINAL_APP"; then
    if [[ -e "$backup_app" ]]; then
        safe_remove_tree "$backup_app"
    fi
else
    if [[ -e "$backup_app" && ! -e "$FINAL_APP" ]]; then
        /bin/mv "$backup_app" "$FINAL_APP"
    fi
    fail "could not publish $FINAL_APP"
fi

printf '\nBuilt %s\n' "$FINAL_APP"
printf '%s\n' \
    "Community release build: no Developer ID and no notarization."
