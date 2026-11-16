#!/bin/bash
# Grants microphone and system-audio-recording permission on a CI machine, where nobody can click "Allow".
# It writes the grants straight into macOS's privacy (TCC) databases, which only works where System Integrity
# Protection is off, as on GitHub's macOS runners. It refuses to run outside CI.
#
# Usage: sudo --preserve-env=CI .github/scripts/grant-audio-permissions.sh [extra client path ...]

set -eu

if [ "${CI:-}" != "true" ]; then
    echo "refusing to edit TCC databases outside CI (CI=true is not set)" >&2
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "run with sudo" >&2
    exit 1
fi

runner_user="${SUDO_USER:-runner}"
runner_home=$(dscl . -read "/Users/$runner_user" NFSHomeDirectory | awk '{print $2}')

# macOS charges audio access to the "responsible" process: the app that launched the command. On a CI runner that is
# the runner agent rather than a terminal, so every likely parent gets the grant along with the binaries themselves.
clients=(
    /bin/bash
    /bin/sh
    /bin/zsh
    /usr/bin/env
    /usr/bin/make
    /usr/local/opt/runner/provisioner/provisioner
    /opt/hca/hosted-compute-agent
)
while IFS= read -r listener; do clients+=("$listener"); done < <(find "$runner_home" /opt /usr/local/opt -maxdepth 6 -name 'Runner.*' -type f -perm -u+x 2>/dev/null)
clients+=("$@")

services=(kTCCServiceMicrophone kTCCServiceAudioCapture kTCCServiceScreenCapture)
now=$(date +%s)

grant() {
    local database="$1" service="$2" client="$3"
    local columns names="" values=""
    columns=$(sqlite3 "$database" "SELECT name FROM pragma_table_info('access');")
    add() {
        if printf '%s\n' "$columns" | grep -qx "$1"; then
            names="$names${names:+, }$1"
            values="$values${values:+, }$2"
        fi
    }
    add service "'$service'"
    add client "'$client'"
    add client_type 1
    add auth_value 2
    add auth_reason 4
    add auth_version 1
    add indirect_object_identifier "'UNUSED'"
    add flags 0
    add last_modified "$now"
    add boot_uuid "'UNUSED'"
    add last_reminded 0
    sqlite3 "$database" "INSERT OR REPLACE INTO access ($names) VALUES ($values);"
}

system_database="/Library/Application Support/com.apple.TCC/TCC.db"
# The microphone's grant, and system audio's, are the user's, in their own database: in their Library until macOS 27,
# from macOS 27 in a ProtectedSystem container (as GitHub's own image setup finds it, in runner-images'
# configure-tccdb-macos-27.sh). Every one found is granted to; one tccd does not use is never read.
user_databases=()
if [ -f "$runner_home/Library/Application Support/com.apple.TCC/TCC.db" ]; then
    user_databases+=("$runner_home/Library/Application Support/com.apple.TCC/TCC.db")
fi
while IFS= read -r database; do user_databases+=("$database"); done < <(
    find /private/var/containers/Data/ProtectedSystem -mindepth 6 -maxdepth 6 -type f \
        -path "*/Data/Library/Application Support/com.apple.TCC/TCC.db" 2>/dev/null
)
if [ "${#user_databases[@]}" -eq 0 ]; then echo "found no user TCC database" >&2; fi

for database in "$system_database" ${user_databases[@]+"${user_databases[@]}"}; do
    if [ ! -f "$database" ]; then
        echo "skipping missing $database"
        continue
    fi
    for service in "${services[@]}"; do
        for client in "${clients[@]}"; do
            grant "$database" "$service" "$client" || echo "could not grant $service to $client in $database" >&2
        done
    done
    echo "granted ${services[*]} to ${#clients[@]} clients in $database"
done
