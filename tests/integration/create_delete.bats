load ../test_helper

# hook_post_create now runs in the background (a tmux pane), so effect-based
# assertions poll for the result the way the --claude test does. ~5s budget.
_wait_for() {
    local path="$1" i
    for i in $(seq 1 25); do
        [ -e "$path" ] && return 0
        sleep 0.2
    done
    return 1
}

# _wait_for_artifact <wt_path> <relpath> — wait until the background half has
# both created the hook artifact and recorded it in the worktree's manifest
# (recording happens just after the file appears, so waiting on the file alone
# would race the dirty-check the delete tests exercise).
_wait_for_artifact() {
    local wt="$1" rel="$2" gitdir i
    gitdir="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
    for i in $(seq 1 25); do
        [ -f "$gitdir/fw-hook-artifacts" ] &&
            grep -qx "$rel" "$gitdir/fw-hook-artifacts" && return 0
        sleep 0.2
    done
    return 1
}

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

@test "fw delete: refuses the golden checkout" {
    "$FW_BIN" regen-env main

    run "$FW_BIN" delete main
    [ "$status" -ne 0 ]
    [[ "$output" == *"golden checkout"* ]]
    [ -d "$BATS_TEST_TMPDIR/myrepo/.git" ]
}

teardown() {
    "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true
}

@test "fw create: makes a worktree with a prefixed branch" {
    run "$FW_BIN" create feat
    [ "$status" -eq 0 ]

    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
    run git -C "$BATS_TEST_TMPDIR/myproj-worktrees/feat" branch --show-current
    [ "$output" = "me/feat" ]
}

@test "fw create: a slashed name is a full branch, folded into the worktree name" {
    # `create other/thing` overrides the prefix: the branch is taken verbatim and
    # the worktree name folds the namespace (other/thing -> other-thing).
    run "$FW_BIN" create other/thing
    [ "$status" -eq 0 ]

    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/other-thing" ]
    run git -C "$BATS_TEST_TMPDIR/myproj-worktrees/other-thing" branch --show-current
    [ "$output" = "other/thing" ]
}

@test "fw create: a slashed name carrying the configured prefix drops it" {
    run "$FW_BIN" create me/thing
    [ "$status" -eq 0 ]

    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/thing" ]
    run git -C "$BATS_TEST_TMPDIR/myproj-worktrees/thing" branch --show-current
    [ "$output" = "me/thing" ]
}

@test "fw create: writes the worktree env file" {
    "$FW_BIN" create feat

    local f="$BATS_TEST_TMPDIR/myproj-worktrees/feat/.env.worktree"
    grep -q '^FW_WORKTREE=feat$' "$f"
    grep -q '^FW_BRANCH=me/feat$' "$f"
}

@test "fw create: clones CoW assets from the golden checkout" {
    mkdir -p "$BATS_TEST_TMPDIR/myrepo/_build"
    echo artifact >"$BATS_TEST_TMPDIR/myrepo/_build/marker"

    "$FW_BIN" create feat

    [ "$(cat "$BATS_TEST_TMPDIR/myproj-worktrees/feat/_build/marker")" = "artifact" ]
}

@test "fw create: runs hook_post_create in the worktree with FW_* env" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_post_create() {
    echo "$FW_WORKTREE:$FW_BRANCH:$(pwd)" >"$FW_WORKTREE_PATH/hook-ran"
}
EOF

    "$FW_BIN" create feat

    # hook_post_create runs in the background window — wait for its result.
    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/feat"
    _wait_for "$wt/hook-ran"
    [ "$(cat "$wt/hook-ran")" = "feat:me/feat:$wt" ]
}

@test "fw create: runs hook_pre_db in the worktree with FW_* env" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_pre_db() {
    echo "$FW_WORKTREE:$FW_BRANCH:$(pwd)" >"$FW_WORKTREE_PATH/pre-db-ran"
}
EOF

    "$FW_BIN" create feat

    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/feat"
    [ -f "$wt/pre-db-ran" ]
    [ "$(cat "$wt/pre-db-ran")" = "feat:me/feat:$wt" ]
}

@test "fw create: hook_pre_db (foreground) runs before hook_post_create (background)" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_pre_db()     { echo pre_db     >>"$FW_WORKTREE_PATH/order.log"; }
hook_post_create() { echo post_create >>"$FW_WORKTREE_PATH/order.log"; }
EOF

    "$FW_BIN" create feat

    # pre_db ran synchronously; post_create appends from the background window.
    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/feat"
    _wait_for "$wt/order.log"
    local i
    for i in $(seq 1 25); do
        [ "$(wc -l <"$wt/order.log")" -ge 2 ] && break
        sleep 0.2
    done
    run cat "$wt/order.log"
    [ "${lines[0]}" = "pre_db" ]
    [ "${lines[1]}" = "post_create" ]
}

@test "fw create: a failing hook_pre_db aborts and rolls back" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_pre_db() { return 1; }
EOF

    run "$FW_BIN" create feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"rolling back"* ]]

    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
    run git -C "$BATS_TEST_TMPDIR/myrepo" branch --list "me/feat"
    [ -z "$output" ]
}

@test "fw delete: does not block on files a pre-db hook created" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_pre_db() { echo hi >"$FW_WORKTREE_PATH/.predb-artifact"; }
EOF
    "$FW_BIN" create feat
    [ -f "$BATS_TEST_TMPDIR/myproj-worktrees/feat/.predb-artifact" ]

    # No --force: the pre-db hook artifact must not read as uncommitted user work.
    run "$FW_BIN" delete feat
    [ "$status" -eq 0 ]
    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

@test "fw create: rejects an existing worktree name" {
    "$FW_BIN" create feat

    run "$FW_BIN" create feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists"* ]]
}

@test "fw create: --base with no value prints a usage error" {
    run "$FW_BIN" create feat --base
    [ "$status" -ne 0 ]
    [ -n "$output" ]
    [[ "$output" == *"--base"* ]]
}

@test "fw create: 'main' is a reserved name" {
    run "$FW_BIN" create main
    [ "$status" -ne 0 ]
    [[ "$output" == *"reserved"* ]]
}

@test "fw create: rejects invalid names" {
    run "$FW_BIN" create "bad name"
    [ "$status" -ne 0 ]

    # A slash is no longer invalid — it names a full branch (see the slashed-name
    # tests above). But a slashed name that folds to nothing is still rejected.
    run "$FW_BIN" create "/"
    [ "$status" -ne 0 ]

    # Uppercase would produce case-sensitive quoted Postgres DB names.
    run "$FW_BIN" create "MyFeature"
    [ "$status" -ne 0 ]
    [[ "$output" == *"lowercase"* ]]
}

@test "fw create: bases the branch on trunk even when the golden checkout is elsewhere" {
    git -C "$BATS_TEST_TMPDIR/myrepo" -c user.email=t@t -c user.name=t \
        commit -q --allow-empty -m "on-main"
    local main_tip
    main_tip="$(git -C "$BATS_TEST_TMPDIR/myrepo" rev-parse main)"
    git -C "$BATS_TEST_TMPDIR/myrepo" checkout -q -b stale-feature
    git -C "$BATS_TEST_TMPDIR/myrepo" -c user.email=t@t -c user.name=t \
        commit -q --allow-empty -m "stale-work"

    run "$FW_BIN" create feat
    [ "$status" -eq 0 ]

    local wt_tip
    wt_tip="$(git -C "$BATS_TEST_TMPDIR/myproj-worktrees/feat" rev-parse HEAD)"
    [ "$wt_tip" = "$main_tip" ]
}

@test "fw create: reuses an existing branch instead of failing" {
    git -C "$BATS_TEST_TMPDIR/myrepo" branch me/feat
    git -C "$BATS_TEST_TMPDIR/myrepo" -c user.email=t@t -c user.name=t \
        commit -q --allow-empty -m "advance-main"

    run "$FW_BIN" create feat
    [ "$status" -eq 0 ]

    run git -C "$BATS_TEST_TMPDIR/myproj-worktrees/feat" branch --show-current
    [ "$output" = "me/feat" ]
}

@test "fw create: a failing hook_post_create does NOT roll back (it runs after the switch)" {
    # hook_post_create is backgrounded, so create has already succeeded and
    # switched in by the time it runs — its failure must not un-create anything.
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_post_create() { return 1; }
EOF

    run "$FW_BIN" create feat
    [ "$status" -eq 0 ]
    [[ "$output" != *"rolling back"* ]]

    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
    run git -C "$BATS_TEST_TMPDIR/myrepo" branch --list "me/feat"
    [ -n "$output" ]
}

@test "fw create: rolls back the worktree and branch when a foreground hook fails" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_pre_db() { return 1; }
EOF

    run "$FW_BIN" create feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"rolling back"* ]]

    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
    run git -C "$BATS_TEST_TMPDIR/myrepo" branch --list "me/feat"
    [ -z "$output" ]
}

@test "fw create: rollback does not delete a pre-existing reused branch" {
    git -C "$BATS_TEST_TMPDIR/myrepo" branch me/feat
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_pre_db() { return 1; }
EOF

    run "$FW_BIN" create feat
    [ "$status" -ne 0 ]

    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
    run git -C "$BATS_TEST_TMPDIR/myrepo" branch --list "me/feat"
    [ -n "$output" ]
}

@test "fw create: a failing hook_worktree_env also rolls back" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_worktree_env() { false; }
EOF

    run "$FW_BIN" create feat
    [ "$status" -ne 0 ]
    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

@test "fw delete: removes the worktree and its branch" {
    "$FW_BIN" create feat

    run "$FW_BIN" delete feat
    [ "$status" -eq 0 ]

    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
    run git -C "$BATS_TEST_TMPDIR/myrepo" branch --list "me/feat"
    [ -z "$output" ]
}

@test "fw delete: kills the worktree's tmux session" {
    # A live session (server running inside it) that outlives the worktree is
    # what races the directory removal and strands a phantom dir. Delete must
    # tear the session down.
    "$FW_BIN" create --no-switch feat
    "$FW_BIN" tmux-open feat
    run "$FW_ROOT/tests/shims/tmux" has-session -t "=myproj-feat"
    [ "$status" -eq 0 ]

    run "$FW_BIN" delete feat
    [ "$status" -eq 0 ]

    run "$FW_ROOT/tests/shims/tmux" has-session -t "=myproj-feat"
    [ "$status" -ne 0 ]
}

@test "fw delete: runs hook_pre_delete while the worktree still exists" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_pre_delete() {
    if [ -d "$FW_WORKTREE_PATH" ]; then
        echo "saw $FW_WORKTREE" >"$FW_REPO_ROOT/pre-delete-ran"
    fi
}
EOF
    "$FW_BIN" create feat

    "$FW_BIN" delete feat

    [ "$(cat "$BATS_TEST_TMPDIR/myrepo/pre-delete-ran")" = "saw feat" ]
}

@test "fw delete: refuses a worktree with uncommitted changes" {
    "$FW_BIN" create feat
    echo dirty >"$BATS_TEST_TMPDIR/myproj-worktrees/feat/newfile"

    run "$FW_BIN" delete feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"uncommitted"* ]]
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

@test "fw delete: does not block on files a post-create hook created" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_post_create() { echo hi >"$FW_WORKTREE_PATH/.welcome"; }
EOF
    "$FW_BIN" create feat
    # hook_post_create runs in the background; wait until its artifact is
    # recorded in the manifest that excludes it from the dirty check.
    _wait_for_artifact "$BATS_TEST_TMPDIR/myproj-worktrees/feat" .welcome

    # No --force: the hook artifact must not read as uncommitted user work.
    run "$FW_BIN" delete feat
    [ "$status" -eq 0 ]
    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

@test "fw delete: still refuses genuine user changes alongside a hook artifact" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_post_create() { echo hi >"$FW_WORKTREE_PATH/.welcome"; }
EOF
    "$FW_BIN" create feat
    _wait_for_artifact "$BATS_TEST_TMPDIR/myproj-worktrees/feat" .welcome
    echo mine >"$BATS_TEST_TMPDIR/myproj-worktrees/feat/user-work"

    run "$FW_BIN" delete feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"uncommitted"* ]]
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

@test "fw delete: does not block on untracked files in a claude_archive_paths dir" {
    # docs/reports is preserved by archive_claude on delete, so its untracked
    # files must not read as uncommitted user work that blocks the delete.
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
claude_archive_paths=(docs/reports:docs/reports)
EOF
    "$FW_BIN" create feat
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/feat/docs/reports"
    echo report >"$BATS_TEST_TMPDIR/myproj-worktrees/feat/docs/reports/r1.md"

    run "$FW_BIN" delete feat
    [ "$status" -eq 0 ]
    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

@test "fw delete: still refuses user changes outside claude_archive_paths dirs" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
claude_archive_paths=(docs/reports:docs/reports)
EOF
    "$FW_BIN" create feat
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/feat/docs/reports"
    echo report >"$BATS_TEST_TMPDIR/myproj-worktrees/feat/docs/reports/r1.md"
    echo mine >"$BATS_TEST_TMPDIR/myproj-worktrees/feat/user-work"

    run "$FW_BIN" delete feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"uncommitted"* ]]
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

@test "fw delete: --force removes a dirty worktree" {
    "$FW_BIN" create feat
    echo dirty >"$BATS_TEST_TMPDIR/myproj-worktrees/feat/newfile"

    run "$FW_BIN" delete --force feat
    [ "$status" -eq 0 ]
    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

@test "fw delete: rejects names with path separators before touching anything" {
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/../victim"
    echo 'FW_DB_NAME=victim_db' >"$BATS_TEST_TMPDIR/victim/.env.worktree"

    run "$FW_BIN" delete "../victim"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid worktree name"* ]]
    [ -f "$BATS_TEST_TMPDIR/victim/.env.worktree" ]
}

@test "fw delete: deletes the branch recorded at create, not the checked-out one" {
    "$FW_BIN" create feat
    git -C "$BATS_TEST_TMPDIR/myrepo" branch release-sim
    git -C "$BATS_TEST_TMPDIR/myproj-worktrees/feat" checkout -q release-sim

    run "$FW_BIN" delete feat
    [ "$status" -eq 0 ]

    run git -C "$BATS_TEST_TMPDIR/myrepo" branch --list "release-sim"
    [ -n "$output" ]
    run git -C "$BATS_TEST_TMPDIR/myrepo" branch --list "me/feat"
    [ -z "$output" ]
}

@test "fw delete: a corrupt worktree fails with a visible error suggesting --force" {
    "$FW_BIN" create feat
    echo "gitdir: /nonexistent/gone" >"$BATS_TEST_TMPDIR/myproj-worktrees/feat/.git"

    run "$FW_BIN" delete feat
    [ "$status" -ne 0 ]
    [ -n "$output" ]
    [[ "$output" == *"--force"* ]]
}

@test "fw delete: --force removes a corrupt worktree" {
    "$FW_BIN" create feat
    echo "gitdir: /nonexistent/gone" >"$BATS_TEST_TMPDIR/myproj-worktrees/feat/.git"

    run "$FW_BIN" delete --force feat
    [ "$status" -eq 0 ]
    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

# fake_git_worktree_remove_noop — a PATH-front git shim that makes
# `git worktree remove` claim success while leaving the directory behind (the
# observed bug: a server writing into the worktree raced git's removal), passing
# every other git call through to the real git.
fake_git_worktree_remove_noop() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/git" <<'EOF'
#!/bin/sh
case " $* " in
    *" worktree remove "*) exit 0 ;;   # pretend success, leave the dir
esac
command -p git "$@"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/git"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "fw delete: force-removes the dir when git worktree remove leaves it behind" {
    "$FW_BIN" create --no-switch feat
    fake_git_worktree_remove_noop

    run "$FW_BIN" delete feat
    [ "$status" -eq 0 ]
    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
    [[ "$output" == *"Deleted feat"* ]]
}

@test "fw delete: reports failure loudly when the dir can't be removed" {
    "$FW_BIN" create --no-switch feat
    fake_git_worktree_remove_noop
    # Also block the rm fallback for this exact dir, so it survives every attempt
    # (a process still writing into it). Other rm calls pass through.
    cat >"$BATS_TEST_TMPDIR/bin/rm" <<EOF
#!/bin/sh
for a in "\$@"; do
    [ "\$a" = "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ] && exit 1
done
command -p rm "\$@"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/rm"

    run "$FW_BIN" delete feat
    [ "$status" -ne 0 ]
    [[ "$output" != *"Deleted feat"* ]]
    [[ "$output" == *"could not be fully removed"* ]]
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

@test "fw delete: a non-worktree dir is not judged by an enclosing repo's status" {
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/stray"
    echo data >"$BATS_TEST_TMPDIR/myproj-worktrees/stray/file"

    run "$FW_BIN" delete stray
    [ "$status" -ne 0 ]
    [[ "$output" != *"uncommitted"* ]]
    [[ "$output" == *"--force"* ]]
}

@test "fw delete: a failing hook_pre_delete warns but the delete completes" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_pre_delete() { echo "hook exploded" >&2; return 1; }
EOF
    "$FW_BIN" create feat

    run "$FW_BIN" delete feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"hook exploded"* ]]
    [[ "$output" == *"Warning"* ]]
    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

@test "fw switch: a failing hook_post_switch warns but the switch completes" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_post_switch() { return 1; }
EOF
    "$FW_BIN" create feat

    run "$FW_BIN" switch feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning"* ]]
}

@test "fw delete: never deletes the trunk branch even when recorded" {
    "$FW_BIN" create feat
    # Simulate a corrupted/hand-edited env file recording trunk as the branch.
    # Portable in-place rewrite (BSD and GNU `sed -i` disagree on the backup arg).
    env_file="$BATS_TEST_TMPDIR/myproj-worktrees/feat/.env.worktree"
    sed 's|^FW_BRANCH=.*|FW_BRANCH=main|' "$env_file" >"$env_file.new"
    mv "$env_file.new" "$env_file"

    run "$FW_BIN" delete feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"trunk"* ]]

    run git -C "$BATS_TEST_TMPDIR/myrepo" branch --list main
    [ -n "$output" ]
}

@test "fw delete: --force removes a stray dir with no env file" {
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/stray"

    run "$FW_BIN" delete --force stray
    [ "$status" -eq 0 ]
    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/stray" ]
}

@test "fw delete: errors on an unknown worktree" {
    run "$FW_BIN" delete nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"nope"* ]]
}

@test "fw delete: accepts a branch name and removes its worktree" {
    "$FW_BIN" create --no-switch feat

    run "$FW_BIN" delete me/feat
    [ "$status" -eq 0 ]
    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
    run git -C "$BATS_TEST_TMPDIR/myrepo" branch --list "me/feat"
    [ -z "$output" ]
}

@test "fw delete: accepts a branch name even after the branch is gone from git" {
    "$FW_BIN" create --no-switch feat
    # The real-world case: the branch was already deleted, but the worktree's
    # env still records it, so delete-by-branch must resolve off that record.
    git -C "$BATS_TEST_TMPDIR/myproj-worktrees/feat" checkout -q -b sidetrack
    git -C "$BATS_TEST_TMPDIR/myrepo" branch -D me/feat

    run "$FW_BIN" delete me/feat
    [ "$status" -eq 0 ]
    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

# Auto-switch is asserted via the "Switching to <name>" line cmd_switch prints
# synchronously — not via a live tmux session, whose presence races on the
# suite's shared test socket.
@test "fw create: switches into the new worktree by default" {
    run "$FW_BIN" create alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switching to alpha"* ]]
}

@test "fw create: --no-switch skips switching" {
    run "$FW_BIN" create --no-switch alpha
    [ "$status" -eq 0 ]
    [[ "$output" != *"Switching to"* ]]
}

@test "fw create: switch_on_create=false disables auto-switch" {
    echo 'switch_on_create=false' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    run "$FW_BIN" create alpha
    [ "$status" -eq 0 ]
    [[ "$output" != *"Switching to"* ]]
}

@test "fw create: untracked build artifacts don't block a clean delete" {
    mkdir -p "$BATS_TEST_TMPDIR/myrepo/_build"
    echo artifact >"$BATS_TEST_TMPDIR/myrepo/_build/marker"
    echo '_build/' >"$BATS_TEST_TMPDIR/myrepo/.gitignore"
    git -C "$BATS_TEST_TMPDIR/myrepo" add .gitignore
    git -C "$BATS_TEST_TMPDIR/myrepo" -c user.email=t@t -c user.name=t commit -qm gitignore

    "$FW_BIN" create feat
    run "$FW_BIN" delete feat
    [ "$status" -eq 0 ]
}

# --- background setup dispatch (background-create-setup spec) ---

@test "fw create: dispatches _create-bg into the session's first window" {
    export FW_TEST_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
    "$FW_BIN" create feat

    [ -f "$FW_TEST_TMUX_LOG" ]
    grep -q -- "send-keys" "$FW_TEST_TMUX_LOG"
    grep -q -- "_create-bg feat" "$FW_TEST_TMUX_LOG"
}

@test "fw create --no-switch: still births the session and dispatches setup" {
    export FW_TEST_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
    run "$FW_BIN" create --no-switch feat
    [ "$status" -eq 0 ]
    [[ "$output" != *"Switching to"* ]]

    grep -q -- "_create-bg feat" "$FW_TEST_TMUX_LOG"
    run "$FW_ROOT/tests/shims/tmux" has-session -t "=myproj-feat"
    [ "$status" -eq 0 ]
}

@test "fw _create-bg: runs hook_post_create and reports completion" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_post_create() { echo hi >"$FW_WORKTREE_PATH/.welcome2"; }
EOF
    "$FW_BIN" create --no-switch feat

    run "$FW_BIN" _create-bg feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"setup complete"* ]]
    [ -f "$BATS_TEST_TMPDIR/myproj-worktrees/feat/.welcome2" ]
}
