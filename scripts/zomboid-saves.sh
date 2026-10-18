#!/usr/bin/env bash
set -euo pipefail

BTRFS_ROOT="/btrfs"
ZOMBOID_SUBVOL="@zomboid"
SNAPSHOT_PREFIX="@zomboid-"

fail() {
    echo "Error: $1" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  list                       List available ${SNAPSHOT_PREFIX}* snapshots to roll back to.
  rollback <snapshot-name>   Roll back ${ZOMBOID_SUBVOL} to the given ${SNAPSHOT_PREFIX}* snapshot.
  remove <snapshot-name>     Delete the given ${SNAPSHOT_PREFIX}* snapshot.
EOF
}

# Pre-flight
check_root() {
    [[ "$EUID" -eq 0 ]] || fail "This script must be run as root (btrfs subvolume operations require root)."
}

check_btrfs_cli() {
    command -v btrfs >/dev/null 2>&1 || fail "btrfs-progs is not installed or 'btrfs' is not on PATH."
}

check_btrfs_root() {
    mountpoint -q "$BTRFS_ROOT" || fail "$BTRFS_ROOT is not a mount point. Is the btrfs filesystem mounted?"
    [[ -d "${BTRFS_ROOT}/${ZOMBOID_SUBVOL}" ]] || fail "${BTRFS_ROOT}/${ZOMBOID_SUBVOL} not found. Is the '${ZOMBOID_SUBVOL}' subvolume present?"
}

# Subvolume helpers
get_snapshot_subvolumes() {
    btrfs subvolume list -o "$BTRFS_ROOT" 2>/dev/null | awk '{print $NF}' | grep -E "^${SNAPSHOT_PREFIX}" | sort || true
}

validate_snapshot_name() {
    local name="$1"

    case "$name" in
        "${SNAPSHOT_PREFIX}"*) ;;
        *) fail "'$name' is not a valid snapshot name, expected it to start with '${SNAPSHOT_PREFIX}'." ;;
    esac
}

check_snapshot_exists() {
    local name="$1"

    [[ -d "${BTRFS_ROOT}/${name}" ]] || fail "Snapshot '$name' does not exist under ${BTRFS_ROOT}."
}

confirm() {
    local prompt="$1" answer

    read -r -p "$prompt [y/N]: " answer
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || fail "Aborted."
}

current_datetime() {
    date +"%Y%m%d-%H%M%S"
}

## Command - list
cmd_list() {
    local snapshots
    snapshots="$(get_snapshot_subvolumes)"

    if [[ -z "$snapshots" ]]; then
        echo "There are no versions to roll back to."
        return
    fi

    echo "Available snapshots to roll back to:"
    while IFS= read -r name; do
        echo "  - $name"
    done <<< "$snapshots"
}

## Command - rollback
cmd_rollback() {
    local target="${1:-}" broken_name

    [[ -n "$target" ]] || fail "Usage: $(basename "$0") rollback <subvolume-name>"
    validate_snapshot_name "$target"
    check_snapshot_exists "$target"

    broken_name="${ZOMBOID_SUBVOL}-$(current_datetime)-broken"

    echo "The following will be done:"
    echo "  1. Stop the server"
    echo "  2. Rename the current version of the game -> '${broken_name}'"
    echo "  3. Recover '${target}'"
    echo "  4. Start the server again"
    confirm "Proceed with rollback to '${target}'?"

    systemctl stop zomboid-server
    mv "${BTRFS_ROOT}/${ZOMBOID_SUBVOL}" "${BTRFS_ROOT}/${broken_name}"
    btrfs subvolume snapshot "${BTRFS_ROOT}/${target}" "${BTRFS_ROOT}/${ZOMBOID_SUBVOL}"
    systemctl start zomboid-server

    echo "Rolled back '${ZOMBOID_SUBVOL}' to '${target}'. Previous data preserved as '${broken_name}'."
}

## Command - remove
cmd_remove() {
    local target="${1:-}"

    [[ -n "$target" ]] || fail "Usage: $(basename "$0") remove <subvolume-name>"
    validate_snapshot_name "$target"
    check_snapshot_exists "$target"

    echo "The following will be done:"
    echo "  - Delete subvolume '${target}'"
    confirm "Proceed with deleting '${target}'?"

    btrfs subvolume delete "${BTRFS_ROOT}/${target}"

    echo "Deleted snapshot '${target}'."
}

# Main
COMMAND="${1:-}"
[[ -n "$COMMAND" ]] || { usage; exit 1; }
shift

case "$COMMAND" in
    -h|--help) usage; exit 0 ;;
esac

check_root
check_btrfs_cli
check_btrfs_root

case "$COMMAND" in
    list)     cmd_list "$@" ;;
    rollback) cmd_rollback "$@" ;;
    remove)   cmd_remove "$@" ;;
    *)        usage; fail "Unknown command: $COMMAND" ;;
esac
