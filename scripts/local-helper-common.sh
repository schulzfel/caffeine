#!/bin/bash

# These constants are consumed by the installer or uninstaller after sourcing
# this file, which ShellCheck cannot infer while checking this file alone.
# shellcheck disable=SC2034

# Shared, fixed paths for the root-installed local-development helper. These
# scripts intentionally accept no path overrides: a root command must never let
# an environment variable redirect writes or launchctl operations.
readonly LOCAL_HELPER_LABEL="tech.46h.caffeine.helper"
readonly LOCAL_APP_PATH="/Applications/Caffeine.app"
readonly LOCAL_APP_EXECUTABLE="$LOCAL_APP_PATH/Contents/MacOS/Caffeine"
readonly LOCAL_BUNDLED_HELPER="$LOCAL_APP_PATH/Contents/MacOS/CaffeineHelper"
readonly LOCAL_APP_INFO_PLIST="$LOCAL_APP_PATH/Contents/Info.plist"
readonly LOCAL_HELPER_DIRECTORY="/Library/PrivilegedHelperTools"
readonly LOCAL_HELPER_PATH="$LOCAL_HELPER_DIRECTORY/$LOCAL_HELPER_LABEL"
readonly LOCAL_DAEMON_DIRECTORY="/Library/LaunchDaemons"
readonly LOCAL_DAEMON_PLIST="$LOCAL_DAEMON_DIRECTORY/$LOCAL_HELPER_LABEL.plist"
readonly LOCAL_PLIST_BUDDY="/usr/libexec/PlistBuddy"

local_helper_fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

local_helper_require_root() {
    [[ "$(/usr/bin/id -u)" == "0" ]] ||
        local_helper_fail "this command must be run as root"
}

local_helper_require_no_arguments() {
    local argument_count="$1"
    local usage="$2"
    [[ "$argument_count" == "0" ]] ||
        local_helper_fail "usage: $usage"
}

local_helper_path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

local_helper_require_real_directory() {
    local directory="$1"
    [[ ! -L "$directory" ]] ||
        local_helper_fail "refusing symbolic-link directory: $directory"
    [[ -d "$directory" ]] ||
        local_helper_fail "required directory is missing: $directory"
}

local_helper_require_secure_system_directory() {
    local directory="$1"
    local expected_mode="$2"
    local details

    local_helper_require_real_directory "$directory"
    details="$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$directory")"
    [[ "$details" == "root:wheel:$expected_mode" ]] ||
        local_helper_fail \
            "$directory ownership/mode is $details; expected root:wheel:$expected_mode"
}

local_helper_require_regular_target_or_absent() {
    local target="$1"
    if ! local_helper_path_exists "$target"; then
        return
    fi
    [[ ! -L "$target" ]] ||
        local_helper_fail "refusing symbolic-link target: $target"
    [[ -f "$target" ]] ||
        local_helper_fail "refusing non-regular target: $target"
}

local_helper_process_list_contains_app() {
    /usr/bin/awk -v expected="$LOCAL_APP_EXECUTABLE" '
        {
            executable = $0
            sub(/^[[:space:]]*/, "", executable)
            sub(/[[:space:]]*$/, "", executable)
            if (executable == expected) {
                found = 1
                exit
            }
        }
        END {
            exit found ? 0 : 1
        }
    '
}

local_helper_app_is_running() {
    /bin/ps -axww -o comm= | local_helper_process_list_contains_app
}

local_helper_require_app_not_running() {
    local attempt

    # A contributor may begin the local install immediately after quitting
    # Caffeine. Give normal application shutdown a bounded window, but never
    # proceed while a process executing the exact installed app remains.
    for ((attempt = 0; attempt < 100; attempt += 1)); do
        if ! local_helper_app_is_running; then
            return
        fi
        /bin/sleep 0.1
    done

    local_helper_fail \
        "quit Caffeine before installing or removing its local helper"
}

local_helper_require_installed_file() {
    local path="$1"
    local expected_mode="$2"
    local label="$3"
    local details

    [[ -f "$path" && ! -L "$path" ]] ||
        local_helper_fail "$label is missing or is not a regular file: $path"
    details="$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$path")"
    [[ "$details" == "root:wheel:$expected_mode" ]] ||
        local_helper_fail \
            "$label ownership/mode is $details; expected root:wheel:$expected_mode"
}

local_helper_require_safe_installed_plist() {
    local requirement

    local_helper_require_installed_file \
        "$LOCAL_DAEMON_PLIST" \
        644 \
        "local helper plist"
    /usr/bin/plutil -lint "$LOCAL_DAEMON_PLIST" >/dev/null
    [[ "$(
        "$LOCAL_PLIST_BUDDY" -c "Print :Label" "$LOCAL_DAEMON_PLIST"
    )" == "$LOCAL_HELPER_LABEL" ]] ||
        local_helper_fail "local helper plist has an unexpected label"
    [[ "$(
        "$LOCAL_PLIST_BUDDY" \
            -c "Print :ProgramArguments:0" \
            "$LOCAL_DAEMON_PLIST"
    )" == "$LOCAL_HELPER_PATH" ]] ||
        local_helper_fail "local helper plist has an unexpected program path"
    [[ "$(
        "$LOCAL_PLIST_BUDDY" \
            -c "Print :MachServices:$LOCAL_HELPER_LABEL" \
            "$LOCAL_DAEMON_PLIST"
    )" == "true" ]] ||
        local_helper_fail "local helper plist has an invalid Mach service"
    requirement="$(
        "$LOCAL_PLIST_BUDDY" \
            -c "Print :EnvironmentVariables:CAFFEINE_APP_REQUIREMENT" \
            "$LOCAL_DAEMON_PLIST"
    )"
    [[ -n "$requirement" && "$requirement" != *$'\n'* ]] ||
        local_helper_fail "local helper plist has no app requirement"
}

local_helper_service_is_loaded() {
    /bin/launchctl print "system/$LOCAL_HELPER_LABEL" >/dev/null 2>&1
}

local_helper_launchctl_field() {
    local details="$1"
    local field="$2"
    printf '%s\n' "$details" |
        /usr/bin/awk -v field="$field" '
            {
                line = $0
                sub(/^[[:space:]]*/, "", line)
                prefix = field " = "
                if (index(line, prefix) == 1) {
                    print substr(line, length(prefix) + 1)
                    exit
                }
            }
        '
}

local_helper_require_loaded_service_paths() {
    local details
    local loaded_path
    local loaded_program

    details="$(/bin/launchctl print "system/$LOCAL_HELPER_LABEL")" ||
        local_helper_fail "could not inspect the loaded helper"
    loaded_path="$(local_helper_launchctl_field "$details" "path")"
    loaded_program="$(local_helper_launchctl_field "$details" "program")"

    [[ "$loaded_path" == "$LOCAL_DAEMON_PLIST" ]] ||
        local_helper_fail \
            "loaded $LOCAL_HELPER_LABEL plist is '$loaded_path'; refusing to modify it"
    [[ "$loaded_program" == "$LOCAL_HELPER_PATH" ]] ||
        local_helper_fail \
            "loaded $LOCAL_HELPER_LABEL program is '$loaded_program'; refusing to modify it"
}

local_helper_wait_until_unloaded() {
    local attempt
    for ((attempt = 0; attempt < 50; attempt += 1)); do
        if ! local_helper_service_is_loaded; then
            return 0
        fi
        /bin/sleep 0.1
    done
    return 1
}

local_helper_wait_until_running() {
    local attempt
    local details
    local state

    for ((attempt = 0; attempt < 50; attempt += 1)); do
        if details="$(
            /bin/launchctl print "system/$LOCAL_HELPER_LABEL" 2>/dev/null
        )"; then
            state="$(local_helper_launchctl_field "$details" "state")"
            if [[ "$state" == "running" ]]; then
                return 0
            fi
        fi
        /bin/sleep 0.1
    done
    return 1
}

local_helper_remove_exact_regular_file() {
    local target="$1"
    if ! local_helper_path_exists "$target"; then
        return 0
    fi
    [[ ! -L "$target" && -f "$target" ]] || return 1
    /bin/rm -f -- "$target"
}
