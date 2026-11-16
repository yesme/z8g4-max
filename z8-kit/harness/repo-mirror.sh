#!/usr/bin/env bash
# Push every branch and tag of the repositories under WORK to bare mirrors on /data/other.
set -euo pipefail
export LC_ALL=C

work=${Z8_MIRROR_WORK:-/srv/work/$USER}
dest=${Z8_MIRROR_DEST:-/data/other/git-mirror/$USER}
mount=${Z8_MIRROR_MOUNT:-/data/other}
[[ $# == 0 ]] || { echo "Usage: $0 (set Z8_MIRROR_WORK or Z8_MIRROR_DEST to override)" >&2; exit 2; }
# Without this check an unmounted pool would leave the copy on the P4618 root.
[[ $(findmnt -rn -M "$mount" -o FSTYPE) == zfs ]] || { echo "$mount is not the mounted ZFS dataset" >&2; exit 1; }
mkdir -p -- "$dest"

status=0
for git_dir in "$work"/*/.git; do
    # Linked worktrees have a .git file and share the main repository's refs.
    [[ -d "$git_dir" ]] || continue
    repo=$(dirname -- "$git_dir")
    mirror="$dest/$(basename -- "$repo").git"
    [[ -d "$mirror" ]] || git init --quiet --bare -- "$mirror"
    # No --prune: a branch deleted by mistake stays in the mirror.
    if git -C "$repo" push --quiet -- "$mirror" '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'; then
        printf 'Mirrored %s\n' "$repo"
    else
        printf 'Failed to mirror %s\n' "$repo" >&2
        status=1
    fi
done
exit "$status"
