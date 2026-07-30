#!/bin/bash

# Shared read-only validation primitives. This file is sourced by artifact
# validators after they define PLIST_BUDDY; it deliberately changes no shell
# options or global validation policy.

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_equal() {
    local actual="$1"
    local expected="$2"
    local description="$3"
    [[ "$actual" == "$expected" ]] ||
        fail "$description is '$actual'; expected '$expected'"
}

plist_value() {
    local plist="$1"
    local key_path="$2"
    "$PLIST_BUDDY" -c "Print :$key_path" "$plist" 2>/dev/null
}

signature_details() {
    /usr/bin/codesign --display --verbose=4 "$1" 2>&1
}

signature_field() {
    local details="$1"
    local field="$2"
    printf '%s\n' "$details" |
        /usr/bin/awk -F= -v field="$field" '
            $1 == field {
                value = substr($0, length(field) + 2)
                print value
                exit
            }
        '
}
