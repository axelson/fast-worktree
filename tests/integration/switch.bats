load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

teardown() {
    "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true
}

@test "fw tmux-open: creates a detached session rooted in the worktree" {
    "$FW_BIN" create --no-switch alpha

    run "$FW_BIN" tmux-open alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"myproj-alpha"* ]]

    run "$FW_ROOT/tests/shims/tmux" list-panes -t "=myproj-alpha" -F '#{pane_current_path}'
    [ "$(realpath "$output")" = "$(realpath "$BATS_TEST_TMPDIR/myproj-worktrees/alpha")" ]
}

@test "fw tmux-open: reuses an existing session" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" tmux-open alpha
    "$FW_BIN" tmux-open alpha

    run bash -c "'$FW_ROOT/tests/shims/tmux' list-sessions -F '#{session_name}' | grep -c '^myproj-alpha$'"
    [ "$output" = "1" ]
}

@test "fw switch: records recency and runs hook_post_switch" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_post_switch() { echo "$FW_WORKTREE" >>"$FW_REPO_ROOT/switch-hook-log"; }
EOF
    "$FW_BIN" create --no-switch alpha

    run "$FW_BIN" switch alpha
    [ "$status" -eq 0 ]

    [ "$(cat "$BATS_TEST_TMPDIR/myrepo/switch-hook-log")" = "alpha" ]
    grep -q "alpha" "$BATS_TEST_TMPDIR/myproj-worktrees/.fw_recent"
}

@test "fw last: toggles between the two most recent worktrees" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" create --no-switch beta
    "$FW_BIN" switch alpha
    "$FW_BIN" switch beta

    run "$FW_BIN" last
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]

    run "$FW_BIN" last
    [[ "$output" == *"beta"* ]]
}

@test "fw last: returns to the main golden checkout" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" switch main
    "$FW_BIN" switch alpha

    run "$FW_BIN" last
    [ "$status" -eq 0 ]
    [[ "$output" == *"myproj-main"* ]]

    run "$FW_ROOT/tests/shims/tmux" list-panes -t "=myproj-main" -F '#{pane_current_path}'
    [ "$(realpath "$output")" = "$(realpath "$BATS_TEST_TMPDIR/myrepo")" ]
}

@test "fw last: skips deleted worktrees in the recency list" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" create --no-switch beta
    "$FW_BIN" create --no-switch gamma
    "$FW_BIN" switch alpha
    "$FW_BIN" switch gamma
    "$FW_BIN" switch beta
    "$FW_BIN" delete gamma

    run "$FW_BIN" last
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
}

@test "fw tmux-open: records recency for fw last" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" create --no-switch beta
    "$FW_BIN" switch alpha
    "$FW_BIN" tmux-open beta

    run "$FW_BIN" last
    [[ "$output" == *"alpha"* ]]
}

@test "fw switch: resolves a branch name to its worktree" {
    "$FW_BIN" create --no-switch alpha

    run "$FW_BIN" switch me/alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
}

@test "record_viewed: compacts an oversized recency log" {
    "$FW_BIN" create --no-switch alpha
    local log="$BATS_TEST_TMPDIR/myproj-worktrees/.fw_recent"
    local i
    for i in $(seq 1 250); do
        printf '%s\talpha\n' "$i" >>"$log"
    done

    "$FW_BIN" switch alpha

    [ "$(wc -l <"$log" | tr -d ' ')" -lt 100 ]
}

@test "fw last: errors with no history" {
    run "$FW_BIN" last
    [ "$status" -ne 0 ]
}

@test "fw switch: bare picker offers main and recent worktrees, switches to selection" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" create --no-switch beta
    "$FW_BIN" switch alpha
    "$FW_BIN" switch beta

    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_SELECT=alpha

    run "$FW_BIN" switch
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]

    cut -f2 "$BATS_TEST_TMPDIR/offered" | grep -q "^main$"
    cut -f2 "$BATS_TEST_TMPDIR/offered" | grep -q "^alpha$"
    cut -f2 "$BATS_TEST_TMPDIR/offered" | grep -q "^beta$"
}

@test "fw switch: bare picker offers a freshly created, never-switched worktree" {
    "$FW_BIN" create --no-switch fresh

    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_CANCEL=1

    run "$FW_BIN" switch
    [ "$status" -eq 0 ]
    cut -f2 "$BATS_TEST_TMPDIR/offered" | grep -q "^fresh$"
}

@test "fw switch: bare picker cancel is a quiet no-op" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" switch alpha

    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" switch
    [ "$status" -eq 0 ]
}

@test "fw switch: --all picker includes never-viewed worktrees" {
    "$FW_BIN" create --no-switch alpha
    # gamma is created but never switched-to, so it's absent from recency.
    "$FW_BIN" create --no-switch gamma
    "$FW_BIN" switch alpha

    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_SELECT=gamma
    run "$FW_BIN" switch --all
    [ "$status" -eq 0 ]
    cut -f2 "$BATS_TEST_TMPDIR/offered" | grep -q "^gamma$"
}

@test "fw switch: default picker omits worktrees not viewed in 7 days" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" create --no-switch stale
    "$FW_BIN" switch alpha
    # Backdate 'stale' well beyond the 7-day window: drop its create-time
    # entry (a name's most recent row wins), leaving only an old one.
    local log="$BATS_TEST_TMPDIR/myproj-worktrees/.fw_recent"
    awk -F'\t' '$2 != "stale"' "$log" >"$log.tmp" && mv "$log.tmp" "$log"
    printf '%s\tstale\n' "$(( $(date +%s) - 30 * 86400 ))" >>"$log"

    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_SELECT=alpha
    run "$FW_BIN" switch
    [ "$status" -eq 0 ]
    cut -f2 "$BATS_TEST_TMPDIR/offered" | grep -q "^alpha$"
    ! cut -f2 "$BATS_TEST_TMPDIR/offered" | grep -q "^stale$"
}

@test "fw switch: requires an existing worktree for an explicit name" {
    run "$FW_BIN" switch nope
    [ "$status" -ne 0 ]
}

@test "fw switch: refuses a phantom dir that lost its env file" {
    # A partially-deleted worktree can leave its directory behind with no env
    # file. Switching into it would land a session in a non-worktree; refuse it
    # instead, matching the env-file invariant list and the picker use.
    "$FW_BIN" create --no-switch alpha
    # create always births a session to run its background setup (even with
    # --no-switch); kill it so the postcondition below proves the *refused
    # switch* birthed no session, not that create's leftover happened to vanish.
    "$FW_ROOT/tests/shims/tmux" kill-session -t "=myproj-alpha" 2>/dev/null || true
    rm -f "$BATS_TEST_TMPDIR/myproj-worktrees/alpha/.env.worktree"

    run "$FW_BIN" switch alpha
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a worktree"* ]]
    # The refused switch must not have landed a session in the phantom dir.
    run "$FW_ROOT/tests/shims/tmux" has-session -t "=myproj-alpha"
    [ "$status" -ne 0 ]
}

@test "fw switch main: opens the golden-checkout (repo_root) main session" {
    run "$FW_BIN" switch main
    [ "$status" -eq 0 ]
    [[ "$output" == *"main"* ]]

    run "$FW_ROOT/tests/shims/tmux" list-panes -t "=myproj-main" -F '#{pane_current_path}'
    [ "$(realpath "$output")" = "$(realpath "$BATS_TEST_TMPDIR/myrepo")" ]
}

@test "fw switch main: runs hook_post_switch rooted at the golden checkout" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_post_switch() { echo "$FW_WORKTREE_PATH" >>"$FW_REPO_ROOT/switch-hook-log"; }
EOF

    run "$FW_BIN" switch main
    [ "$status" -eq 0 ]

    [ "$(realpath "$(cat "$BATS_TEST_TMPDIR/myrepo/switch-hook-log")")" = "$(realpath "$BATS_TEST_TMPDIR/myrepo")" ]
}

@test "fw switch: picking main from the bare picker opens the golden-checkout session" {
    "$FW_BIN" create --no-switch alpha

    export FW_TEST_FZF_SELECT=main
    run "$FW_BIN" switch
    [ "$status" -eq 0 ]

    run "$FW_ROOT/tests/shims/tmux" list-panes -t "=myproj-main" -F '#{pane_current_path}'
    [ "$(realpath "$output")" = "$(realpath "$BATS_TEST_TMPDIR/myrepo")" ]
}

@test "fw switch: bare picker preselects the current worktree" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" switch alpha
    cd "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"

    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" switch
    [ "$status" -eq 0 ]
    # names = (main, alpha) → alpha is the 2nd (1-based) line.
    grep -q "pos(2)" "$BATS_TEST_TMPDIR/fzf.log"
}

@test "fw switch: bare picker preselects main from the golden checkout" {
    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" switch
    [ "$status" -eq 0 ]
    grep -q "pos(1)" "$BATS_TEST_TMPDIR/fzf.log"
}

@test "fw switch: switch_recent_days config drives the window and header" {
    echo 'switch_recent_days=2' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" create --no-switch stale
    "$FW_BIN" switch alpha
    local log="$BATS_TEST_TMPDIR/myproj-worktrees/.fw_recent"
    printf '%s\tstale\n' "$(( $(date +%s) - 3 * 86400 ))" >>"$log"

    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_SELECT=alpha
    run "$FW_BIN" switch
    [ "$status" -eq 0 ]
    cut -f2 "$BATS_TEST_TMPDIR/offered" | grep -q "^alpha$"
    ! cut -f2 "$BATS_TEST_TMPDIR/offered" | grep -q "^stale$"
    grep -q "last 2d" "$BATS_TEST_TMPDIR/fzf.log"
}

@test "fw switch: phase-1 rows carry a trailing tab-name key and a select on the name resolves it" {
    "$FW_BIN" create alpha
    "$FW_BIN" switch alpha

    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_SELECT=alpha
    run "$FW_BIN" switch
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]

    # Each offered line is "<visible>\t<name>": field 2 is the bare name key, and
    # a tabless line would leave $2 empty, so this proves the key is present.
    awk -F'\t' '$2 == "main"' "$BATS_TEST_TMPDIR/offered" | grep -q .
    awk -F'\t' '$2 == "alpha"' "$BATS_TEST_TMPDIR/offered" | grep -q .
    # ...and the visible half is more than the bare name (carries the age column).
    awk -F'\t' '$2 == "alpha" && $1 != "alpha"' "$BATS_TEST_TMPDIR/offered" | grep -q .
}

@test "fw switch: fzf argv enables ansi and binds the phase-2 reload to the resolved binary" {
    "$FW_BIN" create alpha
    "$FW_BIN" switch alpha

    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" switch
    [ "$status" -eq 0 ]

    grep -q -- "--ansi" "$BATS_TEST_TMPDIR/fzf.log"
    # Typing filters and re-lands the cursor on the top (best) match, matching
    # the legacy picker.
    grep -q "change:first" "$BATS_TEST_TMPDIR/fzf.log"
    # The default picker enriches through a DIRECT reload-sync (not one gated
    # behind a transform — that supersedes the first, slow enrich before it can
    # commit), self-perpetuating as the refresh loop.
    grep -q "load:reload-sync(" "$BATS_TEST_TMPDIR/fzf.log"
    ! grep -q "load:transform:" "$BATS_TEST_TMPDIR/fzf.log"
    grep -q "FW_COLOR=always" "$BATS_TEST_TMPDIR/fzf.log"
    # The reload invokes the resolved fast-worktree binary (FW_SELF, absolute),
    # not a bare `fw` from PATH, via the cache+pace wrapper.
    grep -q "/fast-worktree" "$BATS_TEST_TMPDIR/fzf.log"
    grep -q "_switch-refresh" "$BATS_TEST_TMPDIR/fzf.log"
    # ...and pins the resolved project, so the phase-2 subprocess enriches the
    # same project phase 1 listed rather than re-resolving from cwd.
    grep -q -- "-p myproj" "$BATS_TEST_TMPDIR/fzf.log"
    # No --all in the reload for the default picker.
    ! grep -q -- "--all" "$BATS_TEST_TMPDIR/fzf.log"
}

@test "fw switch --all: reload command propagates --all" {
    "$FW_BIN" create alpha

    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" switch --all
    [ "$status" -eq 0 ]

    grep -q -- "--all" "$BATS_TEST_TMPDIR/fzf.log"
    grep -q "_switch-refresh" "$BATS_TEST_TMPDIR/fzf.log"
}

@test "fw switch: the picker re-enriches on the default 10s interval" {
    "$FW_BIN" create alpha
    "$FW_BIN" switch alpha

    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" switch
    [ "$status" -eq 0 ]

    # A self-perpetuating load loop: a direct reload-sync of the cache+pace
    # wrapper, which throttles the expensive enrich to the interval...
    grep -q "load:reload-sync(" "$BATS_TEST_TMPDIR/fzf.log"
    ! grep -q "load:transform:" "$BATS_TEST_TMPDIR/fzf.log"
    grep -q -- "_switch-refresh --secs 10" "$BATS_TEST_TMPDIR/fzf.log"
    grep -q -- "--cache" "$BATS_TEST_TMPDIR/fzf.log"
    # ...and still preselects the current worktree on the first pass.
    grep -q "pos(" "$BATS_TEST_TMPDIR/fzf.log"
}

@test "fw switch: switch_refresh_secs config sets the interval" {
    echo 'switch_refresh_secs=3' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    "$FW_BIN" create alpha

    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" switch
    [ "$status" -eq 0 ]

    grep -q -- "_switch-refresh --secs 3" "$BATS_TEST_TMPDIR/fzf.log"
    ! grep -q -- "--secs 10" "$BATS_TEST_TMPDIR/fzf.log"
}

@test "fw switch: switch_refresh_secs=0 disables the refresh loop (one-shot enrich)" {
    echo 'switch_refresh_secs=0' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    "$FW_BIN" create alpha

    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" switch
    [ "$status" -eq 0 ]

    # Byte-for-byte the pre-refresh behavior: one enrich, then unbind — no
    # caching wrapper, no transform.
    grep -q "load:reload-sync(" "$BATS_TEST_TMPDIR/fzf.log"
    grep -q "unbind(load)" "$BATS_TEST_TMPDIR/fzf.log"
    grep -q "_switch-data" "$BATS_TEST_TMPDIR/fzf.log"
    ! grep -q "_switch-refresh" "$BATS_TEST_TMPDIR/fzf.log"
    ! grep -q "transform" "$BATS_TEST_TMPDIR/fzf.log"
}

@test "fw switch: a non-numeric switch_refresh_secs falls back to the 10s default" {
    echo 'switch_refresh_secs=abc' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    "$FW_BIN" create alpha

    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" switch
    [ "$status" -eq 0 ]

    # Only a bare integer reaches the interval — no "abc" interpolated through.
    grep -q -- "_switch-refresh --secs 10" "$BATS_TEST_TMPDIR/fzf.log"
    ! grep -q -- "--secs abc" "$BATS_TEST_TMPDIR/fzf.log"
}
