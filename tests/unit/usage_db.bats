load ../test_helper

setup() {
    isolate_env
    command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"
    source "$FW_ROOT/lib/config.sh"
    source "$FW_ROOT/lib/usage.sh"
}

db() { sqlite3 "$USAGE_DB" "$@"; }

# One session with a main-loop and a subagent transcript behind it, so the
# weight views have something to split.
seed_session() {
    db "
INSERT INTO sessions (session_id, project, worktree, category, category_source,
                      model, input_tokens, output_tokens, cache_create, cache_read,
                      total_cost, first_activity, last_activity)
VALUES ('s1', 'myproj', 'feat', 'own', 'branch_prefix', 'claude-opus-5',
        100, 200, 300, 400, 10.0, '2026-08-01T00:00:00Z', '2026-08-01T01:00:00Z');
INSERT INTO main_loop (session_id, model, input_tokens, output_tokens, cache_create,
                       cache_read, estimated_cost, cache_read_cost,
                       cache_rewrites, cache_rewrite_tokens, cache_rewrite_cost,
                       file_path, file_size, file_mtime)
VALUES ('s1', 'claude-opus-5', 10, 90, 0, 900, 6.0, 3.0, 2, 5000, 1.0, '/m.jsonl', 1, 1);
INSERT INTO subagents (session_id, agent_id, agent_type, model, input_tokens,
                       output_tokens, cache_create, cache_read, estimated_cost,
                       cache_read_cost, file_path, file_size, file_mtime)
VALUES ('s1', 'a1', 'Explore', 'claude-opus-5', 10, 10, 0, 100, 2.0, 0.5, '/a.jsonl', 1, 1);
"
}

@test "_usage_init_db: puts the cache DB under XDG_CACHE_HOME and creates it" {
    [[ "$USAGE_DB" == "$HOME/.cache/fast-worktree/usage.db" ]]
    _usage_init_db
    [ -f "$USAGE_DB" ]
}

@test "_usage_init_db: sessions carries a project column" {
    _usage_init_db
    run db "SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name = 'project';"
    [ "$output" = "1" ]
}

@test "_usage_init_db: creates the parser's tables so reads never hit a missing table" {
    _usage_init_db
    run db "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"
    [[ "$output" == *"main_loop"* ]]
    [[ "$output" == *"projects"* ]]
    [[ "$output" == *"sessions"* ]]
    [[ "$output" == *"subagents"* ]]
}

@test "_usage_init_db: indexes sessions by project and worktree" {
    _usage_init_db
    run db "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='sessions';"
    [[ "$output" == *"idx_sessions_project_worktree"* ]]
}

@test "_usage_init_db: each weight view splits the ccusage total, never adds to it" {
    _usage_init_db
    seed_session
    local mode
    for mode in cost output tokens; do
        run db "SELECT printf('%.4f', main_cost + sub_cost), printf('%.4f', total_cost)
                FROM session_costs_${mode} WHERE session_id = 's1';"
        [ "$status" -eq 0 ]
        [ "$output" = "10.0000|10.0000" ]
    done
}

@test "_usage_init_db: the weight basis changes the subagent share" {
    _usage_init_db
    seed_session
    # cost basis: 2 of 8 dollars are subagent. output basis: 10 of 100 tokens.
    run db "SELECT printf('%.2f', sub_cost) FROM session_costs_cost WHERE session_id='s1';"
    [ "$output" = "2.50" ]
    run db "SELECT printf('%.2f', sub_cost) FROM session_costs_output WHERE session_id='s1';"
    [ "$output" = "1.00" ]
}

@test "_usage_init_db: views expose the project column for per-project reporting" {
    _usage_init_db
    seed_session
    run db "SELECT project FROM session_costs_cost WHERE session_id = 's1';"
    [ "$output" = "myproj" ]
}

@test "_usage_init_db: cache-read and rewrite percentages come off the parser figures" {
    _usage_init_db
    seed_session
    # cache_read_cost 3.0 + 0.5 of 8.0 total parser cost = 43.75%.
    run db "SELECT printf('%.2f', cache_read_pct), cache_rewrites, cache_rewrite_tokens,
                   printf('%.2f', cache_rewrite_pct)
            FROM session_costs_cost WHERE session_id = 's1';"
    [ "$output" = "43.75|2|5000|12.50" ]
}

@test "_usage_init_db: is idempotent" {
    _usage_init_db
    seed_session
    _usage_init_db
    run db "SELECT COUNT(*) FROM sessions;"
    [ "$output" = "1" ]
}

@test "_usage_init_db: backfills cache-rewrite columns onto an older main_loop" {
    mkdir -p "$(dirname "$USAGE_DB")"
    db "CREATE TABLE main_loop (
            id INTEGER PRIMARY KEY, session_id TEXT, model TEXT,
            input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
            cache_create INTEGER DEFAULT 0, cache_read INTEGER DEFAULT 0,
            estimated_cost REAL DEFAULT 0, cache_read_cost REAL DEFAULT 0,
            file_path TEXT, file_size INTEGER, file_mtime INTEGER DEFAULT 0);"

    _usage_init_db

    run db "SELECT COUNT(*) FROM pragma_table_info('main_loop')
            WHERE name IN ('cache_rewrites','cache_rewrite_tokens','cache_rewrite_cost');"
    [ "$output" = "3" ]
    run db "SELECT COUNT(*) FROM session_costs_cost;"
    [ "$status" -eq 0 ]
}

@test "_usage_require_sqlite3: missing sqlite3 is a loud error" {
    mkdir -p "$BATS_TEST_TMPDIR/empty"
    PATH="$BATS_TEST_TMPDIR/empty" run _usage_require_sqlite3
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
    [[ "$output" == *"sqlite3"* ]]
}

@test "_sql_quote: doubles embedded single quotes" {
    run _sql_quote "it's"
    [ "$output" = "it''s" ]
}

@test "_usage_weight_expr: names the column each basis weights by" {
    [ "$(_usage_weight_expr cost)" = "estimated_cost" ]
    [ "$(_usage_weight_expr output)" = "output_tokens" ]
    [[ "$(_usage_weight_expr tokens)" == *"cache_read"* ]]
}

@test "_usage_weight_label: reads as English in the header line" {
    [ "$(_usage_weight_label cost)" = "cost" ]
    [ "$(_usage_weight_label output)" = "output tokens" ]
    [ "$(_usage_weight_label tokens)" = "all tokens" ]
}
