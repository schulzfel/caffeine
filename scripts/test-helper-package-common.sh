#!/bin/bash

set -euo pipefail

SCRIPT_DIRECTORY="$(
    cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P
)"
readonly SCRIPT_DIRECTORY

# shellcheck source=scripts/helper-package-common.sh
source "$SCRIPT_DIRECTORY/helper-package-common.sh"

expect_match() {
    local process_list="$1"
    if ! printf '%s\n' "$process_list" |
        caffeine_package_process_list_contains_app; then
        caffeine_package_fail \
            "expected exact Caffeine executable path to match"
    fi
}

expect_no_match() {
    local process_list="$1"
    if printf '%s\n' "$process_list" |
        caffeine_package_process_list_contains_app; then
        caffeine_package_fail \
            "an unrelated executable path matched Caffeine"
    fi
}

expect_match "  $CAFFEINE_APP_EXECUTABLE  "
expect_match $'/usr/bin/example\n'"$CAFFEINE_APP_EXECUTABLE"
expect_no_match "/tmp/Caffeine"
expect_no_match "/Applications/Other.app/Contents/MacOS/Caffeine"
expect_no_match "$CAFFEINE_APP_EXECUTABLE-copy"

metadata_test_directory="$(
    /usr/bin/mktemp \
        -d \
        "${TMPDIR:-/tmp}/caffeine-helper-package-metadata.XXXXXX"
)"
metadata_test_file="$metadata_test_directory/published-helper"
/usr/bin/touch "$metadata_test_file"

cleanup_metadata_test() {
    /bin/rm -f -- "$metadata_test_file"
    /bin/rmdir "$metadata_test_directory"
}
trap cleanup_metadata_test EXIT

# macOS 26 attaches com.apple.provenance to newly published files and does not
# remove it for `xattr -c`. It is platform metadata, not an unpreserved custom
# attribute, so both an attribute-free file and a provenance-only file must be
# accepted.
[[ -z "$(/usr/bin/xattr /bin/ls)" ]] ||
    caffeine_package_fail \
        "the attribute-free metadata fixture unexpectedly has extended attributes"
caffeine_package_require_supported_extended_attributes \
    "/bin/ls" \
    "attribute-free fixture"

/usr/bin/xattr -c "$metadata_test_file"
metadata_attributes="$(
    /usr/bin/xattr "$metadata_test_file"
)"
if [[ -z "$metadata_attributes" ]]; then
    /usr/bin/xattr \
        -w \
        "com.apple.provenance" \
        "caffeine-test" \
        "$metadata_test_file"
    metadata_attributes="$(
        /usr/bin/xattr "$metadata_test_file"
    )"
fi
[[ "$metadata_attributes" == "com.apple.provenance" ]] ||
    caffeine_package_fail \
        "the provenance-only fixture has unexpected attributes: $metadata_attributes"
caffeine_package_require_supported_extended_attributes \
    "$metadata_test_file" \
    "provenance-only fixture"

/usr/bin/xattr \
    -w \
    "tech.46h.caffeine.synthetic" \
    "installer-added" \
    "$metadata_test_file"
set +e
unsupported_attribute_output="$(
    (
        caffeine_package_require_supported_extended_attributes \
            "$metadata_test_file" \
            "synthetic published helper"
    ) 2>&1
)"
unsupported_attribute_status="$?"
set -e
[[ "$unsupported_attribute_status" != "0" ]] ||
    caffeine_package_fail \
        "published-file metadata validation accepted an unsupported attribute"
[[ "$unsupported_attribute_output" \
    == *"synthetic published helper"* &&
   "$unsupported_attribute_output" \
    == *"tech.46h.caffeine.synthetic"* ]] ||
    caffeine_package_fail \
        "unsupported-attribute failure did not identify its file and attribute"

running_guard_started="$SECONDS"
set +e
running_guard_output="$(
    (
        caffeine_package_copy_process_list() {
            printf '%s\n' "$CAFFEINE_APP_EXECUTABLE"
        }
        caffeine_package_require_app_not_running
    ) 2>&1
)"
running_guard_status="$?"
set -e
running_guard_seconds="$((SECONDS - running_guard_started))"
[[ "$running_guard_status" != "0" ]] ||
    caffeine_package_fail \
        "the app-running guard accepted a running Caffeine process"
[[ "$running_guard_output" \
    == *"Caffeine is still running; quit it before installing its helper"* ]] ||
    caffeine_package_fail \
        "the app-running guard did not produce its actionable error"
if ((running_guard_seconds >= 2)); then
    caffeine_package_fail \
        "the running-app guard took ${running_guard_seconds}s; expected under 2s"
fi

set +e
enumeration_failure_output="$(
    (
        caffeine_package_copy_process_list() {
            return 71
        }
        caffeine_package_app_is_running
    ) 2>&1
)"
enumeration_failure_status="$?"
set -e
[[ "$enumeration_failure_status" != "0" ]] ||
    caffeine_package_fail \
        "a failed process enumeration was treated as no running app"
[[ "$enumeration_failure_output" \
    == *"could not inspect running processes; refusing helper installation"* ]] ||
    caffeine_package_fail \
        "a failed process enumeration did not produce the fail-closed error"

TIMEFORMAT='%R'
elapsed_seconds="$(
    {
        time {
            if caffeine_package_app_is_running; then
                :
            else
                :
            fi
        }
    } 2>&1 >/dev/null
)"
printf '%s\n' "$elapsed_seconds" |
    /usr/bin/awk '
        $1 ~ /^[0-9]+([.][0-9]+)?$/ && $1 < 2 {
            fast = 1
        }
        END {
            exit fast ? 0 : 1
        }
    ' ||
    caffeine_package_fail \
        "the non-root app-running check took ${elapsed_seconds}s; expected under 2s"

printf \
    'helper package common tests passed (running guard %ss, process check %ss)\n' \
    "$running_guard_seconds" \
    "$elapsed_seconds"
