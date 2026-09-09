load ../test_helper

# fw clean removes worktrees whose branch upstream is [gone] (merged and
# deleted on the remote), after `git fetch --prune`. Removal routes through
# cmd_delete, so its guards apply: a dirty worktree is never removed.

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/origin"
    git clone -q "$BATS_TEST_TMPDIR/origin" "$BATS_TEST_TMPDIR/myrepo" 2>/dev/null
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

# make_gone <name> — create a worktree whose branch tracks an origin branch
# that is then deleted, so fetch --prune will mark its upstream [gone].
make_gone() {
    local name="$1"
    "$FW_BIN" create "$name"
    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/$name"
    git -C "$wt" push -q -u origin "me/$name"
    git -C "$BATS_TEST_TMPDIR/origin" branch -D "me/$name" >/dev/null 2>&1 \
        || git -C "$BATS_TEST_TMPDIR/origin" update-ref -d "refs/heads/me/$name"
}

@test "fw clean: removes a worktree whose upstream is gone" {
    make_gone feat

    run bash -c "printf 'y\n' | '$FW_BIN' clean"
    [ "$status" -eq 0 ]
    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
    # Branch is gone too (cmd_delete removes it).
    ! git -C "$BATS_TEST_TMPDIR/myrepo" show-ref -q --verify refs/heads/me/feat
}

@test "fw clean: aborts on a non-yes answer, keeping the worktree" {
    make_gone feat

    run bash -c "printf 'n\n' | '$FW_BIN' clean"
    [ "$status" -eq 0 ]
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

@test "fw clean: leaves a worktree whose branch is not merged/gone" {
    "$FW_BIN" create keep

    run bash -c "printf 'y\n' | '$FW_BIN' clean"
    [ "$status" -eq 0 ]
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/keep" ]
    [[ "$output" == *"No merged worktrees"* ]]
}

@test "fw clean: never removes a dirty gone worktree" {
    make_gone feat
    echo dirty >"$BATS_TEST_TMPDIR/myproj-worktrees/feat/dirty.txt"
    git -C "$BATS_TEST_TMPDIR/myproj-worktrees/feat" add dirty.txt

    run bash -c "printf 'y\n' | '$FW_BIN' clean"
    # The dirty worktree survives (cmd_delete refuses it).
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
    # The skip message suggests the actionable command (clean itself has no
    # --force flag).
    [[ "$output" == *"fw delete --force feat"* ]]
}

@test "fw clean: reports nothing to do when there are no worktrees" {
    run bash -c "printf 'y\n' | '$FW_BIN' clean"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No merged worktrees"* ]]
}

@test "fw clean: skips a gone worktree whose live branch differs from the recorded one" {
    make_gone feat
    # The user reused the worktree for unrelated work: its live HEAD is now a
    # different branch, even though the recorded branch me/feat is [gone].
    git -C "$BATS_TEST_TMPDIR/myproj-worktrees/feat" checkout -q -b otherwork

    run bash -c "printf 'y\n' | '$FW_BIN' clean"
    [ "$status" -eq 0 ]
    # The worktree and its live branch survive; nothing is destroyed.
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
    git -C "$BATS_TEST_TMPDIR/myrepo" show-ref -q --verify refs/heads/otherwork
    [[ "$output" == *"No merged worktrees"* ]]
}

@test "fw clean: skips a gone worktree in detached HEAD" {
    make_gone feat
    git -C "$BATS_TEST_TMPDIR/myproj-worktrees/feat" checkout -q --detach

    run bash -c "printf 'y\n' | '$FW_BIN' clean"
    [ "$status" -eq 0 ]
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
    [[ "$output" == *"No merged worktrees"* ]]
}

@test "fw clean: aborts on a failed fetch rather than judging from stale state" {
    make_gone feat
    # A broken origin URL makes fetch --prune fail; origin still lists, so this
    # is the failing-fetch path, not the no-origin early path.
    git -C "$BATS_TEST_TMPDIR/myrepo" remote set-url origin /nonexistent/repo.git

    run bash -c "printf 'y\n' | '$FW_BIN' clean"
    [ "$status" -ne 0 ]
    [[ "$output" == *"stale"* ]]
    # No candidates were judged or removed.
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

@test "fw clean --cache: removes each configured cache dir and skips worktree cleaning" {
    mkdir -p "$BATS_TEST_TMPDIR/cacheA/sub" "$BATS_TEST_TMPDIR/cacheB"
    echo x >"$BATS_TEST_TMPDIR/cacheA/sub/f"
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<EOF
cache_dirs=($BATS_TEST_TMPDIR/cacheA $BATS_TEST_TMPDIR/cacheB)
EOF
    # A gone worktree exists; --cache must NOT touch it (clear-and-exit).
    make_gone feat

    run "$FW_BIN" clean --cache
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/cacheA" ]
    [ ! -e "$BATS_TEST_TMPDIR/cacheB" ]
    # Worktree cleaning was skipped: no fetch, worktree survives.
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
    [[ "$output" != *"Fetching and pruning"* ]]
}

@test "fw clean --cache: friendly message when no cache_dirs configured" {
    run "$FW_BIN" clean --cache
    [ "$status" -eq 0 ]
    [[ "$output" == *"cache_dirs"* ]]
}

@test "fw clean --cache: tolerates a nonexistent cache dir" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<EOF
cache_dirs=($BATS_TEST_TMPDIR/does-not-exist)
EOF
    run "$FW_BIN" clean --cache
    [ "$status" -eq 0 ]
}

@test "fw clean --cache: refuses a relative-path entry, removing nothing" {
    mkdir -p "$BATS_TEST_TMPDIR/cacheA"
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<EOF
cache_dirs=(relative/cache $BATS_TEST_TMPDIR/cacheA)
EOF
    run "$FW_BIN" clean --cache
    [ "$status" -ne 0 ]
    [[ "$output" == *"relative/cache"* ]]
    # The later, valid entry was never reached.
    [ -d "$BATS_TEST_TMPDIR/cacheA" ]
}

@test "fw clean --cache: refuses \$HOME as an entry" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
cache_dirs=("$HOME")
EOF
    run "$FW_BIN" clean --cache
    [ "$status" -ne 0 ]
    [ -d "$HOME" ]
}

@test "fw clean --cache: refuses a trailing-slash \$HOME/ entry" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
cache_dirs=("$HOME/")
EOF
    run "$FW_BIN" clean --cache
    [ "$status" -ne 0 ]
    [ -d "$HOME" ]
}

@test "fw clean --cache: refuses an existing entry that cannot be canonicalized" {
    # Shim realpath to fail ONLY for the cache entry (delegating every other
    # call to the real tool so the entrypoint still starts). The guard must not
    # fall back to the literal string and remove an unresolved directory — it
    # must refuse the entry.
    mkdir -p "$BATS_TEST_TMPDIR/shim"
    # Bake in the real realpath's absolute path: `exec command -p realpath` is
    # not portable — dash's `exec` (Debian/Ubuntu /bin/sh) can't exec the
    # `command` builtin and dies 127, which would take the entrypoint's own
    # startup realpath down with it. Resolve it now, before the shim is on PATH.
    local real_realpath
    real_realpath="$(command -v realpath)"
    cat >"$BATS_TEST_TMPDIR/shim/realpath" <<EOF
#!/bin/sh
for a in "\$@"; do
    case "\$a" in *live-cache*) exit 1 ;; esac
done
exec "$real_realpath" "\$@"
EOF
    chmod +x "$BATS_TEST_TMPDIR/shim/realpath"
    mkdir -p "$BATS_TEST_TMPDIR/live-cache"
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<EOF
cache_dirs=($BATS_TEST_TMPDIR/live-cache)
EOF
    PATH="$BATS_TEST_TMPDIR/shim:$PATH" run "$FW_BIN" clean --cache
    [ "$status" -ne 0 ]
    [[ "$output" == *"live-cache"* ]]
    [ -d "$BATS_TEST_TMPDIR/live-cache" ]
}

@test "fw clean: still rejects an unknown argument" {
    run "$FW_BIN" clean --bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown argument"* ]]
}

@test "fw clean: regenerates the Caddyfile once for the batch, not per delete" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<EOF
domain=test.local
caddyfile=$BATS_TEST_TMPDIR/Caddyfile
web_port_var=WEB_PORT
hook_worktree_env() { echo "WEB_PORT=40\${FW_PORT_SLOT}"; }
EOF
    make_gone one
    make_gone two
    export FW_TEST_RUNNING_PROCS=caddy
    export FW_TEST_CADDY_LOG="$BATS_TEST_TMPDIR/caddy.log"
    : >"$FW_TEST_CADDY_LOG"

    run bash -c "printf 'y\n' | '$FW_BIN' clean"
    [ "$status" -eq 0 ]
    # One reload for the whole batch, not one per deleted worktree.
    [ "$(wc -l <"$FW_TEST_CADDY_LOG")" -eq 1 ]
}
