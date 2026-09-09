load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
    export FW_TEST_PBCOPY_LOG="$BATS_TEST_TMPDIR/clip"
}

teardown() { "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true; }

set_ticket_url() {
    echo 'ticket_url=https://tracker.example/issue/{id}' \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
}

# Path of the worktree `fw create <name>` just made (avoids depending on the
# worktrees_dir default): the one entry in `git worktree list` that isn't main.
worktree_path_of() {
    git -C "$BATS_TEST_TMPDIR/myrepo" worktree list --porcelain \
        | awk '/^worktree /{print $2}' | grep -v '/myrepo$' | head -1
}

# The golden checkout is not a worktree (like `fw ticket`/`fw pr`), so the
# branch/PR/path items resolve a target: a bare branch argument falls through
# to that branch, matching how the ticket tests pass "foo/app-…".

@test "fw copy branch: copies the target branch" {
    run "$FW_BIN" copy branch me/foo
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/clip")" = "me/foo" ]
    printf '%s\n' "$output" | grep -q "✓ Copied: me/foo"
}

@test "fw copy path: copies the worktree path" {
    "$FW_BIN" create thing
    run "$FW_BIN" copy path thing
    [ "$status" -eq 0 ]
    # An absolute path to the real worktree dir (exact string can differ by the
    # macOS /var -> /private/var symlink, so assert shape, not equality).
    local clip
    clip="$(cat "$BATS_TEST_TMPDIR/clip")"
    [ -d "$clip" ]
    [ "$(basename "$clip")" = "thing" ]
}

@test "fw copy path: copies the main checkout path from the golden checkout" {
    # cwd is the golden checkout (repo_root) with no target — the path fact is
    # meaningful there, so it copies the main checkout instead of erroring.
    run "$FW_BIN" copy path
    [ "$status" -eq 0 ]
    local clip
    clip="$(cat "$BATS_TEST_TMPDIR/clip")"
    [ -d "$clip" ]
    [ "$(basename "$clip")" = "myrepo" ]
}

@test "fw copy pr-link: copies the PR URL from gh" {
    export FW_TEST_GH_PR_JSON='{"url":"https://github.com/o/r/pull/7"}'
    run "$FW_BIN" copy pr-link me/foo
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/clip")" = "https://github.com/o/r/pull/7" ]
}

@test "fw copy pr-number: copies the bare PR number from gh" {
    export FW_TEST_GH_PR_NUMBER=7
    run "$FW_BIN" copy pr-number me/foo
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/clip")" = "7" ]
}

@test "fw copy pr-link: errors cleanly when there is no PR" {
    # gh shim with no FW_TEST_GH_PR_* returns a failure for pr view.
    run "$FW_BIN" copy pr-link me/foo
    [ "$status" -ne 0 ]
    [ ! -s "$BATS_TEST_TMPDIR/clip" ]
}

@test "fw copy ticket-url: copies the URL built from ticket_url and the branch id" {
    set_ticket_url
    run "$FW_BIN" copy ticket-url foo/app-10873-title
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/clip")" = "https://tracker.example/issue/APP-10873" ]
}

@test "fw copy ticket-url: errors when ticket_url is not configured" {
    run "$FW_BIN" copy ticket-url foo/app-1-x
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "ticket_url"
}

@test "fw copy stack-branch: errors cleanly when there is no stack" {
    run "$FW_BIN" copy stack-branch
    [ "$status" -ne 0 ]
    [ ! -s "$BATS_TEST_TMPDIR/clip" ]
}

@test "fw copy: no argument opens the picker and copies the selection" {
    "$FW_BIN" create thing
    cd "$(worktree_path_of)"
    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_SELECT="Branch"
    run "$FW_BIN" copy
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/clip")" = "me/thing" ]
    # The offered list carries a hidden token field and hides unavailable items.
    grep -q $'Branch\tbranch' "$BATS_TEST_TMPDIR/offered"
    grep -q $'PR link\tpr-link' "$BATS_TEST_TMPDIR/offered"
    ! grep -q "ticket-url" "$BATS_TEST_TMPDIR/offered"
    ! grep -q "stack-branch" "$BATS_TEST_TMPDIR/offered"
}

@test "fw copy: the picker offers the ticket item once ticket_url is set" {
    set_ticket_url
    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" copy
    [ "$status" -eq 0 ]
    grep -q $'Ticket URL\tticket-url' "$BATS_TEST_TMPDIR/offered"
}

@test "fw copy: an unknown item errors" {
    run "$FW_BIN" copy bogus
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "unknown copy item"
}

@test "fw menu: offers the Copy entry dispatching to copy with a wait pause" {
    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" menu
    [ "$status" -eq 0 ]
    grep -q $'📋 Copy…\tcopy\twait' "$BATS_TEST_TMPDIR/offered"
}
