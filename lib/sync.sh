# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# fw sync — keep the golden checkout compiled and current so worktree
# creation stays instant. A three-layer sandwich:
#   1. core: fast-forward trunk from origin
#   2. project: hook_sync (build steps; unrecognized fw sync flags pass through)
#   3. core: stack backend sync

cmd_sync() {
    _ensure_trunk
    local trunk current
    trunk="$(trunk_branch)"
    current="$(git -C "$repo_root" branch --show-current 2>/dev/null || true)"
    if [[ "$current" != "$trunk" ]]; then
        if [[ -n "$(git -C "$repo_root" status --porcelain 2>/dev/null | head -1)" ]]; then
            echo "Error: the golden checkout is on '${current:-a detached HEAD}' with uncommitted changes." >&2
            echo "Clean it up and check out $trunk in $repo_root before syncing." >&2
            return 1
        fi
        echo "Golden checkout is on '${current:-a detached HEAD}' — checking out $trunk"
        git -C "$repo_root" checkout -q "$trunk"
    fi

    if git -C "$repo_root" remote get-url origin >/dev/null 2>&1; then
        echo "Syncing $trunk from origin..."
        git -C "$repo_root" fetch -q origin "$trunk"
        git -C "$repo_root" merge --ff-only "origin/$trunk"
    else
        echo "Note: no origin remote; skipping fetch"
    fi

    _export_fw_project_env
    run_hook hook_sync "$repo_root" fatal "$@" || return 1

    stack_sync

    echo "Golden checkout synced."
    return 0
}
