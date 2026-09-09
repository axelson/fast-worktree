load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

teardown() {
    "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true
}

@test "fw stack-switch: offers the current stack and switches to the pick" {
    "$FW_BIN" create feat
    cd "$BATS_TEST_TMPDIR/myproj-worktrees/feat"

    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_SELECT="me/feat"

    run "$FW_BIN" stack-switch
    [ "$status" -eq 0 ]
    [[ "$output" == *"feat"* ]]

    grep -q "me/feat" "$BATS_TEST_TMPDIR/offered"
}

@test "fw ss: reports no stack when on trunk" {
    run "$FW_BIN" ss
    [ "$status" -eq 0 ]
    [[ "$output" == *"trunk"* ]]
}

@test "fw stack-switch: cancel is a quiet no-op" {
    "$FW_BIN" create feat
    cd "$BATS_TEST_TMPDIR/myproj-worktrees/feat"

    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" stack-switch
    [ "$status" -eq 0 ]
}

@test "fw stack: shows the single branch under the none backend" {
    "$FW_BIN" create feat
    cd "$BATS_TEST_TMPDIR/myproj-worktrees/feat"

    run "$FW_BIN" stack
    [ "$status" -eq 0 ]
    [[ "$output" == *"me/feat"* ]]
}

@test "fw stack: refuses to run from a foreign repo" {
    make_repo "$BATS_TEST_TMPDIR/other"
    git -C "$BATS_TEST_TMPDIR/other" checkout -q -b unrelated-branch
    export FW_PROJECT=myproj
    cd "$BATS_TEST_TMPDIR/other"

    run "$FW_BIN" stack
    [ "$status" -ne 0 ]
    [[ "$output" == *"myproj"* ]]
    [[ "$output" != *"unrelated-branch"* ]]
}

@test "fw stack: refuses to run outside any git repo" {
    export FW_PROJECT=myproj
    cd "$BATS_TEST_TMPDIR"

    run "$FW_BIN" stack
    [ "$status" -ne 0 ]
}

@test "fw stack: reports no stack on trunk" {
    run "$FW_BIN" stack
    [ "$status" -eq 0 ]
    [[ "$output" == *"trunk"* ]]
}

@test "fw create: tracks the new branch with graphite when configured" {
    echo 'stack_backend=graphite' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GT_LOG="$BATS_TEST_TMPDIR/gt.log"

    run "$FW_BIN" create feat
    [ "$status" -eq 0 ]

    grep -q "track --parent main" "$FW_TEST_GT_LOG"
}

@test "fw create: does not invoke gt under the none backend" {
    export FW_TEST_GT_LOG="$BATS_TEST_TMPDIR/gt.log"

    "$FW_BIN" create feat

    [ ! -s "$BATS_TEST_TMPDIR/gt.log" ]
}

@test "fw create: rollback untracks through the stack backend" {
    echo 'stack_backend=graphite' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    # A foreground hook failure (hook_pre_db) still rolls back; hook_post_create
    # runs in the background after the switch and no longer triggers rollback.
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_pre_db() { return 1; }
EOF
    export FW_TEST_GT_LOG="$BATS_TEST_TMPDIR/gt.log"

    run "$FW_BIN" create feat
    [ "$status" -ne 0 ]

    grep -q "track --parent main" "$FW_TEST_GT_LOG"
    grep -q "delete me/feat" "$FW_TEST_GT_LOG"
}

@test "fw create: gt track runs non-interactively" {
    echo 'stack_backend=graphite' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GT_LOG="$BATS_TEST_TMPDIR/gt.log"

    "$FW_BIN" create feat

    grep "track" "$FW_TEST_GT_LOG" | grep -q -- "--no-interactive"
}

@test "fw create: a reused branch is also tracked" {
    echo 'stack_backend=graphite' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GT_LOG="$BATS_TEST_TMPDIR/gt.log"
    git -C "$BATS_TEST_TMPDIR/myrepo" branch me/feat

    run "$FW_BIN" create feat
    [ "$status" -eq 0 ]

    grep -q "track --parent main" "$FW_TEST_GT_LOG"
}

@test "fw create: --base creates a stacked worktree and tracks the right parent" {
    echo 'stack_backend=graphite' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GT_LOG="$BATS_TEST_TMPDIR/gt.log"
    "$FW_BIN" create part1
    git -C "$BATS_TEST_TMPDIR/myproj-worktrees/part1" \
        -c user.email=t@t -c user.name=t commit -q --allow-empty -m "part1 work"
    local part1_tip
    part1_tip="$(git -C "$BATS_TEST_TMPDIR/myrepo" rev-parse me/part1)"

    run "$FW_BIN" create part2 --base me/part1
    [ "$status" -eq 0 ]

    local part2_tip
    part2_tip="$(git -C "$BATS_TEST_TMPDIR/myproj-worktrees/part2" rev-parse HEAD)"
    [ "$part2_tip" = "$part1_tip" ]
    grep -q "track --parent me/part1" "$FW_TEST_GT_LOG"
}

@test "fw create: --base=. stacks on the current branch and tracks it" {
    echo 'stack_backend=graphite' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GT_LOG="$BATS_TEST_TMPDIR/gt.log"
    "$FW_BIN" create part1
    git -C "$BATS_TEST_TMPDIR/myproj-worktrees/part1" \
        -c user.email=t@t -c user.name=t commit -q --allow-empty -m "part1 work"
    local part1_tip
    part1_tip="$(git -C "$BATS_TEST_TMPDIR/myrepo" rev-parse me/part1)"
    cd "$BATS_TEST_TMPDIR/myproj-worktrees/part1"

    run "$FW_BIN" create part2 --base=.
    [ "$status" -eq 0 ]

    local part2_tip
    part2_tip="$(git -C "$BATS_TEST_TMPDIR/myproj-worktrees/part2" rev-parse HEAD)"
    [ "$part2_tip" = "$part1_tip" ]
    grep -q "track --parent me/part1" "$FW_TEST_GT_LOG"
}

@test "fw create: --base=. reads cwd's branch, not the golden checkout's trunk" {
    echo 'stack_backend=graphite' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GT_LOG="$BATS_TEST_TMPDIR/gt.log"
    # Golden checkout ($BATS_TEST_TMPDIR/myrepo) stays on trunk; cwd is on me/part1.
    "$FW_BIN" create part1
    cd "$BATS_TEST_TMPDIR/myproj-worktrees/part1"
    : >"$FW_TEST_GT_LOG"  # drop part1's own track-on-main; assert only part2's

    run "$FW_BIN" create part2 --base=.
    [ "$status" -eq 0 ]

    grep -q "track --parent me/part1" "$FW_TEST_GT_LOG"
    ! grep -q "track --parent main" "$FW_TEST_GT_LOG"
}

@test "fw create: --base=. errors on a detached HEAD" {
    "$FW_BIN" create part1
    cd "$BATS_TEST_TMPDIR/myproj-worktrees/part1"
    git checkout -q --detach

    run "$FW_BIN" create part2 --base=.
    [ "$status" -ne 0 ]
    [[ "$output" == *"current branch"* ]]
    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/part2" ]
}

@test "fw create: --base=. refuses to stack a branch on itself" {
    export FW_PROJECT=myproj
    git -C "$BATS_TEST_TMPDIR/myrepo" branch me/solo
    git -C "$BATS_TEST_TMPDIR/myrepo" worktree add -q "$BATS_TEST_TMPDIR/solo-wt" me/solo
    cd "$BATS_TEST_TMPDIR/solo-wt"

    run "$FW_BIN" create solo --base=.
    [ "$status" -ne 0 ]
    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/solo" ]
}

@test "fw create: --base rejects an unknown branch" {
    run "$FW_BIN" create feat --base me/nonexistent
    [ "$status" -ne 0 ]
    [[ "$output" == *"me/nonexistent"* ]]
    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

@test "fw create: reusing a tracked mid-stack branch keeps its parent" {
    echo 'stack_backend=graphite' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GT_LOG="$BATS_TEST_TMPDIR/gt.log"
    git -C "$BATS_TEST_TMPDIR/myrepo" branch me/part1
    git -C "$BATS_TEST_TMPDIR/myrepo" branch me/part2
    sqlite3 "$BATS_TEST_TMPDIR/myrepo/.git/.graphite_metadata.db" "
        CREATE TABLE branch_metadata (
            branch_name TEXT PRIMARY KEY,
            parent_branch_name TEXT,
            children TEXT
        );
        INSERT INTO branch_metadata VALUES ('me/part1', 'main', '[\"me/part2\"]');
        INSERT INTO branch_metadata VALUES ('me/part2', 'me/part1', '[]');
    "

    run "$FW_BIN" create part2
    [ "$status" -eq 0 ]

    grep -q "track --parent me/part1" "$FW_TEST_GT_LOG"
    ! grep -q "track --parent main" "$FW_TEST_GT_LOG"
}

@test "graphite delete: reports when the branch survives (checked out elsewhere)" {
    echo 'stack_backend=graphite' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    "$FW_BIN" create feat
    git -C "$BATS_TEST_TMPDIR/myrepo" worktree add -q "$BATS_TEST_TMPDIR/outside-wt" me/feat 2>/dev/null || {
        # me/feat is checked out in the fw worktree; use a second branch ref trick:
        # detach the fw worktree so the branch is free, then check it out outside.
        git -C "$BATS_TEST_TMPDIR/myproj-worktrees/feat" checkout -q --detach
        git -C "$BATS_TEST_TMPDIR/myrepo" worktree add -q "$BATS_TEST_TMPDIR/outside-wt" me/feat
    }

    run "$FW_BIN" delete --force feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"not deleted"* || "$output" == *"still exists"* ]]

    run git -C "$BATS_TEST_TMPDIR/myrepo" branch --list me/feat
    [ -n "$output" ]
}

@test "fw delete: deletes the branch through the graphite backend" {
    echo 'stack_backend=graphite' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GT_LOG="$BATS_TEST_TMPDIR/gt.log"
    "$FW_BIN" create feat

    run "$FW_BIN" delete feat
    [ "$status" -eq 0 ]

    grep -q "delete me/feat" "$FW_TEST_GT_LOG"
    run git -C "$BATS_TEST_TMPDIR/myrepo" branch --list me/feat
    [ -z "$output" ]
}
