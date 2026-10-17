#!/bin/bash
# Line coverage of totalrecall by the integration tests. Runs tests/run.sh against a build instrumented for coverage
# (make coverage builds it), prints a per-file report, writes an HTML one, and fails if the tests cover less than
# COVERAGE_MIN percent of the lines. Without the test devices it still runs the scenarios that need none and reports
# their coverage, but does not hold that partial number to the minimum.
#
# Usage: tests/coverage.sh BINARY [scenario ...]     (COVERAGE_MIN defaults to 0; the report goes to REPORT)

set -u

root="$(cd "$(dirname "$0")/.." && pwd)"
binary="$1"
shift
report="${REPORT:-$root/tests/build/coverage}"
minimum="${COVERAGE_MIN:-0}"

# A fresh folder each run, so profiles from an earlier run or another build never get merged in.
profiles=$(mktemp -d "${TMPDIR:-/tmp}/totalrecall-coverage.XXXXXX") || exit 2

# Every totalrecall process writes its own profile when it exits; one killed with SIGKILL writes none.
TOTALRECALL="$binary" LLVM_PROFILE_FILE="$profiles/%p.profraw" SKIP_MISSING_DEVICES=1 "$root/tests/run.sh" "$@"
tests_status=$?
# 3: the scenarios that ran passed, but those needing the test devices were skipped.
partial=0
if [ "$tests_status" -eq 3 ]; then
    partial=1
    tests_status=0
fi

if ! ls "$profiles"/*.profraw >/dev/null 2>&1; then
    echo "no coverage profiles in $profiles: did $binary run?" >&2
    exit 2
fi
mkdir -p "$report"
xcrun llvm-profdata merge -sparse -o "$report/totalrecall.profdata" "$profiles"/*.profraw || exit 2

xcrun llvm-cov report "$binary" -instr-profile="$report/totalrecall.profdata" | tee "$report/report.txt"
xcrun llvm-cov show "$binary" -instr-profile="$report/totalrecall.profdata" -format=html -output-dir="$report/html" \
    -show-line-counts-or-regions -project-title=totalrecall || exit 2
coverage=$(xcrun llvm-cov export "$binary" -instr-profile="$report/totalrecall.profdata" -summary-only |
    jq '.data[0].totals.lines.percent * 100 | round / 100')

if [ "$partial" -eq 1 ]; then
    summary="line coverage: ${coverage}%, partial: scenarios needing the test devices were skipped, so the ${minimum}% minimum is not checked"
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
