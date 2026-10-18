#!/bin/bash
# Runs a test command on a build instrumented for coverage (make coverage builds it) and reports the line coverage of
# Sources: the profiles of the test bundles plus those of the totalrecall and transcribe binaries the end-to-end tests
# run. Writes the report to COVERAGE_REPORT (build/coverage): report.txt and html. Fails below COVERAGE_MIN percent,
# unless the tests that need the BlackHole test devices were skipped, which leaves the coverage partial.
#
# Usage: scripts/coverage.sh PRODUCTS-DIRECTORY TEST-COMMAND...

set -u

products="$1"
shift
report="${COVERAGE_REPORT:-build/coverage}"
minimum="${COVERAGE_MIN:-0}"
mkdir -p "$report"

# A fresh folder each run, so profiles from an earlier run never get merged in.
profiles=$(mktemp -d "${TMPDIR:-/tmp}/totalrecall-coverage.XXXXXX") || exit 2
TOTALRECALL="$products/totalrecall" TRANSCRIBE="$products/transcribe" LLVM_PROFILE_FILE="$profiles/%m-%p.profraw" \
    "$@" 2>&1 | tee "$report/tests.log"
tests_status=${PIPESTATUS[0]}
partial=0
if grep -q "needs the BlackHole test devices" "$report/tests.log"; then partial=1; fi

if ! ls "$profiles"/*.profraw >/dev/null 2>&1; then
    echo "no coverage profiles in $profiles" >&2
    exit 2
fi
xcrun llvm-profdata merge -sparse -o "$report/coverage.profdata" "$profiles"/*.profraw || exit 2
objects=("$products/totalrecall")
# Only files: a bundle's Contents/MacOS can also hold its .dSYM folder.
for binary in "$products/transcribe" "$products"/*.xctest/Contents/MacOS/*; do
    if [ -f "$binary" ]; then objects+=(-object "$binary"); fi
done
options=(-instr-profile="$report/coverage.profdata" -ignore-filename-regex='/(Tests|build|\.build)/' "${objects[@]}")

xcrun llvm-cov report "${options[@]}" | tee "$report/report.txt"
xcrun llvm-cov show "${options[@]}" -format=html -output-dir="$report/html" -show-line-counts-or-regions \
    -project-title=totalrecall || exit 2
coverage=$(xcrun llvm-cov export "${options[@]}" -summary-only | jq '.data[0].totals.lines.percent * 100 | round / 100')

if [ "$partial" -eq 1 ]; then
    summary="line coverage: ${coverage}%, partial: the tests that need the test devices were skipped, so the ${minimum}% minimum is not checked"
else
    summary="line coverage: ${coverage}% (minimum ${minimum}%)"
fi
echo ""
echo "$summary; report in $report/html/index.html"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### Coverage"
        echo ""
        echo "$summary"
        echo ""
        echo '```'
        cat "$report/report.txt"
        echo '```'
    } >>"$GITHUB_STEP_SUMMARY"
fi

if [ "$tests_status" -ne 0 ]; then exit "$tests_status"; fi
if [ "$partial" -eq 0 ] && awk -v coverage="$coverage" -v minimum="$minimum" 'BEGIN { exit !(coverage < minimum) }'; then
    echo "coverage fell below ${minimum}%" >&2
    exit 1
fi
