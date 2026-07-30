#!/bin/bash

set -euo pipefail
umask 077

SCRIPT_DIRECTORY="$(
    cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P
)"
readonly SCRIPT_DIRECTORY
REPOSITORY_ROOT="$(
    cd "$SCRIPT_DIRECTORY/.." && pwd -P
)"
readonly REPOSITORY_ROOT

# shellcheck source=scripts/local-helper-common.sh
source "$SCRIPT_DIRECTORY/local-helper-common.sh"

readonly LEGACY_PLIST_TEMPLATE="$REPOSITORY_ROOT/Resources/$LOCAL_HELPER_LABEL.legacy.plist.in"

staging_directory=""
staged_helper=""
staged_plist=""
old_helper=""
old_plist=""
publish_temporary=""
had_old_helper=0
had_old_plist=0
service_was_loaded=0
mutation_started=0
installation_committed=0

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

require_universal_binary() {
    local binary="$1"
    local label="$2"
    local architectures
    local architecture_count

    architectures="$(/usr/bin/lipo -archs "$binary")"
    architecture_count="$(
        printf '%s\n' "$architectures" |
            /usr/bin/awk '{ print NF }'
    )"
    [[ "$architecture_count" == "2" ]] ||
        local_helper_fail \
            "$label must contain exactly two architectures; found: $architectures"
    /usr/bin/lipo "$binary" -verify_arch arm64 x86_64 >/dev/null ||
        local_helper_fail "$label is not Universal 2: $architectures"
}

require_ad_hoc_signature() {
    local code="$1"
    local expected_identifier="$2"
    local label="$3"
    local architecture
    local details
    local identifier
    local signature
    local team_identifier

    /usr/bin/codesign \
        --verify \
        --strict \
        --all-architectures \
        --verbose=2 \
        "$code" ||
        local_helper_fail "$label has an invalid code signature"

    for architecture in arm64 x86_64; do
        details="$(
            /usr/bin/codesign \
                --display \
                --verbose=4 \
                --arch "$architecture" \
                "$code" 2>&1
        )"
        identifier="$(signature_field "$details" "Identifier")"
        signature="$(signature_field "$details" "Signature")"
        team_identifier="$(signature_field "$details" "TeamIdentifier")"

        [[ "$identifier" == "$expected_identifier" ]] ||
            local_helper_fail \
                "$label $architecture signing identifier is '$identifier'; expected '$expected_identifier'"
        [[ "$signature" == "adhoc" ]] ||
            local_helper_fail \
                "$label $architecture slice must be ad-hoc signed; signature is '$signature'"
        [[ -z "$team_identifier" || "$team_identifier" == "not set" ]] ||
            local_helper_fail \
                "$label $architecture slice unexpectedly has Team ID '$team_identifier'"
        signature_has_flag "$details" "runtime" ||
            local_helper_fail \
                "$label $architecture slice is not signed with the hardened runtime"
    done
}

require_exact_cdhash_or_requirement() {
    local requirement="$1"
    local first_term
    local second_term

    first_term="${requirement%% or *}"
    second_term="${requirement#* or }"
    [[ "$first_term" != "$requirement" ]] ||
        local_helper_fail \
            "the Universal app designated requirement is not a CDHash OR expression"
    [[ "$second_term" != *" or "* ]] ||
        local_helper_fail \
            "the app designated requirement contains unexpected extra alternatives"

    require_cdhash_term "$first_term"
    require_cdhash_term "$second_term"
}

require_cdhash_term() {
    local term="$1"
    local digest

    [[ "$term" == 'cdhash H"'*'"' ]] ||
        local_helper_fail "invalid designated-requirement term: $term"
    digest="${term#cdhash H\"}"
    digest="${digest%\"}"
    [[ "${#digest}" == "40" && "$digest" =~ ^[0-9A-Fa-f]+$ ]] ||
        local_helper_fail "invalid CDHash in designated requirement"
}

derive_app_requirement() {
    local requirement_output
    local requirement_count
    local requirement

    requirement_output="$(
        /usr/bin/codesign --display --requirements - "$LOCAL_APP_PATH" 2>&1
    )"
    requirement_count="$(
        printf '%s\n' "$requirement_output" |
            /usr/bin/awk '
                /^# designated => / {
                    count += 1
                }
                END {
                    print count + 0
                }
            '
    )"
    [[ "$requirement_count" == "1" ]] ||
        local_helper_fail \
            "could not derive exactly one app designated requirement"
    requirement="$(
        printf '%s\n' "$requirement_output" |
            /usr/bin/sed -n 's/^# designated => //p'
    )"
    require_exact_cdhash_or_requirement "$requirement"
    printf '%s\n' "$requirement"
}

require_helper_supports_exact_requirement() {
    /usr/bin/strings -a "$LOCAL_BUNDLED_HELPER" |
        /usr/bin/awk '
            $0 == "CAFFEINE_APP_REQUIREMENT" {
                found = 1
            }
            END {
                exit found ? 0 : 1
            }
        ' ||
        local_helper_fail \
            "the bundled helper does not support CAFFEINE_APP_REQUIREMENT"
}

validate_source_app() {
    local bundle_identifier
    local embedded_team_identifier
    local unexpected_symlink

    local_helper_require_real_directory "/Applications"
    local_helper_require_real_directory "$LOCAL_APP_PATH"
    [[ -f "$LOCAL_APP_EXECUTABLE" && ! -L "$LOCAL_APP_EXECUTABLE" ]] ||
        local_helper_fail "app executable is missing or symbolic"
    [[ -f "$LOCAL_BUNDLED_HELPER" && ! -L "$LOCAL_BUNDLED_HELPER" ]] ||
        local_helper_fail "bundled helper is missing or symbolic"
    [[ -f "$LOCAL_APP_INFO_PLIST" && ! -L "$LOCAL_APP_INFO_PLIST" ]] ||
        local_helper_fail "app Info.plist is missing or symbolic"

    unexpected_symlink="$(
        /usr/bin/find "$LOCAL_APP_PATH" -type l -print -quit
    )"
    [[ -z "$unexpected_symlink" ]] ||
        local_helper_fail \
            "app bundle contains a symbolic link: $unexpected_symlink"

    /usr/bin/plutil -lint "$LOCAL_APP_INFO_PLIST" >/dev/null
    bundle_identifier="$(
        "$LOCAL_PLIST_BUDDY" \
            -c "Print :CFBundleIdentifier" \
            "$LOCAL_APP_INFO_PLIST"
    )"
    [[ "$bundle_identifier" == "tech.46h.caffeine" ]] ||
        local_helper_fail \
            "app bundle identifier is '$bundle_identifier'; expected 'tech.46h.caffeine'"
    embedded_team_identifier="$(
        "$LOCAL_PLIST_BUDDY" \
            -c "Print :CaffeineTeamIdentifier" \
            "$LOCAL_APP_INFO_PLIST"
    )"
    [[ -z "$embedded_team_identifier" ]] ||
        local_helper_fail \
            "local helper installation requires an ad-hoc app with no embedded Team ID"

    require_universal_binary "$LOCAL_APP_EXECUTABLE" "Caffeine"
    require_universal_binary "$LOCAL_BUNDLED_HELPER" "CaffeineHelper"
    require_ad_hoc_signature \
        "$LOCAL_APP_PATH" \
        "tech.46h.caffeine" \
        "Caffeine"
    require_ad_hoc_signature \
        "$LOCAL_BUNDLED_HELPER" \
        "$LOCAL_HELPER_LABEL" \
        "CaffeineHelper"
    require_helper_supports_exact_requirement
}

validate_staged_plist() {
    local plist="$1"
    local expected_requirement="$2"
    local actual_requirement

    /usr/bin/plutil -lint "$plist" >/dev/null
    [[ "$(
        "$LOCAL_PLIST_BUDDY" -c "Print :Label" "$plist"
    )" == "$LOCAL_HELPER_LABEL" ]] ||
        local_helper_fail "legacy helper plist has an unexpected label"
    [[ "$(
        "$LOCAL_PLIST_BUDDY" -c "Print :ProgramArguments:0" "$plist"
    )" == "$LOCAL_HELPER_PATH" ]] ||
        local_helper_fail "legacy helper plist has an unexpected program path"
    [[ "$(
        "$LOCAL_PLIST_BUDDY" \
            -c "Print :MachServices:$LOCAL_HELPER_LABEL" \
            "$plist"
    )" == "true" ]] ||
        local_helper_fail "legacy helper plist has an invalid Mach service"
    [[ "$(
        "$LOCAL_PLIST_BUDDY" -c "Print :KeepAlive" "$plist"
    )" == "true" ]] ||
        local_helper_fail "legacy helper plist must keep the helper alive"
    actual_requirement="$(
        "$LOCAL_PLIST_BUDDY" \
            -c "Print :EnvironmentVariables:CAFFEINE_APP_REQUIREMENT" \
            "$plist"
    )"
    [[ "$actual_requirement" == "$expected_requirement" ]] ||
        local_helper_fail \
            "legacy helper plist does not contain the exact app requirement"
}

publish_file_atomically() {
    local source="$1"
    local target="$2"
    local mode="$3"
    local target_directory
    local target_name

    target_directory="${target%/*}"
    target_name="${target##*/}"
    publish_temporary="$(
        /usr/bin/mktemp "$target_directory/.$target_name.install.XXXXXX"
    )" || return 1
    if ! /usr/bin/install \
        -o root \
        -g wheel \
        -m "$mode" \
        "$source" \
        "$publish_temporary"; then
        /bin/rm -f -- "$publish_temporary"
        publish_temporary=""
        return 1
    fi
    if ! /bin/mv -f "$publish_temporary" "$target"; then
        /bin/rm -f -- "$publish_temporary"
        publish_temporary=""
        return 1
    fi
    publish_temporary=""
}

restore_previous_installation() {
    local rollback_failed=0

    printf 'Rolling back the local helper installation…\n' >&2
    if local_helper_service_is_loaded; then
        /bin/launchctl bootout "system/$LOCAL_HELPER_LABEL" >/dev/null 2>&1 ||
            rollback_failed=1
        local_helper_wait_until_unloaded || rollback_failed=1
    fi

    if [[ "$had_old_helper" == "1" ]]; then
        publish_file_atomically "$old_helper" "$LOCAL_HELPER_PATH" 0755 ||
            rollback_failed=1
    else
        local_helper_remove_exact_regular_file "$LOCAL_HELPER_PATH" ||
            rollback_failed=1
    fi

    if [[ "$had_old_plist" == "1" ]]; then
        publish_file_atomically "$old_plist" "$LOCAL_DAEMON_PLIST" 0644 ||
            rollback_failed=1
    else
        local_helper_remove_exact_regular_file "$LOCAL_DAEMON_PLIST" ||
            rollback_failed=1
    fi

    if [[ "$service_was_loaded" == "1" && "$had_old_plist" == "1" ]]; then
        if ! /bin/launchctl bootstrap \
            system \
            "$LOCAL_DAEMON_PLIST" >/dev/null 2>&1; then
            rollback_failed=1
        elif ! local_helper_wait_until_running; then
            rollback_failed=1
        fi
    fi

    if [[ "$rollback_failed" == "1" ]]; then
        printf '%s\n' \
            "warning: automatic rollback was incomplete; inspect only:" \
            "  $LOCAL_HELPER_PATH" \
            "  $LOCAL_DAEMON_PLIST" >&2
    fi
}

clean_temporary_files() {
    if [[ -n "$publish_temporary" ]]; then
        case "$publish_temporary" in
            "$LOCAL_HELPER_DIRECTORY"/.*|"$LOCAL_DAEMON_DIRECTORY"/.*)
                /bin/rm -f -- "$publish_temporary"
                ;;
        esac
    fi

    if [[ -n "$staging_directory" ]]; then
        case "$staging_directory" in
            /private/var/tmp/caffeine-local-helper.*)
                /bin/rm -f -- \
                    "$staged_helper" \
                    "$staged_plist" \
                    "$old_helper" \
                    "$old_plist"
                /bin/rmdir "$staging_directory" 2>/dev/null || true
                ;;
        esac
    fi
}

handle_exit() {
    local status="$?"
    trap - EXIT
    if [[ "$status" != "0" &&
          "$mutation_started" == "1" &&
          "$installation_committed" == "0" ]]; then
        restore_previous_installation
    fi
    clean_temporary_files
    exit "$status"
}

trap handle_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

local_helper_require_root
local_helper_require_no_arguments \
    "$#" \
    "sudo ${BASH_SOURCE[0]}"
local_helper_require_app_not_running

[[ -f "$LEGACY_PLIST_TEMPLATE" && ! -L "$LEGACY_PLIST_TEMPLATE" ]] ||
    local_helper_fail \
        "legacy helper plist template is missing or symbolic: $LEGACY_PLIST_TEMPLATE"

validate_source_app
app_requirement="$(derive_app_requirement)"
readonly app_requirement
/usr/bin/codesign \
    --verify \
    --strict \
    --all-architectures \
    -R="$app_requirement" \
    "$LOCAL_APP_PATH" ||
    local_helper_fail "the derived requirement does not identify the app"

local_helper_require_secure_system_directory "/Library" 755
local_helper_require_secure_system_directory "$LOCAL_DAEMON_DIRECTORY" 755
if ! local_helper_path_exists "$LOCAL_HELPER_DIRECTORY"; then
    /usr/bin/install \
        -d \
        -o root \
        -g wheel \
        -m 0755 \
        "$LOCAL_HELPER_DIRECTORY"
fi
local_helper_require_secure_system_directory "$LOCAL_HELPER_DIRECTORY" 755
local_helper_require_regular_target_or_absent "$LOCAL_HELPER_PATH"
local_helper_require_regular_target_or_absent "$LOCAL_DAEMON_PLIST"

staging_directory="$(
    /usr/bin/mktemp -d /private/var/tmp/caffeine-local-helper.XXXXXX
)"
staged_helper="$staging_directory/new-helper"
staged_plist="$staging_directory/new.plist"
old_helper="$staging_directory/old-helper"
old_plist="$staging_directory/old.plist"

/usr/bin/install \
    -o root \
    -g wheel \
    -m 0755 \
    "$LOCAL_BUNDLED_HELPER" \
    "$staged_helper"
/usr/bin/install \
    -o root \
    -g wheel \
    -m 0644 \
    "$LEGACY_PLIST_TEMPLATE" \
    "$staged_plist"
/usr/bin/plutil \
    -replace EnvironmentVariables.CAFFEINE_APP_REQUIREMENT \
    -string "$app_requirement" \
    "$staged_plist"

require_universal_binary "$staged_helper" "staged CaffeineHelper"
require_ad_hoc_signature \
    "$staged_helper" \
    "$LOCAL_HELPER_LABEL" \
    "staged CaffeineHelper"
validate_staged_plist "$staged_plist" "$app_requirement"

if local_helper_path_exists "$LOCAL_HELPER_PATH"; then
    /usr/bin/install -m 0600 "$LOCAL_HELPER_PATH" "$old_helper"
    had_old_helper=1
fi
if local_helper_path_exists "$LOCAL_DAEMON_PLIST"; then
    /usr/bin/install -m 0600 "$LOCAL_DAEMON_PLIST" "$old_plist"
    had_old_plist=1
fi

if local_helper_service_is_loaded; then
    local_helper_require_loaded_service_paths
    [[ "$had_old_helper" == "1" && "$had_old_plist" == "1" ]] ||
        local_helper_fail \
            "loaded helper does not have both expected on-disk files"
    service_was_loaded=1
fi

# Revalidate after staging so a concurrently replaced app cannot authorize a
# different CDHash than the one written into the root-owned daemon plist.
validate_source_app
[[ "$(derive_app_requirement)" == "$app_requirement" ]] ||
    local_helper_fail "the app changed while the helper was being staged"

# Close the staging window before the first launchd or filesystem mutation. A
# user may have relaunched Caffeine while the source app and payload were being
# verified above.
local_helper_require_app_not_running
mutation_started=1
if [[ "$service_was_loaded" == "1" ]]; then
    /bin/launchctl bootout "system/$LOCAL_HELPER_LABEL" ||
        local_helper_fail "could not boot out the previous local helper"
    local_helper_wait_until_unloaded ||
        local_helper_fail "the previous local helper did not stop"
fi

publish_file_atomically "$staged_helper" "$LOCAL_HELPER_PATH" 0755 ||
    local_helper_fail "could not publish the local helper executable"
publish_file_atomically "$staged_plist" "$LOCAL_DAEMON_PLIST" 0644 ||
    local_helper_fail "could not publish the local helper plist"

[[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$LOCAL_HELPER_PATH")" \
    == "root:wheel:755" ]] ||
    local_helper_fail "installed helper ownership or mode is invalid"
[[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$LOCAL_DAEMON_PLIST")" \
    == "root:wheel:644" ]] ||
    local_helper_fail "installed plist ownership or mode is invalid"
require_universal_binary "$LOCAL_HELPER_PATH" "installed CaffeineHelper"
require_ad_hoc_signature \
    "$LOCAL_HELPER_PATH" \
    "$LOCAL_HELPER_LABEL" \
    "installed CaffeineHelper"
validate_staged_plist "$LOCAL_DAEMON_PLIST" "$app_requirement"
[[ "$(
    /usr/bin/shasum -a 256 "$LOCAL_HELPER_PATH" |
        /usr/bin/awk '{ print $1 }'
)" == "$(
    /usr/bin/shasum -a 256 "$staged_helper" |
        /usr/bin/awk '{ print $1 }'
)" ]] ||
    local_helper_fail "installed helper does not match the staged helper"

/bin/launchctl bootstrap system "$LOCAL_DAEMON_PLIST" ||
    local_helper_fail "could not bootstrap the local helper"
local_helper_wait_until_running ||
    local_helper_fail "the local helper did not reach the running state"
local_helper_require_loaded_service_paths

validate_source_app
[[ "$(derive_app_requirement)" == "$app_requirement" ]] ||
    local_helper_fail "the app changed before helper verification completed"
/usr/bin/codesign \
    --verify \
    --strict \
    --all-architectures \
    -R="$app_requirement" \
    "$LOCAL_APP_PATH" ||
    local_helper_fail "the installed requirement no longer identifies the app"

installation_committed=1
printf '%s\n' \
    "Installed and started the local Caffeine helper:" \
    "  $LOCAL_HELPER_PATH" \
    "  $LOCAL_DAEMON_PLIST"
