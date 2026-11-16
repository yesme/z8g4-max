#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp"/{bin,work,other}
cat > "$tmp/bin/findmnt" <<'MOCK'
#!/usr/bin/env bash
if [[ -e "$Z8_TEST/mounted" ]]; then echo zfs; fi
MOCK
chmod +x "$tmp/bin/findmnt"
export Z8_TEST="$tmp" PATH="$tmp/bin:$PATH" Z8_MIRROR_WORK="$tmp/work" Z8_MIRROR_DEST="$tmp/other/mirror" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
mirror() { bash z8-kit/harness/repo-mirror.sh; }

git init --quiet -b main "$tmp/work/example"
git -C "$tmp/work/example" commit --quiet --allow-empty -m first
git -C "$tmp/work/example" worktree add --quiet -b task/agent "$tmp/work/example-agent"
git -C "$tmp/work/example-agent" commit --quiet --allow-empty -m agent
if mirror 2>/dev/null; then echo 'Mirrored without the ZFS mount' >&2; exit 1; fi
[[ ! -e "$tmp/other/mirror" ]]
touch "$tmp/mounted"
mirror >/dev/null
bare="$tmp/other/mirror/example.git"
[[ ! -e "$tmp/other/mirror/example-agent.git" ]]
[[ $(git -C "$bare" rev-parse task/agent) == $(git -C "$tmp/work/example-agent" rev-parse HEAD) ]]
# A rewritten branch is updated; a branch deleted locally stays in the mirror.
git -C "$tmp/work/example" commit --quiet --amend --allow-empty -m rewritten
git -C "$tmp/work/example" worktree remove "$tmp/work/example-agent"
git -C "$tmp/work/example" branch --quiet -D task/agent
mirror >/dev/null
[[ $(git -C "$bare" rev-parse main) == $(git -C "$tmp/work/example" rev-parse main) ]]
git -C "$bare" rev-parse --quiet --verify task/agent >/dev/null
echo 'Repository mirror tests passed: mount guard, worktree branches, rewrite and deletion.'
