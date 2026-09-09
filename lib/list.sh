# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# fw list / fw info — read-only views over the worktrees directory.

# _worktree_dirty_markers <wt_path> — compact S:/M:/?: counts, empty if clean.
_worktree_dirty_markers() {
    local wt_path="$1"
    local staged=0 modified=0 untracked=0 line ps
    local -a pathspecs=()
    while IFS= read -r ps; do pathspecs+=("$ps"); done \
        < <(_dirty_check_pathspecs "$wt_path")
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        case "${line:0:2}" in
            '??') ((untracked++)) || true ;;
            ?' ' | ' '?) # one side only
                [[ "${line:0:1}" != ' ' ]] && ((staged++)) || true
                [[ "${line:1:1}" != ' ' ]] && ((modified++)) || true
                ;;
            *)
                ((staged++)) || true
                ((modified++)) || true
                ;;
        esac
    done < <(git -C "$wt_path" status --porcelain -- "${pathspecs[@]}" 2>/dev/null || true)

    local parts=()
    [[ $staged -gt 0 ]] && parts+=("S:$staged")
    [[ $modified -gt 0 ]] && parts+=("M:$modified")
    [[ $untracked -gt 0 ]] && parts+=("?:$untracked")
    local IFS=' '
    echo "${parts[*]:-}"
}

cmd_list() {
    local archived=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --archived) archived=true; shift ;;
            -*) echo "Error: unknown flag '$1'" >&2; return 1 ;;
            *) echo "Error: fw list takes no positional arguments" >&2; return 1 ;;
        esac
    done
    if [[ "$archived" == true ]]; then
        cmd_list_archived
        return
    fi

    local nb
    nb="$(worktree_names_branches)" || {
        echo "No worktrees yet — create one with: fw create <name>"
        return 0
    }

    # One Claude-agent fetch for the whole listing, bucketed under each worktree
    # name (waiting outranks running) so the per-row lookup below is a plain
    # array read, not a fork. Empty when claude is absent.
    local -A claude_by_wt=()
    build_claude_status_map claude_by_wt

    # Header row + dashes underline (felt-worktree parity). Plain, uncolored.
    printf '%-24s %-32s %-8s %s\n' "NAME" "BRANCH" "STATUS" "CHANGES"
    printf '%-24s %-32s %-8s %s\n' "----" "------" "------" "-------"

    local name branch markers claude cpre csuf
    while IFS=$'\t' read -r name branch; do
        markers="$(_worktree_dirty_markers "$worktrees_dir/$name")"
        claude="${claude_by_wt[$name]:-}"
        # Color the status cell; keep the escapes OUTSIDE the %-8s field so the
        # width padding counts visible characters, not escape bytes.
        cpre="" csuf=""
        case "$claude" in
            running) cpre="$C_GREEN"  csuf="$C_RESET" ;;
            waiting) cpre="$C_YELLOW" csuf="$C_RESET" ;;
        esac
        printf '%-24s %-32s %s%-8s%s %s\n' \
            "$name" "$branch" "$cpre" "$claude" "$csuf" "$markers"
    done <<<"$nb"
    return 0
}

cmd_info() {
    resolve_worktree "${1:-}" || return 1
    # shellcheck disable=SC2153  # WT_PATH is set by resolve_worktree
    read_worktree_env "$WT_PATH" || return 1

    echo "Worktree:  $WT_NAME"
    echo "Path:      $WT_PATH"
    echo "Branch:    $WT_BRANCH"
    echo "Port slot: $WT_PORT_SLOT"
    if [[ -n "$WT_DB_NAME" ]]; then
        echo "Database:  $WT_DB_NAME"
        echo "Test DB:   $WT_TEST_DB_NAME"
    fi
    echo "Project:   $project"
    echo "Repo:      $repo_root"
    return 0
}
