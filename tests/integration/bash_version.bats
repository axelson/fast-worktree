load ../test_helper

# The re-exec trampoline: started under bash < 4, the entrypoint probes PATH
# for a modern bash and execs itself under it instead of just erroring.
# These tests drive the script under /bin/bash directly (3.2 on macOS) to
# reproduce a PATH where an old bash shadows a new one; on systems whose
# /bin/bash is already >= 4 there is no old interpreter to test with.

setup() {
    isolate_env
    [[ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" -lt 4 ]] ||
        skip "needs an old /bin/bash to exercise the trampoline"
}

@test "started under old bash, re-execs itself with a modern bash from PATH" {
    run /bin/bash "$FW_BIN" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "trampoline probes PATH in order, skipping old-bash candidates" {
    mkdir -p "$BATS_TEST_TMPDIR/dud"
    cat >"$BATS_TEST_TMPDIR/dud/bash" <<EOF
#!/bin/sh
echo probed >>"$BATS_TEST_TMPDIR/dud.log"
echo 3
EOF
    chmod +x "$BATS_TEST_TMPDIR/dud/bash"
    PATH="$BATS_TEST_TMPDIR/dud:$PATH" run /bin/bash "$FW_BIN" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    [ -f "$BATS_TEST_TMPDIR/dud.log" ]   # the dud was probed, then skipped
}

@test "no modern bash on PATH: clean error, no exec loop" {
    PATH="/usr/bin:/bin" run /bin/bash "$FW_BIN" help
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires bash >= 4"* ]]
}

@test "re-exec guard: FW_BASH_REEXEC set means no second re-exec attempt" {
    FW_BASH_REEXEC=1 run /bin/bash "$FW_BIN" help
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires bash >= 4"* ]]
}
