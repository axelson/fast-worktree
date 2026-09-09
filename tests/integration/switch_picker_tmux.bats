load ../test_helper

# Behaviour test for the `fw switch` two-phase picker running under REAL fzf in a
# REAL (private-socket) tmux client — the only setup that catches this class of
# bug. The bats fzf shim never interprets `--bind`, and a plain pty misses the
# shell-specific failure, so both pass green while the picker is visibly broken
# (see wiki/testing-fzf-pickers.md).
#
# The bug this guards: fzf runs its `--bind` commands under the user's $SHELL.
# fw's pos() transform is POSIX-sh (`if [ -e M ]; then …; fi`); under a login
# shell that can't parse it (fish: "Missing end to balance this if statement")
# the transform errors, pos() is never emitted, and the cursor is stuck on the
# top row (main) instead of the current worktree. `_fzf_pick_line` pins
# SHELL=/bin/sh so every picker's binds run in POSIX sh regardless of login
# shell — this test proves the switch picker lands correctly even with
# SHELL=fish.
#
# Requires real fzf and fish; skips cleanly (e.g. in the Linux CI container)
# when either is absent.

# The first fzf on PATH that is not our shim.
_real_fzf() {
    local c
    for c in $(type -aP fzf 2>/dev/null); do
        case "$c" in */tests/shims/*) ;; *) printf '%s\n' "$c"; return 0 ;; esac
    done
    return 1
}

# The fzf cursor row is the only candidate line carrying a background-colour SGR
# ("[48;…"); non-cursor rows colour just their gutter glyph in the foreground.
# The worktree name is plain ASCII in that line, so grep it straight out.
_picker_cursor_name() {
    printf '%s\n' "$1" | grep -a '\[48;' | grep -aoE 'main|alpha' | head -1
}

setup() {
    isolate_env
    unset FZF_DEFAULT_OPTS

    FISH="$(command -v fish || true)"
    REALFZF="$(_real_fzf || true)"
    [ -n "$FISH" ]    || skip "fish not installed (needed to reproduce the login-shell bind bug)"
    [ -n "$REALFZF" ] || skip "no real fzf on PATH (only the shim)"

    # Real fzf must win over the shim for this picker.
    mkdir -p "$BATS_TEST_TMPDIR/realbin"
    ln -sf "$REALFZF" "$BATS_TEST_TMPDIR/realbin/fzf"
    export PATH="$BATS_TEST_TMPDIR/realbin:$PATH"

    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    cd "$BATS_TEST_TMPDIR/myrepo"

    # main is always candidate row 1; seed alpha into the recency log so it is
    # candidate row 2 — a clean discriminator from the default top row.
    "$FW_BIN" create --no-switch alpha >/dev/null 2>&1
    "$FW_BIN" switch alpha             >/dev/null 2>&1
}

teardown() {
    "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true
}

@test "fw switch: preselects the current worktree even when the login shell is fish" {
    local tmuxsh="$FW_ROOT/tests/shims/tmux"
    local alpha="$BATS_TEST_TMPDIR/myproj-worktrees/alpha"

    # Launch the real picker in tmux with SHELL=fish, rooted in the alpha
    # worktree so the current worktree is alpha (candidate row 2). Real fzf runs
    # its binds under fish — the environment that broke pos().
    "$tmuxsh" new-session -d -s pick -x 120 -y 30 -c "$alpha" \
        "cd '$alpha' && SHELL='$FISH' exec '$FW_BIN' switch"

    # Poll until both candidate rows have drawn and a cursor row is readable.
    local pane cursor="" i
    for ((i = 0; i < 50; i++)); do
        sleep 0.2
        pane="$("$tmuxsh" capture-pane -p -e -t pick 2>/dev/null)"
        if grep -q 'main' <<<"$pane" && grep -q 'alpha' <<<"$pane"; then
            cursor="$(_picker_cursor_name "$pane")"
            [ -n "$cursor" ] && break
        fi
    done

    if [ -z "$cursor" ]; then
        echo "picker never rendered a readable cursor row; last pane:"
        printf '%s\n' "$pane" | cat -v
        false
    fi
    if [ "$cursor" != "alpha" ]; then
        echo "cursor landed on '$cursor', expected the current worktree 'alpha'"
        printf '%s\n' "$pane" | cat -v
        false
    fi
}
