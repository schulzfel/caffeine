#!/bin/bash

set -euo pipefail
umask 077

SCRIPT_DIRECTORY="$(
    cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P
)"
readonly SCRIPT_DIRECTORY

# shellcheck source=scripts/local-helper-common.sh
source "$SCRIPT_DIRECTORY/local-helper-common.sh"

local_helper_require_root
local_helper_require_no_arguments \
    "$#" \
    "sudo ${BASH_SOURCE[0]}"
local_helper_require_app_not_running

local_helper_require_secure_system_directory "/Library" 755
local_helper_require_secure_system_directory "$LOCAL_DAEMON_DIRECTORY" 755
if local_helper_path_exists "$LOCAL_HELPER_DIRECTORY"; then
    local_helper_require_secure_system_directory "$LOCAL_HELPER_DIRECTORY" 755
fi
local_helper_require_regular_target_or_absent "$LOCAL_HELPER_PATH"
local_helper_require_regular_target_or_absent "$LOCAL_DAEMON_PLIST"

helper_is_installed=0
plist_is_installed=0
if local_helper_path_exists "$LOCAL_HELPER_PATH"; then
    helper_is_installed=1
fi
if local_helper_path_exists "$LOCAL_DAEMON_PLIST"; then
    plist_is_installed=1
fi
[[ "$helper_is_installed" == "$plist_is_installed" ]] ||
    local_helper_fail \
        "local helper installation is incomplete; restore both files before uninstalling"

if [[ "$helper_is_installed" == "1" ]]; then
    local_helper_require_installed_file \
        "$LOCAL_HELPER_PATH" \
        755 \
        "local helper executable"
    /usr/bin/codesign \
        --verify \
        --strict \
        --all-architectures \
        --verbose=2 \
        "$LOCAL_HELPER_PATH" ||
        local_helper_fail \
            "refusing to launch an invalid installed helper during cleanup"
    local_helper_require_safe_installed_plist
fi

if local_helper_service_is_loaded; then
    local_helper_require_loaded_service_paths
elif [[ "$helper_is_installed" == "1" ]]; then
    # Startup repairs a stale Caffeine ownership marker; bootout then invokes
    # the helper's synchronous SIGTERM cleanup before the recovery binary is
    # removed.
    /bin/launchctl bootstrap system "$LOCAL_DAEMON_PLIST" ||
        local_helper_fail \
            "could not bootstrap the local helper for pre-uninstall recovery"
    if ! local_helper_wait_until_running; then
        /bin/launchctl bootout \
            "system/$LOCAL_HELPER_LABEL" >/dev/null 2>&1 || true
        local_helper_wait_until_unloaded || true
        local_helper_fail \
            "the local helper did not start for pre-uninstall recovery"
    fi
    local_helper_require_loaded_service_paths
fi

if local_helper_service_is_loaded; then
    /bin/launchctl bootout "system/$LOCAL_HELPER_LABEL" ||
        local_helper_fail "could not boot out the local helper"
    local_helper_wait_until_unloaded ||
        local_helper_fail "the local helper did not stop"
fi

local_helper_remove_exact_regular_file "$LOCAL_DAEMON_PLIST" ||
    local_helper_fail "refusing to remove unexpected plist target"
local_helper_remove_exact_regular_file "$LOCAL_HELPER_PATH" ||
    local_helper_fail "refusing to remove unexpected helper target"

local_helper_service_is_loaded &&
    local_helper_fail "the local helper is still loaded"
! local_helper_path_exists "$LOCAL_DAEMON_PLIST" ||
    local_helper_fail "the local helper plist still exists"
! local_helper_path_exists "$LOCAL_HELPER_PATH" ||
    local_helper_fail "the local helper executable still exists"

printf '%s\n' \
    "Removed the local Caffeine helper:" \
    "  $LOCAL_HELPER_PATH" \
    "  $LOCAL_DAEMON_PLIST"
