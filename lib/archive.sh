# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# fw archive / restore / purge — park work without losing it.
# Archive commits loose files, removes the worktree (and its DB), keeps the
# branch, and logs the reason. Restore recreates the worktree from the
# branch. Purge permanently deletes an archived branch.

_archive_log() {
    echo "$worktrees_dir/.fw_archive_log"
}

# _archived_entry_for <name-or-branch> — echoes "name<TAB>branch" from one
# log row: the latest whose name matches, else the latest whose branch
# matches. Both fields always come from the same row.
_archived_entry_for() {
    local log
    log="$(_archive_log)"
    [[ -f "$log" ]] || return 1
    awk -F'\t' -v q="$1" '
        $2 == q { nn = $2; nb = $3 }
        $3 == q { bn = $2; bb = $3 }
        END {
            if (nn != "") { print nn "\t" nb; exit 0 }
            if (bn != "") { print bn "\t" bb; exit 0 }
            exit 1
        }
    ' "$log"
}

# _retire_archive_entry <name> <branch> — remove the consumed row(s).
_retire_archive_entry() {
    local log
    log="$(_archive_log)"
    [[ -f "$log" ]] || return 0
    local tmp="$log.tmp.$$"
    awk -F'\t' -v n="$1" -v b="$2" '!($2 == n && $3 == b)' "$log" >"$tmp"
    mv "$tmp" "$log"
}

# _check_untracked_archivable <wt_path> <files…> — refuse binaries and
# oversized files; committing them onto the branch would pollute the PR.
_check_untracked_archivable() {
    local wt_path="$1"
    shift
    local f mime size bad=""
    for f in "$@"; do
        [[ -n "$f" ]] || continue
        size="$(wc -c <"$wt_path/$f" 2>/dev/null | tr -d ' ')"
        if [[ -n "$size" && "$size" -gt 1048576 ]]; then
            bad+="  $f (${size} bytes)"$'\n'
            continue
        fi
        mime="$(file --mime-type -b "$wt_path/$f" 2>/dev/null)"
        case "$mime" in
            text/* | application/json | application/xml | inode/x-empty | "") ;;
            *) bad+="  $f (binary: $mime)"$'\n' ;;
        esac
    done
    if [[ -n "$bad" ]]; then
        echo "Error: refusing to archive untracked binary/large files — remove or gitignore them first:" >&2
        printf '%s' "$bad" >&2
        return 1
    fi
    return 0
}

# _git_identity_args <dir> — fallback identity so archive commits work on
# machines without global git config.
_git_identity_args() {
    if git -C "$1" config user.email >/dev/null 2>&1; then
        return 0
    fi
    echo "-c user.name=fast-worktree -c user.email=fw@localhost"
}

cmd_archive() {
    local reason="" name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --reason)
                if [[ $# -lt 2 ]]; then
                    echo "Error: --reason requires a value" >&2
                    return 1
                fi
                reason="$2"
                shift 2
                ;;
            --reason=*) reason="${1#--reason=}"; shift ;;
            -*) echo "Error: unknown flag '$1'" >&2; return 1 ;;
            *) name="$1"; shift ;;
        esac
    done
    if [[ -z "$reason" ]]; then
        echo "Error: a reason is required (fw archive --reason TEXT [name])" >&2
        return 1
    fi

    # --allow-main so we can *detect* the golden checkout (explicit or from cwd)
    # and refuse it with a clear message, rather than letting it fall through.
    resolve_worktree --allow-main "$name" || return 1
    # The golden checkout resolves to "main" but is never a lifecycle target:
    # archiving it would try to tear down repo_root. Refuse before any work.
    if [[ "$WT_NAME" == "main" ]]; then
        echo "Error: refusing to archive the golden checkout (main)" >&2
        return 1
    fi
    # shellcheck disable=SC2153  # WT_PATH set by resolve_worktree
    read_worktree_env "$WT_PATH" 2>/dev/null || WT_BRANCH=""

    # Archive is a branch-preserving operation; without a recorded branch the
    # log entry could never be restored or purged.
    if [[ -z "$WT_BRANCH" ]]; then
        echo "Error: worktree '$WT_NAME' has no recorded branch (missing env file?) — cannot archive safely; use fw delete instead" >&2
        return 1
    fi
    local current
    current="$(git -C "$WT_PATH" branch --show-current 2>/dev/null || true)"
    if [[ "$current" != "$WT_BRANCH" ]]; then
        echo "Error: worktree '$WT_NAME' has '$current' checked out but records '$WT_BRANCH' — the rescue commit would land on the wrong branch. Switch back or use fw delete." >&2
        return 1
    fi

    local modified
    modified="$(git -C "$WT_PATH" diff --name-only 2>/dev/null || true)"
    if [[ -n "$modified" ]]; then
        echo "Error: worktree has modified tracked files — commit or stash them first:" >&2
        printf '  %s\n' "${modified//$'\n'/$'\n'  }" >&2
        return 1
    fi
    local staged
    staged="$(git -C "$WT_PATH" diff --cached --name-only 2>/dev/null || true)"
    if [[ -n "$staged" ]]; then
        echo "Error: worktree has staged changes — commit them first" >&2
        return 1
    fi

    # Commit loose untracked files (except the env file) so nothing is lost.
    local untracked
    untracked="$(git -C "$WT_PATH" ls-files --others --exclude-standard -- ":(exclude)$env_file" 2>/dev/null || true)"
    if [[ -n "$untracked" ]]; then
        local -a untracked_files=()
        while IFS= read -r f; do untracked_files+=("$f"); done <<<"$untracked"
        _check_untracked_archivable "$WT_PATH" "${untracked_files[@]}" || return 1
        echo "Committing loose files..."
        local id_args
        id_args="$(_git_identity_args "$WT_PATH")"
        # Add the exact untracked list (already env- and ignore-filtered above).
        # `git add .` would abort on the gitignored env file ("paths are ignored").
        git -C "$WT_PATH" add -- "${untracked_files[@]}"
        # shellcheck disable=SC2086  # id_args is deliberately word-split
        git -C "$WT_PATH" $id_args commit -q -m "fw archive: loose files"
    fi

    db_drop_for_worktree "$WT_PATH"

    # Preserve Claude artifacts (gitignored, so the rescue commit can't keep
    # them) before the worktree is gone; a no-op when there's nothing to keep.
    archive_claude "$WT_PATH" false "$WT_BRANCH"

    echo "Archiving $WT_NAME (branch kept: ${WT_BRANCH:-unknown})..."
    _remove_worktree_dir "$WT_PATH"

    mkdir -p "$worktrees_dir"
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$WT_NAME" "${WT_BRANCH:-}" "$reason" >>"$(_archive_log)"
    regenerate_caddyfile
    echo "Archived $WT_NAME"
    return 0
}

cmd_restore() {
    local query="${1:-}"
    if [[ -z "$query" ]]; then
        echo "Error: usage: fw restore <name|branch>" >&2
        return 1
    fi

    local name branch
    if ! IFS=$'\t' read -r name branch < <(_archived_entry_for "$query"); then
        echo "Error: no archived entry found for '$query'" >&2
        return 1
    fi
    if [[ -z "$branch" ]]; then
        echo "Error: archived entry '$name' has no branch recorded — restore it manually" >&2
        return 1
    fi

    local wt_path="$worktrees_dir/$name"
    if [[ -e "$wt_path" ]]; then
        echo "Error: worktree '$name' already exists" >&2
        return 1
    fi

    echo "Restoring $name from branch $branch..."
    _materialize_worktree "$name" "$branch" || return 1

    # Pop the rescue commit so loose files return to untracked.
    if [[ "$(git -C "$wt_path" log -1 --format=%s 2>/dev/null)" == "fw archive: loose files" ]]; then
        git -C "$wt_path" reset -q HEAD~1
    fi

    # Copy back the archived Claude artifacts (dirs + files) the rescue commit
    # never carried (gitignored/excluded). Runs after _materialize_worktree so
    # it overwrites any template a post-create hook freshly stamped, and moves
    # them out of the archive dir — symmetric with retiring the log entry below.
    restore_claude "$wt_path" "$branch"

    _retire_archive_entry "$name" "$branch"
    echo "Restored $wt_path"
    return 0
}

# _purge_interactive — fzf multi-select over archived entries; purge each pick.
# An empty archive log is a message, not an error; a cancelled picker is a
# quiet no-op.
_purge_interactive() {
    local log
    log="$(_archive_log)"
    local entries=""
    if [[ -f "$log" ]]; then
        # The three archive-log parsers (_archived_entry_for, cmd_list_archived,
        # here) each re-read the "<ts>\t<name>\t<branch>\t<reason>" rows; a
        # shared iterator is a deferred cleanup. Newest first (awk reverse —
        # macOS has no `tac`). Only name+reason are shown/used, so the branch
        # field isn't carried into the picker.
        local _ts name _branch reason
        while IFS=$'\t' read -r _ts name _branch reason; do
            [[ -n "$name" ]] || continue
            entries+="${name}"$'\t'"${reason}"$'\n'
        done < <(awk '{ a[NR]=$0 } END { for (i=NR;i>=1;i--) print a[i] }' "$log")
    fi
    if [[ -z "$entries" ]]; then
        echo "No archived worktrees to purge."
        return 0
    fi

    local selected rc=0
    selected="$(printf '%s' "$entries" | _fzf_pick_line --multi --delimiter=$'\t' \
        --header='Select archived worktrees to purge (Tab: toggle, Enter: confirm)')" || rc=$?
    case $rc in
        0) ;;              # selection in $selected
        1) return 0 ;;     # cancelled / nothing selected — quiet no-op
        *) return 1 ;;     # fzf missing or real error (message already printed)
    esac

    local pname prc=0
    while IFS=$'\t' read -r pname _; do
        [[ -n "$pname" ]] || continue
        _purge_one "$pname" || prc=1
    done <<<"$selected"
    return "$prc"
}

cmd_purge() {
    local query="${1:-}"
    if [[ -z "$query" ]]; then
        _purge_interactive
        return
    fi
    _purge_one "$query"
}

_purge_one() {
    local query="$1"
    local name branch
    if ! IFS=$'\t' read -r name branch < <(_archived_entry_for "$query"); then
        echo "Error: '$query' has no archive entry — only archived branches can be purged (use fw delete for live worktrees)" >&2
        return 1
    fi
    if [[ -d "$worktrees_dir/$name" ]]; then
        echo "Error: worktree '$name' is live again — use fw delete instead of purge" >&2
        return 1
    fi

    echo "Purging branch $branch..."
    if ! stack_delete_branch "$branch"; then
        if git -C "$repo_root" show-ref -q --verify "refs/heads/$branch"; then
            echo "Error: branch $branch was not deleted (in use elsewhere?)" >&2
            return 1
        fi
    fi
    _retire_archive_entry "$name" "$branch"
    echo "Purged $branch"
    return 0
}

# cmd_list_archived — called from cmd_list --archived.
cmd_list_archived() {
    local log
    log="$(_archive_log)"
    if [[ ! -f "$log" ]]; then
        echo "No archived worktrees."
        return 0
    fi
    local _ts name branch reason
    while IFS=$'\t' read -r _ts name branch reason; do
        printf '%-20s %-28s %s\n' "$name" "$branch" "$reason"
    done <"$log"
    return 0
}
