#!/usr/bin/env bash
set -euo pipefail

BTRFS_ROOT="/btrfs"
ZOMBOID_SUBVOL="@zomboid"
LOCK_FILE="/run/lock/zomboid-reaper.lock"
GRACE_PERIOD=600
ZOMBOID_CLI="/usr/local/bin/zomboid-cli"
SERVICE="zomboid-server"

fail() {
    echo "Error: $1" >&2
    exit 1
}

# Pre-flight
acquire_lock() {
    exec 9>"$LOCK_FILE"
    flock -n 9 || { echo "Another run in progress, exiting."; exit 0; }
}

check_root() {
    [[ "$EUID" -eq 0 ]] || fail "This script must be run as root."
}

# A stopped server counts as empty, so forgotten instances get reaped too.
get_player_count() {
    local out

    if ! systemctl is-active --quiet "$SERVICE"; then
        echo 0
        return
    fi

    out="$("$ZOMBOID_CLI" players)" || fail "'zomboid-cli players' failed. Is RCON up yet?"
    [[ "$out" =~ Players\ connected\ \(([0-9]+)\) ]] || fail "Unexpected 'zomboid-cli players' output: $out"
    echo "${BASH_REMATCH[1]}"
}

current_datetime() {
    date +"%Y%m%d-%H%M%S"
}

# Main
acquire_lock
check_root

count="$(get_player_count)"
if (( count > 0 )); then
    echo "${count} player(s) connected, nothing to do."
    exit 0
fi

echo "No players connected, checking again in $((GRACE_PERIOD / 60)) minutes."
sleep "$GRACE_PERIOD"

count="$(get_player_count)"
if (( count > 0 )); then
    echo "${count} player(s) connected after waiting, nothing to do."
    exit 0
fi

echo "Server still empty, stopping ${SERVICE}."
systemctl stop "$SERVICE"

snapshot="${ZOMBOID_SUBVOL}-$(current_datetime)"
btrfs subvolume snapshot "${BTRFS_ROOT}/${ZOMBOID_SUBVOL}" "${BTRFS_ROOT}/${snapshot}"
echo "Created snapshot '${snapshot}'."

echo "Powering off the instance."
systemctl poweroff
