#!/bin/bash
# Builds the synthetic-boundary ownership harness against a source tree with
# ASan/UBSan and runs every test in its own process.
#
#   tests/ownership/run.sh <source-root> <fixed|baseline>
#
# <source-root> provides the plugin sources and the bundled 4D Plugin API.
# The harness itself always comes from this script's directory, so the SAME
# harness can be run against an immutable baseline (git archive of the base
# SHA) and against the fixed tree.
#
# In "fixed" mode every test must pass. In "baseline" mode the tests named
# in EXPECTED_BASELINE_FAILURES must fail and every other test (the
# controls) must pass; anything else is a harness or model error.
set -euo pipefail

SRC=$(cd "$1" && pwd)
MODE=$2
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

EXPECTED_BASELINE_FAILURES="
defect_dormant_ob_get_a_result_not_cleared
defect_dormant_ob_get_n_wrong_kind_not_cleared
defect_dormant_ob_get_b_wrong_kind_not_cleared
defect_dormant_ob_get_c_reference_not_released
defect_dormant_ob_get_o_reference_not_released
hardening_ob_get_error_result_untouched
hardening_ob_stringify_error_result_untouched
"

SAN="-g -O1 -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=undefined"
# Same header search paths as the Xcode project; VersyPDF is never linked
# (engine_harness.cpp stubs the entry points the plugin uses).
INC=(-I "$SRC/4D Plugin API" -I "$SRC/4D Plugin API/Classes" -I "$SRC/support" -I "$SRC" -I "$SRC/include/versypdf")
WARN="-w"

objs=()
cc() { # <lang> <file> [extra flags...]
    local lang=$1 file=$2; shift 2
    local o="$OUT/$(basename "$file").o"
    xcrun clang $SAN $WARN -x "$lang" "${INC[@]}" "$@" -c "$file" -o "$o"
    objs+=("$o")
}

cc c "$SRC/4D Plugin API/4DPluginAPI.c" -Wno-multichar -Wno-error=int-conversion
for f in C_TEXT C_BLOB C_LONGINT; do
    cc objective-c++ "$SRC/4D Plugin API/Classes/$f.cpp" -std=c++17 -fno-objc-arc
done
cc objective-c++ "$SRC/support/4DPlugin-JSON.cpp" -std=c++17 -fno-objc-arc
# engine_harness.cpp #includes 4DPlugin-VersyPDF.cpp from $SRC.
cc objective-c++ "$HERE/engine_harness.cpp" -std=c++17 -fno-objc-arc

xcrun clang++ $SAN "${objs[@]}" -framework Foundation -framework CoreFoundation -framework CoreGraphics -o "$OUT/harness"

export ASAN_OPTIONS=abort_on_error=0:halt_on_error=1
export UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1

bad=0
for t in $("$OUT/harness" --list); do
    if "$OUT/harness" "$t" >"$OUT/$t.log" 2>&1; then got=pass; else got=fail; fi
    expect=pass
    if [ "$MODE" = baseline ] && grep -qx "$t" <<<"$EXPECTED_BASELINE_FAILURES"; then expect=fail; fi
    if [ "$got" = "$expect" ]; then status=OK; else status=UNEXPECTED; bad=1; fi
    printf '%-12s %-5s (expected %-4s) %s\n' "$status" "$got" "$expect" "$t"
    if [ "$got" = fail ]; then sed 's/^/    | /' "$OUT/$t.log"; fi
    # A sanitizer report or harness error is never an expected outcome.
    if grep -qE 'ERROR: AddressSanitizer|runtime error:|HARNESS ERROR' "$OUT/$t.log"; then
        echo "UNEXPECTED   sanitizer/harness error in $t"; bad=1
    fi
done

if [ $bad -ne 0 ]; then echo "RESULT ($MODE): FAILED"; exit 1; fi
echo "RESULT ($MODE): all outcomes as expected"
