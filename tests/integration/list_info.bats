load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

@test "fw list: shows each worktree with its branch" {
    "$FW_BIN" create alpha
    "$FW_BIN" create beta

    run "$FW_BIN" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"me/alpha"* ]]
    [[ "$output" == *"beta"* ]]
    [[ "$output" == *"me/beta"* ]]
}

@test "fw list: prints a header row with an underline" {
    "$FW_BIN" create alpha

    run "$FW_BIN" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"NAME"* ]]
    [[ "$output" == *"BRANCH"* ]]
    [[ "$output" == *"STATUS"* ]]
    [[ "$output" == *"CHANGES"* ]]
    [[ "$output" == *"----"* ]]
}

@test "fw list: colors a running Claude status green" {
    "$FW_BIN" create alpha
    export FW_TEST_CLAUDE_AGENTS_JSON="[{\"pid\":1,\"cwd\":\"$BATS_TEST_TMPDIR/myproj-worktrees/alpha\",\"status\":\"busy\",\"startedAt\":0}]"
    export FW_COLOR=always

    run "$FW_BIN" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"running"* ]]
    # green escape (C_GREEN) wraps the status cell
    [[ "$output" == *$'\033[0;32m'* ]]
}

@test "fw list: colors a waiting Claude status yellow" {
    "$FW_BIN" create alpha
    export FW_TEST_CLAUDE_AGENTS_JSON="[{\"pid\":1,\"cwd\":\"$BATS_TEST_TMPDIR/myproj-worktrees/alpha\",\"status\":\"waiting\",\"startedAt\":0}]"
    export FW_COLOR=always

    run "$FW_BIN" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"waiting"* ]]
    # yellow escape (C_YELLOW) wraps the status cell
    [[ "$output" == *$'\033[1;33m'* ]]
}

@test "fw list: no color codes when color is disabled" {
    "$FW_BIN" create alpha
    export FW_TEST_CLAUDE_AGENTS_JSON="[{\"pid\":1,\"cwd\":\"$BATS_TEST_TMPDIR/myproj-worktrees/alpha\",\"status\":\"busy\",\"startedAt\":0}]"
    export FW_COLOR=never

    run "$FW_BIN" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"running"* ]]
    [[ "$output" != *$'\033['* ]]
}

@test "fw list: marks dirty worktrees" {
    "$FW_BIN" create alpha
    echo change >"$BATS_TEST_TMPDIR/myproj-worktrees/alpha/newfile"

    run "$FW_BIN" list
    [[ "$output" == *"?:1"* ]]
}

@test "fw list: clean worktrees carry no dirty markers" {
    "$FW_BIN" create alpha

    run "$FW_BIN" list
    [[ "$output" != *"?:"* ]]
    [[ "$output" != *"M:"* ]]
}

@test "fw list: friendly message with no worktrees" {
    run "$FW_BIN" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"No worktrees"* ]]
}

@test "fw list: the env file itself does not count as dirt" {
    "$FW_BIN" create alpha

    run "$FW_BIN" list
    [[ "$output" != *"?:"* ]]
}

@test "fw list: does not show the handoffs directory as a worktree" {
    "$FW_BIN" create alpha
    printf '# Handoff: x\n' >"$BATS_TEST_TMPDIR/h.md"
    "$FW_BIN" handoff save "$BATS_TEST_TMPDIR/h.md"

    run "$FW_BIN" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" != *"handoffs"* ]]
}

@test "fw list: a handoffs-only worktrees dir still reports no worktrees" {
    printf '# Handoff: x\n' >"$BATS_TEST_TMPDIR/h.md"
    "$FW_BIN" handoff save "$BATS_TEST_TMPDIR/h.md"

    run "$FW_BIN" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"No worktrees"* ]]
}

@test "fw list: files created by hook_post_create are not counted as dirt" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_post_create() { echo hi >"$FW_WORKTREE_PATH/.welcome"; }
EOF
    "$FW_BIN" create alpha

    # hook_post_create runs in the background; wait until its artifact is
    # recorded in the manifest that excludes it from the dirty check.
    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/alpha" gitdir i
    gitdir="$(git -C "$wt" rev-parse --absolute-git-dir)"
    for i in $(seq 1 25); do
        [ -f "$gitdir/fw-hook-artifacts" ] &&
            grep -qx ".welcome" "$gitdir/fw-hook-artifacts" && break
        sleep 0.2
    done

    run "$FW_BIN" list
    [[ "$output" != *"?:"* ]]
}

@test "fw info: prints the worktree's configuration" {
    "$FW_BIN" create alpha

    run "$FW_BIN" info alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"me/alpha"* ]]
    [[ "$output" == *"$BATS_TEST_TMPDIR/myproj-worktrees/alpha"* ]]
    [[ "$output" =~ [Ss]lot ]]
}

@test "fw info: detects the worktree from cwd" {
    "$FW_BIN" create alpha
    cd "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"

    run "$FW_BIN" info
    [ "$status" -eq 0 ]
    [[ "$output" == *"me/alpha"* ]]
}

@test "fw info: detects from a subdirectory of the worktree" {
    "$FW_BIN" create alpha
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha/deep/sub"
    cd "$BATS_TEST_TMPDIR/myproj-worktrees/alpha/deep/sub"

    run "$FW_BIN" info
    [[ "$output" == *"me/alpha"* ]]
}

@test "fw info: errors outside a worktree with no name given" {
    run "$FW_BIN" info
    [ "$status" -ne 0 ]
    [[ "$output" == *"worktree"* ]]
}

@test "fw info: errors on an unknown worktree" {
    run "$FW_BIN" info nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"nope"* ]]
}
