#!/bin/bash

# This file is installed by Install Caffeine Helper.pkg at the fixed path below
# with root:wheel ownership. It accepts no path overrides and removes itself
# only after the helper and LaunchDaemon have been stopped and deleted.

set -euo pipefail
umask 077

readonly HELPER_LABEL="tech.46h.caffeine.helper"
readonly HELPER_DIRECTORY="/Library/PrivilegedHelperTools"
readonly HELPER_PATH="$HELPER_DIRECTORY/$HELPER_LABEL"
readonly UNINSTALLER_PATH="$HELPER_DIRECTORY/tech.46h.caffeine.uninstall-helper"
readonly DAEMON_DIRECTORY="/Library/LaunchDaemons"
readonly DAEMON_PLIST="$DAEMON_DIRECTORY/$HELPER_LABEL.plist"
readonly PACKAGE_RECEIPT_ID="tech.46h.caffeine.helper-installer"
readonly PLIST_BUDDY="/usr/libexec/PlistBuddy"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

require_real_directory() {
    local directory="$1"

    [[ ! -L "$directory" ]] ||
        fail "refusing symbolic-link directory: $directory"
    [[ -d "$directory" ]] ||
        fail "required directory is missing: $directory"
}

require_secure_system_directory() {
    local directory="$1"
    local expected_mode="$2"
    local details

    require_real_directory "$directory"
    details="$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$directory")"
    [[ "$details" == "root:wheel:$expected_mode" ]] ||
        fail \
            "$directory ownership/mode is $details; expected root:wheel:$expected_mode"
    /bin/ls -lde "$directory" |
        /usr/bin/awk '
            NR == 1 {
                has_acl = index($1, "+") != 0
            }
            NR > 1 && $0 ~ /^[[:space:]]*[0-9]+:/ {
                has_acl = 1
            }
            END {
                exit has_acl ? 0 : 1
            }
        ' &&
        fail \
            "$directory has an access-control list; refusing privileged writes"
    return 0
}

require_supported_extended_attributes() {
    local path="$1"
    local label="$2"
    local attributes

    attributes="$(/usr/bin/xattr "$path")" ||
        fail "could not inspect extended attributes on $label"
    # macOS 26 retains this OS-managed marker even when xattr -c succeeds.
    case "$attributes" in
        "" | "com.apple.provenance")
            ;;
        *)
            fail "$label has unsupported extended attributes: $attributes"
            ;;
    esac
}

require_installed_file() {
    local path="$1"
    local expected_mode="$2"
    local label="$3"
    local details
    local flags

    [[ -f "$path" && ! -L "$path" ]] ||
        fail "$label is missing or is not a regular file: $path"
    details="$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$path")"
    [[ "$details" == "root:wheel:$expected_mode" ]] ||
        fail \
            "$label ownership/mode is $details; expected root:wheel:$expected_mode"
    /bin/ls -le "$path" |
        /usr/bin/awk '
            NR == 1 {
                has_acl = index($1, "+") != 0
            }
            NR > 1 && $0 ~ /^[[:space:]]*[0-9]+:/ {
                has_acl = 1
            }
            END {
                exit has_acl ? 0 : 1
            }
        ' &&
        fail "$label has an access-control list"
    flags="$(/usr/bin/stat -f '%Sf' "$path")"
    [[ "$flags" == "-" ]] ||
        fail "$label has unexpected file flags: $flags"
    require_supported_extended_attributes "$path" "$label"
}

require_regular_target_or_absent() {
    local target="$1"

    if ! path_exists "$target"; then
        return
    fi
    [[ ! -L "$target" ]] ||
        fail "refusing symbolic-link target: $target"
    [[ -f "$target" ]] ||
        fail "refusing non-regular target: $target"
}

signature_field() {
    local details="$1"
    local field="$2"

    printf '%s\n' "$details" |
        /usr/bin/awk -F= -v field="$field" '
            $1 == field {
                print substr($0, length(field) + 2)
                exit
            }
        '
}

require_safe_helper() {
    local architectures
    local architecture_count
    local architecture
    local details
    local identifier
    local signature
    local team_identifier

    require_installed_file "$HELPER_PATH" 755 "Caffeine helper"
    architectures="$(/usr/bin/lipo -archs "$HELPER_PATH")"
    architecture_count="$(
        printf '%s\n' "$architectures" |
            /usr/bin/awk '{ print NF }'
    )"
    [[ "$architecture_count" == "2" ]] ||
        fail \
            "Caffeine helper must have two architectures; found: $architectures"
    /usr/bin/lipo \
        "$HELPER_PATH" \
        -verify_arch arm64 x86_64 \
        >/dev/null ||
        fail "Caffeine helper is not Universal 2"
    /usr/bin/codesign \
        --verify \
        --strict \
        --all-architectures \
        --verbose=2 \
        "$HELPER_PATH" ||
        fail "Caffeine helper has an invalid code signature"

    for architecture in arm64 x86_64; do
        details="$(
            /usr/bin/codesign \
                --display \
                --verbose=4 \
                --arch "$architecture" \
                "$HELPER_PATH" 2>&1
        )"
        identifier="$(signature_field "$details" "Identifier")"
        signature="$(signature_field "$details" "Signature")"
        team_identifier="$(
            signature_field "$details" "TeamIdentifier"
        )"
        [[ "$identifier" == "$HELPER_LABEL" ]] ||
            fail \
                "Caffeine helper $architecture identifier is '$identifier'"
        [[ "$signature" == "adhoc" ]] ||
            fail \
                "Caffeine helper $architecture is not ad-hoc signed"
        [[ -z "$team_identifier" || "$team_identifier" == "not set" ]] ||
            fail \
                "Caffeine helper $architecture unexpectedly has Team ID '$team_identifier'"
    done
}

require_cdhash_term() {
    local term="$1"
    local digest

    [[ "$term" == 'cdhash H"'*'"' ]] ||
        fail "invalid app requirement term in installed plist"
    digest="${term#cdhash H\"}"
    digest="${digest%\"}"
    [[ "${#digest}" == "40" && "$digest" =~ ^[0-9A-Fa-f]+$ ]] ||
        fail "invalid CDHash in installed plist"
}

require_exact_requirement() {
    local requirement="$1"
    local first_term
    local second_term

    first_term="${requirement%% or *}"
    second_term="${requirement#* or }"
    [[ "$first_term" != "$requirement" &&
       "$second_term" != *" or "* &&
       "$first_term" != "$second_term" ]] ||
        fail "installed plist does not contain an exact two-CDHash requirement"
    require_cdhash_term "$first_term"
    require_cdhash_term "$second_term"
}

plist_value() {
    local key_path="$1"

    "$PLIST_BUDDY" -c "Print :$key_path" "$DAEMON_PLIST" 2>/dev/null
}

xpath_count() {
    local expression="$1"
    local expected="$2"
    local description="$3"
    local actual

    actual="$(
        /usr/bin/xmllint \
            --xpath "count($expression)" \
            "$DAEMON_PLIST" \
            2>/dev/null
    )" ||
        fail "installed plist is not canonical XML: $description"
    [[ "$actual" == "$expected" ]] ||
        fail \
            "installed plist schema mismatch ($description: $actual, expected $expected)"
}

require_exact_plist_schema() {
    local mach_dictionary
    local environment_dictionary

    mach_dictionary='/plist/dict/key[.="MachServices"]/following-sibling::*[1][self::dict]'
    environment_dictionary='/plist/dict/key[.="EnvironmentVariables"]/following-sibling::*[1][self::dict]'

    xpath_count '/plist/dict/key' 5 "top-level key count"
    xpath_count '/plist/dict/*' 10 "top-level element count"
    for expected_key in \
        Label \
        ProgramArguments \
        MachServices \
        EnvironmentVariables \
        KeepAlive; do
        xpath_count \
            "/plist/dict/key[.=\"$expected_key\"]" \
            1 \
            "$expected_key key count"
    done
    xpath_count \
        '/plist/dict/key[.="Label"]/following-sibling::*[1][self::string]' \
        1 \
        "Label value type"
    xpath_count \
        '/plist/dict/key[.="ProgramArguments"]/following-sibling::*[1][self::array]' \
        1 \
        "ProgramArguments value type"
    xpath_count \
        '/plist/dict/key[.="ProgramArguments"]/following-sibling::*[1]/string' \
        1 \
        "ProgramArguments item count"
    xpath_count "$mach_dictionary/key" 1 "MachServices key count"
    xpath_count \
        "$mach_dictionary/key[.=\"$HELPER_LABEL\"]" \
        1 \
        "MachServices label count"
    xpath_count \
        "$mach_dictionary/key[.=\"$HELPER_LABEL\"]/following-sibling::*[1][self::true]" \
        1 \
        "MachServices value type"
    xpath_count \
        "$environment_dictionary/key" \
        1 \
        "EnvironmentVariables key count"
    xpath_count \
        "$environment_dictionary/key[.=\"CAFFEINE_APP_REQUIREMENT\"]" \
        1 \
        "app requirement key count"
    xpath_count \
        "$environment_dictionary/key[.=\"CAFFEINE_APP_REQUIREMENT\"]/following-sibling::*[1][self::string]" \
        1 \
        "app requirement value type"
    xpath_count \
        '/plist/dict/key[.="KeepAlive"]/following-sibling::*[1][self::true]' \
        1 \
        "KeepAlive value type"
}

require_safe_plist() {
    local requirement

    require_installed_file \
        "$DAEMON_PLIST" \
        644 \
        "Caffeine LaunchDaemon plist"
    /usr/bin/plutil -lint "$DAEMON_PLIST" >/dev/null
    require_exact_plist_schema
    [[ "$(plist_value "Label")" == "$HELPER_LABEL" ]] ||
        fail "installed plist has an unexpected label"
    [[ "$(plist_value "ProgramArguments:0")" == "$HELPER_PATH" ]] ||
        fail "installed plist has an unexpected program path"
    [[ "$(plist_value "MachServices:$HELPER_LABEL")" == "true" ]] ||
        fail "installed plist has an invalid Mach service"
    [[ "$(plist_value "KeepAlive")" == "true" ]] ||
        fail "installed plist has an invalid KeepAlive value"
    requirement="$(
        plist_value "EnvironmentVariables:CAFFEINE_APP_REQUIREMENT"
    )"
    require_exact_requirement "$requirement"
}

service_is_loaded() {
    /bin/launchctl print "system/$HELPER_LABEL" >/dev/null 2>&1
}

launchctl_field() {
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

require_loaded_service_paths() {
    loaded_service_paths_are_expected ||
        fail "loaded Caffeine helper has unexpected launchd paths"
}

loaded_service_paths_are_expected() {
    local details
    local loaded_path
    local loaded_program

    details="$(/bin/launchctl print "system/$HELPER_LABEL")" ||
        return 1
    loaded_path="$(launchctl_field "$details" "path")"
    loaded_program="$(launchctl_field "$details" "program")"
    [[ "$loaded_path" == "$DAEMON_PLIST" &&
       "$loaded_program" == "$HELPER_PATH" ]]
}

wait_until_unloaded() {
    local attempt

    for ((attempt = 0; attempt < 50; attempt += 1)); do
        if ! service_is_loaded; then
            return 0
        fi
        /bin/sleep 0.1
    done
    return 1
}

wait_until_running() {
    local attempt
    local details
    local state

    for ((attempt = 0; attempt < 50; attempt += 1)); do
        if details="$(
            /bin/launchctl print "system/$HELPER_LABEL" 2>/dev/null
        )"; then
            state="$(launchctl_field "$details" "state")"
            [[ "$state" == "running" ]] && return 0
        fi
        /bin/sleep 0.1
    done
    return 1
}

require_app_not_running() {
    local attempt

    for ((attempt = 0; attempt < 100; attempt += 1)); do
        if ! /bin/ps -axww -o comm= |
            /usr/bin/awk \
                -v expected="/Applications/Caffeine.app/Contents/MacOS/Caffeine" '
                    {
                        executable = $0
                        sub(/^[[:space:]]*/, "", executable)
                        sub(/[[:space:]]*$/, "", executable)
                        if (executable == expected) {
                            found = 1
                        }
                    }
                    END {
                        exit found ? 0 : 1
                    }
                '; then
            return
        fi
        /bin/sleep 0.1
    done
    fail "quit /Applications/Caffeine.app before removing its helper"
}

remove_regular_file() {
    local target="$1"

    if ! path_exists "$target"; then
        return 0
    fi
    [[ ! -L "$target" && -f "$target" ]] || return 1
    /bin/rm -f -- "$target"
}

publish_backup_file() {
    local source="$1"
    local target="$2"
    local mode="$3"
    local temporary

    temporary="$(
        /usr/bin/mktemp \
            "${target%/*}/.${target##*/}.restore.XXXXXX"
    )" || return 1
    if ! /usr/bin/install \
        -o root \
        -g wheel \
        -m "$mode" \
        "$source" \
        "$temporary" ||
       ! /bin/chmod -N "$temporary" ||
       ! /usr/bin/xattr -c "$temporary" ||
       ! /bin/mv -f "$temporary" "$target"; then
        /bin/rm -f -- "$temporary"
        return 1
    fi
}

cleanup_backup_directory() {
    if [[ -z "${backup_directory:-}" ]]; then
        return
    fi
    case "$backup_directory" in
        /private/var/tmp/caffeine-helper-uninstall.*)
            /bin/rm -f -- \
                "${backup_helper:-}" \
                "${backup_plist:-}"
            /bin/rmdir "$backup_directory" 2>/dev/null ||
                true
            ;;
    esac
}

handle_uninstall_exit() {
    local status="$?"
    local rollback_ok=1

    trap - EXIT
    trap '' HUP INT TERM
    if [[ "$status" != "0" ]]; then
        if [[ "${started_service:-0}" == "1" ]] &&
           service_is_loaded; then
            /bin/launchctl bootout \
                "system/$HELPER_LABEL" \
                >/dev/null 2>&1 ||
                rollback_ok=0
            wait_until_unloaded || rollback_ok=0
        fi

        if [[ "${mutation_started:-0}" == "1" &&
              "${uninstall_committed:-0}" == "0" ]]; then
            if service_is_loaded; then
                if loaded_service_paths_are_expected; then
                    /bin/launchctl bootout \
                        "system/$HELPER_LABEL" \
                        >/dev/null 2>&1 ||
                        rollback_ok=0
                    wait_until_unloaded || rollback_ok=0
                else
                    rollback_ok=0
                fi
            fi
            if ! path_exists "$HELPER_PATH"; then
                publish_backup_file \
                    "$backup_helper" \
                    "$HELPER_PATH" \
                    0755 ||
                    rollback_ok=0
            fi
            if ! path_exists "$DAEMON_PLIST"; then
                publish_backup_file \
                    "$backup_plist" \
                    "$DAEMON_PLIST" \
                    0644 ||
                    rollback_ok=0
            fi
        fi

        if [[ "${service_was_loaded:-0}" == "1" &&
              "${service_booted_out:-0}" == "1" &&
              "$rollback_ok" == "1" &&
              -f "$HELPER_PATH" &&
              -f "$DAEMON_PLIST" ]] &&
           ! service_is_loaded; then
            /bin/launchctl bootstrap \
                system \
                "$DAEMON_PLIST" \
                >/dev/null 2>&1 ||
                rollback_ok=0
            wait_until_running || rollback_ok=0
        fi

        if [[ "$rollback_ok" == "0" ]]; then
            printf '%s\n' \
                "warning: helper removal rollback was incomplete." \
                "Root-only recovery backups remain at:" \
                "  ${backup_directory:-unavailable}" >&2
            exit "$status"
        fi
    fi
    cleanup_backup_directory
    exit "$status"
}

backup_directory=""
backup_helper=""
backup_plist=""
service_was_loaded=0
service_booted_out=0
started_service=0
mutation_started=0
uninstall_committed=0
trap handle_uninstall_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[[ "$(/usr/bin/id -u)" == "0" ]] ||
    fail "this command must be run as root"
[[ "$#" == "0" ]] ||
    fail "usage: sudo /bin/bash \"$UNINSTALLER_PATH\""
[[ "${BASH_SOURCE[0]}" == "$UNINSTALLER_PATH" ]] ||
    fail "run the root-owned uninstaller at its installed path"

require_app_not_running
require_secure_system_directory "/Library" 755
require_secure_system_directory "$DAEMON_DIRECTORY" 755
require_secure_system_directory "$HELPER_DIRECTORY" 755
require_installed_file \
    "$UNINSTALLER_PATH" \
    755 \
    "Caffeine root uninstaller"
require_regular_target_or_absent "$HELPER_PATH"
require_regular_target_or_absent "$DAEMON_PLIST"

helper_is_installed=0
plist_is_installed=0
path_exists "$HELPER_PATH" && helper_is_installed=1
path_exists "$DAEMON_PLIST" && plist_is_installed=1
[[ "$helper_is_installed" == "$plist_is_installed" ]] ||
    fail \
        "helper installation is incomplete; restore both files before uninstalling"

if [[ "$helper_is_installed" == "1" ]]; then
    require_safe_helper
    require_safe_plist
    backup_directory="$(
        /usr/bin/mktemp \
            -d \
            /private/var/tmp/caffeine-helper-uninstall.XXXXXX
    )"
    backup_helper="$backup_directory/CaffeineHelper"
    backup_plist="$backup_directory/helper.plist"
    /usr/bin/install -o root -g wheel -m 0600 \
        "$HELPER_PATH" \
        "$backup_helper"
    /usr/bin/install -o root -g wheel -m 0600 \
        "$DAEMON_PLIST" \
        "$backup_plist"
fi

if service_is_loaded; then
    [[ "$helper_is_installed" == "1" ]] ||
        fail "a Caffeine helper service is loaded without its installed files"
    require_loaded_service_paths
    service_was_loaded=1
elif [[ "$helper_is_installed" == "1" ]]; then
    # Starting then stopping the helper repairs any stale root-owned sleep
    # marker before its recovery executable is removed.
    /bin/launchctl bootstrap system "$DAEMON_PLIST" ||
        fail "could not start the helper for pre-uninstall recovery"
    started_service=1
    if ! wait_until_running; then
        /bin/launchctl bootout \
            "system/$HELPER_LABEL" \
            >/dev/null 2>&1 ||
            true
        wait_until_unloaded || true
        fail "the helper did not start for pre-uninstall recovery"
    fi
    require_loaded_service_paths
fi

if service_is_loaded; then
    /bin/launchctl bootout "system/$HELPER_LABEL" ||
        fail "could not boot out the Caffeine helper"
    if [[ "$service_was_loaded" == "1" ]]; then
        service_booted_out=1
    fi
    wait_until_unloaded ||
        fail "the Caffeine helper did not stop"
    started_service=0
fi

mutation_started=1
remove_regular_file "$DAEMON_PLIST" ||
    fail "refusing to remove an unexpected plist target"
remove_regular_file "$HELPER_PATH" ||
    fail "refusing to remove an unexpected helper target"

service_is_loaded &&
    fail "the Caffeine helper is still loaded"
! path_exists "$DAEMON_PLIST" ||
    fail "the Caffeine helper plist still exists"
! path_exists "$HELPER_PATH" ||
    fail "the Caffeine helper executable still exists"

uninstall_committed=1
remove_regular_file "$UNINSTALLER_PATH" ||
    fail "refusing to remove the root-owned uninstaller"
! path_exists "$UNINSTALLER_PATH" ||
    fail "the root-owned uninstaller still exists"

if ! /usr/sbin/pkgutil \
    --forget \
    "$PACKAGE_RECEIPT_ID" \
    >/dev/null 2>&1; then
    printf 'warning: could not forget package receipt %s\n' \
        "$PACKAGE_RECEIPT_ID" >&2 ||
        true
fi

printf '%s\n' \
    "Removed the Caffeine helper:" \
    "  $HELPER_PATH" \
    "  $DAEMON_PLIST" \
    "  $UNINSTALLER_PATH" ||
    true
