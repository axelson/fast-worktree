load ../test_helper

setup() {
    isolate_env
    if ! command -v pg_isready >/dev/null 2>&1 || ! pg_isready -q 2>/dev/null; then
        skip "postgres not available"
    fi

    # Real databases on the local cluster — everything namespaced fwtest_ and
    # dropped in teardown.
    TEST_ID="${BATS_TEST_NUMBER}_$$"
    TEMPLATE_DB="fwtest_tmpl_${TEST_ID}"
    DB_PREFIX="fwtest_wt_${TEST_ID}_"

    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    {
        echo 'branch_prefix=me'
        echo "db_prefix=$DB_PREFIX"
    } >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

teardown() {
    [[ -n "${TEMPLATE_DB:-}" ]] || return 0
    # A test may have left a reconnecting client pool alive; stop it and drop any
    # lingering connections so the cleanup drops below can't be blocked.
    pkill -f "psql -d ${DB_PREFIX}feat" 2>/dev/null || true
    psql -d postgres -qAtc \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
         WHERE datname LIKE '${DB_PREFIX}feat%' AND pid <> pg_backend_pid();" \
        >/dev/null 2>&1 || true
    dropdb --if-exists "$TEMPLATE_DB" 2>/dev/null || true
    dropdb --if-exists "${DB_PREFIX}feat" 2>/dev/null || true
    dropdb --if-exists "${DB_PREFIX}feat_test" 2>/dev/null || true
}

db_exists() {
    psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$1'" | grep -q 1
}

@test "fw create: clones the worktree database from db_source" {
    createdb "$TEMPLATE_DB"
    psql -q -d "$TEMPLATE_DB" -c "CREATE TABLE marker (id int);"
    echo "db_source=$TEMPLATE_DB" >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    run "$FW_BIN" create feat
    [ "$status" -eq 0 ]

    db_exists "${DB_PREFIX}feat"
    psql -d "${DB_PREFIX}feat" -tAc "SELECT count(*) FROM marker" | grep -q 0
}

@test "fw create: clones from db_template when set, not db_source" {
    # db_source names a database that is never touched here; the marker table
    # lives only in the template, so a successful clone proves db_template was
    # the source.
    createdb "$TEMPLATE_DB"
    psql -q -d "$TEMPLATE_DB" -c "CREATE TABLE marker (id int);"
    {
        echo "db_source=fwtest_live_${TEST_ID}"
        echo "db_template=$TEMPLATE_DB"
    } >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    run "$FW_BIN" create feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"from $TEMPLATE_DB"* ]]

    db_exists "${DB_PREFIX}feat"
    psql -d "${DB_PREFIX}feat" -tAc "SELECT count(*) FROM marker" | grep -q 0
}

@test "fw create: db_template falls back to db_source when unset" {
    createdb "$TEMPLATE_DB"
    psql -q -d "$TEMPLATE_DB" -c "CREATE TABLE marker (id int);"
    echo "db_source=$TEMPLATE_DB" >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    run "$FW_BIN" create feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"from $TEMPLATE_DB"* ]]

    db_exists "${DB_PREFIX}feat"
    psql -d "${DB_PREFIX}feat" -tAc "SELECT count(*) FROM marker" | grep -q 0
}

@test "fw create: no database is created when db_source is unset" {
    "$FW_BIN" create feat

    ! db_exists "${DB_PREFIX}feat"
}

@test "fw create: falls back to db_setup_cmd when the template clone fails" {
    echo "db_source=fwtest_does_not_exist_${TEST_ID}" >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    echo 'db_setup_cmd="touch fallback-ran"' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    run "$FW_BIN" create feat
    [ "$status" -eq 0 ]

    [ -f "$BATS_TEST_TMPDIR/myproj-worktrees/feat/fallback-ran" ]
}

@test "fw create: db_setup_cmd fallback runs with the worktree env in scope" {
    echo "db_source=fwtest_does_not_exist_${TEST_ID}" >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
db_setup_cmd='echo "$FW_DB_NAME:$FW_WORKTREE:$FW_BRANCH:$FW_WORKTREE_PATH:$(pwd)" > fallback-env'
EOF

    run "$FW_BIN" create feat
    [ "$status" -eq 0 ]

    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/feat"
    [ "$(cat "$wt/fallback-env")" = "${DB_PREFIX}feat:feat:me/feat:$wt:$wt" ]
}

@test "fw create: hook_pre_db runs before the db_setup_cmd fallback" {
    echo "db_source=fwtest_does_not_exist_${TEST_ID}" >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_pre_db() { echo pre_db >>"$FW_WORKTREE_PATH/order.log"; }
db_setup_cmd='echo db_setup >>"$FW_WORKTREE_PATH/order.log"'
hook_post_create() { echo post_create >>"$FW_WORKTREE_PATH/order.log"; }
EOF

    run "$FW_BIN" create feat
    [ "$status" -eq 0 ]

    # pre_db + db_setup run synchronously; post_create appends from the
    # background window, so wait for the third line before asserting order.
    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/feat" i
    for i in $(seq 1 25); do
        [ -f "$wt/order.log" ] && [ "$(wc -l <"$wt/order.log")" -ge 3 ] && break
        sleep 0.2
    done
    run cat "$wt/order.log"
    [ "${lines[0]}" = "pre_db" ]
    [ "${lines[1]}" = "db_setup" ]
    [ "${lines[2]}" = "post_create" ]
}

@test "fw create: aborts with a clear error when the target DB already exists" {
    createdb "$TEMPLATE_DB"
    createdb "${DB_PREFIX}feat"
    echo "db_source=$TEMPLATE_DB" >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    run "$FW_BIN" create feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists"* ]]
    [[ "$output" == *"${DB_PREFIX}feat"* ]]

    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
    db_exists "${DB_PREFIX}feat"
}

@test "fw create: a missing template surfaces the real error text" {
    echo "db_source=fwtest_does_not_exist_${TEST_ID}" >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    run "$FW_BIN" create feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"fwtest_does_not_exist_${TEST_ID}"* ]]
}

@test "fw delete: drops the worktree databases" {
    createdb "$TEMPLATE_DB"
    echo "db_source=$TEMPLATE_DB" >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    "$FW_BIN" create feat
    createdb "${DB_PREFIX}feat_test"
    db_exists "${DB_PREFIX}feat"

    run "$FW_BIN" delete feat
    [ "$status" -eq 0 ]

    ! db_exists "${DB_PREFIX}feat"
    ! db_exists "${DB_PREFIX}feat_test"
}

@test "fw delete: force-drops the database so open connections can't defeat it" {
    createdb "$TEMPLATE_DB"
    echo "db_source=$TEMPLATE_DB" >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    "$FW_BIN" create feat
    db_exists "${DB_PREFIX}feat"

    # The worktree's own server holds a connection pool to this DB at delete
    # time. A plain terminate-then-dropdb races that pool: it reconnects between
    # the terminate and the drop, so dropdb fails ("being accessed by other
    # users") and — with the error swallowed — the DB leaks. The drop must be
    # atomic (dropdb --force) so no reconnect can slip in.
    #
    # Whether the race actually leaks is load-dependent (a heavyweight caller
    # lets dropdb win), so it can't gate a test. We instead (a) hold real open
    # connections and prove the drop still succeeds, and (b) assert via a
    # recording shim that the drop used the atomic --force form.
    local -a pool=() c
    for c in 1 2 3 4 5; do
        psql -d "${DB_PREFIX}feat" -qAtc "SELECT pg_sleep(3600)" >/dev/null 2>&1 &
        pool+=($!)
    done
    local conns i
    for i in $(seq 1 50); do
        conns="$(psql -d postgres -tAc \
            "SELECT count(*) FROM pg_stat_activity WHERE datname='${DB_PREFIX}feat'")"
        [ "${conns:-0}" -ge 5 ] && break
        sleep 0.1
    done

    # Shim dropdb (bare-name PATH seam) to record every invocation, then forward
    # to the real one so the DB is genuinely dropped.
    local shimdir="$BATS_TEST_TMPDIR/shim" real_dropdb
    mkdir -p "$shimdir"
    real_dropdb="$(command -v dropdb)"
    cat >"$shimdir/dropdb" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/dropdb.args"
exec "$real_dropdb" "\$@"
EOF
    chmod +x "$shimdir/dropdb"

    PATH="$shimdir:$PATH" run "$FW_BIN" delete feat
    local st="$status"

    for c in "${pool[@]}"; do kill "$c" 2>/dev/null || true; done

    [ "$st" -eq 0 ]
    ! db_exists "${DB_PREFIX}feat"
    # Every dropdb the delete issued must be a force drop.
    [ -f "$BATS_TEST_TMPDIR/dropdb.args" ]
    run cat "$BATS_TEST_TMPDIR/dropdb.args"
    local line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        [[ "$line" == *"--force"* ]] || { echo "non-force dropdb call: $line"; return 1; }
    done <<<"$output"
}
