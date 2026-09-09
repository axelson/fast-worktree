load ../test_helper

# Behaviour test for the `fw switch-claude` two-phase picker running under REAL
# fzf in a REAL (private-socket) tmux client — the only setup that proves the
# picker actually LIVE-REFRESHES. The bats fzf shim never interprets `--bind`, so
# the bind-string assertions in switch_claude.bats prove the loop is *wired* but
# not that it *fires*; this test flips a session's status in the registry while
# the picker is open and confirms the row repaints (see wiki/testing-fzf-pickers.md).
#
# It also runs the picker under SHELL=fish: fzf runs its `--bind` commands under
# $SHELL, and switch-claude's reload embeds an env assignment (`FW_COLOR=always
# <bin> …`) that fish cannot parse. `_fzf_pick_line` pins SHELL=$BASH so the bind
# runs under bash regardless of login shell; this test would catch a regression
# that dropped that pin (fish would error on the reload and the row would never
# update).
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

# seed_session <file> <pid> <cwd> <status> <age-secs> <tmux> <name>
seed_session() {
    local dir="$CLAUDE_CONFIG_DIR/sessions"
    mkdir -p "$dir"
    local supd=$(( ( $(date +%s) - $5 ) * 1000 ))
    cat >"$dir/$1.json" <<EOF
{"pid":$2,"cwd":"$3","status":"$4","statusUpdatedAt":$supd,"updatedAt":$supd,"tmux":"$6","name":"$7"}
EOF
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
    # A short interval so the flip shows within a couple of poll cycles. Global,
    # because switch-claude is cross-project.
    echo 'switch_claude_refresh_secs=1' >>"$FW_CONFIG_DIR/config.sh"
    # The registry dir must be exported BEFORE the first tmux command so the
    # pre-started server (and thus the picker's reload subprocess) inherits it.
    export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

teardown() {
    "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true
}

@test "fw switch-claude: the picker live-refreshes when a session's status flips" {
    local tmuxsh="$FW_ROOT/tests/shims/tmux"
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" idle 30 "myproj-alpha:@2.%2" agent

    # Launch the real picker in tmux with SHELL=fish. Real fzf runs its binds
    # under fish — the environment that would break an unpinned env-assignment
    # reload command.
    "$tmuxsh" new-session -d -s pick -x 120 -y 30 -c "$BATS_TEST_TMPDIR" \
        "cd '$BATS_TEST_TMPDIR' && SHELL='$FISH' exec '$FW_BIN' switch-claude"

    # Wait until the picker has drawn the idle row.
    local pane i
    for ((i = 0; i < 50; i++)); do
        sleep 0.2
        pane="$("$tmuxsh" capture-pane -p -e -t pick 2>/dev/null)"
        grep -q 'idle' <<<"$pane" && break
    done
    if ! grep -q 'idle' <<<"$pane"; then
        echo "picker never drew the initial idle row; last pane:"
        printf '%s\n' "$pane" | cat -v
        false
    fi
    # The registry has not been touched yet, so nothing should read as waiting.
    ! grep -q 'waiting' <<<"$pane"

    # Flip the session to waiting in the registry — the live refresh must notice.
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" waiting 5 "myproj-alpha:@2.%2" agent

    local seen=""
    for ((i = 0; i < 75; i++)); do
        sleep 0.2
        pane="$("$tmuxsh" capture-pane -p -e -t pick 2>/dev/null)"
        if grep -q 'waiting' <<<"$pane"; then seen=1; break; fi
    done
    if [ -z "$seen" ]; then
        echo "picker never repainted the row as waiting after the registry flip; last pane:"
        printf '%s\n' "$pane" | cat -v
        false
    fi
}

@test "fw switch-claude: preselects the current pane's own session over the project" {
    local tmuxsh="$FW_ROOT/tests/shims/tmux"
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"

    # Start a placeholder pane FIRST so we can read its id and seed a session
    # onto it BEFORE the picker launches — the preselect pos() is computed from
    # the phase-1 rows, so the session must already be in the registry. The
    # pane's cwd is myrepo, so the picker's current project resolves to myproj:
    # the project-header preselect would land on line 1, and the pane match must
    # win and land on the alpha session row instead.
    "$tmuxsh" new-session -d -s pick -x 120 -y 30 -c "$BATS_TEST_TMPDIR/myrepo" 'exec bash --norc'
    local win pane
    win="$("$tmuxsh" display-message -p -t pick '#{window_id}')"
    pane="$("$tmuxsh" display-message -p -t pick '#{pane_id}')"
    seed_session a "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" idle 20 "pick:$win.$pane" agent

    # Launch the picker in that same pane, under fish (the file's SHELL-pin
    # coverage). Its own `tmux display-message` reports this pane, matching the
    # seeded session.
    "$tmuxsh" send-keys -t pick "SHELL='$FISH' exec '$FW_BIN' switch-claude" Enter

    # Poll until fzf's CURRENT line is the alpha row. fzf draws its pointer glyph
    # on every list line, distinguishing the current one only by a highlight — a
    # background-color (or reverse-video) SGR that non-current rows lack — so the
    # -e capture is required (a plain -p capture cannot tell the rows apart).
    local hl=$'\033''\[(48;|7m)' capture cur="" i
    for ((i = 0; i < 60; i++)); do
        sleep 0.2
        capture="$("$tmuxsh" capture-pane -p -e -t pick 2>/dev/null)"
        cur="$(printf '%s\n' "$capture" | grep -aE 'alpha|myproj' | grep -aE "$hl" | head -1)"
        [[ "$cur" == *alpha* ]] && break
    done
    if [[ "$cur" != *alpha* ]]; then
        echo "the current line never became the alpha session row; last highlighted: [$cur]; pane:"
        printf '%s\n' "$capture" | cat -v
        false
    fi
    # the pane match beat the project-header preselect (myproj, line 1)
    [[ "$cur" != *myproj* ]]
}
