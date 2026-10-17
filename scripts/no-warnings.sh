#!/bin/bash
# Runs a build command and fails if it fails or prints a single warning, from any tool: the Swift compiler leaves a few
# diagnostics as warnings even with warnings-as-errors (such as data-race checks about older Apple APIs), and the
# linker, SwiftPM and speexdsp's configure and make print their own.
#
# Usage: scripts/no-warnings.sh COMMAND...

"$@" 2>&1 | tee /dev/stderr | grep -i "warning:" > /dev/null
statuses=("${PIPESTATUS[@]}")
if [ "${statuses[0]}" -ne 0 ]; then
    exit "${statuses[0]}"
fi
if [ "${statuses[2]}" -eq 0 ]; then
    echo "error: the build printed warnings (above), and warnings fail the build" >&2
    exit 1
fi
