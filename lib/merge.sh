# shellcheck disable=SC2154  # config globals (repo_root, worktrees_dir, ...) are
# assigned by load_config; WT_NAME/WT_PATH/WT_BRANCH are set by resolve_worktree
# and read_worktree_env in other lib files.
#
# fw merge — merge a worktree's branch into the main worktree's current branch,
# then delete the worktree. Local only: never pushes. See docs/specs/fw-merge.md.
#
# The branch merged (and later deleted) is the one recorded in the worktree's
# env file at create time, exactly as `fw delete` chooses its branch — never
# whatever happens to be checked out in the worktree now.

# cmd_merge [--no-ff | --ff-only] [-y|--yes] [--no-sync] <name-or-branch>
cmd_merge() {
    local no_ff=false ff_only=false assume_yes=false sync=true name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-ff)   no_ff=true; shift ;;
            --ff-only) ff_only=true; shift ;;
            -y|--yes)  assume_yes=true; shift ;;
            --no-sync) sync=false; shift ;;
            -*) echo "Error: unknown flag '$1'" >&2; return 1 ;;
            *)  name="$1"; shift ;;
        esac
    done

    # Pure argument errors — reject before touching anything.
    if [[ "$no_ff" == true && "$ff_only" == true ]]; then
        echo "Error: --no-ff and --ff-only are mutually exclusive" >&2
        return 1
    fi
    if [[ -z "$name" ]]; then
        echo "Error: usage: fw merge [--no-ff|--ff-only] [-y] <name-or-branch>" >&2
        return 1
    fi

    # Resolve to a managed worktree (errors when none exists for the name/branch).
    resolve_worktree "$name" || return 1

    local branch=""
    if read_worktree_env "$WT_PATH" 2>/dev/null; then
        # shellcheck disable=SC2153  # WT_BRANCH is set by read_worktree_env
        branch="$WT_BRANCH"
    fi
    if [[ -z "$branch" ]]; then
        echo "Error: worktree '$WT_NAME' has no recorded branch to merge" >&2
        return 1
    fi

    # We can't cd the shell out of a directory we're about to delete (fw has no
    # eval convention; `fw switch` uses tmux). Refuse the one case that would
    # strand the caller's shell in a removed directory.
    local rp_pwd rp_wt
    rp_pwd="$(realpath "$PWD" 2>/dev/null || echo "$PWD")"
    rp_wt="$(realpath "$WT_PATH" 2>/dev/null || echo "$WT_PATH")"
    if [[ "$rp_pwd" == "$rp_wt" || "$rp_pwd" == "$rp_wt"/* ]]; then
        echo "Error: cannot merge from inside the worktree being deleted — run from the main worktree (fw sw main) or elsewhere" >&2
        return 1
    fi

    _ensure_trunk
    local trunk current
    trunk="$(trunk_branch)"
    if [[ "$branch" == "$trunk" ]]; then
        echo "Error: refusing to merge the trunk branch ($branch)" >&2
        return 1
    fi
    current="$(git -C "$repo_root" branch --show-current 2>/dev/null || true)"
    if [[ -n "$current" && "$branch" == "$current" ]]; then
        echo "Error: the main worktree is already on '$branch' — nothing to merge" >&2
        return 1
    fi

    # Source worktree: no tracked (uncommitted) changes. Untracked is allowed,
    # with confirmation below. Reuse the shared pathspecs so fw's own setup
    # artifacts (env file, hook-created files) never read as user work.
    local -a _pathspecs=()
    local _ps
    while IFS= read -r _ps; do _pathspecs+=("$_ps"); done \
        < <(_dirty_check_pathspecs "$WT_PATH")

    local porcelain tracked untracked
    porcelain="$(git -C "$WT_PATH" status --porcelain -- "${_pathspecs[@]}" 2>/dev/null || true)"
    # Drop untracked (`??`) lines, then the lone blank line `printf` adds when
    # porcelain is empty — what remains is tracked (staged or unstaged) work.
    tracked="$(printf '%s\n' "$porcelain" | grep -v '^??' | grep -v '^[[:space:]]*$' || true)"
    if [[ -n "$tracked" ]]; then
        echo "Error: worktree '$WT_NAME' has uncommitted tracked changes — commit or discard them first:" >&2
        printf '  %s\n' "${tracked//$'\n'/$'\n'  }" >&2
        return 1
    fi

    # Merge into a predictable state: the main worktree must be clean too.
    if [[ -n "$(git -C "$repo_root" status --porcelain 2>/dev/null | head -1)" ]]; then
        echo "Error: the main worktree has uncommitted changes — clean it up before merging" >&2
        return 1
    fi

    # Untracked files are destroyed by the delete step; confirm before merging so
    # a decline aborts the whole operation with nothing merged.
    untracked="$(printf '%s\n' "$porcelain" | grep '^??' | sed 's/^?? //' || true)"
    if [[ -n "$untracked" && "$assume_yes" != true ]]; then
        local -a u=()
        local line
        while IFS= read -r line; do [[ -n "$line" ]] && u+=("$line"); done <<<"$untracked"
        echo "Worktree '$WT_NAME' has untracked files that will be lost when it's deleted:"
        local i
        for i in "${!u[@]}"; do
            [[ "$i" -ge 5 ]] && break
            echo "  ${u[$i]}"
        done
        if [[ "${#u[@]}" -gt 5 ]]; then
            echo "  … and $(( ${#u[@]} - 5 )) more"
        fi
        local reply=""
        read -r -p "Merge and delete anyway? [y/N] " reply || reply=""
        case "$reply" in
            y | Y | yes | Yes) ;;
            *) echo "Aborted." >&2; return 1 ;;
        esac
    fi

    # Merge into the main worktree's current branch. --no-ff / --ff-only pass
    # through; the default is git's own fast-forward behavior. Fallback identity
    # lets a --no-ff merge commit succeed even when git user.* is unset.
    local -a merge_flags=()
    [[ "$no_ff" == true ]] && merge_flags+=(--no-ff)
    [[ "$ff_only" == true ]] && merge_flags+=(--ff-only)
    local id_args
    id_args="$(_git_identity_args "$repo_root")"
    echo "Merging $branch into ${current:-HEAD}..."
    # shellcheck disable=SC2086  # id_args is deliberately word-split
    if ! git -C "$repo_root" $id_args merge ${merge_flags[@]+"${merge_flags[@]}"} "$branch"; then
        # A content conflict leaves an in-progress merge; --abort restores the
        # clean checkout. A pre-flight failure (e.g. --ff-only that can't fast-
        # forward) starts no merge, so --abort is a harmless no-op there.
        git -C "$repo_root" merge --abort 2>/dev/null || true
        echo "Error: merge of $branch failed — aborted; worktree '$WT_NAME' left intact" >&2
        return 1
    fi

    # Merge succeeded: tear down the worktree with the same guarantees as
    # `fw delete` (hooks, DB drop, Claude archive, branch deletion). --force
    # because the confirmed untracked files would otherwise re-trip delete's
    # dirty guard.
    cmd_delete --force "$WT_NAME"

    # Keep the golden checkout current and compiled after the merge — but only
    # when it's on trunk, since `fw sync` fast-forwards trunk and would otherwise
    # switch a feature checkout away to trunk. --no-sync skips it entirely. The
    # merge and delete have already committed, so a sync failure surfaces
    # (non-zero) without undoing the merge — rerun `fw sync` to retry.
    if [[ "$sync" == true && "$current" == "$trunk" ]]; then
        cmd_sync || return 1
    fi
}
