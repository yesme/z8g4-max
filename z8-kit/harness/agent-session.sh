#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: bash $0 <cli> <worktree> [cli arguments...]" >&2
    exit 2
fi
requested=$1
worktree=$(realpath -e -- "$2")
shift 2

case "$requested" in
    antigravity) cli=agy ;;
    qoder) cli=qodercn ;;
    minimax) cli=mcode ;;
    trae) cli=traecli ;;
    codex|claude|agy|grok|muse|kimi|zcode|opencode|qodercn|omp|pi|dsh|codebuddy|mcode|traecli)
        cli=$requested ;;
    *) echo "Unknown CLI: $requested" >&2; exit 2 ;;
esac

[[ -d "$worktree" ]] || { echo 'Worktree is not a directory' >&2; exit 2; }
cli_path=$(type -P "$cli") || { echo "Install $cli first" >&2; exit 1; }
project=$(basename -- "$worktree" | tr -c '[:alnum:]_-' '-')
fingerprint=$(printf '%s' "$worktree" | sha256sum | cut -c1-10)
session="agent-$cli-${project:0:36}-$fingerprint"

if tmux has-session -t "=$session" 2>/dev/null; then
    if [[ -n ${TMUX:-} ]]; then
        exec tmux switch-client -t "=$session"
    fi
    exec tmux attach-session -t "=$session"
fi
session_env=()
case "$cli" in
    omp|pi|dsh)
        if [[ -n ${DEEPSEEK_API_KEY:-} ]]; then
            session_env=(-e "DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY")
        fi
        ;;
esac
if [[ -n ${TMUX:-} ]]; then
    tmux new-session -d "${session_env[@]}" -s "$session" -c "$worktree" env -- "$cli_path" "$@"
    exec tmux switch-client -t "=$session"
fi
exec tmux new-session "${session_env[@]}" -s "$session" -c "$worktree" env -- "$cli_path" "$@"
