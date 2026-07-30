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
    /bin/rm -rf -- "$metadata_test_directory/relaunch"
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

relaunch_test_directory="$metadata_test_directory/relaunch"
/bin/mkdir "$relaunch_test_directory"

run_relaunch_fixture() {
    local fixture_console_uid="$1"
    local fixture_gui_available="$2"
    local fixture_open_status="$3"
    local fixture_committed="${4:-1}"
    local fixture_directory
    local fixture_status

    fixture_directory="$relaunch_test_directory/$(
        /usr/bin/basename "$fixture_console_uid"
    )-$fixture_gui_available-$fixture_open_status-$fixture_committed-$RANDOM"
    /bin/mkdir "$fixture_directory"
    set +e
    (
        CAFFEINE_INSTALLATION_COMMITTED="$fixture_committed"
        caffeine_package_copy_console_uid() {
            if [[ "$fixture_console_uid" == "STAT_FAILURE" ]]; then
                return 71
            fi
            printf '%s\n' "$fixture_console_uid"
        }
        caffeine_package_gui_domain_is_available() {
            printf '%s\n' "$1" >>"$fixture_directory/gui-uids"
            [[ "$fixture_gui_available" == "yes" ]]
        }
        caffeine_package_open_app_as_user() {
            printf '%s\n' "$1" >>"$fixture_directory/open-uids"
            return "$fixture_open_status"
        }
        caffeine_package_relaunch_app_after_install
    ) >"$fixture_directory/stdout" 2>"$fixture_directory/stderr"
    fixture_status="$?"
    set -e
    [[ "$fixture_status" == "0" ]] ||
        caffeine_package_fail \
            "best-effort relaunch fixture returned $fixture_status"
    printf '%s\n' "$fixture_directory"
}

valid_relaunch_fixture="$(run_relaunch_fixture 501 yes 0)"
[[ "$(/bin/cat "$valid_relaunch_fixture/gui-uids")" == "501" &&
   "$(/bin/cat "$valid_relaunch_fixture/open-uids")" == "501" ]] ||
    caffeine_package_fail \
        "valid console user was not relaunched through its GUI domain"
[[ ! -s "$valid_relaunch_fixture/stderr" ]] ||
    caffeine_package_fail \
        "successful relaunch unexpectedly emitted a warning"

for rejected_uid in invalid 0 499 STAT_FAILURE; do
    rejected_relaunch_fixture="$(
        run_relaunch_fixture "$rejected_uid" yes 0
    )"
    [[ ! -e "$rejected_relaunch_fixture/gui-uids" &&
       ! -e "$rejected_relaunch_fixture/open-uids" ]] ||
        caffeine_package_fail \
            "invalid, root, or system console user reached the relaunch command"
    [[ "$(/bin/cat "$rejected_relaunch_fixture/stderr")" \
        == *"no normal console user is available"* ]] ||
        caffeine_package_fail \
            "rejected console UID did not produce a warning"
done

no_gui_relaunch_fixture="$(run_relaunch_fixture 502 no 0)"
[[ "$(/bin/cat "$no_gui_relaunch_fixture/gui-uids")" == "502" &&
   ! -e "$no_gui_relaunch_fixture/open-uids" ]] ||
    caffeine_package_fail \
        "console user without a GUI domain reached the relaunch command"
[[ "$(/bin/cat "$no_gui_relaunch_fixture/stderr")" \
    == *"has no graphical login session"* ]] ||
    caffeine_package_fail \
        "missing GUI domain did not produce a warning"

failed_open_relaunch_fixture="$(run_relaunch_fixture 503 yes 69)"
[[ "$(/bin/cat "$failed_open_relaunch_fixture/open-uids")" == "503" ]] ||
    caffeine_package_fail \
        "opener-failure fixture did not attempt the relaunch"
[[ "$(/bin/cat "$failed_open_relaunch_fixture/stderr")" \
    == *"could not be reopened automatically"* ]] ||
    caffeine_package_fail \
        "opener failure did not produce a warning"

uncommitted_relaunch_fixture="$(run_relaunch_fixture 504 yes 0 0)"
[[ ! -e "$uncommitted_relaunch_fixture/gui-uids" &&
   ! -e "$uncommitted_relaunch_fixture/open-uids" &&
   ! -s "$uncommitted_relaunch_fixture/stderr" ]] ||
    caffeine_package_fail \
        "an uncommitted installation attempted to relaunch Caffeine"

completion_output="$(
    (
        CAFFEINE_INSTALLATION_COMMITTED=0
        caffeine_package_relaunch_app_after_install() {
            printf 'committed=%s\n' "$CAFFEINE_INSTALLATION_COMMITTED"
            return 71
        }
        caffeine_package_complete_installation
    )
)"
[[ "$completion_output" == "committed=1" ]] ||
    caffeine_package_fail \
        "installation completion did not commit before best-effort relaunch"

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
    'helper package common tests passed (relaunch, running guard %ss, process check %ss)\n' \
    "$running_guard_seconds" \
    "$elapsed_seconds"
