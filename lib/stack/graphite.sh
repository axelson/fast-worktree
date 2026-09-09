# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# The graphite stack backend. Reads go straight to Graphite's SQLite metadata
# (~7ms) instead of the gt CLI (~400ms Node startup); writes go through gt.

_graphite_db() {
    _graphite_metadata_db
}

graphite_stack_branches() {
    "$SCRIPT_DIR/scripts/gt-stack-fast.sh" "$repo_root" "$(trunk_branch)"
}

graphite_stack_parent() {
    local branch="${1//\'/\'\'}"
    local parent
    parent="$(sqlite3 "$(_graphite_db)" \
        "SELECT parent_branch_name FROM branch_metadata WHERE branch_name='$branch';" \
        2>/dev/null || true)"
    if [[ -n "$parent" ]]; then
        echo "$parent"
    else
        trunk_branch
    fi
}

# cwd must be the worktree whose branch is being tracked.
graphite_stack_track() {
    gt track --parent "$2" --no-interactive
}

# gt get checks the fetched branch out in the golden checkout temporarily;
# require a clean tree and restore the original branch afterwards.
graphite_stack_adopt() {
    if [[ -n "$(git -C "$repo_root" status --porcelain 2>/dev/null | head -1)" ]]; then
        echo "Error: the golden checkout has uncommitted changes — gt get checks the branch out there temporarily; commit or stash first" >&2
        return 1
    fi
    local original
    original="$(git -C "$repo_root" branch --show-current 2>/dev/null || true)"
    if ! (cd "$repo_root" && gt get "$1"); then
        # gt get pulls the branch from the remote; when it can't (e.g. the
        # branch isn't on the remote), fall back to an existing local branch.
        if ! git -C "$repo_root" show-ref -q --verify "refs/heads/$1"; then
            echo "Error: branch $1 not found on the remote or locally" >&2
            return 1
        fi
        _stack_adopt_fallback_warn "$1"
    fi
    if [[ -n "$original" && "$(git -C "$repo_root" branch --show-current 2>/dev/null)" != "$original" ]]; then
        git -C "$repo_root" checkout -q "$original"
    fi
    return 0
}

graphite_stack_delete_branch() {
    # gt delete removes branch + metadata. On gt failure, surface the error
    # and still delete the branch with git (the worktree is going away), but
    # say so — the metadata may now be stale. A branch that never existed
    # returns nonzero, matching the none backend.
    local existed=true err
    git -C "$repo_root" show-ref -q --verify "refs/heads/$1" || existed=false

    if err="$( (cd "$repo_root" && gt delete "$1" --force --no-interactive) 2>&1)"; then
        # Trust but verify: if gt claims success yet the ref survives, finish
        # the job with git — and if it STILL survives (checked out in another
        # worktree), say so instead of reporting success.
        if git -C "$repo_root" show-ref -q --verify "refs/heads/$1"; then
            git -C "$repo_root" branch -D "$1" >/dev/null 2>&1
            if git -C "$repo_root" show-ref -q --verify "refs/heads/$1"; then
                echo "Warning: branch $1 still exists (checked out elsewhere?) — its graphite metadata may already be gone" >&2
                return 1
            fi
        fi
        [[ "$existed" == true ]]
        return
    fi

    if [[ "$existed" == true ]]; then
        echo "Warning: gt delete failed (${err:-no output}); deleting $1 with git — graphite metadata may be stale" >&2
        git -C "$repo_root" branch -D "$1" >/dev/null 2>&1
    else
        return 1
    fi
}

# graphite_stack_restack <worktree-dir> — restack that worktree's branch and
# everything downstack of it onto the (already-restacked) parents. A conflict
# leaves the working tree mid-rebase, so abort the partial restack before
# returning failure: the caller is walking the stack and a stranded rebase would
# poison the next worktree. gt output goes to the terminal so the user sees the
# conflicting files.
graphite_stack_restack() {
    local dir="$1"
    if gt --cwd "$dir" restack --downstack; then
        return 0
    fi
    # Abort the partial restack. The real Graphite command is the standalone
    # `gt abort` (`-f` skips its confirmation); there is no `gt restack --abort`.
    gt --cwd "$dir" abort -f >/dev/null 2>&1 || true
    # The abort reset the tree, so there's nothing to "resolve" in place — the
    # actionable path is to re-run the restack in that worktree and drive it to
    # completion. Backend-specific, so the hint lives here, not in present.sh.
    echo "Restack conflict — the partial rebase was aborted. To finish it: cd into that worktree, run 'gt restack', resolve the conflicts, then 'gt continue'." >&2
    return 1
}

graphite_stack_sync() {
    (cd "$repo_root" && gt sync --no-interactive)
}
