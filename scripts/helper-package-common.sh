#!/bin/bash

# Runtime shared by the preinstall and postinstall scripts in the unsigned
# helper package. The package has no Installer payload: this code derives the
# installed app's exact requirement, validates the exact embedded helper, and
# then owns the complete privileged-file transaction.

readonly CAFFEINE_HELPER_LABEL="tech.46h.caffeine.helper"
readonly CAFFEINE_APP_IDENTIFIER="tech.46h.caffeine"
readonly CAFFEINE_APP_PATH="/Applications/Caffeine.app"
readonly CAFFEINE_APP_EXECUTABLE="$CAFFEINE_APP_PATH/Contents/MacOS/Caffeine"
readonly CAFFEINE_APP_INFO_PLIST="$CAFFEINE_APP_PATH/Contents/Info.plist"
readonly CAFFEINE_APP_HELPER="$CAFFEINE_APP_PATH/Contents/MacOS/CaffeineHelper"
readonly CAFFEINE_HELPER_DIRECTORY="/Library/PrivilegedHelperTools"
readonly CAFFEINE_HELPER_PATH="$CAFFEINE_HELPER_DIRECTORY/$CAFFEINE_HELPER_LABEL"
readonly CAFFEINE_UNINSTALLER_PATH="$CAFFEINE_HELPER_DIRECTORY/tech.46h.caffeine.uninstall-helper"
readonly CAFFEINE_DAEMON_DIRECTORY="/Library/LaunchDaemons"
readonly CAFFEINE_DAEMON_PLIST="$CAFFEINE_DAEMON_DIRECTORY/$CAFFEINE_HELPER_LABEL.plist"
readonly CAFFEINE_PLIST_BUDDY="/usr/libexec/PlistBuddy"
readonly CAFFEINE_PACKAGE_HELPER="$SCRIPT_DIRECTORY/CaffeineHelper"
readonly CAFFEINE_PACKAGE_PLIST="$SCRIPT_DIRECTORY/$CAFFEINE_HELPER_LABEL.plist"
readonly CAFFEINE_PACKAGE_UNINSTALLER="$SCRIPT_DIRECTORY/uninstall-helper"

caffeine_package_fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

caffeine_package_path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

caffeine_package_require_root_target() {
    local target_volume="$1"

    [[ "$(/usr/bin/id -u)" == "0" ]] ||
        caffeine_package_fail "the helper package must run as root"
    [[ "$target_volume" == "/" ]] ||
        caffeine_package_fail \
            "the Caffeine helper can only be installed on the startup volume"
}

caffeine_package_require_real_directory() {
    local directory="$1"

    [[ ! -L "$directory" ]] ||
        caffeine_package_fail "refusing symbolic-link directory: $directory"
    [[ -d "$directory" ]] ||
        caffeine_package_fail "required directory is missing: $directory"
}

caffeine_package_require_secure_system_directory() {
    local directory="$1"
    local expected_mode="$2"
    local details

    caffeine_package_require_real_directory "$directory"
    details="$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$directory")"
    [[ "$details" == "root:wheel:$expected_mode" ]] ||
        caffeine_package_fail \
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
        caffeine_package_fail \
            "$directory has an access-control list; refusing privileged writes"
    return 0
}

caffeine_package_require_regular_target_or_absent() {
    local target="$1"

    if ! caffeine_package_path_exists "$target"; then
        return
    fi
    [[ ! -L "$target" ]] ||
        caffeine_package_fail "refusing symbolic-link target: $target"
    [[ -f "$target" ]] ||
        caffeine_package_fail "refusing non-regular target: $target"
}

caffeine_package_require_existing_metadata_or_absent() {
    local target="$1"
    local expected_mode="$2"
    local label="$3"
    local details
    local flags
    local attributes

    caffeine_package_require_regular_target_or_absent "$target"
    if ! caffeine_package_path_exists "$target"; then
        return
    fi
    details="$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$target")"
    [[ "$details" == "root:wheel:$expected_mode" ]] ||
        caffeine_package_fail \
            "$label ownership/mode is $details; expected root:wheel:$expected_mode"
    /bin/ls -le "$target" |
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
        caffeine_package_fail \
            "$label has an access-control list; refusing to replace it"
    flags="$(/usr/bin/stat -f '%Sf' "$target")"
    [[ "$flags" == "-" ]] ||
        caffeine_package_fail \
            "$label has unexpected file flags: $flags"
    attributes="$(/usr/bin/xattr "$target")"
    [[ -z "$attributes" ]] ||
        caffeine_package_fail \
            "$label has extended attributes; refusing lossy rollback"
}

caffeine_package_require_packaged_file() {
    local path="$1"
    local label="$2"

    [[ -f "$path" && ! -L "$path" ]] ||
        caffeine_package_fail "$label is missing or symbolic in the package"
}

caffeine_package_signature_field() {
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

caffeine_package_signature_has_flag() {
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

caffeine_package_require_universal_binary() {
    local binary="$1"
    local label="$2"
    local architectures
    local architecture_count

    [[ -f "$binary" && ! -L "$binary" ]] ||
        caffeine_package_fail "$label is missing or symbolic"
    architectures="$(/usr/bin/lipo -archs "$binary")"
    architecture_count="$(
        printf '%s\n' "$architectures" |
            /usr/bin/awk '{ print NF }'
    )"
    [[ "$architecture_count" == "2" ]] ||
        caffeine_package_fail \
            "$label must contain exactly two architectures; found: $architectures"
    /usr/bin/lipo "$binary" -verify_arch arm64 x86_64 >/dev/null ||
        caffeine_package_fail "$label is not Universal 2: $architectures"
}

caffeine_package_require_ad_hoc_signature() {
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
        caffeine_package_fail "$label has an invalid code signature"

    for architecture in arm64 x86_64; do
        details="$(
            /usr/bin/codesign \
                --display \
                --verbose=4 \
                --arch "$architecture" \
                "$code" 2>&1
        )"
        identifier="$(
            caffeine_package_signature_field "$details" "Identifier"
        )"
        signature="$(
            caffeine_package_signature_field "$details" "Signature"
        )"
        team_identifier="$(
            caffeine_package_signature_field "$details" "TeamIdentifier"
        )"

        [[ "$identifier" == "$expected_identifier" ]] ||
            caffeine_package_fail \
                "$label $architecture signing identifier is '$identifier'; expected '$expected_identifier'"
        [[ "$signature" == "adhoc" ]] ||
            caffeine_package_fail \
                "$label $architecture slice must be ad-hoc signed; signature is '$signature'"
        [[ -z "$team_identifier" || "$team_identifier" == "not set" ]] ||
            caffeine_package_fail \
                "$label $architecture slice unexpectedly has Team ID '$team_identifier'"
        caffeine_package_signature_has_flag "$details" "runtime" ||
            caffeine_package_fail \
                "$label $architecture slice is not signed with the hardened runtime"
    done
}

caffeine_package_require_cdhash_term() {
    local term="$1"
    local digest

    [[ "$term" == 'cdhash H"'*'"' ]] ||
        caffeine_package_fail "invalid designated-requirement term: $term"
    digest="${term#cdhash H\"}"
    digest="${digest%\"}"
    [[ "${#digest}" == "40" && "$digest" =~ ^[0-9A-Fa-f]+$ ]] ||
        caffeine_package_fail "invalid CDHash in designated requirement"
}

caffeine_package_require_exact_requirement() {
    local requirement="$1"
    local first_term
    local second_term

    first_term="${requirement%% or *}"
    second_term="${requirement#* or }"
    [[ "$first_term" != "$requirement" ]] ||
        caffeine_package_fail \
            "the baked app requirement is not a CDHash OR expression"
    [[ "$second_term" != *" or "* ]] ||
        caffeine_package_fail \
            "the baked app requirement contains unexpected alternatives"
    caffeine_package_require_cdhash_term "$first_term"
    caffeine_package_require_cdhash_term "$second_term"
    [[ "$first_term" != "$second_term" ]] ||
        caffeine_package_fail \
            "the baked app requirement repeats the same CDHash"
}

caffeine_package_derive_app_requirement() {
    local output
    local count
    local requirement

    output="$(
        /usr/bin/codesign \
            --display \
            --requirements - \
            "$CAFFEINE_APP_PATH" 2>&1
    )"
    count="$(
        printf '%s\n' "$output" |
            /usr/bin/awk '
                /^# designated => / {
                    count += 1
                }
                END {
                    print count + 0
                }
            '
    )"
    [[ "$count" == "1" ]] ||
        caffeine_package_fail \
            "could not derive exactly one app designated requirement"
    requirement="$(
        printf '%s\n' "$output" |
            /usr/bin/sed -n 's/^# designated => //p'
    )"
    caffeine_package_require_exact_requirement "$requirement"
    printf '%s\n' "$requirement"
}

caffeine_package_plist_value() {
    local plist="$1"
    local key_path="$2"

    "$CAFFEINE_PLIST_BUDDY" -c "Print :$key_path" "$plist" 2>/dev/null
}

caffeine_package_validate_plist() {
    local plist="$1"
    local expected_requirement="$2"

    /usr/bin/plutil -lint "$plist" >/dev/null
    caffeine_package_validate_plist_schema "$plist"
    [[ "$(caffeine_package_plist_value "$plist" "Label")" \
        == "$CAFFEINE_HELPER_LABEL" ]] ||
        caffeine_package_fail "helper plist has an unexpected label"
    [[ "$(caffeine_package_plist_value "$plist" "ProgramArguments:0")" \
        == "$CAFFEINE_HELPER_PATH" ]] ||
        caffeine_package_fail "helper plist has an unexpected program path"
    [[ "$(
        caffeine_package_plist_value \
            "$plist" \
            "MachServices:$CAFFEINE_HELPER_LABEL"
    )" == "true" ]] ||
        caffeine_package_fail "helper plist has an invalid Mach service"
    [[ "$(caffeine_package_plist_value "$plist" "KeepAlive")" == "true" ]] ||
        caffeine_package_fail "helper plist must keep the helper alive"
    [[ "$(
        caffeine_package_plist_value \
            "$plist" \
            "EnvironmentVariables:CAFFEINE_APP_REQUIREMENT"
    )" == "$expected_requirement" ]] ||
        caffeine_package_fail \
            "helper plist does not contain the exact baked app requirement"
}

caffeine_package_xpath_count() {
    local plist="$1"
    local expression="$2"
    local expected="$3"
    local description="$4"
    local actual

    actual="$(
        /usr/bin/xmllint \
            --xpath "count($expression)" \
            "$plist" \
            2>/dev/null
    )" ||
        caffeine_package_fail \
            "helper plist is not canonical XML: $description"
    [[ "$actual" == "$expected" ]] ||
        caffeine_package_fail \
            "helper plist schema mismatch ($description: $actual, expected $expected)"
}

caffeine_package_validate_plist_schema() {
    local plist="$1"
    local mach_dictionary
    local environment_dictionary

    mach_dictionary='/plist/dict/key[.="MachServices"]/following-sibling::*[1][self::dict]'
    environment_dictionary='/plist/dict/key[.="EnvironmentVariables"]/following-sibling::*[1][self::dict]'

    caffeine_package_xpath_count \
        "$plist" \
        '/plist/dict/key' \
        5 \
        "top-level key count"
    caffeine_package_xpath_count \
        "$plist" \
        '/plist/dict/*' \
        10 \
        "top-level element count"
    for expected_key in \
        Label \
        ProgramArguments \
        MachServices \
        EnvironmentVariables \
        KeepAlive; do
        caffeine_package_xpath_count \
            "$plist" \
            "/plist/dict/key[.=\"$expected_key\"]" \
            1 \
            "$expected_key key count"
    done
    caffeine_package_xpath_count \
        "$plist" \
        '/plist/dict/key[.="Label"]/following-sibling::*[1][self::string]' \
        1 \
        "Label value type"
    caffeine_package_xpath_count \
        "$plist" \
        '/plist/dict/key[.="ProgramArguments"]/following-sibling::*[1][self::array]' \
        1 \
        "ProgramArguments value type"
    caffeine_package_xpath_count \
        "$plist" \
        '/plist/dict/key[.="ProgramArguments"]/following-sibling::*[1]/string' \
        1 \
        "ProgramArguments item count"
    caffeine_package_xpath_count \
        "$plist" \
        "$mach_dictionary/key" \
        1 \
        "MachServices key count"
    caffeine_package_xpath_count \
        "$plist" \
        "$mach_dictionary/key[.=\"$CAFFEINE_HELPER_LABEL\"]" \
        1 \
        "MachServices label count"
    caffeine_package_xpath_count \
        "$plist" \
        "$mach_dictionary/key[.=\"$CAFFEINE_HELPER_LABEL\"]/following-sibling::*[1][self::true]" \
        1 \
        "MachServices value type"
    caffeine_package_xpath_count \
        "$plist" \
        "$environment_dictionary/key" \
        1 \
        "EnvironmentVariables key count"
    caffeine_package_xpath_count \
        "$plist" \
        "$environment_dictionary/key[.=\"CAFFEINE_APP_REQUIREMENT\"]" \
        1 \
        "app requirement key count"
    caffeine_package_xpath_count \
        "$plist" \
        "$environment_dictionary/key[.=\"CAFFEINE_APP_REQUIREMENT\"]/following-sibling::*[1][self::string]" \
        1 \
        "app requirement value type"
    caffeine_package_xpath_count \
        "$plist" \
        '/plist/dict/key[.="KeepAlive"]/following-sibling::*[1][self::true]' \
        1 \
        "KeepAlive value type"
}

caffeine_package_require_app_not_running() {
    local attempt

    for ((attempt = 0; attempt < 100; attempt += 1)); do
        if ! /bin/ps -axww -o comm= |
            /usr/bin/awk -v expected="$CAFFEINE_APP_EXECUTABLE" '
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
    caffeine_package_fail \
        "quit /Applications/Caffeine.app before installing its helper"
}

caffeine_package_validate_assets() {
    local package_helper_hash
    local app_helper_hash

    caffeine_package_require_packaged_file \
        "$CAFFEINE_PACKAGE_HELPER" \
        "packaged CaffeineHelper"
    caffeine_package_require_packaged_file \
        "$CAFFEINE_PACKAGE_PLIST" \
        "packaged helper plist"
    caffeine_package_require_packaged_file \
        "$CAFFEINE_PACKAGE_UNINSTALLER" \
        "packaged root uninstaller"

    caffeine_package_validate_plist \
        "$CAFFEINE_PACKAGE_PLIST" \
        ""
    caffeine_package_require_universal_binary \
        "$CAFFEINE_PACKAGE_HELPER" \
        "packaged CaffeineHelper"
    caffeine_package_require_ad_hoc_signature \
        "$CAFFEINE_PACKAGE_HELPER" \
        "$CAFFEINE_HELPER_LABEL" \
        "packaged CaffeineHelper"
    /usr/bin/strings -a "$CAFFEINE_PACKAGE_HELPER" |
        /usr/bin/awk '
            $0 == "CAFFEINE_APP_REQUIREMENT" {
                found = 1
            }
            END {
                exit found ? 0 : 1
            }
        ' ||
        caffeine_package_fail \
            "packaged helper does not support CAFFEINE_APP_REQUIREMENT"
    /bin/bash -n "$CAFFEINE_PACKAGE_UNINSTALLER" ||
        caffeine_package_fail "packaged root uninstaller has invalid syntax"

    package_helper_hash="$(
        /usr/bin/shasum -a 256 "$CAFFEINE_PACKAGE_HELPER" |
            /usr/bin/awk '{ print $1 }'
    )"
    app_helper_hash="$(
        /usr/bin/shasum -a 256 "$CAFFEINE_APP_HELPER" |
            /usr/bin/awk '{ print $1 }'
    )"
    [[ "$package_helper_hash" == "$app_helper_hash" ]] ||
        caffeine_package_fail \
            "packaged helper does not match the exact app's embedded helper"
}

caffeine_package_validate_source_app() {
    local bundle_identifier
    local embedded_team_identifier
    local unexpected_symlink
    local derived_requirement

    caffeine_package_require_real_directory "/Applications"
    caffeine_package_require_real_directory "$CAFFEINE_APP_PATH"
    [[ -f "$CAFFEINE_APP_EXECUTABLE" &&
       ! -L "$CAFFEINE_APP_EXECUTABLE" ]] ||
        caffeine_package_fail "app executable is missing or symbolic"
    [[ -f "$CAFFEINE_APP_HELPER" && ! -L "$CAFFEINE_APP_HELPER" ]] ||
        caffeine_package_fail "embedded helper is missing or symbolic"
    [[ -f "$CAFFEINE_APP_INFO_PLIST" &&
       ! -L "$CAFFEINE_APP_INFO_PLIST" ]] ||
        caffeine_package_fail "app Info.plist is missing or symbolic"

    unexpected_symlink="$(
        /usr/bin/find "$CAFFEINE_APP_PATH" -type l -print -quit
    )"
    [[ -z "$unexpected_symlink" ]] ||
        caffeine_package_fail \
            "app bundle contains a symbolic link: $unexpected_symlink"

    /usr/bin/plutil -lint "$CAFFEINE_APP_INFO_PLIST" >/dev/null
    bundle_identifier="$(
        caffeine_package_plist_value \
            "$CAFFEINE_APP_INFO_PLIST" \
            "CFBundleIdentifier"
    )"
    [[ "$bundle_identifier" == "$CAFFEINE_APP_IDENTIFIER" ]] ||
        caffeine_package_fail \
            "app bundle identifier is '$bundle_identifier'; expected '$CAFFEINE_APP_IDENTIFIER'"
    embedded_team_identifier="$(
        caffeine_package_plist_value \
            "$CAFFEINE_APP_INFO_PLIST" \
            "CaffeineTeamIdentifier"
    )"
    [[ -z "$embedded_team_identifier" ]] ||
        caffeine_package_fail \
            "the community helper package requires an ad-hoc app with no Team ID"

    caffeine_package_require_universal_binary \
        "$CAFFEINE_APP_EXECUTABLE" \
        "Caffeine"
    caffeine_package_require_universal_binary \
        "$CAFFEINE_APP_HELPER" \
        "embedded CaffeineHelper"
    caffeine_package_require_ad_hoc_signature \
        "$CAFFEINE_APP_PATH" \
        "$CAFFEINE_APP_IDENTIFIER" \
        "Caffeine"
    caffeine_package_require_ad_hoc_signature \
        "$CAFFEINE_APP_HELPER" \
        "$CAFFEINE_HELPER_LABEL" \
        "embedded CaffeineHelper"
    /usr/bin/codesign \
        --verify \
        --deep \
        --strict \
        --all-architectures \
        --verbose=2 \
        "$CAFFEINE_APP_PATH" ||
        caffeine_package_fail "Caffeine.app has an invalid nested signature"

    derived_requirement="$(caffeine_package_derive_app_requirement)"
    /usr/bin/codesign \
        --verify \
        --deep \
        --strict \
        --all-architectures \
        -R="$derived_requirement" \
        "$CAFFEINE_APP_PATH" ||
        caffeine_package_fail \
            "the derived exact requirement does not identify Caffeine.app"

    caffeine_package_validate_assets
}

caffeine_package_preflight() {
    local target_volume="$1"

    caffeine_package_require_root_target "$target_volume"
    caffeine_package_require_app_not_running
    caffeine_package_validate_source_app
    caffeine_package_require_secure_system_directory "/Library" 755
    caffeine_package_require_secure_system_directory \
        "$CAFFEINE_DAEMON_DIRECTORY" \
        755
    if caffeine_package_path_exists "$CAFFEINE_HELPER_DIRECTORY"; then
        caffeine_package_require_secure_system_directory \
            "$CAFFEINE_HELPER_DIRECTORY" \
            755
    fi
    caffeine_package_require_existing_metadata_or_absent \
        "$CAFFEINE_HELPER_PATH" \
        755 \
        "existing Caffeine helper"
    caffeine_package_require_existing_metadata_or_absent \
        "$CAFFEINE_DAEMON_PLIST" \
        644 \
        "existing Caffeine LaunchDaemon plist"
    caffeine_package_require_existing_metadata_or_absent \
        "$CAFFEINE_UNINSTALLER_PATH" \
        755 \
        "existing Caffeine root uninstaller"
}

caffeine_package_service_is_loaded() {
    /bin/launchctl print \
        "system/$CAFFEINE_HELPER_LABEL" \
        >/dev/null 2>&1
}

caffeine_package_launchctl_field() {
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

caffeine_package_require_loaded_service_paths() {
    caffeine_package_loaded_service_paths_are_expected ||
        caffeine_package_fail \
            "loaded Caffeine helper has unexpected launchd paths"
}

caffeine_package_loaded_service_paths_are_expected() {
    local details
    local loaded_path
    local loaded_program

    details="$(
        /bin/launchctl print "system/$CAFFEINE_HELPER_LABEL"
    )" || return 1
    loaded_path="$(
        caffeine_package_launchctl_field "$details" "path"
    )"
    loaded_program="$(
        caffeine_package_launchctl_field "$details" "program"
    )"
    [[ "$loaded_path" == "$CAFFEINE_DAEMON_PLIST" &&
       "$loaded_program" == "$CAFFEINE_HELPER_PATH" ]]
}

caffeine_package_wait_until_unloaded() {
    local attempt

    for ((attempt = 0; attempt < 50; attempt += 1)); do
        if ! caffeine_package_service_is_loaded; then
            return 0
        fi
        /bin/sleep 0.1
    done
    return 1
}

caffeine_package_wait_until_running() {
    local attempt
    local details
    local state

    for ((attempt = 0; attempt < 50; attempt += 1)); do
        if details="$(
            /bin/launchctl print \
                "system/$CAFFEINE_HELPER_LABEL" \
                2>/dev/null
        )"; then
            state="$(
                caffeine_package_launchctl_field "$details" "state"
            )"
            if [[ "$state" == "running" ]]; then
                return 0
            fi
        fi
        /bin/sleep 0.1
    done
    return 1
}

caffeine_package_publish_file() {
    local source="$1"
    local target="$2"
    local mode="$3"
    local target_directory
    local target_name

    target_directory="${target%/*}"
    target_name="${target##*/}"
    CAFFEINE_PUBLISH_TEMPORARY="$(
        /usr/bin/mktemp \
            "$target_directory/.$target_name.install.XXXXXX"
    )" || return 1
    if ! /usr/bin/install \
        -o root \
        -g wheel \
        -m "$mode" \
        "$source" \
        "$CAFFEINE_PUBLISH_TEMPORARY"; then
        /bin/rm -f -- "$CAFFEINE_PUBLISH_TEMPORARY"
        CAFFEINE_PUBLISH_TEMPORARY=""
        return 1
    fi
    if ! /bin/chmod -N "$CAFFEINE_PUBLISH_TEMPORARY" ||
       ! /usr/bin/xattr -c "$CAFFEINE_PUBLISH_TEMPORARY"; then
        /bin/rm -f -- "$CAFFEINE_PUBLISH_TEMPORARY"
        CAFFEINE_PUBLISH_TEMPORARY=""
        return 1
    fi
    if ! /bin/mv -f "$CAFFEINE_PUBLISH_TEMPORARY" "$target"; then
        /bin/rm -f -- "$CAFFEINE_PUBLISH_TEMPORARY"
        CAFFEINE_PUBLISH_TEMPORARY=""
        return 1
    fi
    CAFFEINE_PUBLISH_TEMPORARY=""
}

caffeine_package_remove_regular_file() {
    local target="$1"

    if ! caffeine_package_path_exists "$target"; then
        return 0
    fi
    [[ ! -L "$target" && -f "$target" ]] || return 1
    /bin/rm -f -- "$target"
}

caffeine_package_restore_one() {
    local had_old="$1"
    local backup="$2"
    local target="$3"
    local mode="$4"

    if [[ "$had_old" == "1" ]]; then
        caffeine_package_publish_file "$backup" "$target" "$mode"
    else
        caffeine_package_remove_regular_file "$target"
    fi
}

caffeine_package_restore_previous_installation() {
    local rollback_failed=0
    local service_stopped=1
    local helper_restored=0
    local plist_restored=0

    printf 'Rolling back the Caffeine helper installation…\n' >&2
    if caffeine_package_service_is_loaded; then
        if caffeine_package_loaded_service_paths_are_expected; then
            if ! /bin/launchctl bootout \
                "system/$CAFFEINE_HELPER_LABEL" \
                >/dev/null 2>&1; then
                rollback_failed=1
            fi
            if ! caffeine_package_wait_until_unloaded; then
                rollback_failed=1
                service_stopped=0
            fi
        else
            rollback_failed=1
            service_stopped=0
        fi
    fi

    if [[ "$service_stopped" == "1" ]]; then
        if caffeine_package_restore_one \
            "$CAFFEINE_HAD_OLD_HELPER" \
            "$CAFFEINE_OLD_HELPER" \
            "$CAFFEINE_HELPER_PATH" \
            0755; then
            helper_restored=1
        else
            rollback_failed=1
        fi
        if caffeine_package_restore_one \
            "$CAFFEINE_HAD_OLD_PLIST" \
            "$CAFFEINE_OLD_PLIST" \
            "$CAFFEINE_DAEMON_PLIST" \
            0644; then
            plist_restored=1
        else
            rollback_failed=1
        fi
        caffeine_package_restore_one \
            "$CAFFEINE_HAD_OLD_UNINSTALLER" \
            "$CAFFEINE_OLD_UNINSTALLER" \
            "$CAFFEINE_UNINSTALLER_PATH" \
            0755 ||
            rollback_failed=1
    else
        rollback_failed=1
    fi

    if [[ "$CAFFEINE_SERVICE_WAS_LOADED" == "1" &&
          "$CAFFEINE_HAD_OLD_HELPER" == "1" &&
          "$CAFFEINE_HAD_OLD_PLIST" == "1" &&
          "$helper_restored" == "1" &&
          "$plist_restored" == "1" &&
          "$service_stopped" == "1" ]]; then
        if caffeine_package_service_is_loaded; then
            rollback_failed=1
        elif ! /bin/launchctl bootstrap \
            system \
            "$CAFFEINE_DAEMON_PLIST" >/dev/null 2>&1; then
            rollback_failed=1
        elif ! caffeine_package_wait_until_running; then
            rollback_failed=1
        fi
    elif [[ "$CAFFEINE_SERVICE_WAS_LOADED" == "1" ]]; then
        rollback_failed=1
    fi

    if [[ "$rollback_failed" == "1" ]]; then
        CAFFEINE_PRESERVE_STAGING=1
        printf '%s\n' \
            "warning: automatic rollback was incomplete; inspect only:" \
            "  $CAFFEINE_HELPER_PATH" \
            "  $CAFFEINE_DAEMON_PLIST" \
            "  $CAFFEINE_UNINSTALLER_PATH" \
            "root-only recovery backups were preserved at:" \
            "  $CAFFEINE_STAGING_DIRECTORY" >&2
    fi

    if [[ "$rollback_failed" == "0" &&
          "${CAFFEINE_CREATED_HELPER_DIRECTORY:-0}" == "1" ]]; then
        /bin/rmdir "$CAFFEINE_HELPER_DIRECTORY" 2>/dev/null ||
            true
    fi
}

caffeine_package_clean_temporary_files() {
    if [[ -n "${CAFFEINE_PUBLISH_TEMPORARY:-}" ]]; then
        case "$CAFFEINE_PUBLISH_TEMPORARY" in
            "$CAFFEINE_HELPER_DIRECTORY"/.*|"$CAFFEINE_DAEMON_DIRECTORY"/.*)
                /bin/rm -f -- "$CAFFEINE_PUBLISH_TEMPORARY"
                ;;
        esac
    fi

    if [[ "${CAFFEINE_PRESERVE_STAGING:-0}" == "1" ]]; then
        return
    fi
    if [[ -n "${CAFFEINE_STAGING_DIRECTORY:-}" ]]; then
        case "$CAFFEINE_STAGING_DIRECTORY" in
            /private/var/tmp/caffeine-helper-package.*)
                /bin/rm -f -- \
                    "${CAFFEINE_STAGED_HELPER:-}" \
                    "${CAFFEINE_STAGED_PLIST:-}" \
                    "${CAFFEINE_STAGED_UNINSTALLER:-}" \
                    "${CAFFEINE_OLD_HELPER:-}" \
                    "${CAFFEINE_OLD_PLIST:-}" \
                    "${CAFFEINE_OLD_UNINSTALLER:-}"
                /bin/rmdir \
                    "$CAFFEINE_STAGING_DIRECTORY" \
                    2>/dev/null ||
                    true
                ;;
        esac
    fi
}

caffeine_package_handle_exit() {
    local status="$?"

    trap - EXIT
    trap '' HUP INT TERM
    if [[ "$status" != "0" &&
          "${CAFFEINE_MUTATION_STARTED:-0}" == "1" &&
          "${CAFFEINE_INSTALLATION_COMMITTED:-0}" == "0" ]]; then
        caffeine_package_restore_previous_installation
    fi
    caffeine_package_clean_temporary_files
    exit "$status"
}

caffeine_package_install() {
    local target_volume="$1"
    local expected_requirement
    local installed_hash
    local staged_hash

    CAFFEINE_STAGING_DIRECTORY=""
    CAFFEINE_STAGED_HELPER=""
    CAFFEINE_STAGED_PLIST=""
    CAFFEINE_STAGED_UNINSTALLER=""
    CAFFEINE_OLD_HELPER=""
    CAFFEINE_OLD_PLIST=""
    CAFFEINE_OLD_UNINSTALLER=""
    CAFFEINE_PUBLISH_TEMPORARY=""
    CAFFEINE_HAD_OLD_HELPER=0
    CAFFEINE_HAD_OLD_PLIST=0
    CAFFEINE_HAD_OLD_UNINSTALLER=0
    CAFFEINE_SERVICE_WAS_LOADED=0
    CAFFEINE_CREATED_HELPER_DIRECTORY=0
    CAFFEINE_PRESERVE_STAGING=0
    CAFFEINE_MUTATION_STARTED=0
    CAFFEINE_INSTALLATION_COMMITTED=0

    trap caffeine_package_handle_exit EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    caffeine_package_require_root_target "$target_volume"
    caffeine_package_require_app_not_running
    caffeine_package_validate_source_app
    expected_requirement="$(caffeine_package_derive_app_requirement)"

    caffeine_package_require_secure_system_directory "/Library" 755
    caffeine_package_require_secure_system_directory \
        "$CAFFEINE_DAEMON_DIRECTORY" \
        755
    if caffeine_package_path_exists "$CAFFEINE_HELPER_DIRECTORY"; then
        caffeine_package_require_secure_system_directory \
            "$CAFFEINE_HELPER_DIRECTORY" \
            755
    fi
    caffeine_package_require_existing_metadata_or_absent \
        "$CAFFEINE_HELPER_PATH" \
        755 \
        "existing Caffeine helper"
    caffeine_package_require_existing_metadata_or_absent \
        "$CAFFEINE_DAEMON_PLIST" \
        644 \
        "existing Caffeine LaunchDaemon plist"
    caffeine_package_require_existing_metadata_or_absent \
        "$CAFFEINE_UNINSTALLER_PATH" \
        755 \
        "existing Caffeine root uninstaller"

    CAFFEINE_STAGING_DIRECTORY="$(
        /usr/bin/mktemp \
            -d \
            /private/var/tmp/caffeine-helper-package.XXXXXX
    )"
    CAFFEINE_STAGED_HELPER="$CAFFEINE_STAGING_DIRECTORY/new-helper"
    CAFFEINE_STAGED_PLIST="$CAFFEINE_STAGING_DIRECTORY/new.plist"
    CAFFEINE_STAGED_UNINSTALLER="$CAFFEINE_STAGING_DIRECTORY/new-uninstaller"
    CAFFEINE_OLD_HELPER="$CAFFEINE_STAGING_DIRECTORY/old-helper"
    CAFFEINE_OLD_PLIST="$CAFFEINE_STAGING_DIRECTORY/old.plist"
    CAFFEINE_OLD_UNINSTALLER="$CAFFEINE_STAGING_DIRECTORY/old-uninstaller"

    /usr/bin/install \
        -o root \
        -g wheel \
        -m 0755 \
        "$CAFFEINE_PACKAGE_HELPER" \
        "$CAFFEINE_STAGED_HELPER"
    /usr/bin/install \
        -o root \
        -g wheel \
        -m 0644 \
        "$CAFFEINE_PACKAGE_PLIST" \
        "$CAFFEINE_STAGED_PLIST"
    /usr/bin/plutil \
        -replace EnvironmentVariables.CAFFEINE_APP_REQUIREMENT \
        -string "$expected_requirement" \
        "$CAFFEINE_STAGED_PLIST"
    /usr/bin/install \
        -o root \
        -g wheel \
        -m 0755 \
        "$CAFFEINE_PACKAGE_UNINSTALLER" \
        "$CAFFEINE_STAGED_UNINSTALLER"

    caffeine_package_require_universal_binary \
        "$CAFFEINE_STAGED_HELPER" \
        "staged CaffeineHelper"
    caffeine_package_require_ad_hoc_signature \
        "$CAFFEINE_STAGED_HELPER" \
        "$CAFFEINE_HELPER_LABEL" \
        "staged CaffeineHelper"
    caffeine_package_validate_plist \
        "$CAFFEINE_STAGED_PLIST" \
        "$expected_requirement"
    /bin/bash -n "$CAFFEINE_STAGED_UNINSTALLER" ||
        caffeine_package_fail "staged root uninstaller has invalid syntax"

    if caffeine_package_path_exists "$CAFFEINE_HELPER_PATH"; then
        /usr/bin/install -m 0600 \
            "$CAFFEINE_HELPER_PATH" \
            "$CAFFEINE_OLD_HELPER"
        CAFFEINE_HAD_OLD_HELPER=1
    fi
    if caffeine_package_path_exists "$CAFFEINE_DAEMON_PLIST"; then
        /usr/bin/install -m 0600 \
            "$CAFFEINE_DAEMON_PLIST" \
            "$CAFFEINE_OLD_PLIST"
        CAFFEINE_HAD_OLD_PLIST=1
    fi
    if caffeine_package_path_exists "$CAFFEINE_UNINSTALLER_PATH"; then
        /usr/bin/install -m 0600 \
            "$CAFFEINE_UNINSTALLER_PATH" \
            "$CAFFEINE_OLD_UNINSTALLER"
        CAFFEINE_HAD_OLD_UNINSTALLER=1
    fi

    if caffeine_package_service_is_loaded; then
        caffeine_package_require_loaded_service_paths
        [[ "$CAFFEINE_HAD_OLD_HELPER" == "1" &&
           "$CAFFEINE_HAD_OLD_PLIST" == "1" ]] ||
            caffeine_package_fail \
                "loaded helper does not have both expected files"
        CAFFEINE_SERVICE_WAS_LOADED=1
    fi

    # This second complete check immediately precedes the privileged mutation.
    caffeine_package_require_app_not_running
    caffeine_package_validate_source_app
    [[ "$(caffeine_package_derive_app_requirement)" \
        == "$expected_requirement" ]] ||
        caffeine_package_fail \
            "the app signature changed while the helper was being staged"
    caffeine_package_validate_plist \
        "$CAFFEINE_PACKAGE_PLIST" \
        ""
    caffeine_package_require_existing_metadata_or_absent \
        "$CAFFEINE_HELPER_PATH" \
        755 \
        "existing Caffeine helper"
    caffeine_package_require_existing_metadata_or_absent \
        "$CAFFEINE_DAEMON_PLIST" \
        644 \
        "existing Caffeine LaunchDaemon plist"
    caffeine_package_require_existing_metadata_or_absent \
        "$CAFFEINE_UNINSTALLER_PATH" \
        755 \
        "existing Caffeine root uninstaller"
    if caffeine_package_service_is_loaded; then
        caffeine_package_require_loaded_service_paths
        [[ "$CAFFEINE_HAD_OLD_HELPER" == "1" &&
           "$CAFFEINE_HAD_OLD_PLIST" == "1" ]] ||
            caffeine_package_fail \
                "newly loaded helper does not have both expected files"
        CAFFEINE_SERVICE_WAS_LOADED=1
    elif [[ "$CAFFEINE_SERVICE_WAS_LOADED" == "1" ]]; then
        caffeine_package_fail \
            "the previous helper's launchd state changed during validation"
    fi

    CAFFEINE_MUTATION_STARTED=1
    if ! caffeine_package_path_exists "$CAFFEINE_HELPER_DIRECTORY"; then
        /usr/bin/install \
            -d \
            -o root \
            -g wheel \
            -m 0755 \
            "$CAFFEINE_HELPER_DIRECTORY"
        CAFFEINE_CREATED_HELPER_DIRECTORY=1
    fi
    caffeine_package_require_secure_system_directory \
        "$CAFFEINE_HELPER_DIRECTORY" \
        755
    if [[ "$CAFFEINE_SERVICE_WAS_LOADED" == "1" ]]; then
        /bin/launchctl bootout "system/$CAFFEINE_HELPER_LABEL" ||
            caffeine_package_fail \
                "could not boot out the previous Caffeine helper"
        caffeine_package_wait_until_unloaded ||
            caffeine_package_fail \
                "the previous Caffeine helper did not stop"
    fi

    caffeine_package_publish_file \
        "$CAFFEINE_STAGED_HELPER" \
        "$CAFFEINE_HELPER_PATH" \
        0755 ||
        caffeine_package_fail \
            "could not publish the Caffeine helper executable"
    caffeine_package_publish_file \
        "$CAFFEINE_STAGED_PLIST" \
        "$CAFFEINE_DAEMON_PLIST" \
        0644 ||
        caffeine_package_fail \
            "could not publish the Caffeine LaunchDaemon plist"
    caffeine_package_publish_file \
        "$CAFFEINE_STAGED_UNINSTALLER" \
        "$CAFFEINE_UNINSTALLER_PATH" \
        0755 ||
        caffeine_package_fail \
            "could not publish the root-owned Caffeine uninstaller"

    [[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$CAFFEINE_HELPER_PATH")" \
        == "root:wheel:755" ]] ||
        caffeine_package_fail \
            "installed helper ownership or mode is invalid"
    [[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$CAFFEINE_DAEMON_PLIST")" \
        == "root:wheel:644" ]] ||
        caffeine_package_fail \
            "installed plist ownership or mode is invalid"
    [[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$CAFFEINE_UNINSTALLER_PATH")" \
        == "root:wheel:755" ]] ||
        caffeine_package_fail \
            "installed uninstaller ownership or mode is invalid"
    caffeine_package_require_existing_metadata_or_absent \
        "$CAFFEINE_HELPER_PATH" \
        755 \
        "installed Caffeine helper"
    caffeine_package_require_existing_metadata_or_absent \
        "$CAFFEINE_DAEMON_PLIST" \
        644 \
        "installed Caffeine LaunchDaemon plist"
    caffeine_package_require_existing_metadata_or_absent \
        "$CAFFEINE_UNINSTALLER_PATH" \
        755 \
        "installed Caffeine root uninstaller"
    caffeine_package_require_universal_binary \
        "$CAFFEINE_HELPER_PATH" \
        "installed CaffeineHelper"
    caffeine_package_require_ad_hoc_signature \
        "$CAFFEINE_HELPER_PATH" \
        "$CAFFEINE_HELPER_LABEL" \
        "installed CaffeineHelper"
    caffeine_package_validate_plist \
        "$CAFFEINE_DAEMON_PLIST" \
        "$expected_requirement"
    /bin/bash -n "$CAFFEINE_UNINSTALLER_PATH" ||
        caffeine_package_fail \
            "installed root uninstaller has invalid syntax"

    installed_hash="$(
        /usr/bin/shasum -a 256 "$CAFFEINE_HELPER_PATH" |
            /usr/bin/awk '{ print $1 }'
    )"
    staged_hash="$(
        /usr/bin/shasum -a 256 "$CAFFEINE_STAGED_HELPER" |
            /usr/bin/awk '{ print $1 }'
    )"
    [[ "$installed_hash" == "$staged_hash" ]] ||
        caffeine_package_fail \
            "installed helper does not match the packaged helper"

    /bin/launchctl bootstrap system "$CAFFEINE_DAEMON_PLIST" ||
        caffeine_package_fail "could not bootstrap the Caffeine helper"
    caffeine_package_wait_until_running ||
        caffeine_package_fail \
            "the Caffeine helper did not reach the running state"
    caffeine_package_require_loaded_service_paths

    caffeine_package_require_app_not_running
    caffeine_package_validate_source_app
    [[ "$(caffeine_package_derive_app_requirement)" \
        == "$expected_requirement" ]] ||
        caffeine_package_fail \
            "Caffeine.app changed before helper verification completed"

    printf '%s\n' \
        "Installed and started the Caffeine helper:" \
        "  $CAFFEINE_HELPER_PATH" \
        "  $CAFFEINE_DAEMON_PLIST" \
        "Safe removal command:" \
        "  sudo /bin/bash \"$CAFFEINE_UNINSTALLER_PATH\"" ||
        true
    CAFFEINE_INSTALLATION_COMMITTED=1
}
