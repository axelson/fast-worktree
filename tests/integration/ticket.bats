load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

teardown() { "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true; }

set_ticket_url() {
    echo 'ticket_url=https://tracker.example/issue/{id}' \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
}

@test "fw ticket: opens the URL built from ticket_url and the branch id" {
    set_ticket_url
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"

    run "$FW_BIN" ticket foo/app-10873-title
    [ "$status" -eq 0 ]
    [ "$(cat "$FW_TEST_OPEN_LOG")" = "https://tracker.example/issue/APP-10873" ]
}

@test "fw ticket: resolves a worktree by name and opens its ticket" {
    set_ticket_url
    "$FW_BIN" create app-55-thing
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"

    run "$FW_BIN" ticket app-55-thing
    [ "$status" -eq 0 ]
    [ "$(cat "$FW_TEST_OPEN_LOG")" = "https://tracker.example/issue/APP-55" ]
}

@test "fw ticket: honors the default_browser config" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/mybrowser" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/browser.log"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/mybrowser"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    echo 'default_browser=mybrowser' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    set_ticket_url

    run "$FW_BIN" ticket foo/app-1-x
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/browser.log")" = "https://tracker.example/issue/APP-1" ]
}

@test "fw ticket: falls back to the PR body when the branch has no id" {
    set_ticket_url
    "$FW_BIN" create plain
    export FW_TEST_GH_PR_JSON='{"body":"Implements APP-999 for prod"}'
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"

    run "$FW_BIN" ticket plain
    [ "$status" -eq 0 ]
    [ "$(cat "$FW_TEST_OPEN_LOG")" = "https://tracker.example/issue/APP-999" ]
}

@test "fw ticket: errors when no id is in the branch or the PR body" {
    set_ticket_url
    "$FW_BIN" create plain
    # No PR (FW_TEST_GH_PR_JSON unset) => the body fallback finds nothing.

    run "$FW_BIN" ticket plain
    [ "$status" -ne 0 ]
    [[ "$output" == *"no ticket found"* ]]
}

@test "fw ticket: errors clearly when ticket_url is not configured" {
    # ticket_url defaults to empty.
    run "$FW_BIN" ticket foo/app-1-x
    [ "$status" -ne 0 ]
    [[ "$output" == *"ticket_url"* ]]
}

@test "fw ticket: bare invocation outside a worktree reports it" {
    set_ticket_url
    run "$FW_BIN" ticket
    [ "$status" -ne 0 ]
    [[ "$output" == *"not inside a worktree"* ]]
}

@test "fw menu: offers 'Open ticket' when ticket_url is set" {
    set_ticket_url
    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_CANCEL=1

    run "$FW_BIN" menu
    [ "$status" -eq 0 ]
    grep -q $'Open ticket\tticket' "$BATS_TEST_TMPDIR/offered"
}

@test "fw menu: hides 'Open ticket' when ticket_url is unset" {
    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_CANCEL=1

    run "$FW_BIN" menu
    [ "$status" -eq 0 ]
    ! grep -q "Open ticket" "$BATS_TEST_TMPDIR/offered"
}
