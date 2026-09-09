load ../test_helper

# `fw db` execs a bare `psql` (PATH seam). These tests don't need a real
# Postgres cluster: a fake psql on PATH records the database name it was
# handed, so we can assert `fw db` connects to the worktree's DB. (A global
# tests/shims/psql would shadow the real psql the db.bats suite needs, so the
# fake lives in a per-test bin dir prepended to PATH.)

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    {
        echo 'branch_prefix=me'
        echo 'db_prefix=fwtest_'
    } >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"

    # Fake psql that records its args instead of connecting.
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/psql" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$BATS_TEST_TMPDIR/psql-args"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/psql"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Build a worktree dir + env file by hand (no real DB ops needed).
make_worktree() {
    local name="$1" db="${2:-}"
    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/$name"
    mkdir -p "$wt"
    {
        echo "FW_WORKTREE=$name"
        echo "FW_BRANCH=me/$name"
        echo "FW_PORT_SLOT=123"
        if [[ -n "$db" ]]; then
            echo "FW_DB_NAME=$db"
            echo "FW_TEST_DB_NAME=${db}_test"
        fi
    } >"$wt/.env.worktree"
}

@test "fw db: connects psql to the worktree database" {
    echo 'db_source=some_template' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    make_worktree feat fwtest_feat

    run "$FW_BIN" db feat
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/psql-args" ]
    run cat "$BATS_TEST_TMPDIR/psql-args"
    [ "$output" = "fwtest_feat" ]
}

@test "fw db: errors when the project has no database configured" {
    # db_source unset -> DB features disabled
    make_worktree feat

    run "$FW_BIN" db feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"no database"* || "$output" == *"db_source"* ]]
    [ ! -f "$BATS_TEST_TMPDIR/psql-args" ]
}

@test "fw db: errors for a missing worktree" {
    echo 'db_source=some_template' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    run "$FW_BIN" db nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}
