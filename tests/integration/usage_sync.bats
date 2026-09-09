load ../test_helper

setup() {
    isolate_env
    command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    source "$FW_ROOT/lib/config.sh"
    source "$FW_ROOT/lib/project.sh"
    source "$FW_ROOT/lib/usage.sh"

    mkdir -p "$BATS_TEST_TMPDIR/bin"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    CCUSAGE_JSON="$BATS_TEST_TMPDIR/ccusage.json"
    export CCUSAGE_JSON
    cat >"$BATS_TEST_TMPDIR/bin/npx" <<'EOF'
#!/bin/sh
echo "$@" >>"$CCUSAGE_ARGS"
[ -n "$CCUSAGE_FAIL" ] && exit 1
cat "$CCUSAGE_JSON"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/npx"
    CCUSAGE_ARGS="$BATS_TEST_TMPDIR/ccusage.args"
    export CCUSAGE_ARGS

    # The parser has its own unit tests; here it is a recording stub, so the
    # pipeline's stages are what's under test.
    _ensure_usage_parser() { return 0; }
    _run_usage_parser() { printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/parser.log"; }

    make_repo "$BATS_TEST_TMPDIR/alpha"
    register_project alpha "$BATS_TEST_TMPDIR/alpha"
    echo "branch_prefix=jason" >>"$FW_CONFIG_DIR/projects/alpha/config.sh"
    ALPHA_WT="$BATS_TEST_TMPDIR/alpha-worktrees"
    mkdir -p "$ALPHA_WT"
}

db() { sqlite3 "$USAGE_DB" "$@"; }

# ccusage reports the Claude project directory, which mangles every character
# outside [A-Za-z0-9] to "-".
mangle() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

# write_ccusage <dir> <session-id> [<dir> <session-id> ...]
write_ccusage() {
    local out="" dir sid
    while [[ $# -gt 0 ]]; do
        dir="$1"; sid="$2"; shift 2
        [[ -n "$out" ]] && out="$out,"
        out="$out{\"sessionId\":\"$sid\",\"projectPath\":\"$dir\",\"modelsUsed\":[\"claude-opus-5\"],\"inputTokens\":10,\"outputTokens\":20,\"cacheCreationTokens\":30,\"cacheReadTokens\":40,\"totalCost\":1.5,\"firstActivity\":\"2026-08-20T00:00:00Z\",\"lastActivity\":\"2026-08-20T01:00:00Z\"}"
    done
    printf '{"sessions":[%s]}\n' "$out" >"$CCUSAGE_JSON"
}

@test "sync: resolves each session to its project and worktree" {
    write_ccusage "$(mangle "$ALPHA_WT/jason-feature")" s1
    run _usage_sync "" 30d
    [ "$status" -eq 0 ]
    run db "SELECT project, worktree, category, category_source FROM sessions;"
    [ "$output" = "alpha|jason-feature|own|branch_prefix" ]
}

@test "sync: a project's main checkout lands under the worktree name 'main'" {
    write_ccusage "$(mangle "$BATS_TEST_TMPDIR/alpha")" s1
    _usage_sync "" 30d
    run db "SELECT project, worktree FROM sessions;"
    [ "$output" = "alpha|main" ]
}

@test "sync: a directory no project claims keeps its mangled name and no category" {
    write_ccusage "-Users-jason-dev-forks-elsewhere" s1
    _usage_sync "" 30d
    run db "SELECT COALESCE(project,'NULL'), worktree, COALESCE(category,'NULL') FROM sessions;"
    [ "$output" = "NULL|-Users-jason-dev-forks-elsewhere|NULL" ]
}

@test "sync: each project classifies its own sessions with its own config and hook" {
    make_repo "$BATS_TEST_TMPDIR/beta"
    register_project beta "$BATS_TEST_TMPDIR/beta"
    cat >>"$FW_CONFIG_DIR/projects/beta/config.sh" <<'EOF'
branch_prefix=bee
usage_extra_prefixes=("shared:misc")
hook_usage_classify() {
    [[ "$1" == special-* ]] || return 1
    echo "review|beta_hook"
}
EOF
    local beta_wt="$BATS_TEST_TMPDIR/beta-worktrees"
    write_ccusage \
        "$(mangle "$ALPHA_WT/jason-feature")" s1 \
        "$(mangle "$ALPHA_WT/shared-thing")" s2 \
        "$(mangle "$beta_wt/bee-feature")" s3 \
        "$(mangle "$beta_wt/special-thing")" s4 \
        "$(mangle "$beta_wt/shared-thing")" s5
    _usage_sync "" 30d

    run db "SELECT session_id, project, worktree, category, category_source
            FROM sessions ORDER BY session_id;"
    [ "${lines[0]}" = "s1|alpha|jason-feature|own|branch_prefix" ]
    # alpha has no extra prefixes and no hook: beta's config must not reach it.
    [ "${lines[1]}" = "s2|alpha|shared-thing|misc|fallback" ]
    [ "${lines[2]}" = "s3|beta|bee-feature|own|branch_prefix" ]
    [ "${lines[3]}" = "s4|beta|special-thing|review|beta_hook" ]
    [ "${lines[4]}" = "s5|beta|shared-thing|misc|extra_prefix" ]
}

@test "sync: ignore rows are dropped once classification is done" {
    cat >>"$FW_CONFIG_DIR/projects/alpha/config.sh" <<'EOF'
hook_usage_classify() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    echo "ignore|numbered_worktree"
}
EOF
    write_ccusage \
        "$(mangle "$ALPHA_WT/7")" s1 \
        "$(mangle "$ALPHA_WT/jason-keep")" s2
    _usage_sync "" 30d
    run db "SELECT session_id FROM sessions;"
    [ "$output" = "s2" ]
}

@test "sync: a hook returning an invalid category fails the sync loudly" {
    cat >>"$FW_CONFIG_DIR/projects/alpha/config.sh" <<'EOF'
hook_usage_classify() { echo "urgent|typo"; }
EOF
    write_ccusage "$(mangle "$ALPHA_WT/jason-feature")" s1
    run _usage_sync "" 30d
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
    [[ "$output" == *"urgent"* ]]
    # No partial report: nothing was imported.
    run db "SELECT COUNT(*) FROM sessions;"
    [ "$output" = "0" ]
}

@test "sync: re-running replaces rows rather than duplicating them" {
    write_ccusage "$(mangle "$ALPHA_WT/jason-feature")" s1
    _usage_sync "" 30d
    _usage_sync "" 30d
    run db "SELECT COUNT(*) FROM sessions;"
    [ "$output" = "1" ]
}

@test "sync: asks ccusage for sessions from the window start" {
    write_ccusage "$(mangle "$ALPHA_WT/jason-feature")" s1
    _usage_sync 2026-08-01 30d
    run cat "$CCUSAGE_ARGS"
    [[ "$output" == *"ccusage claude session --json --since 2026-08-01"* ]]
}

@test "sync: passes --yes so a first-run install can't block on a prompt" {
    write_ccusage "$(mangle "$ALPHA_WT/jason-feature")" s1
    _usage_sync "" 30d
    run cat "$CCUSAGE_ARGS"
    [[ "$output" == *"--yes ccusage claude session"* ]]
}

@test "sync: runs the transcript parser once, over the Claude config dir" {
    export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude-config"
    write_ccusage "$(mangle "$ALPHA_WT/jason-feature")" s1
    _usage_sync "" 30d
    run cat "$BATS_TEST_TMPDIR/parser.log"
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" == "$USAGE_DB $BATS_TEST_TMPDIR/claude-config/projects" ]]
}

@test "sync: without CLAUDE_CONFIG_DIR the parser reads ~/.claude/projects" {
    write_ccusage "$(mangle "$ALPHA_WT/jason-feature")" s1
    _usage_sync "" 30d
    run cat "$BATS_TEST_TMPDIR/parser.log"
    [[ "$output" == "$USAGE_DB $HOME/.claude/projects" ]]
}

@test "sync: a parser failure fails the sync" {
    _run_usage_parser() { return 4; }
    write_ccusage "$(mangle "$ALPHA_WT/jason-feature")" s1
    run _usage_sync "" 30d
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
}

@test "sync: a parser build failure fails the sync before calling ccusage" {
    _ensure_usage_parser() { echo "Error: no go" >&2; return 1; }
    write_ccusage "$(mangle "$ALPHA_WT/jason-feature")" s1
    run _usage_sync "" 30d
    [ "$status" -ne 0 ]
    [ ! -f "$CCUSAGE_ARGS" ]
}

@test "sync: missing npx is a loud error" {
    write_ccusage "$(mangle "$ALPHA_WT/jason-feature")" s1
    rm "$BATS_TEST_TMPDIR/bin/npx"
    PATH="/usr/bin:/bin" run _usage_sync "" 30d
    [ "$status" -ne 0 ]
    [[ "$output" == *"npx"* ]]
    [[ "$output" == *"Error"* ]]
}

@test "sync: missing jq is a loud error" {
    write_ccusage "$(mangle "$ALPHA_WT/jason-feature")" s1
    # macOS ships /usr/bin/jq, so the only way to see it absent is a PATH of
    # everything-but-jq: the stages before the jq check still need their tools.
    mkdir -p "$BATS_TEST_TMPDIR/nojq"
    ln -s /usr/bin/* /bin/* "$BATS_TEST_TMPDIR/nojq/" 2>/dev/null || true
    rm -f "$BATS_TEST_TMPDIR/nojq/jq"
    cp "$BATS_TEST_TMPDIR/bin/npx" "$BATS_TEST_TMPDIR/nojq/npx"

    PATH="$BATS_TEST_TMPDIR/nojq" run _usage_sync "" 30d
    [ "$status" -ne 0 ]
    [[ "$output" == *"jq"* ]]
    [[ "$output" == *"Error"* ]]
}

@test "sync: a ccusage failure is a loud error" {
    write_ccusage "$(mangle "$ALPHA_WT/jason-feature")" s1
    export CCUSAGE_FAIL=1
    run _usage_sync "" 30d
    [ "$status" -ne 0 ]
    [[ "$output" == *"ccusage"* ]]
}

# --- git-author reclassification ---

# A branch on origin whose tip commit carries <email>, so the fallback pass has
# something to read.
seed_branch() {
    local repo="$1" branch="$2" email="$3"
    git -C "$repo" -c user.email="$email" -c user.name=someone \
        commit -q --allow-empty -m "work on $branch"
    git -C "$repo" update-ref "refs/remotes/origin/$branch" HEAD
}

@test "sync: a fallback worktree authored by me becomes own work" {
    git -C "$BATS_TEST_TMPDIR/alpha" config user.email jason@example.com
    seed_branch "$BATS_TEST_TMPDIR/alpha" mystery-branch jason@example.com
    write_ccusage "$(mangle "$ALPHA_WT/mystery-branch")" s1
    _usage_sync "" 30d
    run db "SELECT category, category_source FROM sessions;"
    [ "$output" = "own|git_author" ]
}

@test "sync: a fallback worktree authored by someone else becomes review" {
    git -C "$BATS_TEST_TMPDIR/alpha" config user.email jason@example.com
    seed_branch "$BATS_TEST_TMPDIR/alpha" mystery-branch someone@example.com
    write_ccusage "$(mangle "$ALPHA_WT/mystery-branch")" s1
    _usage_sync "" 30d
    run db "SELECT category, category_source FROM sessions;"
    [ "$output" = "review|git_author" ]
}

@test "sync: the git-author pass finds a branch under the user's own prefix" {
    git -C "$BATS_TEST_TMPDIR/alpha" config user.email jason@example.com
    seed_branch "$BATS_TEST_TMPDIR/alpha" jason/mystery-branch jason@example.com
    write_ccusage "$(mangle "$ALPHA_WT/mystery-branch")" s1
    _usage_sync "" 30d
    run db "SELECT category, category_source FROM sessions;"
    [ "$output" = "own|git_author" ]
}

@test "sync: the git-author pass leaves already-classified rows alone" {
    seed_branch "$BATS_TEST_TMPDIR/alpha" jason-feature someone@example.com
    write_ccusage "$(mangle "$ALPHA_WT/jason-feature")" s1
    _usage_sync "" 30d
    run db "SELECT category, category_source FROM sessions;"
    [ "$output" = "own|branch_prefix" ]
}

@test "sync: the git-author pass skips main and unclaimed directories" {
    write_ccusage \
        "$(mangle "$BATS_TEST_TMPDIR/alpha")" s1 \
        "-Users-jason-dev-forks-elsewhere" s2
    _usage_sync "" 30d
    run db "SELECT session_id, COALESCE(category,'NULL') FROM sessions ORDER BY session_id;"
    [ "${lines[0]}" = "s1|misc" ]
    [ "${lines[1]}" = "s2|NULL" ]
}
