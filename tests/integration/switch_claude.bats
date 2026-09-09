load ../test_helper

# End-to-end tests for `fw switch-claude` (`sc`): the cross-project picker over
# the live Claude session registry, and the switch action (exact tmux pane, with
# a fallback to the worktree's fw session).

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

teardown() {
    "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true
}

# seed_session <file> <pid> <cwd> <status> <age-secs> <tmux> <name>
seed_session() {
    local dir="$CLAUDE_CONFIG_DIR/sessions"
    mkdir -p "$dir"
    local supd=$(( ( $(date +%s) - $5 ) * 1000 ))
    cat >"$dir/$1.json" <<EOF
{"pid":$2,"cwd":"$3","status":"$4","statusUpdatedAt":$supd,"updatedAt":$supd,"tmux":"$6","name":"$7"}
EOF
}

@test "fw switch-claude: reports when no sessions are active" {
    run "$FW_BIN" switch-claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"No active Claude sessions."* ]]
}

@test "fw sc: the alias resolves to the same command" {
    run "$FW_BIN" sc
    [ "$status" -eq 0 ]
    [[ "$output" == *"No active Claude sessions."* ]]
}

@test "fw switch-claude: offers nested rows and drives fzf with --ansi" {
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    seed_session m "$$" "$BATS_TEST_TMPDIR/myrepo" idle 30 "myproj-main:@1.%1" m
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" waiting 12 "myproj-alpha:@2.%2" a

    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_CANCEL=1

    run "$FW_BIN" switch-claude
    [ "$status" -eq 0 ]

    grep -q -- "--ansi" "$BATS_TEST_TMPDIR/fzf.log"
    # only the first (visible) field is displayed; the S/pane/project/worktree
    # key columns after the first tab stay in the line but off the display.
    grep -q -- "--with-nth=1" "$BATS_TEST_TMPDIR/fzf.log"
    grep -q "myproj" "$BATS_TEST_TMPDIR/offered"
    grep -q "waiting" "$BATS_TEST_TMPDIR/offered"
    # a project header is a selectable P row (keyed to main); session rows carry S
    awk -F'\t' '$2 == "P"' "$BATS_TEST_TMPDIR/offered" | grep -q .
    awk -F'\t' '$2 == "S"' "$BATS_TEST_TMPDIR/offered" | grep -q .
}

@test "fw switch-claude: preselects the current project's header via pos()" {
    # A second project with a waiting session floats ABOVE myproj, so myproj's
    # header is not line 1 — proving pos() targets the current project, not top.
    # cwd is myrepo (the main worktree) which has NO session, so the worktree
    # step finds nothing and the project-header step applies.
    make_repo "$BATS_TEST_TMPDIR/otherrepo"
    register_project other "$BATS_TEST_TMPDIR/otherrepo"
    mkdir -p "$BATS_TEST_TMPDIR/other-worktrees/beta" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    seed_session b "$$" "$BATS_TEST_TMPDIR/other-worktrees/beta" waiting 12 "other-beta:@1.%1" b
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" idle 30 "myproj-alpha:@2.%2" a

    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_CANCEL=1
    # cwd is myrepo (setup cd'd here) and not inside tmux; main has no session ->
    # preselect the myproj header. Rows: other(P) beta(S) myproj(P) alpha(S) -> pos(3).
    run "$FW_BIN" switch-claude
    [ "$status" -eq 0 ]
    grep -q "pos(3)" "$BATS_TEST_TMPDIR/fzf.log"
}

@test "fw switch-claude: preselects the current worktree's session via pos()" {
    # Two sessions in myproj: beta (younger, floats first) and alpha (older). The
    # cwd is the alpha worktree, so the preselect must target alpha's row — NOT
    # the first/most-urgent session (beta) — proving it is the *current* worktree.
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" "$BATS_TEST_TMPDIR/myproj-worktrees/beta"
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" idle 50 "myproj-alpha:@1.%1" a
    seed_session b "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/beta"  idle 10 "myproj-beta:@2.%2"  b

    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_CANCEL=1
    cd "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    run "$FW_BIN" switch-claude
    [ "$status" -eq 0 ]
    # Rows: myproj(P) beta(S) alpha(S) -> alpha is line 3.
    grep -q "pos(3)" "$BATS_TEST_TMPDIR/fzf.log"
    ! grep -q "pos(2)" "$BATS_TEST_TMPDIR/fzf.log"
}

@test "fw switch-claude: no preselect when the cwd is outside every project" {
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" idle 10 "myproj-alpha:@1.%1" agent

    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_CANCEL=1
    unset FW_PROJECT
    cd "$BATS_TEST_TMPDIR"
    run "$FW_BIN" switch-claude
    [ "$status" -eq 0 ]
    # no current pane session, no resolvable current project -> fzf's default top
    ! grep -q "pos(" "$BATS_TEST_TMPDIR/fzf.log"
}

@test "fw switch-claude: selecting a session jumps to its exact tmux pane" {
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    local tmuxsh="$FW_ROOT/tests/shims/tmux"
    "$tmuxsh" new-session -d -s myproj-alpha -c "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    local win pane
    win="$("$tmuxsh" display-message -p -t "=myproj-alpha" '#{window_id}')"
    pane="$("$tmuxsh" display-message -p -t "=myproj-alpha" '#{pane_id}')"

    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" idle 10 "myproj-alpha:$win.$pane" agent

    export FW_TEST_FZF_SELECT=alpha
    export FW_TEST_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"

    run "$FW_BIN" switch-claude
    [ "$status" -eq 0 ]

    grep -q "select-window -t $win" "$BATS_TEST_TMPDIR/tmux.log"
    grep -q "select-pane -t $pane" "$BATS_TEST_TMPDIR/tmux.log"
    grep -q "alpha" "$BATS_TEST_TMPDIR/myproj-worktrees/.fw_recent"
}

@test "fw switch-claude: selecting a project header switches to its main worktree" {
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" idle 10 "myproj-alpha:@1.%1" agent

    # "myproj" matches the project header line before any session row. The header
    # is now selectable and routes to the project's main worktree.
    export FW_TEST_FZF_SELECT=myproj
    run "$FW_BIN" switch-claude
    [ "$status" -eq 0 ]
    # the main fw session was opened
    "$FW_ROOT/tests/shims/tmux" has-session -t "=myproj-main"
}

@test "fw switch-claude: selecting a worktree sub-header opens that worktree" {
    "$FW_BIN" create --no-switch alpha
    # two live sessions in alpha make it a multi-session worktree, so the render
    # emits a selectable "alpha" sub-header (marker W) above the child rows.
    seed_session a1 "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" idle 20 "x:@1.%1" agent-a
    seed_session a2 "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" idle 30 "x:@2.%2" agent-b

    # "alpha" first matches the sub-header line (it precedes the agent-* rows).
    export FW_TEST_FZF_SELECT=alpha
    run "$FW_BIN" switch-claude
    [ "$status" -eq 0 ]
    # the sub-header routed through cmd_tmux_open to the worktree's fw session
    "$FW_ROOT/tests/shims/tmux" has-session -t "=myproj-alpha"
}

@test "fw switch-claude: falls back to the worktree session when the pane is gone" {
    "$FW_BIN" create --no-switch alpha
    # The referenced tmux session does not exist, so the exact-pane jump fails.
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" idle 10 "myproj-alpha:@9.%9" agent

    export FW_TEST_FZF_SELECT=alpha
    run "$FW_BIN" switch-claude
    [ "$status" -eq 0 ]
    # the fallback opened the worktree's fw session
    "$FW_ROOT/tests/shims/tmux" has-session -t "=myproj-alpha"
}

@test "fw switch-claude: a real fzf failure is a hard error" {
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" idle 10 "s:@1.%1" agent

    export FW_TEST_FZF_ERROR=1
    run "$FW_BIN" switch-claude
    [ "$status" -ne 0 ]
}

@test "fw switch-claude: cancel is a quiet no-op" {
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" idle 10 "s:@1.%1" agent

    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" switch-claude
    [ "$status" -eq 0 ]
}

# --- continuous refresh: the two-phase self-perpetuating load loop -----------

@test "fw switch-claude: the picker re-enriches on the default 10s interval" {
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" waiting 12 "myproj-alpha:@2.%2" a

    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" switch-claude
    [ "$status" -eq 0 ]

    # A self-perpetuating load loop: a DIRECT reload-sync of the cache+pace
    # wrapper (not gated behind a transform — that supersedes the first, slow
    # enrich before it commits), which throttles the expensive registry read to
    # the interval.
    grep -q "load:reload-sync(" "$BATS_TEST_TMPDIR/fzf.log"
    ! grep -q "load:transform:" "$BATS_TEST_TMPDIR/fzf.log"
    grep -q "FW_COLOR=always" "$BATS_TEST_TMPDIR/fzf.log"
    # Invokes the resolved fast-worktree binary (FW_SELF, absolute), not a bare
    # `fw`, via the cache+pace wrapper on the default interval.
    grep -q "/fast-worktree" "$BATS_TEST_TMPDIR/fzf.log"
    grep -q -- "_switch-claude-refresh --secs 10" "$BATS_TEST_TMPDIR/fzf.log"
    grep -q -- "--cache" "$BATS_TEST_TMPDIR/fzf.log"
    # Cross-project by nature: the reload pins no single project.
    ! grep -q -- "-p " "$BATS_TEST_TMPDIR/fzf.log"
}

@test "fw switch-claude: switch_claude_refresh_secs config sets the interval" {
    echo 'switch_claude_refresh_secs=3' >>"$FW_CONFIG_DIR/config.sh"
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" idle 10 "myproj-alpha:@2.%2" a

    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" switch-claude
    [ "$status" -eq 0 ]

    grep -q -- "_switch-claude-refresh --secs 3" "$BATS_TEST_TMPDIR/fzf.log"
    ! grep -q -- "--secs 10" "$BATS_TEST_TMPDIR/fzf.log"
}

@test "fw switch-claude: switch_claude_refresh_secs=0 disables the refresh loop" {
    echo 'switch_claude_refresh_secs=0' >>"$FW_CONFIG_DIR/config.sh"
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" idle 10 "myproj-alpha:@2.%2" a

    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" switch-claude
    [ "$status" -eq 0 ]

    # One enrich, then unbind — no caching wrapper, no transform.
    grep -q "load:reload-sync(" "$BATS_TEST_TMPDIR/fzf.log"
    grep -q "unbind(load)" "$BATS_TEST_TMPDIR/fzf.log"
    grep -q "_switch-claude-data" "$BATS_TEST_TMPDIR/fzf.log"
    ! grep -q "_switch-claude-refresh" "$BATS_TEST_TMPDIR/fzf.log"
    ! grep -q "transform" "$BATS_TEST_TMPDIR/fzf.log"
}

@test "fw switch-claude: a non-numeric interval falls back to the 10s default" {
    echo 'switch_claude_refresh_secs=abc' >>"$FW_CONFIG_DIR/config.sh"
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" idle 10 "myproj-alpha:@2.%2" a

    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" switch-claude
    [ "$status" -eq 0 ]

    # Only a bare integer reaches the interval — no "abc" interpolated through.
    grep -q -- "_switch-claude-refresh --secs 10" "$BATS_TEST_TMPDIR/fzf.log"
    ! grep -q -- "--secs abc" "$BATS_TEST_TMPDIR/fzf.log"
}

# --- the internal reload commands (cross-project, no _require_project) --------

@test "fw _switch-claude-data: prints the nested rows the picker reloads" {
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    seed_session m "$$" "$BATS_TEST_TMPDIR/myrepo" idle 30 "myproj-main:@1.%1" m
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" waiting 12 "myproj-alpha:@2.%2" a

    # Cross-project: runs from anywhere, needs no project flag.
    cd "$BATS_TEST_TMPDIR"
    run "$FW_BIN" _switch-claude-data
    [ "$status" -eq 0 ]

    grep -q "myproj" <<<"$output"
    grep -q "waiting" <<<"$output"
    # a project header is a selectable P row (keyed to main); session rows carry S
    awk -F'\t' '$2 == "P"' <<<"$output" | grep -q .
    awk -F'\t' '$2 == "S"' <<<"$output" | grep -q .
}

@test "fw _switch-claude-refresh: empty cache regenerates and populates the cache" {
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" waiting 12 "myproj-alpha:@2.%2" a

    local cache="$BATS_TEST_TMPDIR/cache"
    run "$FW_BIN" _switch-claude-refresh --secs 10 --cache "$cache"
    [ "$status" -eq 0 ]
    grep -q "waiting" <<<"$output"
    [ -s "$cache" ]
}

@test "fw _switch-claude-refresh: a fresh cache is served without regenerating" {
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" waiting 12 "myproj-alpha:@2.%2" a

    local cache="$BATS_TEST_TMPDIR/cache"
    printf 'SENTINEL-CACHED-ROW\n' >"$cache"
    date +%s >"$cache.ts"

    # A cache younger than the interval is served verbatim (sleeps out the
    # remainder), so the sentinel comes back, not freshly-read registry rows.
    run "$FW_BIN" _switch-claude-refresh --secs 1 --cache "$cache"
    [ "$status" -eq 0 ]
    grep -q "SENTINEL-CACHED-ROW" <<<"$output"
    ! grep -q "waiting" <<<"$output"
}

@test "fw _switch-claude-refresh: an empty-but-fresh cache still paces (no hot-spin)" {
    # When zero sessions are live, _swc_build_rows emits nothing, so the cache is
    # a legitimately EMPTY file. Pacing must key off the freshness stamp, not the
    # cache size — otherwise every reload misses the pace branch and re-reads the
    # registry as fast as it completes while an empty picker stays open.
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"

    local cache="$BATS_TEST_TMPDIR/cache"
    : >"$cache"            # a prior clean pass produced empty output
    date +%s >"$cache.ts"  # stamped fresh

    # A session appears AFTER the fresh empty cache was written. A paced refresh
    # serves the (empty) cache for the rest of the interval rather than
    # regenerating, so the new session must NOT show up yet.
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" waiting 12 "myproj-alpha:@2.%2" a

    run "$FW_BIN" _switch-claude-refresh --secs 1 --cache "$cache"
    [ "$status" -eq 0 ]
    ! grep -q "waiting" <<<"$output"
}

@test "fw sc --project-only: shows only the current project's sessions" {
    make_repo "$BATS_TEST_TMPDIR/otherrepo"
    register_project other "$BATS_TEST_TMPDIR/otherrepo"
    mkdir -p "$BATS_TEST_TMPDIR/other-worktrees/beta"

    seed_session m "$$" "$BATS_TEST_TMPDIR/myrepo" idle 30 "myproj-main:@1.%1" mine
    seed_session b "$$" "$BATS_TEST_TMPDIR/other-worktrees/beta" waiting 12 "other-beta:@2.%2" theirs

    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_CANCEL=1

    # cwd is myrepo (setup cd'd here) -> the current project is myproj
    run "$FW_BIN" sc --project-only
    [ "$status" -eq 0 ]

    grep -q "myproj" "$BATS_TEST_TMPDIR/offered"
    # `! grep` is exempt from set -e, so a robust negative uses run + status.
    run grep -F "other" "$BATS_TEST_TMPDIR/offered"
    [ "$status" -ne 0 ]
    run grep -F "theirs" "$BATS_TEST_TMPDIR/offered"
    [ "$status" -ne 0 ]
}

@test "fw sc --project-only: empty state still opens the picker with a placeholder" {
    # myproj has no live sessions at all.
    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
    # default selection picks the first offered line (the project header) -> no-op

    run "$FW_BIN" sc --project-only
    [ "$status" -eq 0 ]

    # the picker WAS opened (it did not print the bail-out message)
    [[ "$output" != *"No active Claude sessions."* ]]
    [ -f "$BATS_TEST_TMPDIR/offered" ]
    grep -q "myproj" "$BATS_TEST_TMPDIR/offered"
    grep -q "no active claude sessions" "$BATS_TEST_TMPDIR/offered"
    # every offered row is a non-selectable header (marker H); nothing is switchable
    run awk -F'\t' '$2 == "S"' "$BATS_TEST_TMPDIR/offered"
    [ -z "$output" ]
    # selecting the header row switched nothing
    if [ -f "$BATS_TEST_TMPDIR/tmux.log" ]; then
        run grep -q "select-pane" "$BATS_TEST_TMPDIR/tmux.log"
        [ "$status" -ne 0 ]
    fi
}

@test "fw sc --project-only: errors when the cwd is outside any project" {
    cd "$BATS_TEST_TMPDIR"
    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"

    run "$FW_BIN" sc --project-only
    [ "$status" -ne 0 ]
    [[ "$output" == *"not inside a registered project"* ]]
    # fzf must never be invoked when resolution fails
    [ ! -f "$BATS_TEST_TMPDIR/fzf.log" ]
}

@test "fw sc: without the flag still spans all projects" {
    make_repo "$BATS_TEST_TMPDIR/otherrepo"
    register_project other "$BATS_TEST_TMPDIR/otherrepo"
    mkdir -p "$BATS_TEST_TMPDIR/other-worktrees/beta"

    seed_session m "$$" "$BATS_TEST_TMPDIR/myrepo" idle 30 "myproj-main:@1.%1" mine
    seed_session b "$$" "$BATS_TEST_TMPDIR/other-worktrees/beta" waiting 12 "other-beta:@2.%2" theirs

    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_CANCEL=1

    run "$FW_BIN" sc
    [ "$status" -eq 0 ]
    grep -q "myproj" "$BATS_TEST_TMPDIR/offered"
    grep -q "other" "$BATS_TEST_TMPDIR/offered"
}

# --- --project-only under the refresh loop: the reload stays scoped -----------

@test "fw sc --project-only: the refresh reload pins the current project" {
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" waiting 12 "myproj-alpha:@2.%2" a

    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" sc --project-only
    [ "$status" -eq 0 ]

    # the paced reload carries the project scope, so a refresh re-lists myproj
    # only (never the whole registry).
    grep -q -- "_switch-claude-refresh --secs 10" "$BATS_TEST_TMPDIR/fzf.log"
    grep -q -- "--project myproj" "$BATS_TEST_TMPDIR/fzf.log"
}

@test "fw _switch-claude-data --project: scopes the reload rows to one project" {
    make_repo "$BATS_TEST_TMPDIR/otherrepo"
    register_project other "$BATS_TEST_TMPDIR/otherrepo"
    mkdir -p "$BATS_TEST_TMPDIR/other-worktrees/beta"

    seed_session m "$$" "$BATS_TEST_TMPDIR/myrepo" idle 30 "myproj-main:@1.%1" mine
    seed_session b "$$" "$BATS_TEST_TMPDIR/other-worktrees/beta" waiting 12 "other-beta:@2.%2" theirs

    # runs from anywhere; the scope comes from the flag, not the cwd
    cd "$BATS_TEST_TMPDIR"
    run "$FW_BIN" _switch-claude-data --project myproj
    [ "$status" -eq 0 ]

    grep -q "myproj" <<<"$output"
    run grep -F "other" <<<"$output"
    [ "$status" -ne 0 ]
}

@test "fw _switch-claude-data --project: re-emits the placeholder when empty" {
    # myproj has no live sessions -> the scoped reload must still show the
    # placeholder, so a refresh never blanks the --project-only picker.
    cd "$BATS_TEST_TMPDIR"
    run "$FW_BIN" _switch-claude-data --project myproj
    [ "$status" -eq 0 ]
    grep -q "myproj" <<<"$output"
    grep -q "no active claude sessions" <<<"$output"
    run awk -F'\t' '$2 == "S"' <<<"$output"
    [ -z "$output" ]
}

@test "fw _switch-claude-refresh --project: scopes the paced regeneration" {
    make_repo "$BATS_TEST_TMPDIR/otherrepo"
    register_project other "$BATS_TEST_TMPDIR/otherrepo"
    mkdir -p "$BATS_TEST_TMPDIR/other-worktrees/beta"

    seed_session m "$$" "$BATS_TEST_TMPDIR/myrepo" idle 30 "myproj-main:@1.%1" mine
    seed_session b "$$" "$BATS_TEST_TMPDIR/other-worktrees/beta" waiting 12 "other-beta:@2.%2" theirs

    local cache="$BATS_TEST_TMPDIR/cache"
    run "$FW_BIN" _switch-claude-refresh --secs 10 --cache "$cache" --project myproj
    [ "$status" -eq 0 ]
    grep -q "myproj" <<<"$output"
    run grep -F "other" <<<"$output"
    [ "$status" -ne 0 ]
}
