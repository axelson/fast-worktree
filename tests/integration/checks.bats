load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
    "$FW_BIN" create feat
    export FW_TEST_GH_PR_NUMBER=42
}

teardown() { "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true; }

checks_json() {
    cat <<'EOF'
[
  {"name":"build","bucket":"pass","link":"","startedAt":"2026-08-20T10:00:00Z"},
  {"name":"unit","bucket":"fail","link":"https://github.com/owner/repo/actions/runs/999/job/1","startedAt":"2026-08-20T10:00:00Z"},
  {"name":"lint","bucket":"pending","link":"","startedAt":"2026-08-20T10:00:00Z"}
]
EOF
}

@test "fw checks: groups results and lists failures" {
    export FW_TEST_GH_CHECKS_JSON="$(checks_json)"

    run "$FW_BIN" checks feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"Failed:"* ]]
    [[ "$output" == *"unit"* ]]
    [[ "$output" == *"runs/999"* ]]
    [[ "$output" == *"pass: 1"* ]]
    [[ "$output" == *"pending: 1"* ]]
}

@test "fw checks: keeps only the latest run of a duplicated check name" {
    export FW_TEST_GH_CHECKS_JSON='[
      {"name":"unit","bucket":"fail","link":"x","startedAt":"2026-08-20T10:00:00Z"},
      {"name":"unit","bucket":"pass","link":"","startedAt":"2026-08-20T11:00:00Z"}
    ]'

    run "$FW_BIN" checks feat
    [ "$status" -eq 0 ]
    [[ "$output" != *"Failed:"* ]]
    [[ "$output" == *"pass: 1"* ]]
}

@test "fw checks: honors the ignored_checks config" {
    echo 'ignored_checks=("triage")' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GH_CHECKS_JSON='[
      {"name":"triage","bucket":"fail","link":"x","startedAt":"2026-08-20T10:00:00Z"},
      {"name":"build","bucket":"pass","link":"","startedAt":"2026-08-20T10:00:00Z"}
    ]'

    run "$FW_BIN" checks feat
    [ "$status" -eq 0 ]
    [[ "$output" != *"Failed:"* ]]
    [[ "$output" == *"pass: 1"* ]]
}

@test "fw retry: reruns failed workflow runs" {
    export FW_TEST_GH_CHECKS_JSON="$(checks_json)"
    export FW_TEST_GH_LOG="$BATS_TEST_TMPDIR/gh.log"

    run "$FW_BIN" retry feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"Retrying"* ]]
    grep -q "run rerun 999" "$FW_TEST_GH_LOG"
    grep -q -- "--failed" "$FW_TEST_GH_LOG"
}

@test "fw retry: reports when there is nothing to retry" {
    export FW_TEST_GH_CHECKS_JSON='[{"name":"build","bucket":"pass","link":"","startedAt":"2026-08-20T10:00:00Z"}]'

    run "$FW_BIN" retry feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"No failed checks"* ]]
}

@test "fw checks-wait: exits 0 when all checks pass" {
    echo 'checks_poll_interval=0' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GH_CHECKS_JSON='[{"name":"build","bucket":"pass","link":"","startedAt":"2026-08-20T10:00:00Z"}]'

    run "$FW_BIN" checks-wait feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"All checks passed"* ]]
}

@test "fw checks-wait: exits 1 when a check has failed and none are pending" {
    echo 'checks_poll_interval=0' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GH_CHECKS_JSON='[
      {"name":"unit","bucket":"fail","link":"x","startedAt":"2026-08-20T10:00:00Z"},
      {"name":"build","bucket":"pass","link":"","startedAt":"2026-08-20T10:00:00Z"}
    ]'

    run "$FW_BIN" checks-wait feat
    [ "$status" -eq 1 ]
    [[ "$output" == *"failed"* ]]
}

@test "fw checks: reports when the PR has no checks (gh exits 1)" {
    export FW_TEST_GH_CHECKS_EXIT=1

    run "$FW_BIN" checks feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"No checks reported"* ]]
}

@test "fw retry: reports nothing to retry when the PR has no checks" {
    export FW_TEST_GH_CHECKS_EXIT=1

    run "$FW_BIN" retry feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"No failed checks"* ]]
}

@test "fw checks-wait: keeps polling when no checks are reported yet" {
    echo 'checks_poll_interval=0' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GH_CHECKS_COUNTER="$BATS_TEST_TMPDIR/checks.count"
    export FW_TEST_GH_CHECKS_EXIT1=1   # first poll: no checks yet
    export FW_TEST_GH_CHECKS_JSON2='[{"name":"build","bucket":"pass","link":"","startedAt":"2026-08-20T10:00:00Z"}]'

    run "$FW_BIN" checks-wait feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"All checks passed"* ]]
}

@test "fw checks-wait: prints elapsed time each poll" {
    echo 'checks_poll_interval=0' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GH_CHECKS_JSON='[{"name":"build","bucket":"pass","link":"","startedAt":"2026-08-20T10:00:00Z"}]'

    run "$FW_BIN" checks-wait feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"Elapsed"* ]]
}

@test "fw checks-wait: announces success through the notify layer" {
    echo 'checks_poll_interval=0' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GH_CHECKS_JSON='[{"name":"build","bucket":"pass","link":"","startedAt":"2026-08-20T10:00:00Z"}]'
    export FW_TEST_SAY_LOG="$BATS_TEST_TMPDIR/say.log"

    run "$FW_BIN" checks-wait feat
    [ "$status" -eq 0 ]

    notify_log="$BATS_TEST_TMPDIR/myproj-worktrees/.fw_notify_log"
    grep -q "All checks passed" "$notify_log"
    grep -q "All checks passed" "$FW_TEST_SAY_LOG"
    # logged under the ci category
    [ "$(tail -1 "$notify_log" | cut -f2)" = "ci" ]
}

@test "fw checks-wait: announces new failures and the final failure count" {
    echo 'checks_poll_interval=0' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GH_CHECKS_JSON='[
      {"name":"unit","bucket":"fail","link":"x","startedAt":"2026-08-20T10:00:00Z"},
      {"name":"build","bucket":"pass","link":"","startedAt":"2026-08-20T10:00:00Z"}
    ]'

    run "$FW_BIN" checks-wait feat
    [ "$status" -eq 1 ]

    notify_log="$BATS_TEST_TMPDIR/myproj-worktrees/.fw_notify_log"
    grep -q "unit failed" "$notify_log"
    grep -q "check(s) failed" "$notify_log"
}

@test "fw checks --open: a single failed check opens directly without a picker" {
    export FW_TEST_GH_CHECKS_JSON="$(checks_json)"
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"
    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"

    run "$FW_BIN" checks --open feat
    [ "$status" -eq 0 ]
    grep -q 'runs/999' "$FW_TEST_OPEN_LOG"
    [ ! -f "$FW_TEST_FZF_LOG" ]
}

@test "fw checks --open: multiple failed checks go through the fzf picker" {
    export FW_TEST_GH_CHECKS_JSON='[
      {"name":"unit","bucket":"fail","link":"https://github.com/owner/repo/actions/runs/999/job/1","startedAt":"2026-08-20T10:00:00Z"},
      {"name":"e2e","bucket":"fail","link":"https://github.com/owner/repo/actions/runs/888/job/2","startedAt":"2026-08-20T10:00:00Z"}
    ]'
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"
    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_SELECT="e2e"

    run "$FW_BIN" checks --open feat
    [ "$status" -eq 0 ]
    grep -q "unit" "$BATS_TEST_TMPDIR/offered"
    grep -q "e2e" "$BATS_TEST_TMPDIR/offered"
    grep -q 'runs/888' "$FW_TEST_OPEN_LOG"
    ! grep -q 'runs/999' "$FW_TEST_OPEN_LOG"
}

@test "fw checks --open: reports when there are no failed checks to open" {
    export FW_TEST_GH_CHECKS_JSON='[{"name":"build","bucket":"pass","link":"","startedAt":"2026-08-20T10:00:00Z"}]'

    run "$FW_BIN" checks --open feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"No failed checks to open"* ]]
}

@test "fw checks: bare 'open' arg suggests --open" {
    run "$FW_BIN" checks open
    [ "$status" -ne 0 ]
    [[ "$output" == *"--open"* ]]
}

@test "fw checks --open: a failure whose only link is null is not openable" {
    export FW_TEST_GH_CHECKS_JSON='[
      {"name":"unit","bucket":"fail","link":null,"startedAt":"2026-08-20T10:00:00Z"}
    ]'
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"

    run "$FW_BIN" checks --open feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"No failed checks to open"* ]]
    [ ! -f "$FW_TEST_OPEN_LOG" ]
}

@test "fw checks --open: a null-link failure never becomes the literal 'null'" {
    export FW_TEST_GH_CHECKS_JSON='[
      {"name":"unit","bucket":"fail","link":null,"startedAt":"2026-08-20T10:00:00Z"},
      {"name":"e2e","bucket":"fail","link":"https://github.com/owner/repo/actions/runs/888/job/2","startedAt":"2026-08-20T10:00:00Z"}
    ]'
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"

    run "$FW_BIN" checks --open feat
    [ "$status" -eq 0 ]
    # Only e2e has a link, so it opens directly; the null one is gone.
    grep -q 'runs/888' "$FW_TEST_OPEN_LOG"
    ! grep -q 'null' "$FW_TEST_OPEN_LOG"
}

@test "fw checks --open: preselects every failure with start:select-all" {
    export FW_TEST_GH_CHECKS_JSON='[
      {"name":"unit","bucket":"fail","link":"https://github.com/owner/repo/actions/runs/999/job/1","startedAt":"2026-08-20T10:00:00Z"},
      {"name":"e2e","bucket":"fail","link":"https://github.com/owner/repo/actions/runs/888/job/2","startedAt":"2026-08-20T10:00:00Z"}
    ]'
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"
    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_SELECT="e2e"

    run "$FW_BIN" checks --open feat
    [ "$status" -eq 0 ]
    grep -q "select-all" "$BATS_TEST_TMPDIR/fzf.log"
}

@test "fw checks --open: cancelling the picker opens nothing" {
    export FW_TEST_GH_CHECKS_JSON='[
      {"name":"unit","bucket":"fail","link":"https://github.com/owner/repo/actions/runs/999/job/1","startedAt":"2026-08-20T10:00:00Z"},
      {"name":"e2e","bucket":"fail","link":"https://github.com/owner/repo/actions/runs/888/job/2","startedAt":"2026-08-20T10:00:00Z"}
    ]'
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"
    export FW_TEST_FZF_CANCEL=1

    run "$FW_BIN" checks --open feat
    [ "$status" -eq 0 ]
    [ ! -f "$FW_TEST_OPEN_LOG" ]
}
