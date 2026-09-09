load ../test_helper

# Pre-created tmux windows: a project's hook_tmux_windows builds a layout at
# session birth via the fw_window helper. External tmux goes through the shim
# onto a per-test socket (never real tmux); assertions read window state back
# from that socket, or the shim's capture log (FW_TEST_TMUX_LOG) for the
# send-keys/new-window argv that pane state can't show deterministically.

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

teardown() {
    "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true
}

# tmuxs — the test socket's tmux (same shim the tool uses).
tmuxs() { "$FW_ROOT/tests/shims/tmux" "$@"; }

# add_hook <body> — append a hook_tmux_windows definition to the project config.
add_hook() {
    { echo 'hook_tmux_windows() {'; echo "$1"; echo '}'; } \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
}

# commit_subdir <relpath> — materialise a tracked subdir so a worktree copy has
# it (a start dir that doesn't exist makes new-window -c fail).
commit_subdir() {
    mkdir -p "$BATS_TEST_TMPDIR/myrepo/$1"
    touch "$BATS_TEST_TMPDIR/myrepo/$1/.keep"
    git -C "$BATS_TEST_TMPDIR/myrepo" add -A
    git -C "$BATS_TEST_TMPDIR/myrepo" -c user.email=t@t -c user.name=t commit -q -m subdir
}

@test "no hook_tmux_windows leaves a bare single-window session" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" tmux-open alpha

    run tmuxs list-windows -t "=myproj-alpha" -F '#{window_name}'
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
}

@test "three windows are built in order, reusing window 0" {
    add_hook '
    fw_window app
    fw_window editor
    fw_window logs'
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" tmux-open alpha

    run tmuxs list-windows -t "=myproj-alpha" -F '#{window_name}'
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'app\neditor\nlogs')" ]
    # Window 0 was reused (renamed), not left as a stray blank-named window.
    ! tmuxs list-windows -t "=myproj-alpha" -F '#{window_name}' | grep -qx ''
}

@test "start dirs: new windows root at worktree/<dir>, default is the root" {
    commit_subdir services/app
    add_hook '
    fw_window top
    fw_window app services/app'
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" tmux-open alpha

    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    run tmuxs list-panes -t "=myproj-alpha:top" -F '#{pane_current_path}'
    [ "$(realpath "$output")" = "$(realpath "$wt")" ]
    run tmuxs list-panes -t "=myproj-alpha:app" -F '#{pane_current_path}'
    [ "$(realpath "$output")" = "$(realpath "$wt/services/app")" ]
}

@test "first window with a subdir re-homes window 0 via a cd keystroke" {
    commit_subdir services/app
    export FW_TEST_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
    add_hook '
    fw_window app services/app'
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" tmux-open alpha

    # Window 0 reused: exactly one window, and no new-window was issued for app.
    run tmuxs list-windows -t "=myproj-alpha" -F '#{window_name}'
    [ "$output" = "app" ]
    ! grep -q 'new-window.*-n app' "$FW_TEST_TMUX_LOG"
    # Re-home is a cd keystroke, since an existing window's start dir is fixed.
    grep -q "send-keys.*cd .*/services/app.*Enter" "$FW_TEST_TMUX_LOG"
}

@test "windows build correctly when the user's tmux base-index is 1" {
    # A very common ~/.tmux.conf setting. tmux reads it at server start even on
    # the test socket, so window 0 lands at index 1 — addressing it as ":0"
    # would fail. Windows are addressed by id, so the layout still builds.
    echo 'set -g base-index 1' >"$HOME/.tmux.conf"
    add_hook '
    fw_window app
    fw_window editor'
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" tmux-open alpha

    run tmuxs list-windows -t "=myproj-alpha" -F '#{window_name}'
    [ "$output" = "$(printf 'app\neditor')" ]
    # The initial window was renamed, not left behind as a stray default window.
    ! printf '%s\n' "$output" | grep -qx ''
}

@test "a hook that builds no windows leaves a bare session" {
    add_hook '    :'
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" tmux-open alpha

    run tmuxs list-windows -t "=myproj-alpha" -F '#{window_name}'
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
}

@test "first window's cd re-home precedes its startup command" {
    commit_subdir services/app
    export FW_TEST_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
    add_hook '
    fw_window app services/app "run-me"'
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" tmux-open alpha

    # The re-home cd must be typed before the command, or the command runs in the
    # wrong directory.
    local cd_line cmd_line
    cd_line=$(grep -n "send-keys.*cd .*/services/app" "$FW_TEST_TMUX_LOG" | head -1 | cut -d: -f1)
    cmd_line=$(grep -n "send-keys.*run-me" "$FW_TEST_TMUX_LOG" | head -1 | cut -d: -f1)
    [ -n "$cd_line" ] && [ -n "$cmd_line" ]
    [ "$cd_line" -lt "$cmd_line" ]
}

@test "a window's command is sent with send-keys, an idle window gets none" {
    export FW_TEST_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
    add_hook '
    fw_window app . "echo hi-from-app"
    fw_window idle'
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" tmux-open alpha

    grep -q "send-keys.*echo hi-from-app.*Enter" "$FW_TEST_TMUX_LOG"
    ! grep -q "send-keys.*idle" "$FW_TEST_TMUX_LOG"
}

@test "--select focuses the marked window on landing" {
    add_hook '
    fw_window app
    fw_window --select editor
    fw_window logs'
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" tmux-open alpha

    run tmuxs list-windows -t "=myproj-alpha" -F '#{window_active} #{window_name}'
    [[ "$output" == *"1 editor"* ]]
}

@test "with no --select the first window is focused" {
    add_hook '
    fw_window app
    fw_window editor'
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" tmux-open alpha

    run tmuxs list-windows -t "=myproj-alpha" -F '#{window_active} #{window_name}'
    [[ "$output" == *"1 app"* ]]
}

@test "main is born with an empty FW_WORKTREE while a worktree gets the layout" {
    export HOOK_LOG="$BATS_TEST_TMPDIR/hook.log"
    # No-colon ${FW_WORKTREE-UNSET}: prints "" when exported empty (main) and
    # "UNSET" only when truly unbound — so this distinguishes "exported empty"
    # (the invariant holds) from "never exported" (the bug this guards against).
    add_hook '
    echo "wt=[${FW_WORKTREE-UNSET}] root=[${FW_REPO_ROOT-UNSET}]" >>"'"$HOOK_LOG"'"
    [[ -n "${FW_WORKTREE:-}" ]] || return 0
    fw_window app
    fw_window editor'
    "$FW_BIN" create --no-switch alpha

    "$FW_BIN" switch main
    "$FW_BIN" tmux-open alpha

    # main saw the contract exported with FW_WORKTREE empty (not unset) and a
    # real repo root, so its hook ran and early-returned to a single window.
    grep -q 'wt=\[\] root=\[.*myrepo\]' "$HOOK_LOG"
    run tmuxs list-windows -t "=myproj-main" -F '#{window_name}'
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]

    # The worktree session saw FW_WORKTREE=alpha and got the full layout.
    grep -q 'wt=\[alpha\]' "$HOOK_LOG"
    run tmuxs list-windows -t "=myproj-alpha" -F '#{window_name}'
    [ "$output" = "$(printf 'app\neditor')" ]
}

@test "a failing hook still lands the session and warns" {
    add_hook '
    fw_window app
    return 1'
    # create now births the session (to run the background setup), so the
    # failing hook_tmux_windows warns here — the later tmux-open just reuses the
    # already-born session.
    run "$FW_BIN" create --no-switch alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning: hook_tmux_windows failed"* ]]

    # Entry is never blocked: the session exists with whatever was built.
    run tmuxs has-session -t "=myproj-alpha"
    [ "$status" -eq 0 ]
}

@test "fw_window outside the hook errors instead of targeting a stray session" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_post_switch() { fw_window rogue; }
EOF
    "$FW_BIN" create --no-switch alpha

    run "$FW_BIN" switch alpha
    [[ "$output" == *"fw_window must be called from hook_tmux_windows"* ]]
}
