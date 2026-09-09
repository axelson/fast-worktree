load ../test_helper

# fw start / check / fix run the project's configured command (start_cmd,
# check_cmd, fix_cmd) inside the worktree directory with the FW_* env
# contract and the worktree's env file applied.

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
    "$FW_BIN" create feat
}

@test "fw start: runs start_cmd in the golden checkout" {
    "$FW_BIN" regen-env main
    echo 'start_cmd='\''printf "%s\n" "$FW_WORKTREE" >ran-main.txt'\' \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    cd "$BATS_TEST_TMPDIR/myrepo"
    run "$FW_BIN" start main
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/myrepo/ran-main.txt")" = "main" ]
}

@test "fw start: runs start_cmd in the worktree with the env contract" {
    echo 'start_cmd='\''printf "%s|%s|%s\n" "$PWD" "$FW_WORKTREE" "$FW_BRANCH" >ran.txt'\' \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    run "$FW_BIN" start feat
    [ "$status" -eq 0 ]

    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/feat"
    [ -f "$wt/ran.txt" ]
    run cat "$wt/ran.txt"
    [[ "$output" == *"/feat|feat|me/feat" ]]
}

@test "fw start: sees the worktree env file keys" {
    echo 'start_cmd='\''printf "%s\n" "$FW_PORT_SLOT" >slot.txt'\' \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    run "$FW_BIN" start feat
    [ "$status" -eq 0 ]

    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/feat"
    run cat "$wt/slot.txt"
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "fw start: errors when start_cmd is not configured" {
    run "$FW_BIN" start feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"start_cmd"* ]]
}

@test "fw check: succeeds when check_cmd exits 0" {
    echo 'check_cmd="true"' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    run "$FW_BIN" check feat
    [ "$status" -eq 0 ]
}

@test "fw check: propagates a nonzero exit from check_cmd" {
    echo 'check_cmd="false"' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    run "$FW_BIN" check feat
    [ "$status" -ne 0 ]
}

@test "fw check: errors when check_cmd is not configured" {
    run "$FW_BIN" check feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"check_cmd"* ]]
}

@test "fw fix: runs fix_cmd in the worktree" {
    echo 'fix_cmd="touch fixed.txt"' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    run "$FW_BIN" fix feat
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/myproj-worktrees/feat/fixed.txt" ]
}

@test "fw fix: errors when fix_cmd is not configured" {
    run "$FW_BIN" fix feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"fix_cmd"* ]]
}

@test "fw start: resolves the worktree from cwd when no name is given" {
    echo 'start_cmd="touch here.txt"' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myproj-worktrees/feat"
    run "$FW_BIN" start
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/myproj-worktrees/feat/here.txt" ]
}
