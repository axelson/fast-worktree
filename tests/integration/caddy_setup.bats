load ../test_helper

# `fw caddy setup` / `fw caddy remove`: automate (and reverse) the per-project
# Caddy HTTPS wiring — config keys, the per-project fragment, the shared
# aggregation import line, the dnsmasq address line, and the sudo steps
# (/etc/resolver + dnsmasq restart). See docs/caddy.md for the manual procedure.
#
# Seams: brew --prefix points etc/ (the shared aggregation Caddyfile and
# dnsmasq.conf) at a scratch dir so their writes are real and assertable; the
# sudo shim logs the privileged steps instead of running them.

setup() {
    isolate_env
    # `fw caddy setup`/`remove` are gated macOS-only in the product (they wire
    # Homebrew Caddy + /etc/resolver + dnsmasq). The brew/sudo/dnsmasq seams are
    # mocked below, so force the Darwin gate to exercise the wiring logic on any
    # host — the exported OSTYPE is inherited by the fw subprocess.
    export OSTYPE=darwin20
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
branch_prefix=me
web_port_var=WEB_PORT
hook_worktree_env() { echo "WEB_PORT=40${FW_PORT_SLOT}"; }
EOF
    export FW_TEST_BREW_PREFIX="$BATS_TEST_TMPDIR/brew"
    ETC="$FW_TEST_BREW_PREFIX/etc"
    mkdir -p "$ETC"
    export FW_TEST_SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
    export FW_TEST_BREW_LOG="$BATS_TEST_TMPDIR/brew.log"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

teardown() {
    "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true
}

@test "setup: writes domain and caddyfile to the project config" {
    "$FW_BIN" caddy setup

    run "$FW_BIN" config get --project domain
    [ "$status" -eq 0 ]
    [ "$output" = myproj.local ]

    run "$FW_BIN" config get --project caddyfile
    [ "$status" -eq 0 ]
    [ "$output" = "$ETC/Caddyfile-fw-myproj" ]
}

@test "setup: writes the per-project fragment with a site block for each worktree" {
    "$FW_BIN" create feat
    "$FW_BIN" caddy setup

    [ -f "$ETC/Caddyfile-fw-myproj" ]
    grep -q '^feat.myproj.local {' "$ETC/Caddyfile-fw-myproj"
    grep -q 'tls internal' "$ETC/Caddyfile-fw-myproj"
}

@test "setup: wires the import line into the shared aggregation Caddyfile" {
    "$FW_BIN" caddy setup

    grep -qF "import $ETC/Caddyfile-fw-myproj" "$ETC/Caddyfile-fast-worktree"
}

@test "setup: the aggregation import is idempotent across repeat runs" {
    "$FW_BIN" caddy setup
    "$FW_BIN" caddy setup

    run grep -cF "import $ETC/Caddyfile-fw-myproj" "$ETC/Caddyfile-fast-worktree"
    [ "$output" -eq 1 ]
}

@test "setup: leaves another project's aggregation import untouched" {
    printf 'import %s/Caddyfile-fw-other\n' "$ETC" >"$ETC/Caddyfile-fast-worktree"
    "$FW_BIN" caddy setup

    grep -qF "import $ETC/Caddyfile-fw-other" "$ETC/Caddyfile-fast-worktree"
    grep -qF "import $ETC/Caddyfile-fw-myproj" "$ETC/Caddyfile-fast-worktree"
}

@test "setup: adds the dnsmasq address line for the domain" {
    "$FW_BIN" caddy setup

    grep -qxF 'address=/myproj.local/127.0.0.1' "$ETC/dnsmasq.conf"
}

@test "setup: the dnsmasq address line is idempotent, leaving other domains" {
    printf 'address=/other.local/127.0.0.1\n' >"$ETC/dnsmasq.conf"
    "$FW_BIN" caddy setup
    "$FW_BIN" caddy setup

    run grep -cxF 'address=/myproj.local/127.0.0.1' "$ETC/dnsmasq.conf"
    [ "$output" -eq 1 ]
    grep -qxF 'address=/other.local/127.0.0.1' "$ETC/dnsmasq.conf"
}

@test "setup: runs the sudo steps — resolver file and dnsmasq restart" {
    "$FW_BIN" caddy setup

    grep -q 'tee /etc/resolver/myproj.local' "$FW_TEST_SUDO_LOG"
    grep -q 'brew services restart dnsmasq' "$FW_TEST_SUDO_LOG"
}

@test "setup: errors when web_port_var is not configured" {
    register_project noport "$BATS_TEST_TMPDIR/myrepo"

    run "$FW_BIN" -p noport caddy setup
    [ "$status" -ne 0 ]
    [[ "$output" == *web_port_var* ]]
    [ ! -f "$FW_TEST_SUDO_LOG" ]
}

@test "setup: --domain overrides the default <project>.local" {
    "$FW_BIN" caddy setup --domain custom.test

    run "$FW_BIN" config get --project domain
    [ "$output" = custom.test ]
    grep -qxF 'address=/custom.test/127.0.0.1' "$ETC/dnsmasq.conf"
    grep -q 'tee /etc/resolver/custom.test' "$FW_TEST_SUDO_LOG"
}

@test "setup: warns when the root Caddyfile does not import the aggregation" {
    printf '# empty root Caddyfile\n' >"$ETC/Caddyfile"
    "$FW_BIN" config set --project caddy_reload_file "$ETC/Caddyfile"

    run "$FW_BIN" caddy setup
    [ "$status" -eq 0 ]
    [[ "$output" == *"does not import Caddyfile-fast-worktree"* ]]
}

@test "setup: no aggregation-import warning once the root imports it" {
    printf 'import Caddyfile-fast-worktree\n' >"$ETC/Caddyfile"
    "$FW_BIN" config set --project caddy_reload_file "$ETC/Caddyfile"

    run "$FW_BIN" caddy setup
    [ "$status" -eq 0 ]
    [[ "$output" != *"does not import Caddyfile-fast-worktree"* ]]
}

@test "setup: reloads a running caddy, with the import already wired" {
    printf 'import Caddyfile-fast-worktree\n' >"$ETC/Caddyfile"
    "$FW_BIN" config set --project caddy_reload_file "$ETC/Caddyfile"
    export FW_TEST_RUNNING_PROCS=caddy
    export FW_TEST_CADDY_LOG="$BATS_TEST_TMPDIR/caddy.log"

    "$FW_BIN" caddy setup

    # The reload targets the shared root, and by the time it fires this
    # project's fragment is imported — so the new site is live immediately.
    grep -q "reload --config $ETC/Caddyfile" "$FW_TEST_CADDY_LOG"
    grep -qF "import $ETC/Caddyfile-fw-myproj" "$ETC/Caddyfile-fast-worktree"
}

# --- fw caddy remove ---

@test "remove: unsets domain and caddyfile in the project config" {
    "$FW_BIN" caddy setup
    "$FW_BIN" caddy remove

    run "$FW_BIN" config get --project domain
    [ "$status" -ne 0 ]
    run "$FW_BIN" config get --project caddyfile
    [ "$status" -ne 0 ]
}

@test "remove: deletes the fragment and this project's import/address lines only" {
    printf 'import %s/Caddyfile-fw-other\n' "$ETC" >"$ETC/Caddyfile-fast-worktree"
    printf 'address=/other.local/127.0.0.1\n' >"$ETC/dnsmasq.conf"
    "$FW_BIN" create feat
    "$FW_BIN" caddy setup
    [ -f "$ETC/Caddyfile-fw-myproj" ]

    "$FW_BIN" caddy remove

    [ ! -f "$ETC/Caddyfile-fw-myproj" ]
    ! grep -qF "import $ETC/Caddyfile-fw-myproj" "$ETC/Caddyfile-fast-worktree"
    ! grep -qxF 'address=/myproj.local/127.0.0.1' "$ETC/dnsmasq.conf"
    grep -qF "import $ETC/Caddyfile-fw-other" "$ETC/Caddyfile-fast-worktree"
    grep -qxF 'address=/other.local/127.0.0.1' "$ETC/dnsmasq.conf"
}

@test "remove: runs the sudo teardown — remove resolver and restart dnsmasq" {
    "$FW_BIN" caddy setup
    : >"$FW_TEST_SUDO_LOG"

    "$FW_BIN" caddy remove

    grep -qE 'rm .*/etc/resolver/myproj.local' "$FW_TEST_SUDO_LOG"
    grep -q 'brew services restart dnsmasq' "$FW_TEST_SUDO_LOG"
}

@test "remove: errors when caddy was never set up for the project" {
    register_project noport "$BATS_TEST_TMPDIR/myrepo"

    run "$FW_BIN" -p noport caddy remove
    [ "$status" -ne 0 ]
}

@test "remove: reloads a running caddy so the dropped site leaves the config" {
    printf 'import Caddyfile-fast-worktree\n' >"$ETC/Caddyfile"
    "$FW_BIN" config set --project caddy_reload_file "$ETC/Caddyfile"
    "$FW_BIN" caddy setup
    export FW_TEST_RUNNING_PROCS=caddy
    export FW_TEST_CADDY_LOG="$BATS_TEST_TMPDIR/caddy.log"

    "$FW_BIN" caddy remove

    grep -q "reload --config $ETC/Caddyfile" "$FW_TEST_CADDY_LOG"
}

@test "remove: stays re-runnable when the sudo teardown fails partway" {
    "$FW_BIN" caddy setup

    # Simulate an aborted sudo (wrong password / Ctrl-C): remove dies, but must
    # leave the layer configured so a retry can finish the teardown.
    FW_TEST_SUDO_EXIT=1 run "$FW_BIN" caddy remove
    [ "$status" -ne 0 ]
    run "$FW_BIN" config get --project domain
    [ "$status" -eq 0 ]
    [ "$output" = myproj.local ]

    # Retry with sudo working: completes and clears the config.
    "$FW_BIN" caddy remove
    run "$FW_BIN" config get --project domain
    [ "$status" -ne 0 ]
}

# --- dispatch ---

@test "caddy: no subcommand errors with usage" {
    run "$FW_BIN" caddy
    [ "$status" -ne 0 ]
    [[ "$output" == *subcommand* ]]
}

@test "caddy: unknown subcommand errors" {
    run "$FW_BIN" caddy bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown caddy subcommand"* ]]
}

@test "setup: rejects an unknown flag" {
    run "$FW_BIN" caddy setup --bogus
    [ "$status" -ne 0 ]
    [ ! -f "$FW_TEST_SUDO_LOG" ]
}
