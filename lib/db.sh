# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# Per-worktree Postgres databases, cloned from the golden checkout's dev
# database via CREATE DATABASE … TEMPLATE (instant, no dump/restore).
# Everything here is skipped when db_source is unset.
#
# We clone with the FILE_COPY strategy (createdb --strategy): it copies the
# template's files directly instead of WAL-logging every block, which is far
# faster for a large template (~0.5s vs ~7s for a 500MB DB on APFS). Its only
# cost is a forced checkpoint before and after the copy — negligible against an
# idle local golden template, which is exactly this tool's case. Requires
# Postgres 15+ (the --strategy flag); on older servers createdb errors and we
# fall through to db_setup_cmd below.

pg_terminate_connections() {
    psql -d postgres -qAtc \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
         WHERE datname='$1' AND pid <> pg_backend_pid();" \
        >/dev/null 2>&1 || true
}

# db_create_for_worktree <name> <branch> <wt_path>
# Template-clone from db_template (falling back to db_source); fall back to
# db_setup_cmd in the worktree. A pre-existing target DB is an error (stale
# leftover), not a fallback case.
db_create_for_worktree() {
    local name="$1" branch="$2" wt_path="$3"
    [[ -n "$db_source" ]] || return 0

    local db template err
    db="$(db_name_for_worktree "$name")"
    # Clone from the golden template when configured; otherwise db_source. The
    # template has no long-lived connections, so createdb -T never races the
    # main checkout's running server the way db_source does.
    template="${db_template:-$db_source}"
    echo "Cloning database $db from $template..."
    pg_terminate_connections "$template"
    if err="$(createdb --strategy=file_copy -T "$template" "$db" 2>&1)"; then
        return 0
    fi

    if [[ "$err" == *"already exists"* ]]; then
        echo "Error: database $db already exists (stale from a previous worktree?)" >&2
        echo "Drop it first: dropdb $db" >&2
        return 1
    fi

    echo "Template clone failed: $err" >&2
    if [[ -n "$db_setup_cmd" ]]; then
        echo "Running db_setup_cmd..."
        # The command sees the same env as hooks: FW_* plus the worktree's
        # env-file keys, so it targets the worktree's DB, not the default one.
        _run_in_worktree_env "$name" "$branch" "$wt_path" "$db_setup_cmd" || return 1
    else
        echo "Warning: could not clone $template and no db_setup_cmd is set" >&2
    fi
    return 0
}

# cmd_db [name] — open an interactive psql session on the worktree's database.
# DB features are presence-based: without db_source the project has no
# per-worktree database, so there is nothing to connect to.
cmd_db() {
    resolve_worktree "${1:-}" || return 1
    # shellcheck disable=SC2153  # WT_PATH is set by resolve_worktree
    read_worktree_env "$WT_PATH" || return 1

    if [[ -z "$db_source" ]]; then
        echo "Error: project '$project' has no database configured (set db_source)" >&2
        return 1
    fi
    if [[ -z "$WT_DB_NAME" ]]; then
        echo "Error: worktree '$WT_NAME' records no database (try 'fw regen-env $WT_NAME')" >&2
        return 1
    fi

    echo "Connecting to $WT_DB_NAME..."
    exec psql "$WT_DB_NAME"
}

# db_drop_for_worktree <wt_path>
# Drops the databases recorded in the worktree's env file.
db_drop_for_worktree() {
    local wt_path="$1"
    local db err
    if ! read_worktree_env "$wt_path" 2>/dev/null; then
        return 0
    fi
    for db in "$WT_DB_NAME" "$WT_TEST_DB_NAME"; do
        [[ -n "$db" ]] || continue
        # --force (DROP DATABASE … WITH FORCE) terminates any live backends and
        # drops in a single step. A plain terminate-then-dropdb races the
        # worktree's own server: its connection pool reconnects in the gap
        # between the two commands, so the drop fails with "being accessed by
        # other users" and the database leaks. Surface a failure rather than
        # swallowing it — a silently-swallowed drop error is what let stale
        # databases pile up unnoticed.
        if ! err="$(dropdb --force --if-exists "$db" 2>&1)"; then
            echo "Warning: could not drop database $db: $err" >&2
        fi
    done
    return 0
}
