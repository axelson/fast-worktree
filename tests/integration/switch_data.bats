load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

WT_DIR() { echo "$BATS_TEST_TMPDIR/myproj-worktrees/$1"; }
RECENT_LOG() { echo "$BATS_TEST_TMPDIR/myproj-worktrees/.fw_recent"; }

# view <name> [age-seconds] — set <name>'s recency to now minus age-seconds
# (default now), replacing any earlier entry (fw create already records one).
# Seeds recency directly (no `fw switch`) so these tests stay hermetic and
# don't spawn tmux sessions that would collide under parallel test runs.
view() {
    local log; log="$(RECENT_LOG)"
    if [[ -f "$log" ]]; then
        awk -F'\t' -v n="$1" '$2 != n' "$log" >"$log.tmp" && mv "$log.tmp" "$log"
    fi
    printf '%s\t%s\n' "$(( $(date +%s) - ${2:-0} ))" "$1" >>"$log"
}

# row_for <name> — the enriched row whose trailing tab-key is <name>.
row_for() { awk -F'\t' -v n="$1" '$2 == n { print $0 }'; }

@test "fw _switch-data: one enriched row per candidate, each with a \\t<name> key" {
    "$FW_BIN" create alpha
    "$FW_BIN" create beta
    view alpha 20
    view beta 10

    run "$FW_BIN" _switch-data
    [ "$status" -eq 0 ]
    # main + alpha + beta = 3 rows.
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 3 ]
    # every row carries a trailing tab-delimited key.
    printf '%s\n' "$output" | row_for main  | grep -q .
    printf '%s\n' "$output" | row_for alpha | grep -q .
    printf '%s\n' "$output" | row_for beta  | grep -q .
    # the visible half leads with the worktree name.
    [[ "$(printf '%s\n' "$output" | row_for alpha)" == alpha* ]]
}

@test "fw _switch-data: claude status column from stubbed statuses, blank when absent" {
    "$FW_BIN" create alpha
    "$FW_BIN" create beta
    view alpha 20
    view beta 10

    export FW_TEST_CLAUDE_AGENTS_JSON="$(cat <<JSON
[{"cwd": "$(WT_DIR alpha)", "status": "busy"}]
JSON
)"
    run "$FW_BIN" _switch-data
    [ "$status" -eq 0 ]
    [[ "$(printf '%s\n' "$output" | row_for alpha)" == *running* ]]
    [[ "$(printf '%s\n' "$output" | row_for beta)" != *running* ]]
    [[ "$(printf '%s\n' "$output" | row_for beta)" != *waiting* ]]
}

@test "fw _switch-data: summary from .fw-summary.md, blank when the file is missing" {
    "$FW_BIN" create alpha
    "$FW_BIN" create beta
    view alpha 20
    view beta 10
    printf '# One-line alpha summary\n' >"$(WT_DIR alpha)/.fw-summary.md"

    run "$FW_BIN" _switch-data
    [ "$status" -eq 0 ]
    [[ "$(printf '%s\n' "$output" | row_for alpha)" == *"One-line alpha summary"* ]]
    # beta has no summary file — its row must not carry alpha's text.
    [[ "$(printf '%s\n' "$output" | row_for beta)" != *"One-line alpha summary"* ]]
}

@test "fw _switch-data: --all widens the candidate set past the recency window" {
    "$FW_BIN" create alpha
    "$FW_BIN" create stale
    view alpha 20
    view stale $(( 30 * 86400 ))

    run "$FW_BIN" _switch-data
    [ "$status" -eq 0 ]
    [ -z "$(printf '%s\n' "$output" | row_for stale)" ]

    run "$FW_BIN" _switch-data --all
    [ "$status" -eq 0 ]
    [ -n "$(printf '%s\n' "$output" | row_for stale)" ]
}

@test "fw _switch-data: a recently-viewed dir that lost its env file is not a candidate" {
    # A partially-deleted worktree (its removal raced a running server) leaves
    # the directory behind but no env file. The env file is the worktree
    # invariant list already uses; the switch picker must share it so a phantom
    # dir never resurfaces as a switch target.
    "$FW_BIN" create alpha
    view alpha 10
    rm -f "$(WT_DIR alpha)/.env.worktree"

    run "$FW_BIN" _switch-data
    [ "$status" -eq 0 ]
    [ -z "$(printf '%s\n' "$output" | row_for alpha)" ]

    # Even --all (which widens the window) must not surface it.
    run "$FW_BIN" _switch-data --all
    [ "$status" -eq 0 ]
    [ -z "$(printf '%s\n' "$output" | row_for alpha)" ]
}
