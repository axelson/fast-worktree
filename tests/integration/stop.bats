load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
branch_prefix=me
hook_worktree_env() { echo "TEST_PORT=$((30000 + FW_PORT_SLOT))"; }
EOF
    cd "$BATS_TEST_TMPDIR/myrepo"
    SERVER_PID=""
}

teardown() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill -9 "$SERVER_PID" 2>/dev/null || true
    fi
}

@test "fw stop: kills listeners on the worktree's _PORT ports" {
    command -v python3 >/dev/null || skip "python3 not available"
    command -v lsof >/dev/null || skip "lsof not available"
    "$FW_BIN" create feat
    local port
    port="$(grep '^TEST_PORT=' "$BATS_TEST_TMPDIR/myproj-worktrees/feat/.env.worktree" | cut -d= -f2)"

    # Close bats' fd 3 for the daemon, or the suite hangs waiting on it.
    python3 -m http.server "$port" --bind 127.0.0.1 </dev/null >/dev/null 2>&1 3>&- &
    SERVER_PID=$!
    local i
    for i in $(seq 1 50); do
        lsof -ti "tcp:$port" -sTCP:LISTEN >/dev/null 2>&1 && break
        sleep 0.1
    done

    run "$FW_BIN" stop feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"$port"* ]]

    sleep 0.2
    ! kill -0 "$SERVER_PID" 2>/dev/null
}

@test "fw stop: sends SIGTERM before escalating" {
    command -v python3 >/dev/null || skip "python3 not available"
    command -v lsof >/dev/null || skip "lsof not available"
    "$FW_BIN" create feat
    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/feat"
    local port
    port="$(grep '^TEST_PORT=' "$wt/.env.worktree" | cut -d= -f2)"

    (cd "$wt" && python3 -c "
import signal, sys, socketserver, http.server
def bye(*a):
    open('got-term', 'w').write('y')
    sys.exit(0)
signal.signal(signal.SIGTERM, bye)
socketserver.TCPServer(('127.0.0.1', $port), http.server.SimpleHTTPRequestHandler).serve_forever()
" </dev/null >/dev/null 2>&1 3>&- &)
    local i
    for i in $(seq 1 50); do
        lsof -ti "tcp:$port" -sTCP:LISTEN >/dev/null 2>&1 && break
        sleep 0.1
    done

    run "$FW_BIN" stop feat
    [ "$status" -eq 0 ]

    sleep 0.3
    [ -f "$wt/got-term" ]
}

@test "fw refresh: stops the worktree's servers before re-cloning" {
    command -v python3 >/dev/null || skip "python3 not available"
    command -v lsof >/dev/null || skip "lsof not available"
    mkdir -p "$BATS_TEST_TMPDIR/myrepo/_build"
    echo artifact >"$BATS_TEST_TMPDIR/myrepo/_build/marker"
    echo 'cow_assets=(_build)' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    "$FW_BIN" create feat
    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/feat"
    local port
    port="$(grep '^TEST_PORT=' "$wt/.env.worktree" | cut -d= -f2)"
    python3 -m http.server "$port" --bind 127.0.0.1 </dev/null >/dev/null 2>&1 3>&- &
    SERVER_PID=$!
    local i
    for i in $(seq 1 50); do
        lsof -ti "tcp:$port" -sTCP:LISTEN >/dev/null 2>&1 && break
        sleep 0.1
    done

    run "$FW_BIN" refresh feat
    [ "$status" -eq 0 ]

    sleep 0.3
    ! kill -0 "$SERVER_PID" 2>/dev/null
}

@test "fw stop: stop_port_vars collects exactly the listed vars (bare PORT in, other _PORT out)" {
    command -v python3 >/dev/null || skip "python3 not available"
    command -v lsof >/dev/null || skip "lsof not available"
    # An allowlist config: only `PORT` (a bare listener var the default *_PORT
    # regex never matches) is killable; `SHARED_PORT` (which the default regex
    # WOULD match) must be spared because it is not listed.
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
stop_port_vars=(PORT)
hook_worktree_env() {
    echo "PORT=$((31000 + FW_PORT_SLOT))"
    echo "SHARED_PORT=$((32000 + FW_PORT_SLOT))"
}
EOF
    "$FW_BIN" create feat
    local env="$BATS_TEST_TMPDIR/myproj-worktrees/feat/.env.worktree"
    local p1 p2
    p1="$(grep '^PORT=' "$env" | cut -d= -f2)"
    p2="$(grep '^SHARED_PORT=' "$env" | cut -d= -f2)"

    python3 -m http.server "$p1" --bind 127.0.0.1 </dev/null >/dev/null 2>&1 3>&- &
    local pid1=$!
    python3 -m http.server "$p2" --bind 127.0.0.1 </dev/null >/dev/null 2>&1 3>&- &
    local pid2=$!
    local i
    for i in $(seq 1 50); do
        lsof -ti "tcp:$p1" -sTCP:LISTEN >/dev/null 2>&1 &&
            lsof -ti "tcp:$p2" -sTCP:LISTEN >/dev/null 2>&1 && break
        sleep 0.1
    done

    run "$FW_BIN" stop feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"$p1"* ]]
    [[ "$output" != *"$p2"* ]]

    sleep 0.3
    ! kill -0 "$pid1" 2>/dev/null   # listed PORT killed
    kill -0 "$pid2" 2>/dev/null     # unlisted SHARED_PORT spared
    kill -9 "$pid2" 2>/dev/null || true
}

@test "fw stop: quiet success when nothing is listening" {
    "$FW_BIN" create feat

    run "$FW_BIN" stop feat
    [ "$status" -eq 0 ]
}

@test "fw stop: accepts the golden checkout" {
    "$FW_BIN" regen-env main

    run "$FW_BIN" stop main
    [ "$status" -eq 0 ]
    [[ "$output" != *"not inside a worktree"* ]]
    [[ "$output" != *"not found"* ]]
}

@test "fw stop: FW_PORT_SLOT is not treated as a port" {
    "$FW_BIN" create feat

    run "$FW_BIN" stop feat
    local slot
    slot="$(grep '^FW_PORT_SLOT=' "$BATS_TEST_TMPDIR/myproj-worktrees/feat/.env.worktree" | cut -d= -f2)"
    [[ "$output" != *"port $slot"* ]]
}
