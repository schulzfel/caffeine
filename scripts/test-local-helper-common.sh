#!/bin/bash

set -euo pipefail

SCRIPT_DIRECTORY="$(
    cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P
)"
readonly SCRIPT_DIRECTORY

# shellcheck source=scripts/local-helper-common.sh
source "$SCRIPT_DIRECTORY/local-helper-common.sh"

expect_match() {
    local process_list="$1"
    if ! printf '%s\n' "$process_list" |
        local_helper_process_list_contains_app; then
        local_helper_fail \
            "expected exact Caffeine executable path to match"
    fi
}

expect_no_match() {
    local process_list="$1"
    if printf '%s\n' "$process_list" |
        local_helper_process_list_contains_app; then
        local_helper_fail \
            "an unrelated executable path matched Caffeine"
    fi
}

expect_match "  $LOCAL_APP_EXECUTABLE  "
expect_match $'/usr/bin/example\n'"$LOCAL_APP_EXECUTABLE"
expect_no_match "/tmp/Caffeine"
expect_no_match "/Applications/Other.app/Contents/MacOS/Caffeine"
expect_no_match "$LOCAL_APP_EXECUTABLE-copy"

printf '%s\n' "local helper common tests passed"
