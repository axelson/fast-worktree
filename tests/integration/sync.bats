load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/origin"
    git clone -q "$BATS_TEST_TMPDIR/origin" "$BATS_TEST_TMPDIR/myrepo" 2>/dev/null
    git -C "$BATS_TEST_TMPDIR/myrepo" checkout -q main
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

advance_origin() {
    git -C "$BATS_TEST_TMPDIR/origin" -c user.email=t@t -c user.name=t \
        commit -q --allow-empty -m "upstream work"
}

@test "fw sync: fast-forwards the golden checkout to origin trunk" {
    advance_origin

    run "$FW_BIN" sync
    [ "$status" -eq 0 ]

    [ "$(git -C "$BATS_TEST_TMPDIR/myrepo" rev-parse main)" = \
      "$(git -C "$BATS_TEST_TMPDIR/origin" rev-parse main)" ]
}

@test "fw sync: does not leak raw fetch progress" {
    advance_origin

    run "$FW_BIN" sync
    [ "$status" -eq 0 ]
    [[ "$output" != *"FETCH_HEAD"* ]]
}

@test "fw sync: runs hook_sync in the repo root with flags passed through" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_sync() { echo "args:$* pwd:$(pwd)" >"$FW_REPO_ROOT/sync-hook-ran"; }
EOF

    run "$FW_BIN" sync --no-mobile --custom-flag
    [ "$status" -eq 0 ]

    [ "$(cat "$BATS_TEST_TMPDIR/myrepo/sync-hook-ran")" = \
      "args:--no-mobile --custom-flag pwd:$BATS_TEST_TMPDIR/myrepo" ]
}

@test "fw sync: self-heals a clean golden checkout onto trunk" {
    git -C "$BATS_TEST_TMPDIR/myrepo" checkout -q -b sidetracked
    advance_origin

    run "$FW_BIN" sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"sidetracked"* ]]

    run git -C "$BATS_TEST_TMPDIR/myrepo" branch --show-current
    [ "$output" = "main" ]
}

@test "fw sync: refuses a dirty golden checkout that is off trunk" {
    git -C "$BATS_TEST_TMPDIR/myrepo" checkout -q -b sidetracked
    echo dirty >"$BATS_TEST_TMPDIR/myrepo/uncommitted.txt"

    run "$FW_BIN" sync
    [ "$status" -ne 0 ]
    [[ "$output" == *"sidetracked"* ]]
    [[ "$output" == *"uncommitted"* ]]
}

@test "fw sync: a failing hook_sync fails the sync" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_sync() { echo "build exploded" >&2; return 1; }
EOF

    run "$FW_BIN" sync
    [ "$status" -ne 0 ]
    [[ "$output" == *"build exploded"* ]]
}

@test "fw sync: runs the stack backend sync op" {
    echo 'stack_backend=graphite' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GT_LOG="$BATS_TEST_TMPDIR/gt.log"

    run "$FW_BIN" sync
    [ "$status" -eq 0 ]

    grep -q "sync --no-interactive" "$FW_TEST_GT_LOG"
}

@test "fw sync: works without an origin remote" {
    git -C "$BATS_TEST_TMPDIR/myrepo" remote remove origin
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_sync() { touch "$FW_REPO_ROOT/hook-ran"; }
EOF

    run "$FW_BIN" sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"no origin"* ]]
    [ -f "$BATS_TEST_TMPDIR/myrepo/hook-ran" ]
}
