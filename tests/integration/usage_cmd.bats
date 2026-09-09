load ../test_helper

setup() { isolate_env; }

@test "fw help: lists the usage command" {
    run "$FW_BIN" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"usage"* ]]
    [[ "$output" == *"Claude Code token usage"* ]]
}

@test "fw usage --help: reaches the command's own help" {
    run "$FW_BIN" usage --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"fw usage"* ]]
    [[ "$output" == *"--weight"* ]]
}

@test "fw usage: runs outside any registered project" {
    command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"
    cd "$BATS_TEST_TMPDIR"
    run "$FW_BIN" usage summary
    [ "$status" -eq 0 ]
    [[ "$output" == *"No usage data"* ]]
}

@test "fw usage: reports a project's worktree end to end" {
    command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"
    make_repo "$BATS_TEST_TMPDIR/myapp"
    register_project myapp "$BATS_TEST_TMPDIR/myapp"
    echo "branch_prefix=jason" >>"$FW_CONFIG_DIR/projects/myapp/config.sh"
    mkdir -p "$HOME/.cache/fast-worktree"
    sqlite3 "$HOME/.cache/fast-worktree/usage.db" \
        "CREATE TABLE sessions (session_id TEXT PRIMARY KEY, project TEXT, worktree TEXT,
             category TEXT, category_source TEXT, model TEXT, input_tokens INTEGER,
             output_tokens INTEGER, cache_create INTEGER, cache_read INTEGER,
             total_cost REAL, first_activity TEXT, last_activity TEXT);
         INSERT INTO sessions VALUES ('s1','myapp','jason-feature','own','branch_prefix',
             'claude-opus-5',1,2000,1,1,42.0,'2026-08-20T00:00:00Z','2026-08-20T01:00:00Z');"
    cd "$BATS_TEST_TMPDIR/myapp"

    run "$FW_BIN" usage summary --period all
    [ "$status" -eq 0 ]
    [[ "$output" == *"myapp"* ]]
    [[ "$output" == *"jason-feature"* ]]
    [[ "$output" == *'$42'* ]]

    run "$FW_BIN" usage jason-feature --period all
    [ "$status" -eq 0 ]
    [[ "$output" == *"jason-feature"* ]]
}

@test "fw usage: missing sqlite3 is a loud error, not an empty report" {
    mkdir -p "$BATS_TEST_TMPDIR/nosqlite"
    ln -s /usr/bin/* /bin/* "$BATS_TEST_TMPDIR/nosqlite/" 2>/dev/null || true
    rm -f "$BATS_TEST_TMPDIR/nosqlite/sqlite3"
    # The entrypoint re-execs itself under a bash >= 4 found on PATH, so the
    # cut-down PATH still needs the one the suite runs under.
    ln -sf "$(command -v bash)" "$BATS_TEST_TMPDIR/nosqlite/bash"
    cd "$BATS_TEST_TMPDIR"

    PATH="$BATS_TEST_TMPDIR/nosqlite" run "$FW_BIN" usage summary
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
    [[ "$output" == *"sqlite3"* ]]
}

@test "fw usage: an unknown flag fails through the binary" {
    run "$FW_BIN" usage summary --bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
}
