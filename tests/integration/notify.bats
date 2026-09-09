load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
    NOTIFY_LOG="$BATS_TEST_TMPDIR/myproj-worktrees/.fw_notify_log"
    export FW_TEST_SAY_LOG="$BATS_TEST_TMPDIR/say.log"
    export FW_TEST_OSASCRIPT_LOG="$BATS_TEST_TMPDIR/osascript.log"
}

teardown() { "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true; }

@test "fw notify: appends a TSV line and voices + posts a desktop notification" {
    run "$FW_BIN" notify ci "build is green"
    [ "$status" -eq 0 ]

    # log line: ts \t category \t branch \t message
    line="$(tail -1 "$NOTIFY_LOG")"
    cat="$(printf '%s' "$line" | cut -f2)"
    msg="$(printf '%s' "$line" | cut -f4)"
    [ "$cat" = "ci" ]
    [ "$msg" = "build is green" ]

    # Posted through the macOS desktop-notification seam (shimmed). `say` is now
    # fire-and-forget (finding 8), so it is deliberately not asserted here.
    grep -q "build is green" "$FW_TEST_OSASCRIPT_LOG"
}

# --- finding 7: multi-word messages must survive dispatch + cmd_notify ---

@test "fw notify: keeps a multi-word message intact" {
    run "$FW_BIN" notify ci build failed
    [ "$status" -eq 0 ]
    msg="$(tail -1 "$NOTIFY_LOG" | cut -f4)"
    [ "$msg" = "build failed" ]
}

# --- finding 6: message goes to osascript as argv data, never as code ---

@test "fw notify: passes the message to osascript as data, not code" {
    run "$FW_BIN" notify ci 'pwn" & (do shell script "boom") & "'
    [ "$status" -eq 0 ]
    # The safe argv template is used and the message is never spliced into the
    # AppleScript source that osascript compiles.
    grep -q 'item 1 of argv' "$FW_TEST_OSASCRIPT_LOG"
    ! grep -q 'display notification "pwn' "$FW_TEST_OSASCRIPT_LOG"
}

# --- finding 9: the log stores an epoch-seconds timestamp ---

@test "fw notify: records an epoch-seconds timestamp" {
    "$FW_BIN" notify ci "hi there"
    ts="$(tail -1 "$NOTIFY_LOG" | cut -f1)"
    [[ "$ts" =~ ^[0-9]+$ ]]
}

# --- finding 13: current branch is recorded (shared helper) ---

@test "fw notify: records the current branch" {
    git -C "$BATS_TEST_TMPDIR/myrepo" checkout -q -b feature/x
    "$FW_BIN" notify ci "on a branch"
    br="$(tail -1 "$NOTIFY_LOG" | cut -f3)"
    [ "$br" = "feature/x" ]
}

@test "fw notify: rejects an unknown category" {
    run "$FW_BIN" notify bogus "hi"
    [ "$status" -ne 0 ]
    [[ "$output" == *"category"* ]]
    [ ! -f "$NOTIFY_LOG" ]
}

@test "fw notify: requires a category and a message" {
    run "$FW_BIN" notify ci
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage"* ]]
}

@test "fw notify: rejects a tab in the message (protects the TSV log)" {
    run "$FW_BIN" notify ci "$(printf 'a\tb')"
    [ "$status" -ne 0 ]
}

@test "fw notify: honors a project-configured notify_categories list" {
    echo 'notify_categories=(release)' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    run "$FW_BIN" notify release "shipped"
    [ "$status" -eq 0 ]
    run "$FW_BIN" notify ci "green"
    [ "$status" -ne 0 ]
}

@test "fw logs: shows recent notifications, most recent first" {
    "$FW_BIN" notify ci "first message"
    "$FW_BIN" notify fix "second message"

    run "$FW_BIN" logs
    [ "$status" -eq 0 ]
    [[ "$output" == *"first message"* ]]
    [[ "$output" == *"second message"* ]]
    # most recent first
    [[ "$output" == *"second message"*"first message"* ]]
}

@test "fw logs: filters by category" {
    "$FW_BIN" notify ci "ci one"
    "$FW_BIN" notify fix "fix one"

    run "$FW_BIN" logs ci
    [ "$status" -eq 0 ]
    [[ "$output" == *"ci one"* ]]
    [[ "$output" != *"fix one"* ]]
}

@test "fw logs: reports an empty log cleanly" {
    run "$FW_BIN" logs
    [ "$status" -eq 0 ]
    [[ "$output" == *"No log entries"* ]]
}

@test "fw log: is an alias for logs" {
    "$FW_BIN" notify ci "aliased entry"
    run "$FW_BIN" log
    [ "$status" -eq 0 ]
    [[ "$output" == *"aliased entry"* ]]
}
