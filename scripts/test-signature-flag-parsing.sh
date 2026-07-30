#!/bin/bash

set -euo pipefail

SCRIPT_DIRECTORY="$(
    cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P
)"
readonly SCRIPT_DIRECTORY

# shellcheck source=scripts/helper-package-common.sh
source "$SCRIPT_DIRECTORY/helper-package-common.sh"

details=$'Executable=/Applications/Caffeine.app/Contents/MacOS/Caffeine\nCodeDirectory v=20500 size=747 flags=0x10002(adhoc,runtime) hashes=12+7 location=embedded\nTeamIdentifier=not set'

caffeine_package_signature_has_flag "$details" "runtime" ||
    caffeine_package_fail "expected runtime signature flag to match"
caffeine_package_signature_has_flag "$details" "adhoc" ||
    caffeine_package_fail "expected ad-hoc signature flag to match"

if caffeine_package_signature_has_flag "$details" "runtime-prefix"; then
    caffeine_package_fail "a partial signature flag unexpectedly matched"
fi
if caffeine_package_signature_has_flag "$details" "linker-signed"; then
    caffeine_package_fail "a missing signature flag unexpectedly matched"
fi
if caffeine_package_signature_has_flag \
    "CodeDirectory v=20500 size=747 flags=0x10000 hashes=12+7 location=embedded" \
    "runtime"; then
    caffeine_package_fail "a numeric-only signature flag unexpectedly matched"
fi

printf '%s\n' "signature flag parsing tests passed"
