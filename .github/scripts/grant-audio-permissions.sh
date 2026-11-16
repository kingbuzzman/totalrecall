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
user_database="$runner_home/Library/Application Support/com.apple.TCC/TCC.db"

# The microphone's grant is the user's, in their own database, which some runner images (macOS 27's) have not made
# yet: without it, totalrecall asks, and waits for an answer nobody can give. Made here as a copy of the system's, its
# layout and version, with none of its grants; the user's tccd, restarted below, then reads it.
made_user_database=false
if [ ! -f "$user_database" ] && [ -f "$system_database" ]; then
    mkdir -p "$(dirname "$user_database")"
    cp "$system_database" "$user_database"
    sqlite3 "$user_database" "DELETE FROM access;"
    chown -R "$runner_user" "$(dirname "$user_database")"
    made_user_database=true
    echo "made $user_database"
fi

for database in "$system_database" "$user_database"; do
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

# A tccd that started before the user's database was made would not see it; launchd starts it again when asked.
if [ "$made_user_database" = true ]; then
    pkill -x -u "$runner_user" tccd || true
fi
