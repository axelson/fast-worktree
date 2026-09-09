load ../test_helper

setup() {
    isolate_env
    source "$FW_ROOT/lib/colors.sh"
    source "$FW_ROOT/lib/config.sh"
    source "$FW_ROOT/lib/hooks.sh"
    source "$FW_ROOT/lib/project.sh"
    source "$FW_ROOT/lib/envfile.sh"
    source "$FW_ROOT/lib/cow.sh"
    source "$FW_ROOT/lib/db.sh"
    source "$FW_ROOT/lib/caddy.sh"
    source "$FW_ROOT/lib/stack.sh"
    source "$FW_ROOT/lib/switch.sh"
    source "$FW_ROOT/lib/worktree.sh"
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    load_config myproj
}

# _mk_wt <name> <branch> — a real git worktree the populate helpers can run
# against (they rev-parse its git dir for the artifact snapshot).
_mk_wt() {
    mkdir -p "$worktrees_dir"
    git -C "$repo_root" worktree add -q "$worktrees_dir/$1" -b "$2" main
}

@test "resolve_worktree --allow-main main: resolves to the golden checkout at repo_root" {
    resolve_worktree --allow-main main
    [ "$WT_NAME" = "main" ]
    [ "$WT_PATH" = "$repo_root" ]
}

@test "resolve_worktree --allow-main: detects the golden checkout from cwd" {
    cd "$repo_root"
    resolve_worktree --allow-main
    [ "$WT_NAME" = "main" ]
    [ "$WT_PATH" = "$repo_root" ]
}

@test "resolve_worktree --allow-main: detects the golden checkout from a subdir of it" {
    mkdir -p "$repo_root/sub/dir"
    cd "$repo_root/sub/dir"
    resolve_worktree --allow-main
    [ "$WT_NAME" = "main" ]
    [ "$WT_PATH" = "$repo_root" ]
}

@test "resolve_worktree: without --allow-main, the golden checkout is not a worktree" {
    # Default (no opt-in): worktree/branch-scoped commands must still reject it.
    cd "$repo_root"
    run resolve_worktree
    [ "$status" -ne 0 ]
    [[ "$output" == *"not inside a worktree"* ]]
}

@test "resolve_worktree: without --allow-main, explicit main is not the golden checkout" {
    run resolve_worktree main
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "resolve_worktree: still resolves a linked worktree by name" {
    mkdir -p "$worktrees_dir/feat"
    resolve_worktree feat
    [ "$WT_NAME" = "feat" ]
    [ "$WT_PATH" = "$worktrees_dir/feat" ]
}

@test "resolve_worktree: errors when cwd is neither a worktree nor the golden checkout" {
    cd "$BATS_TEST_TMPDIR"
    run resolve_worktree
    [ "$status" -ne 0 ]
    [[ "$output" == *"not inside a worktree"* ]]
}

# --- foreground/background split (background-create-setup spec) ---

@test "_populate_worktree_fg: runs hook_pre_db but not hook_post_create" {
    hook_pre_db()      { echo pre  >>"$FW_WORKTREE_PATH/marks"; }
    hook_post_create() { echo post >>"$FW_WORKTREE_PATH/marks"; }
    _mk_wt feat me/feat
    local wt="$worktrees_dir/feat" _db_created=false
    _populate_worktree_fg feat me/feat "$wt"
    [ "$(cat "$wt/marks")" = "pre" ]
}

@test "_populate_worktree_bg: runs hook_post_create after _fg" {
    hook_post_create() { echo hi >"$FW_WORKTREE_PATH/.welcome"; }
    _mk_wt feat me/feat
    local wt="$worktrees_dir/feat" _db_created=false
    _populate_worktree_fg feat me/feat "$wt"
    [ ! -f "$wt/.welcome" ]
    _populate_worktree_bg feat me/feat "$wt"
    [ -f "$wt/.welcome" ]
}

@test "_populate_worktree_bg: records the files hook_post_create creates" {
    hook_post_create() { echo hi >"$FW_WORKTREE_PATH/.welcome"; }
    _mk_wt feat me/feat
    local wt="$worktrees_dir/feat" _db_created=false
    _populate_worktree_fg feat me/feat "$wt"
    _populate_worktree_bg feat me/feat "$wt"
    local gitdir
    gitdir="$(git -C "$wt" rev-parse --absolute-git-dir)"
    grep -qx ".welcome" "$gitdir/fw-hook-artifacts"
}

@test "_run_hook_recording: does not record a file created outside the hook" {
    # A file that exists before the hook runs is user state, not a hook artifact.
    hook_post_create() { :; }
    _mk_wt feat me/feat
    local wt="$worktrees_dir/feat" _db_created=false
    _populate_worktree_fg feat me/feat "$wt"
    echo mine >"$wt/user-file"
    _populate_worktree_bg feat me/feat "$wt"
    local gitdir
    gitdir="$(git -C "$wt" rev-parse --absolute-git-dir)"
    ! { [ -f "$gitdir/fw-hook-artifacts" ] && grep -qx "user-file" "$gitdir/fw-hook-artifacts"; }
}

@test "_populate_worktree: composite runs pre_db then post_create in order" {
    hook_pre_db()      { echo pre  >>"$FW_WORKTREE_PATH/order.log"; }
    hook_post_create() { echo post >>"$FW_WORKTREE_PATH/order.log"; }
    _mk_wt feat me/feat
    local wt="$worktrees_dir/feat" _db_created=false
    _populate_worktree feat me/feat "$wt"
    run cat "$wt/order.log"
    [ "${lines[0]}" = "pre" ]
    [ "${lines[1]}" = "post" ]
}

@test "_populate_worktree_bg: a failing hook_post_create returns non-zero without rollback side effects" {
    hook_post_create() { return 1; }
    _mk_wt feat me/feat
    local wt="$worktrees_dir/feat" _db_created=false
    _populate_worktree_fg feat me/feat "$wt"
    run _populate_worktree_bg feat me/feat "$wt"
    [ "$status" -ne 0 ]
    # _bg never removes the worktree itself; rollback is the caller's job
    [ -d "$wt" ]
}
