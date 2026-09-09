load ../test_helper

setup() {
    isolate_env
    command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"
    source "$FW_ROOT/lib/config.sh"
    source "$FW_ROOT/lib/project.sh"
    source "$FW_ROOT/lib/worktree.sh"
    source "$FW_ROOT/lib/usage.sh"
    PROJECT_FLAG=""

    make_repo "$BATS_TEST_TMPDIR/alpha"
    register_project alpha "$BATS_TEST_TMPDIR/alpha"
    printf 'branch_prefix=jason\nusage_tz="-10:HST"\n' \
        >>"$FW_CONFIG_DIR/projects/alpha/config.sh"
    mkdir -p "$BATS_TEST_TMPDIR/alpha-worktrees"
    _usage_init_db
}

db() { sqlite3 "$USAGE_DB" "$@"; }

# add_session <id> <project|NULL> <worktree> <category|NULL> <cost> [output_tokens]
add_session() {
    local sid="$1" proj="$2" wt="$3" cat="$4" cost="$5" out="${6:-1000}"
    local proj_sql="'$proj'" cat_sql="'$cat'"
    [[ "$proj" == NULL ]] && proj_sql=NULL
    [[ "$cat" == NULL ]] && cat_sql=NULL
    db "INSERT INTO sessions (session_id, project, worktree, category, category_source,
            model, input_tokens, output_tokens, cache_create, cache_read, total_cost,
            first_activity, last_activity)
        VALUES ('$sid', $proj_sql, '$wt', $cat_sql, 'branch_prefix', 'claude-opus-5',
                1, $out, 1, 1, $cost, '2026-08-20T00:00:00Z', '2026-08-20T02:00:00Z');"
}

# add_transcripts <id> <main-cost> <sub-cost> [agent-type]
add_transcripts() {
    local sid="$1" main="$2" sub="$3" agent="${4:-Explore}"
    db "INSERT INTO main_loop (session_id, model, input_tokens, output_tokens, cache_create,
            cache_read, estimated_cost, cache_read_cost, cache_rewrites,
            cache_rewrite_tokens, cache_rewrite_cost, file_path, file_size, file_mtime)
        VALUES ('$sid', 'claude-opus-5', 1, 10, 1, 100, $main, 0, 0, 0, 0, '/m-$sid', 1, 1);"
    [[ "$sub" == 0 ]] && return 0
    db "INSERT INTO subagents (session_id, agent_id, agent_type, model, input_tokens,
            output_tokens, cache_create, cache_read, estimated_cost, cache_read_cost,
            file_path, file_size, file_mtime)
        VALUES ('$sid', 'a-$sid', '$agent', 'claude-opus-5', 1, 5, 1, 10, $sub, 0,
                '/a-$sid', 1, 1);"
}

in_project() { cd "$BATS_TEST_TMPDIR/alpha" || return 1; }

# --- summary ---

@test "usage summary: header totals, category split, and worktree rows" {
    in_project
    add_session s1 alpha jason-feature own 100
    add_transcripts s1 75 25
    add_session s2 alpha chris-thing review 40
    add_transcripts s2 40 0
    add_session s3 alpha odd-branch misc 10
    add_transcripts s3 10 0

    run cmd_usage summary --period all
    [ "$status" -eq 0 ]
    [[ "$output" == *"Claude Code Usage"* ]]
    [[ "$output" == *"3 sessions"* ]]
    [[ "$output" == *'$150'* ]]
    [[ "$output" == *"own"* ]]
    [[ "$output" == *"review"* ]]
    [[ "$output" == *"jason-feature"* ]]
    [[ "$output" == *"chris-thing"* ]]
    # 25 of 100 subagent on s1
    [[ "$output" == *"25%"* ]]
}

@test "usage summary: --category narrows the report" {
    in_project
    add_session s1 alpha jason-feature own 100
    add_session s2 alpha chris-thing review 40

    run cmd_usage summary --period all --category review
    [ "$status" -eq 0 ]
    [[ "$output" == *"chris-thing"* ]]
    [[ "$output" != *"jason-feature"* ]]
}

@test "usage summary: --weight moves the subagent share" {
    in_project
    add_session s1 alpha jason-feature own 100
    # Subagent is a quarter of the cost but two thirds of the output tokens.
    db "INSERT INTO main_loop (session_id, model, input_tokens, output_tokens,
            cache_create, cache_read, estimated_cost, cache_read_cost, file_path,
            file_size, file_mtime)
        VALUES ('s1','claude-opus-5',1,10,1,1,75,0,'/m',1,1);"
    db "INSERT INTO subagents (session_id, agent_id, agent_type, model, input_tokens,
            output_tokens, cache_create, cache_read, estimated_cost, cache_read_cost,
            file_path, file_size, file_mtime)
        VALUES ('s1','a1','Explore','claude-opus-5',1,20,1,1,25,0,'/a',1,1);"

    run cmd_usage summary --period all --weight cost
    [[ "$output" == *"25%"* ]]
    run cmd_usage summary --period all --weight output
    [[ "$output" == *"67%"* ]]
    [[ "$output" == *"output tokens"* ]]
}

@test "usage summary: header split rounds rather than truncates" {
    in_project
    add_session s1 alpha jason-feature own 100
    # Cost weights 50/25 → sub share 33.33, main 66.67: main must round to
    # $67, not floor to $66 (sqlite's printf('%.0f') truncates on its own).
    add_transcripts s1 50 25

    run cmd_usage summary --period all
    [ "$status" -eq 0 ]
    [[ "$output" == *'main $67'* ]]
    [[ "$output" == *'subagents $33'* ]]
}

@test "usage summary: other registered projects appear as one-line subtotals" {
    make_repo "$BATS_TEST_TMPDIR/beta"
    register_project beta "$BATS_TEST_TMPDIR/beta"
    in_project
    add_session s1 alpha jason-feature own 100
    add_session s2 beta bee-thing own 60
    add_session s3 beta bee-other own 20

    run cmd_usage summary --period all
    [ "$status" -eq 0 ]
    [[ "$output" == *"jason-feature"* ]]
    [[ "$output" == *"beta"* ]]
    # The other project is summarised, not expanded into its worktrees.
    [[ "$output" != *"bee-thing"* ]]
    [[ "$output" == *'$80'* ]]
}

@test "usage summary: with no active project every project gets a section" {
    make_repo "$BATS_TEST_TMPDIR/beta"
    register_project beta "$BATS_TEST_TMPDIR/beta"
    cd "$BATS_TEST_TMPDIR"
    add_session s1 alpha jason-feature own 100
    add_session s2 beta bee-thing own 60

    run cmd_usage summary --period all
    [ "$status" -eq 0 ]
    [[ "$output" == *"jason-feature"* ]]
    [[ "$output" == *"bee-thing"* ]]
}

@test "usage summary: -p reorders which project leads" {
    make_repo "$BATS_TEST_TMPDIR/beta"
    register_project beta "$BATS_TEST_TMPDIR/beta"
    in_project
    add_session s1 alpha jason-feature own 100
    add_session s2 beta bee-thing own 60

    PROJECT_FLAG=beta run cmd_usage summary --period all
    [ "$status" -eq 0 ]
    [[ "$output" == *"bee-thing"* ]]
    [[ "$output" != *"jason-feature"* ]]
}

@test "usage summary: unclaimed directories are listed apart but stay in the total" {
    in_project
    add_session s1 alpha jason-feature own 100
    add_session s2 NULL -Users-jason-dev-forks-elsewhere NULL 30
    db "INSERT INTO projects (project_dir, cwd)
        VALUES ('-Users-jason-dev-forks-elsewhere', '$HOME/dev/forks/elsewhere');"

    run cmd_usage summary --period all
    [ "$status" -eq 0 ]
    [[ "$output" == *"Other projects"* ]]
    [[ "$output" == *"~/dev/forks/elsewhere"* ]]
    # In the grand total, out of the category split.
    [[ "$output" == *'$130'* ]]
}

@test "usage summary --json: rows carry project, worktree, and the weight basis" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    in_project
    add_session s1 alpha jason-feature own 100
    add_transcripts s1 75 25

    run cmd_usage summary --period all --json --weight output
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.[0].project')" = "alpha" ]
    [ "$(printf '%s' "$output" | jq -r '.[0].worktree')" = "jason-feature" ]
    [ "$(printf '%s' "$output" | jq -r '.[0].weight_basis')" = "output" ]
    [ "$(printf '%s' "$output" | jq -r '.[0].cost')" = "100.0" ]
}

@test "usage: an empty window says so instead of printing an empty table" {
    in_project
    run cmd_usage summary --since 2030-01-01
    [ "$status" -eq 0 ]
    [[ "$output" == *"No usage data"* ]]
}

# --- detail ---

@test "usage <worktree>: shows the session breakdown with the subagent split" {
    in_project
    add_session s1 alpha jason-feature own 100
    add_transcripts s1 75 25 Explore

    run cmd_usage jason-feature --period all
    [ "$status" -eq 0 ]
    [[ "$output" == *"jason-feature"* ]]
    [[ "$output" == *"1 sessions"* ]]
    [[ "$output" == *"Main loop"* ]]
    [[ "$output" == *"Explore"* ]]
    [[ "$output" == *"75.00"* ]]
    [[ "$output" == *"25.00"* ]]
}

@test "usage <worktree>: a session with no subagents says so" {
    in_project
    add_session s1 alpha jason-feature own 100
    add_transcripts s1 100 0

    run cmd_usage jason-feature --period all
    [ "$status" -eq 0 ]
    [[ "$output" == *"no subagents"* ]]
}

@test "usage <prefix>: a unique prefix of a stored worktree resolves" {
    in_project
    add_session s1 alpha jason-feature-long-name own 100
    add_transcripts s1 100 0

    run cmd_usage jason-feature --period all
    [ "$status" -eq 0 ]
    [[ "$output" == *"jason-feature-long-name"* ]]
}

@test "usage <branch>: a branch name resolves to its worktree" {
    in_project
    mkdir -p "$BATS_TEST_TMPDIR/alpha-worktrees/jason-feature"
    echo "FW_BRANCH=jason/feature" >"$BATS_TEST_TMPDIR/alpha-worktrees/jason-feature/.env.worktree"
    add_session s1 alpha jason-feature own 100
    add_transcripts s1 100 0

    run cmd_usage jason/feature --period all
    [ "$status" -eq 0 ]
    [[ "$output" == *"jason-feature"* ]]
}

@test "usage <worktree>: with no active project the name still finds its rows" {
    cd "$BATS_TEST_TMPDIR"
    add_session s1 alpha jason-feature own 100
    add_transcripts s1 100 0

    run cmd_usage jason-feature --period all
    [ "$status" -eq 0 ]
    [[ "$output" == *"jason-feature"* ]]
    [[ "$output" == *"1 sessions"* ]]
}

@test "usage <worktree>: an unknown name is a loud error with a hint" {
    in_project
    add_session s1 alpha jason-feature own 100
    run cmd_usage nothing-like-this --period all
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
    [[ "$output" == *"summary"* ]]
}

@test "usage <path>: a recorded directory resolves through the projects table" {
    in_project
    mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
    add_session s1 NULL -Users-jason-dev-forks-elsewhere NULL 30
    add_transcripts s1 30 0
    db "INSERT INTO projects (project_dir, cwd)
        VALUES ('-Users-jason-dev-forks-elsewhere', '$(cd "$BATS_TEST_TMPDIR/elsewhere" && pwd)');"

    run cmd_usage "$BATS_TEST_TMPDIR/elsewhere" --period all
    [ "$status" -eq 0 ]
    [[ "$output" == *"elsewhere"* ]]
    [[ "$output" == *"1 sessions"* ]]
}

@test "usage <path>: a directory Claude never ran in is a loud error" {
    in_project
    add_session s1 alpha jason-feature own 100
    run cmd_usage "$BATS_TEST_TMPDIR/alpha-worktrees" --period all
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
    [[ "$output" == *"usage"* ]]
}

@test "usage <worktree> --json: emits per-session rows with UTC timestamps" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    in_project
    add_session s1 alpha jason-feature own 100
    add_transcripts s1 75 25

    run cmd_usage jason-feature --period all --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.[0].session_id')" = "s1" ]
    [ "$(printf '%s' "$output" | jq -r '.[0].subagent_cost')" = "25.0" ]
    [ "$(printf '%s' "$output" | jq -r '.[0].first_activity')" = "2026-08-20T00:00:00Z" ]
}

@test "usage: inside a worktree with no argument reports that worktree" {
    add_session s1 alpha jason-feature own 100
    add_transcripts s1 100 0
    git -C "$BATS_TEST_TMPDIR/alpha" worktree add -q \
        "$BATS_TEST_TMPDIR/alpha-worktrees/jason-feature" -b jason/feature
    cd "$BATS_TEST_TMPDIR/alpha-worktrees/jason-feature"

    run cmd_usage --period all
    [ "$status" -eq 0 ]
    [[ "$output" == *"jason-feature"* ]]
}

# --- argument handling ---

@test "usage: an invalid --category is rejected" {
    in_project
    run cmd_usage summary --category nonsense
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
    [[ "$output" == *"own"* ]]
}

@test "usage: an invalid --weight is rejected" {
    in_project
    run cmd_usage summary --weight bananas
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
}

@test "usage: an unknown flag is rejected" {
    in_project
    run cmd_usage summary --nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
}

@test "usage --help: documents the subcommands and flags" {
    in_project
    run cmd_usage --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"fw usage"* ]]
    [[ "$output" == *"sync"* ]]
    [[ "$output" == *"summary"* ]]
    [[ "$output" == *"--weight"* ]]
    [[ "$output" == *"--period"* ]]
}

# --- display zone ---

@test "usage summary: the header names the display zone" {
    in_project
    add_session s1 alpha jason-feature own 100

    run cmd_usage summary --since 2026-08-01
    [ "$status" -eq 0 ]
    [[ "$output" == *"since 2026-08-01 HST"* ]]
}

@test "usage <worktree>: session dates render in the display zone" {
    in_project
    add_session s1 alpha jason-feature own 100
    add_transcripts s1 100 0

    run cmd_usage jason-feature --period all
    [ "$status" -eq 0 ]
    [[ "$output" != *"invalid number"* ]]
    # Stored 2026-08-20T00:00:00Z, which is the 19th in HST.
    [[ "$output" == *"2026-08-19"* ]]
}
