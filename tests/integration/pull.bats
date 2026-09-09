load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/origin"
    git -C "$BATS_TEST_TMPDIR/origin" checkout -q -b colleague/cool-fix
    echo work >"$BATS_TEST_TMPDIR/origin/work.txt"
    git -C "$BATS_TEST_TMPDIR/origin" add work.txt
    git -C "$BATS_TEST_TMPDIR/origin" -c user.email=t@t -c user.name=t commit -qm "cool fix"
    git -C "$BATS_TEST_TMPDIR/origin" checkout -q main

    git clone -q "$BATS_TEST_TMPDIR/origin" "$BATS_TEST_TMPDIR/myrepo" 2>/dev/null
    git -C "$BATS_TEST_TMPDIR/myrepo" checkout -q main
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

teardown() {
    "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true
}

@test "fw pull: creates a worktree from a remote branch, named after it" {
    run "$FW_BIN" pull colleague/cool-fix
    [ "$status" -eq 0 ]

    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/colleague-cool-fix"
    [ -d "$wt" ]
    [ "$(cat "$wt/work.txt")" = "work" ]
    run git -C "$wt" branch --show-current
    [ "$output" = "colleague/cool-fix" ]
    grep -q '^FW_BRANCH=colleague/cool-fix$' "$wt/.env.worktree"
}

@test "fw pull: records recency so the bare switch picker sees the worktree" {
    run "$FW_BIN" pull colleague/cool-fix
    [ "$status" -eq 0 ]
    grep -q $'\tcolleague-cool-fix$' "$BATS_TEST_TMPDIR/myproj-worktrees/.fw_recent"
}

# Asserted via the "Switching to <name>" line (see the note in
# create_delete.bats) rather than a live tmux session, which races on the
# shared test socket.
@test "fw pull: switches into the new worktree by default" {
    run "$FW_BIN" pull colleague/cool-fix
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switching to colleague-cool-fix"* ]]
}

@test "fw pull: --no-switch skips switching" {
    run "$FW_BIN" pull --no-switch colleague/cool-fix
    [ "$status" -eq 0 ]
    [[ "$output" != *"Switching to"* ]]
}

@test "fw pull: resolves a PR number to its branch via gh" {
    export FW_TEST_GH_PR_BRANCH=colleague/cool-fix
    export FW_TEST_GH_LOG="$BATS_TEST_TMPDIR/gh.log"

    run "$FW_BIN" pull 123
    [ "$status" -eq 0 ]

    grep -q "pr view 123" "$FW_TEST_GH_LOG"
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/colleague-cool-fix" ]
}

@test "fw pull: resolves a PR URL to its branch via gh" {
    export FW_TEST_GH_PR_BRANCH=colleague/cool-fix
    export FW_TEST_GH_LOG="$BATS_TEST_TMPDIR/gh.log"

    run "$FW_BIN" pull "https://github.com/felt/felt/pull/456"
    [ "$status" -eq 0 ]

    grep -q "pr view 456" "$FW_TEST_GH_LOG"
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/colleague-cool-fix" ]
}

@test "fw pull: updates the local branch to the remote tip on re-pull" {
    "$FW_BIN" pull colleague/cool-fix
    "$FW_BIN" delete --force colleague-cool-fix
    git -C "$BATS_TEST_TMPDIR/origin" checkout -q colleague/cool-fix
    echo more >>"$BATS_TEST_TMPDIR/origin/work.txt"
    git -C "$BATS_TEST_TMPDIR/origin" -c user.email=t@t -c user.name=t commit -qam more
    git -C "$BATS_TEST_TMPDIR/origin" checkout -q main

    run "$FW_BIN" pull colleague/cool-fix
    [ "$status" -eq 0 ]

    [ "$(git -C "$BATS_TEST_TMPDIR/myproj-worktrees/colleague-cool-fix" rev-parse HEAD)" = \
      "$(git -C "$BATS_TEST_TMPDIR/origin" rev-parse colleague/cool-fix)" ]
}

@test "fw pull: errors when a worktree for that branch already exists" {
    "$FW_BIN" pull colleague/cool-fix

    run "$FW_BIN" pull colleague/cool-fix
    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists"* ]]
    [[ "$output" == *"switch"* ]]
}

@test "fw pull: runs hook_post_pull in the worktree" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_post_pull() { echo "$FW_BRANCH" >"$FW_WORKTREE_PATH/pull-hook-ran"; }
EOF

    "$FW_BIN" pull colleague/cool-fix

    [ "$(cat "$BATS_TEST_TMPDIR/myproj-worktrees/colleague-cool-fix/pull-hook-ran")" = "colleague/cool-fix" ]
}

@test "fw pull: graphite adopt restores the golden checkout after gt get" {
    echo 'stack_backend=graphite' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GT_GET_CHECKOUT=1

    run "$FW_BIN" pull colleague/cool-fix
    [ "$status" -eq 0 ]

    run git -C "$BATS_TEST_TMPDIR/myrepo" branch --show-current
    [ "$output" = "main" ]
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/colleague-cool-fix" ]
    run git -C "$BATS_TEST_TMPDIR/myproj-worktrees/colleague-cool-fix" branch --show-current
    [ "$output" = "colleague/cool-fix" ]
}

@test "fw pull: graphite adopt refuses a dirty golden checkout" {
    echo 'stack_backend=graphite' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GT_GET_CHECKOUT=1
    echo dirty >"$BATS_TEST_TMPDIR/myrepo/uncommitted.txt"

    run "$FW_BIN" pull colleague/cool-fix
    [ "$status" -ne 0 ]
    [[ "$output" == *"uncommitted"* ]]
    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/colleague-cool-fix" ]
    run git -C "$BATS_TEST_TMPDIR/myrepo" branch --show-current
    [ "$output" = "main" ]
}

@test "fw pull --model: writes the model into settings.local.json" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
claude_model_aliases=([opus]="claude-opus-4-8[1m]")
EOF
    "$FW_BIN" pull colleague/cool-fix --model opus
    local settings="$BATS_TEST_TMPDIR/myproj-worktrees/colleague-cool-fix/.claude/settings.local.json"
    [ -f "$settings" ]
    [ "$(jq -r .model "$settings")" = "claude-opus-4-8[1m]" ]
}

@test "fw pull --model=literal: passes an unknown value through" {
    "$FW_BIN" pull colleague/cool-fix --model=some-model-id
    [ "$(jq -r .model "$BATS_TEST_TMPDIR/myproj-worktrees/colleague-cool-fix/.claude/settings.local.json")" = "some-model-id" ]
}

@test "fw pull --review: a configured bare prompt-flag starts Claude in a tmux claude window" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
claude_prompt_flags=([review]="/pr-review")
EOF
    export FW_TEST_CLAUDE_LOG="$BATS_TEST_TMPDIR/claude.log"
    "$FW_BIN" pull colleague/cool-fix --review

    run "$FW_ROOT/tests/shims/tmux" list-windows -t "=myproj-colleague-cool-fix" -F '#{window_name}'
    [[ "$output" == *"claude"* ]]

    local i
    for i in $(seq 1 25); do
        [ -f "$FW_TEST_CLAUDE_LOG" ] && grep -q -- "/pr-review" "$FW_TEST_CLAUDE_LOG" && break
        sleep 0.2
    done
    grep -q -- "/pr-review" "$FW_TEST_CLAUDE_LOG"
}

@test "fw pull --claude: passes a literal prompt through" {
    export FW_TEST_CLAUDE_LOG="$BATS_TEST_TMPDIR/claude.log"
    "$FW_BIN" pull colleague/cool-fix --claude "/some-literal"

    local i
    for i in $(seq 1 25); do
        [ -f "$FW_TEST_CLAUDE_LOG" ] && grep -q -- "/some-literal" "$FW_TEST_CLAUDE_LOG" && break
        sleep 0.2
    done
    grep -q -- "/some-literal" "$FW_TEST_CLAUDE_LOG"
}

@test "fw pull: an unconfigured bare flag is still an unknown-flag error" {
    run "$FW_BIN" pull colleague/cool-fix --nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown flag '--nope'"* ]]
}

@test "fw pull: builds a worktree on a local-only branch with no remote counterpart" {
    git -C "$BATS_TEST_TMPDIR/myrepo" checkout -q -b me/local-only main
    echo local >"$BATS_TEST_TMPDIR/myrepo/local.txt"
    git -C "$BATS_TEST_TMPDIR/myrepo" add local.txt
    git -C "$BATS_TEST_TMPDIR/myrepo" -c user.email=t@t -c user.name=t commit -qm "local work"
    git -C "$BATS_TEST_TMPDIR/myrepo" checkout -q main

    run "$FW_BIN" pull me/local-only
    [ "$status" -eq 0 ]

    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/local-only"
    [ -d "$wt" ]
    [ "$(cat "$wt/local.txt")" = "local" ]
    run git -C "$wt" branch --show-current
    [ "$output" = "me/local-only" ]
    grep -q '^FW_BRANCH=me/local-only$' "$wt/.env.worktree"
    [[ "$output" != *"Warning"* ]]
}

@test "fw pull: warns but uses the local branch when origin is unreachable" {
    git -C "$BATS_TEST_TMPDIR/myrepo" checkout -q -b me/offline main
    echo offline >"$BATS_TEST_TMPDIR/myrepo/offline.txt"
    git -C "$BATS_TEST_TMPDIR/myrepo" add offline.txt
    git -C "$BATS_TEST_TMPDIR/myrepo" -c user.email=t@t -c user.name=t commit -qm "offline work"
    git -C "$BATS_TEST_TMPDIR/myrepo" checkout -q main
    git -C "$BATS_TEST_TMPDIR/myrepo" remote set-url origin "$BATS_TEST_TMPDIR/gone"

    run "$FW_BIN" pull me/offline
    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning"* ]]
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/offline" ]
    [ "$(cat "$BATS_TEST_TMPDIR/myproj-worktrees/offline/offline.txt")" = "offline" ]
}

@test "fw pull: builds a worktree on a local-only branch under graphite" {
    echo 'stack_backend=graphite' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GT_GET_CHECKOUT=1

    git -C "$BATS_TEST_TMPDIR/myrepo" checkout -q -b me/local-only main
    echo local >"$BATS_TEST_TMPDIR/myrepo/local.txt"
    git -C "$BATS_TEST_TMPDIR/myrepo" add local.txt
    git -C "$BATS_TEST_TMPDIR/myrepo" -c user.email=t@t -c user.name=t commit -qm "local work"
    git -C "$BATS_TEST_TMPDIR/myrepo" checkout -q main

    run "$FW_BIN" pull me/local-only
    [ "$status" -eq 0 ]

    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/local-only"
    [ -d "$wt" ]
    [ "$(cat "$wt/local.txt")" = "local" ]
    run git -C "$wt" branch --show-current
    [ "$output" = "me/local-only" ]
    run git -C "$BATS_TEST_TMPDIR/myrepo" branch --show-current
    [ "$output" = "main" ]
    [[ "$output" != *"Warning"* ]]
}

@test "fw pull: graphite warns but uses the local branch when origin is unreachable" {
    echo 'stack_backend=graphite' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GT_GET_CHECKOUT=1

    git -C "$BATS_TEST_TMPDIR/myrepo" checkout -q -b me/offline main
    echo offline >"$BATS_TEST_TMPDIR/myrepo/offline.txt"
    git -C "$BATS_TEST_TMPDIR/myrepo" add offline.txt
    git -C "$BATS_TEST_TMPDIR/myrepo" -c user.email=t@t -c user.name=t commit -qm "offline work"
    git -C "$BATS_TEST_TMPDIR/myrepo" checkout -q main
    git -C "$BATS_TEST_TMPDIR/myrepo" remote set-url origin "$BATS_TEST_TMPDIR/gone"

    run "$FW_BIN" pull me/offline
    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning"* ]]
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/offline" ]
}

@test "fw pull: branch missing both locally and on the remote fails cleanly" {
    run "$FW_BIN" pull colleague/nope
    [ "$status" -ne 0 ]
    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/colleague-nope" ]
}

@test "fw pull: rollback on a failing hook_post_create leaves no stale Caddy entry" {
    # _fg regenerates the Caddyfile (adding this worktree) before the composite
    # runs hook_post_create; pull still rolls back when that hook fails, so the
    # rollback must refresh the Caddy map or it strands a dead reverse-proxy entry.
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<EOF
domain=myproj.local
caddyfile=$BATS_TEST_TMPDIR/Caddyfile
web_port_var=WEB_PORT
EOF
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_worktree_env() { echo "WEB_PORT=40${FW_PORT_SLOT}"; }
hook_post_create() { return 1; }
EOF

    run "$FW_BIN" pull colleague/cool-fix
    [ "$status" -ne 0 ]
    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/colleague-cool-fix" ]

    # The Caddyfile (if written at all) must not reference the rolled-back worktree.
    if [ -f "$BATS_TEST_TMPDIR/Caddyfile" ]; then
        ! grep -q "colleague-cool-fix" "$BATS_TEST_TMPDIR/Caddyfile"
    fi
}
