load ../test_helper

# The Caddy/dnsmasq opt-in layer (domain config) + `fw open`. A project hook
# derives a WEB_PORT from the slot, exactly as a real project would; core reads
# it back through the web_port_var config for the reverse proxy and open URL.

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
branch_prefix=me
hook_worktree_env() { echo "WEB_PORT=40${FW_PORT_SLOT}"; }
EOF
    CADDYFILE="$BATS_TEST_TMPDIR/Caddyfile"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

teardown() {
    "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true
}

# enable_caddy — append the Caddy opt-in config (domain + file path + port var).
enable_caddy() {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<EOF
domain=test.local
caddyfile=$CADDYFILE
web_port_var=WEB_PORT
EOF
}

wt_web_port() {
    grep '^WEB_PORT=' "$BATS_TEST_TMPDIR/myproj-worktrees/$1/.env.worktree" | cut -d= -f2
}

# --- Caddyfile regeneration ---

@test "create: writes a reverse-proxy site block when domain is set" {
    enable_caddy
    "$FW_BIN" create feat

    [ -f "$CADDYFILE" ]
    grep -q '^feat.test.local {' "$CADDYFILE"
    grep -q 'tls internal' "$CADDYFILE"
    local port
    port="$(wt_web_port feat)"
    [ -n "$port" ]
    grep -q "reverse_proxy localhost:$port" "$CADDYFILE"
}

@test "create: does not touch any Caddyfile when domain is unset" {
    "$FW_BIN" create feat
    [ ! -f "$CADDYFILE" ]
}

@test "create: does not regenerate when web_port_var is unset" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<EOF
domain=test.local
caddyfile=$CADDYFILE
EOF
    "$FW_BIN" create feat
    [ ! -f "$CADDYFILE" ]
}

@test "regen covers every live worktree, one block each" {
    enable_caddy
    "$FW_BIN" create feat
    "$FW_BIN" create bar

    grep -q '^feat.test.local {' "$CADDYFILE"
    grep -q '^bar.test.local {' "$CADDYFILE"
}

@test "delete: regenerates the Caddyfile without the removed worktree" {
    enable_caddy
    "$FW_BIN" create feat
    "$FW_BIN" create bar
    "$FW_BIN" delete feat

    grep -q '^bar.test.local {' "$CADDYFILE"
    ! grep -q '^feat.test.local {' "$CADDYFILE"
}

@test "regen-env: rebuilds a missing Caddyfile" {
    enable_caddy
    "$FW_BIN" create feat
    rm -f "$CADDYFILE"

    "$FW_BIN" regen-env feat
    grep -q '^feat.test.local {' "$CADDYFILE"
}

@test "archive: regenerates the Caddyfile without the archived worktree" {
    enable_caddy
    "$FW_BIN" create feat
    "$FW_BIN" create bar
    "$FW_BIN" archive --reason done feat

    grep -q '^bar.test.local {' "$CADDYFILE"
    ! grep -q '^feat.test.local {' "$CADDYFILE"
}

@test "site block: serves a not-running fallback page on proxy errors" {
    enable_caddy
    "$FW_BIN" create feat

    # handle_errors + an inline HTML page naming the worktree and the command
    # that starts it, so a browser hit on a stopped worktree isn't a bare 502.
    grep -q 'handle_errors' "$CADDYFILE"
    grep -q 'Content-Type text/html' "$CADDYFILE"
    grep -q 'feat</span> is not running' "$CADDYFILE"
    grep -q 'fw start feat' "$CADDYFILE"
}

@test "site block: fallback page is per-worktree" {
    enable_caddy
    "$FW_BIN" create feat
    "$FW_BIN" create bar

    grep -q 'fw start feat' "$CADDYFILE"
    grep -q 'fw start bar' "$CADDYFILE"
}

@test "site block: golden checkout fallback page says fw start main" {
    enable_caddy
    "$FW_BIN" regen-env main

    grep -q 'fw start main' "$CADDYFILE"
}

# --- catch-all 404 for unknown/deleted worktrees ---

@test "catch-all: regen emits a wildcard 404 site for unknown worktrees" {
    enable_caddy
    "$FW_BIN" create feat

    # A *.<domain> site that any hostname with no specific block falls through
    # to, serving a styled 404 that names the requested address at runtime.
    # Assert the 404 status, copy, and host placeholder are inside the wildcard
    # block itself (it runs to EOF, being appended last), not merely somewhere
    # in the file — a per-worktree block must never be what matched.
    grep -q '^\*.test.local {' "$CADDYFILE"
    run awk '/^\*\.test\.local \{/{f=1} f' "$CADDYFILE"
    [[ "$output" == *"respond 404"* ]]
    [[ "$output" == *"No worktree"* ]]
    [[ "$output" == *"{http.request.host}"* ]]
}

@test "catch-all: the wildcard site carries tls internal for a trusted cert" {
    enable_caddy
    "$FW_BIN" create feat

    # The tls internal line must be inside the *.<domain> block itself (a
    # wildcard cert from the already-trusted internal CA), not just present
    # elsewhere in the file from a per-worktree site.
    run awk '/^\*\.test\.local \{/{f=1} f&&/tls internal/{print "yes"; exit}' "$CADDYFILE"
    [ "$output" = yes ]
}

@test "catch-all: clears a stale service worker for the dead origin" {
    enable_caddy
    "$FW_BIN" create feat

    grep -q 'serviceWorker' "$CADDYFILE"
    grep -q 'unregister' "$CADDYFILE"
    grep -q 'caches' "$CADDYFILE"
}

@test "catch-all: specific worktree blocks precede the wildcard" {
    enable_caddy
    "$FW_BIN" create feat

    local feat_ln star_ln
    feat_ln="$(grep -n '^feat.test.local {' "$CADDYFILE" | head -1 | cut -d: -f1)"
    star_ln="$(grep -n '^\*.test.local {' "$CADDYFILE" | head -1 | cut -d: -f1)"
    [ -n "$feat_ln" ] && [ -n "$star_ln" ]
    [ "$feat_ln" -lt "$star_ln" ]
}

@test "catch-all: survives a delete, present even with zero worktrees" {
    enable_caddy
    "$FW_BIN" create feat
    "$FW_BIN" delete feat

    ! grep -q '^feat.test.local {' "$CADDYFILE"
    grep -q '^\*.test.local {' "$CADDYFILE"
}

# --- caddy reload ---

@test "reload: reloads a running caddy with the config path" {
    enable_caddy
    export FW_TEST_RUNNING_PROCS=caddy
    export FW_TEST_CADDY_LOG="$BATS_TEST_TMPDIR/caddy.log"

    "$FW_BIN" create feat

    grep -q "reload --config $CADDYFILE" "$FW_TEST_CADDY_LOG"
}

@test "reload: uses caddy_reload_file when set, not the per-project caddyfile" {
    # With caddy_reload_file pointing at a shared root Caddyfile, the reload
    # re-reads the whole import chain (keeping every project's sites live)
    # while the WRITE still lands in the per-project $caddyfile — the two are
    # decoupled.
    enable_caddy
    local reload_target="$BATS_TEST_TMPDIR/root-Caddyfile"
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<EOF
caddy_reload_file=$reload_target
EOF
    export FW_TEST_RUNNING_PROCS=caddy
    export FW_TEST_CADDY_LOG="$BATS_TEST_TMPDIR/caddy.log"

    "$FW_BIN" create feat

    # Reload targets the shared root file, not the per-project write file.
    grep -q "reload --config $reload_target" "$FW_TEST_CADDY_LOG"
    ! grep -q "reload --config $CADDYFILE" "$FW_TEST_CADDY_LOG"

    # The site block is still WRITTEN to the per-project $caddyfile.
    grep -q '^feat.test.local {' "$CADDYFILE"
}

@test "reload: skipped when caddy is not running" {
    enable_caddy
    export FW_TEST_CADDY_LOG="$BATS_TEST_TMPDIR/caddy.log"

    "$FW_BIN" create feat

    [ ! -f "$FW_TEST_CADDY_LOG" ]
}

# --- golden checkout (main) site ---

@test "regen: emits a main.<domain> site for the golden checkout" {
    enable_caddy
    "$FW_BIN" regen-env main

    [ -f "$CADDYFILE" ]
    grep -q '^main.test.local {' "$CADDYFILE"
    local port
    port="$(grep '^WEB_PORT=' "$BATS_TEST_TMPDIR/myrepo/.env.worktree" | cut -d= -f2)"
    grep -q "reverse_proxy localhost:$port" "$CADDYFILE"
}

@test "regen: golden checkout site coexists with worktree sites" {
    enable_caddy
    "$FW_BIN" create feat
    "$FW_BIN" regen-env main

    grep -q '^feat.test.local {' "$CADDYFILE"
    grep -q '^main.test.local {' "$CADDYFILE"
}

@test "regen: no main site until the golden checkout has an env file" {
    enable_caddy
    "$FW_BIN" create feat

    grep -q '^feat.test.local {' "$CADDYFILE"
    ! grep -q '^main.test.local {' "$CADDYFILE"
}

# --- fw open ---

@test "open: builds an https URL for the golden checkout" {
    enable_caddy
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"
    "$FW_BIN" regen-env main

    run "$FW_BIN" open main
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://main.test.local"* ]]
    grep -q '^https://main.test.local$' "$FW_TEST_OPEN_LOG"
}

@test "open: detects the golden checkout from cwd" {
    enable_caddy
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"
    "$FW_BIN" regen-env main
    cd "$BATS_TEST_TMPDIR/myrepo"

    run "$FW_BIN" open
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://main.test.local"* ]]
}

@test "open: golden checkout errors before regen-env has given it a site" {
    enable_caddy

    run "$FW_BIN" open main
    [ "$status" -ne 0 ]
    [[ "$output" == *"regen-env"* ]]
}

@test "open: golden checkout falls back to localhost when caddy is disabled" {
    echo 'web_port_var=WEB_PORT' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"
    "$FW_BIN" regen-env main
    local port
    port="$(grep '^WEB_PORT=' "$BATS_TEST_TMPDIR/myrepo/.env.worktree" | cut -d= -f2)"

    run "$FW_BIN" open main
    [ "$status" -eq 0 ]
    [[ "$output" == *"http://localhost:$port"* ]]
}

@test "open: builds an https URL when domain is set" {
    enable_caddy
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"
    "$FW_BIN" create feat

    run "$FW_BIN" open feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://feat.test.local"* ]]
    grep -q '^https://feat.test.local$' "$FW_TEST_OPEN_LOG"
}

@test "open: builds a localhost URL when domain is unset" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
web_port_var=WEB_PORT
EOF
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"
    "$FW_BIN" create feat
    local port
    port="$(wt_web_port feat)"

    run "$FW_BIN" open feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"http://localhost:$port"* ]]
    grep -q "^http://localhost:$port\$" "$FW_TEST_OPEN_LOG"
}

@test "open: builds a localhost URL when the caddy layer is only partly configured" {
    # domain + web_port_var but no caddyfile: caddy is not actually enabled, so
    # generation never wrote an https site — open must not build a dead https URL.
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
domain=test.local
web_port_var=WEB_PORT
EOF
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"
    "$FW_BIN" create feat
    local port
    port="$(wt_web_port feat)"

    run "$FW_BIN" open feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"http://localhost:$port"* ]]
    grep -q "^http://localhost:$port\$" "$FW_TEST_OPEN_LOG"
}

@test "open: detects the worktree from the current directory" {
    enable_caddy
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"
    "$FW_BIN" create feat

    cd "$BATS_TEST_TMPDIR/myproj-worktrees/feat"
    run "$FW_BIN" open
    [ "$status" -eq 0 ]
    grep -q '^https://feat.test.local$' "$FW_TEST_OPEN_LOG"
}

@test "open: errors on an unknown worktree" {
    enable_caddy
    run "$FW_BIN" open nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"nope"* ]]
}

@test "open: errors when no domain and no web port are configured" {
    "$FW_BIN" create feat
    run "$FW_BIN" open feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"web port"* || "$output" == *"web_port_var"* ]]
}
