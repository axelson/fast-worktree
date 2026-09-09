# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# The `none` stack backend: plain single-branch workflow, no stacking tool.
# Stack commands degrade to "a stack of one based on trunk".

none_stack_branches() {
    local current trunk
    current="$(git branch --show-current 2>/dev/null || true)"
    trunk="$(trunk_branch)"
    if [[ -n "$current" && "$current" != "$trunk" ]]; then
        echo "*$current"
    fi
    return 0
}

none_stack_parent() {
    trunk_branch
}

none_stack_track() {
    :
}

# Contract: after adopt, the branch exists locally. With a matching remote
# branch, the local branch is reset to the remote tip (even after a remote
# rewrite); errors clearly when it is checked out. With no matching remote
# branch, an existing local branch is adopted as-is at its current tip —
# silently when origin merely lacks the branch (the normal unpushed case),
# with a warning when origin was unreachable. A branch that exists neither on
# the remote nor locally is an error.
none_stack_adopt() {
    if git -C "$repo_root" fetch origin "$1" 2>/dev/null; then
        if git -C "$repo_root" show-ref -q --verify "refs/heads/$1"; then
            if ! git -C "$repo_root" branch -f "$1" "origin/$1" 2>/dev/null; then
                echo "Error: branch $1 is checked out; cannot update it in place" >&2
                return 1
            fi
        else
            git -C "$repo_root" branch --track "$1" "origin/$1" >/dev/null
        fi
        return 0
    fi

    # Fetch failed: adopt an existing local branch, or error if there's none.
    if git -C "$repo_root" show-ref -q --verify "refs/heads/$1"; then
        _stack_adopt_fallback_warn "$1"
        return 0
    fi
    echo "Error: branch $1 not found on origin or locally" >&2
    return 1
}

none_stack_delete_branch() {
    git -C "$repo_root" branch -D "$1" >/dev/null 2>&1
}

# The none backend has no rebase machinery — "a stack of one based on trunk"
# has nothing to restack. Fail clearly (the <worktree-dir> arg is ignored).
none_stack_restack() {
    echo "Error: restack needs a stack backend (set stack_backend=graphite)" >&2
    return 1
}

none_stack_sync() {
    git -C "$repo_root" fetch --prune origin 2>/dev/null || true
}
