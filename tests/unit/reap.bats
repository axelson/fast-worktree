load ../test_helper

# tests/reap-fw-test reaps orphaned fw-test tmux servers left behind when a
# test run dies uncatchably (SIGKILL) or a developer runs `bats` directly (no
# run tag). It is age-gated: a live server belongs to a single test whose life
# is capped by BATS_TEST_TIMEOUT, so anything older than the threshold is
# provably an orphan. Selection is what the reaper owns; actually killing the
# server is tmux's job, so these tests drive a recording `tmux` stub and real
# socket files with controlled mtimes rather than spawning real servers.

setup() {
    isolate_env

    # Isolated tmux socket dir the reaper will scan (honors TMUX_TMPDIR).
    export TMUX_TMPDIR="$BATS_TEST_TMPDIR/tmuxtmp"
    SOCKDIR="$TMUX_TMPDIR/tmux-$(id -u)"
    mkdir -p "$SOCKDIR"

    # Recording tmux stub, ahead of tests/shims on PATH, logging every call so
    # we can assert which sockets the reaper targeted.
    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    TMUX_STUB_LOG="$BATS_TEST_TMPDIR/tmux-calls.log"
    export TMUX_STUB_LOG
    mkdir -p "$STUB_BIN"
    cat >"$STUB_BIN/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TMUX_STUB_LOG"
exit 0
EOF
    chmod +x "$STUB_BIN/tmux"
    export PATH="$STUB_BIN:$PATH"

    : >"$TMUX_STUB_LOG"
}

# make_socket <name> <age-seconds> — a stand-in socket file aged via mtime.
make_socket() {
    local name="$1" age="$2" f="$SOCKDIR/$1"
    : >"$f"
    local ts=$(( $(date +%s) - age ))
    # Epoch -> touch stamp, portably: BSD spells it `date -r EPOCH`, GNU
    # `date -d @EPOCH` (GNU's -r means a reference file, so it errors here and
    # we fall through). Mirrors the date fallbacks in lib/.
    touch -t "$(date -r "$ts" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$ts" +%Y%m%d%H%M.%S)" "$f"
}

@test "reap: an old fw-test orphan is killed and its socket file removed" {
    make_socket "fw-test-1234567890" 1200   # 20 min old — provably an orphan

    run "$FW_ROOT/tests/reap-fw-test"
    [ "$status" -eq 0 ]

    # It asked tmux to kill exactly that server...
    grep -q -- '-L fw-test-1234567890 kill-server' "$TMUX_STUB_LOG"
    # ...and removed the stale socket file.
    [ ! -e "$SOCKDIR/fw-test-1234567890" ]
}

@test "reap: spares a fresh fw-test socket (a live test's server)" {
    make_socket "fw-test-9999999999" 0      # just created — a running test owns it

    run "$FW_ROOT/tests/reap-fw-test"
    [ "$status" -eq 0 ]

    # Never touched: no kill call, socket file intact.
    ! grep -q 'kill-server' "$TMUX_STUB_LOG"
    [ -e "$SOCKDIR/fw-test-9999999999" ]
}

@test "reap: never touches the user's default socket or other sockets, at any age" {
    make_socket "default" 3600              # the user's real server, 1h old
    make_socket "some-other-app-42" 3600    # unrelated socket, 1h old

    run "$FW_ROOT/tests/reap-fw-test"
    [ "$status" -eq 0 ]

    ! grep -q 'kill-server' "$TMUX_STUB_LOG"
    [ -e "$SOCKDIR/default" ]
    [ -e "$SOCKDIR/some-other-app-42" ]
}
