load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
branch_prefix=me
stack_backend=graphite
EOF
    cd "$BATS_TEST_TMPDIR/myrepo"
}

teardown() {
    "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true
}

WT() { echo "$BATS_TEST_TMPDIR/myproj-worktrees/$1"; }

# Create an empty graphite metadata table in the golden checkout's git dir.
make_gt_db() {
    sqlite3 "$BATS_TEST_TMPDIR/myrepo/.git/.graphite_metadata.db" \
        "CREATE TABLE branch_metadata (branch_name TEXT PRIMARY KEY, parent_branch_name TEXT, children TEXT);"
}

# Two-branch stack: me/part1 (bottom) -> me/part2 (top), each with a worktree.
make_stack() {
    "$FW_BIN" create part1
    "$FW_BIN" create part2
    make_gt_db
    sqlite3 "$BATS_TEST_TMPDIR/myrepo/.git/.graphite_metadata.db" "
        INSERT INTO branch_metadata VALUES ('me/part1','main','[\"me/part2\"]');
        INSERT INTO branch_metadata VALUES ('me/part2','me/part1','[]');
    "
}

# --- navigation ---------------------------------------------------------------

@test "fw up: moves from the bottom branch to its child" {
    make_stack
    cd "$(WT part1)"

    run "$FW_BIN" up
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switching to part2"* ]]
}

@test "fw down: moves from the top branch to its parent" {
    make_stack
    cd "$(WT part2)"

    run "$FW_BIN" down
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switching to part1"* ]]
}

@test "fw up: reports already at top when on the tip" {
    make_stack
    cd "$(WT part2)"

    run "$FW_BIN" up
    [ "$status" -eq 0 ]
    [[ "$output" == *"top of stack"* ]]
    [[ "$output" != *"Switching"* ]]
}

@test "fw down: reports already at bottom when on the base" {
    make_stack
    cd "$(WT part1)"

    run "$FW_BIN" down
    [ "$status" -eq 0 ]
    [[ "$output" == *"bottom of stack"* ]]
    [[ "$output" != *"Switching"* ]]
}

@test "fw top: jumps from the base to the tip" {
    make_stack
    cd "$(WT part1)"

    run "$FW_BIN" top
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switching to part2"* ]]
}

@test "fw bottom: jumps from the tip to the base" {
    make_stack
    cd "$(WT part2)"

    run "$FW_BIN" bottom
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switching to part1"* ]]
}

@test "fw top: reports already at top when already on the tip" {
    make_stack
    cd "$(WT part2)"

    run "$FW_BIN" top
    [ "$status" -eq 0 ]
    [[ "$output" == *"top of stack"* ]]
}

@test "fw up: errors with a pull hint when the target worktree is missing" {
    "$FW_BIN" create part1
    make_gt_db
    sqlite3 "$BATS_TEST_TMPDIR/myrepo/.git/.graphite_metadata.db" "
        INSERT INTO branch_metadata VALUES ('me/part1','main','[\"me/part2\"]');
        INSERT INTO branch_metadata VALUES ('me/part2','me/part1','[]');
    "
    cd "$(WT part1)"

    run "$FW_BIN" up
    [ "$status" -ne 0 ]
    [[ "$output" == *"me/part2"* ]]
    [[ "$output" == *"fw pull me/part2"* ]]
}

@test "fw up: reports no stack on trunk" {
    make_gt_db
    run "$FW_BIN" up
    [ "$status" -eq 0 ]
    [[ "$output" == *"trunk"* ]]
}

@test "fw up: refuses to run from a foreign repo" {
    make_stack
    make_repo "$BATS_TEST_TMPDIR/other"
    git -C "$BATS_TEST_TMPDIR/other" checkout -q -b unrelated
    export FW_PROJECT=myproj
    cd "$BATS_TEST_TMPDIR/other"

    run "$FW_BIN" up
    [ "$status" -ne 0 ]
    [[ "$output" == *"myproj"* ]]
}

# --- restack ------------------------------------------------------------------

@test "fw restack: restacks the current branch and below, bottom-to-top" {
    make_stack
    export FW_TEST_GT_LOG="$BATS_TEST_TMPDIR/gt.log"
    cd "$(WT part2)"

    run "$FW_BIN" restack
    [ "$status" -eq 0 ]

    grep -q -- "restack --downstack" "$FW_TEST_GT_LOG"
    # bottom-to-top: part1's worktree restacked before part2's
    local p1_line p2_line
    p1_line="$(grep -n -- "restack --downstack" "$FW_TEST_GT_LOG" | grep "part1" | head -1 | cut -d: -f1)"
    p2_line="$(grep -n -- "restack --downstack" "$FW_TEST_GT_LOG" | grep "part2" | head -1 | cut -d: -f1)"
    [ -n "$p1_line" ]
    [ -n "$p2_line" ]
    [ "$p1_line" -lt "$p2_line" ]
}

@test "fw restack: default scope stops at the current branch" {
    make_stack
    export FW_TEST_GT_LOG="$BATS_TEST_TMPDIR/gt.log"
    cd "$(WT part1)"

    run "$FW_BIN" restack
    [ "$status" -eq 0 ]

    grep -q "part1" "$FW_TEST_GT_LOG"
    # part2 is above the current branch, so the default scope must skip it
    ! grep -- "restack --downstack" "$FW_TEST_GT_LOG" | grep -q "part2"
}

@test "fw restack --all: restacks the whole stack from the base" {
    make_stack
    export FW_TEST_GT_LOG="$BATS_TEST_TMPDIR/gt.log"
    cd "$(WT part1)"

    run "$FW_BIN" restack --all
    [ "$status" -eq 0 ]

    grep -- "restack --downstack" "$FW_TEST_GT_LOG" | grep -q "part1"
    grep -- "restack --downstack" "$FW_TEST_GT_LOG" | grep -q "part2"
}

@test "fw restack: errors when a stack worktree is missing" {
    "$FW_BIN" create part1
    make_gt_db
    sqlite3 "$BATS_TEST_TMPDIR/myrepo/.git/.graphite_metadata.db" "
        INSERT INTO branch_metadata VALUES ('me/part1','main','[\"me/part2\"]');
        INSERT INTO branch_metadata VALUES ('me/part2','me/part1','[]');
    "
    export FW_TEST_GT_LOG="$BATS_TEST_TMPDIR/gt.log"
    cd "$(WT part1)"

    run "$FW_BIN" restack --all
    [ "$status" -ne 0 ]
    [[ "$output" == *"me/part2"* ]]
    [[ "$output" == *"fw pull"* ]]
    [ ! -f "$FW_TEST_GT_LOG" ] || ! grep -q -- "restack --downstack" "$FW_TEST_GT_LOG"
}

@test "fw restack: errors on a dirty worktree before touching gt" {
    make_stack
    export FW_TEST_GT_LOG="$BATS_TEST_TMPDIR/gt.log"
    # give part1 a tracked, modified file
    echo hi >"$(WT part1)/tracked"
    git -C "$(WT part1)" -c user.email=t@t -c user.name=t add tracked
    git -C "$(WT part1)" -c user.email=t@t -c user.name=t commit -q -m tracked
    echo changed >"$(WT part1)/tracked"
    cd "$(WT part1)"

    run "$FW_BIN" restack
    [ "$status" -ne 0 ]
    [[ "$output" == *"part1"* ]]
    [ ! -f "$FW_TEST_GT_LOG" ] || ! grep -q -- "restack --downstack" "$FW_TEST_GT_LOG"
}

@test "fw restack: reports no stack on trunk" {
    make_gt_db
    run "$FW_BIN" restack
    [ "$status" -eq 0 ]
    [[ "$output" == *"trunk"* ]]
}

@test "fw restack: aborts and reports when a branch conflicts" {
    make_stack
    export FW_TEST_GT_LOG="$BATS_TEST_TMPDIR/gt.log"
    export FW_TEST_GT_RESTACK_FAIL=part2
    cd "$(WT part2)"

    run "$FW_BIN" restack
    [ "$status" -ne 0 ]
    [[ "$output" == *"part2"* ]]
    # the partial restack was aborted with the real Graphite command (`gt abort
    # -f`), not the non-existent `gt restack --abort`
    grep -- "part2" "$FW_TEST_GT_LOG" | grep -q -- "abort -f"
    ! grep -q -- "restack --abort" "$FW_TEST_GT_LOG"
}

@test "fw restack: fails with a clear message under the none backend" {
    # a distinct repo/project with no stack backend configured (its own
    # repo_root so cwd-based resolution can't collide with myproj)
    make_repo "$BATS_TEST_TMPDIR/nonerepo"
    register_project noneproj "$BATS_TEST_TMPDIR/nonerepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/noneproj/config.sh"
    cd "$BATS_TEST_TMPDIR/nonerepo"
    "$FW_BIN" create solo
    cd "$BATS_TEST_TMPDIR/noneproj-worktrees/solo"

    run "$FW_BIN" restack
    [ "$status" -ne 0 ]
    [[ "$output" == *"stack backend"* ]]
    # It must refuse upfront, before announcing any restack or reporting a
    # (non-existent) conflict.
    [[ "$output" != *"Restacking"* ]]
    [[ "$output" != *"restack failed"* ]]
}
