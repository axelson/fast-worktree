# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# fw changes — what this worktree changes relative to its stack parent
# (trunk under the none backend), from the merge-base, including
# uncommitted work.

cmd_changes() {
    local stat=false name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stat) stat=true; shift ;;
            -*) echo "Error: unknown flag '$1'" >&2; return 1 ;;
            *) name="$1"; shift ;;
        esac
    done

    resolve_worktree "$name" || return 1
    _ensure_trunk

    local branch parent base
    branch="$(git -C "$WT_PATH" branch --show-current 2>/dev/null || true)"
    parent="$(stack_parent "$branch")"
    if ! base="$(git -C "$WT_PATH" merge-base "$parent" HEAD 2>/dev/null)"; then
        echo "Error: cannot find a merge base with '$parent'" >&2
        return 1
    fi

    local args=(diff)
    if [[ "$stat" == true ]]; then
        args+=(--stat)
    fi
    git -C "$WT_PATH" "${args[@]}" "$base"
    return 0
}
