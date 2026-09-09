load ../test_helper

setup() { isolate_env; }

@test "fw with no args prints usage and fails" {
    run "$FW_BIN"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "fw help prints usage and succeeds" {
    run "$FW_BIN" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "fw help: the handoff line shows that save takes a file" {
    run "$FW_BIN" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"handoff save <file>"* ]]
}

@test "fw init + fw projects round-trip through the binary" {
    make_repo "$BATS_TEST_TMPDIR/myapp"
    cd "$BATS_TEST_TMPDIR/myapp"

    run "$FW_BIN" init
    [ "$status" -eq 0 ]

    run "$FW_BIN" projects
    [ "$status" -eq 0 ]
    [ "$output" = "myapp" ]
}

@test "unknown command fails with a clear error" {
    make_repo "$BATS_TEST_TMPDIR/myapp"
    register_project myapp "$BATS_TEST_TMPDIR/myapp"
    cd "$BATS_TEST_TMPDIR/myapp"

    run "$FW_BIN" bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown command"*"bogus"* ]]
}

@test "custom command from the user-level commands dir runs with args" {
    make_repo "$BATS_TEST_TMPDIR/myapp"
    register_project myapp "$BATS_TEST_TMPDIR/myapp"
    mkdir -p "$FW_CONFIG_DIR/commands"
    cat >"$FW_CONFIG_DIR/commands/hello" <<'EOF'
#!/bin/sh
echo "hello $1"
EOF
    chmod +x "$FW_CONFIG_DIR/commands/hello"
    cd "$BATS_TEST_TMPDIR/myapp"

    run "$FW_BIN" hello world
    [ "$status" -eq 0 ]
    [ "$output" = "hello world" ]
}

@test "project-level custom command wins over user-level" {
    make_repo "$BATS_TEST_TMPDIR/myapp"
    register_project myapp "$BATS_TEST_TMPDIR/myapp"
    mkdir -p "$FW_CONFIG_DIR/commands" "$FW_CONFIG_DIR/projects/myapp/commands"
    printf '#!/bin/sh\necho user-level\n' >"$FW_CONFIG_DIR/commands/which"
    printf '#!/bin/sh\necho project-level\n' >"$FW_CONFIG_DIR/projects/myapp/commands/which"
    chmod +x "$FW_CONFIG_DIR/commands/which" "$FW_CONFIG_DIR/projects/myapp/commands/which"
    cd "$BATS_TEST_TMPDIR/myapp"

    run "$FW_BIN" which
    [ "$output" = "project-level" ]
}

@test "custom command receives FW_PROJECT and FW_REPO_ROOT" {
    make_repo "$BATS_TEST_TMPDIR/myapp"
    register_project myapp "$BATS_TEST_TMPDIR/myapp"
    mkdir -p "$FW_CONFIG_DIR/commands"
    printf '#!/bin/sh\necho "$FW_PROJECT:$FW_REPO_ROOT"\n' >"$FW_CONFIG_DIR/commands/env-check"
    chmod +x "$FW_CONFIG_DIR/commands/env-check"
    cd "$BATS_TEST_TMPDIR/myapp"

    run "$FW_BIN" env-check
    [ "$output" = "myapp:$BATS_TEST_TMPDIR/myapp" ]
}

@test "custom command receives FW_BIN pointing at the running entrypoint" {
    make_repo "$BATS_TEST_TMPDIR/myapp"
    register_project myapp "$BATS_TEST_TMPDIR/myapp"
    mkdir -p "$FW_CONFIG_DIR/commands"
    printf '#!/bin/sh\necho "$FW_BIN"\n' >"$FW_CONFIG_DIR/commands/bin-check"
    chmod +x "$FW_CONFIG_DIR/commands/bin-check"
    cd "$BATS_TEST_TMPDIR/myapp"

    run "$FW_BIN" bin-check
    [ "$status" -eq 0 ]
    # FW_BIN must be a runnable path to the tool (re-invocable by exec'd scripts).
    [ -x "$output" ]
    [ "$(cd "$(dirname "$output")" && pwd)/$(basename "$output")" = "$(cd "$(dirname "$FW_BIN")" && pwd)/$(basename "$FW_BIN")" ]
}

@test "custom command receives FW_BROWSER from the default_browser config" {
    make_repo "$BATS_TEST_TMPDIR/myapp"
    register_project myapp "$BATS_TEST_TMPDIR/myapp"
    echo 'default_browser="Google Chrome"' >>"$FW_CONFIG_DIR/projects/myapp/config.sh"
    mkdir -p "$FW_CONFIG_DIR/commands"
    printf '#!/bin/sh\necho "$FW_BROWSER"\n' >"$FW_CONFIG_DIR/commands/browser-check"
    chmod +x "$FW_CONFIG_DIR/commands/browser-check"
    cd "$BATS_TEST_TMPDIR/myapp"

    run "$FW_BIN" browser-check
    [ "$status" -eq 0 ]
    [ "$output" = "Google Chrome" ]
}

@test "-p selects the project from outside any repo" {
    make_repo "$BATS_TEST_TMPDIR/myapp"
    register_project myapp "$BATS_TEST_TMPDIR/myapp"
    mkdir -p "$FW_CONFIG_DIR/projects/myapp/commands"
    printf '#!/bin/sh\necho "in $FW_PROJECT"\n' >"$FW_CONFIG_DIR/projects/myapp/commands/where"
    chmod +x "$FW_CONFIG_DIR/projects/myapp/commands/where"
    cd "$BATS_TEST_TMPDIR"

    run "$FW_BIN" -p myapp where
    [ "$output" = "in myapp" ]
}

@test "commands needing a project fail cleanly when none resolves" {
    cd "$BATS_TEST_TMPDIR"

    run "$FW_BIN" bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"fw init"* ]]
}
