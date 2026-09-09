load ../test_helper

# ci's worklist is the worktrees visited in the last 48h (--all only drops the
# author filter, it does not enumerate every worktree), so tests seed the
# recency log directly.
seed_recent() {
    local wt_dir="$BATS_TEST_TMPDIR/myproj-worktrees"
    mkdir -p "$wt_dir"
    printf '%s\t%s\n' "$(date +%s)" "$1" >>"$wt_dir/.fw_recent"
}

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
    "$FW_BIN" create feat
    seed_recent feat
    export FW_TEST_GH_PR_NUMBER=42
    export FW_TEST_GH_PR_JSON='{"number":42,"state":"OPEN","author":{"login":"bob"}}'
}

teardown() { "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true; }

@test "fw ci --all: shows a failed check status and an author column" {
    export FW_TEST_GH_CHECKS_JSON='[
      {"name":"unit","bucket":"fail","link":"x","startedAt":"2026-08-20T10:00:00Z"},
      {"name":"build","bucket":"pass","link":"","startedAt":"2026-08-20T10:00:00Z"}
    ]'

    run "$FW_BIN" ci --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"#42"* ]]
    [[ "$output" == *"feat"* ]]
    [[ "$output" == *"failed"* ]]
    [[ "$output" == *"unit"* ]]
    [[ "$output" == *"AUTHOR"* ]]
    [[ "$output" == *"bob"* ]]
}

@test "fw ci --all: reports ok when every check passes" {
    export FW_TEST_GH_CHECKS_JSON='[{"name":"build","bucket":"pass","link":"","startedAt":"2026-08-20T10:00:00Z"}]'

    run "$FW_BIN" ci --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"feat"* ]]
    [[ "$output" == *"ok"* ]]
}

@test "fw ci: without --all filters to the configured github_username" {
    echo 'github_username=someoneelse' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GH_CHECKS_JSON='[{"name":"build","bucket":"pass","link":"","startedAt":"2026-08-20T10:00:00Z"}]'

    run "$FW_BIN" ci --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"feat"* ]]   # --all overrides the author filter

    run "$FW_BIN" ci feat
    [ "$status" -eq 0 ]
    # feat is authored by bob, not someoneelse: hidden in the default view
    [[ "$output" != *"#42"* ]]
}

@test "fw ci --all: omits merged/closed PRs" {
    export FW_TEST_GH_PR_JSON='{"number":42,"state":"MERGED","author":{"login":"bob"}}'
    export FW_TEST_GH_CHECKS_JSON='[{"name":"build","bucket":"pass","link":"","startedAt":"2026-08-20T10:00:00Z"}]'

    run "$FW_BIN" ci --all
    [ "$status" -eq 0 ]
    [[ "$output" != *"#42"* ]]
}

@test "fw ci <target>: errors when the branch has no PR" {
    unset FW_TEST_GH_PR_JSON   # shim then reports no PR for the branch

    run "$FW_BIN" ci feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"no PR found"* ]]
}

@test "fw ci --all: shows a sensible status when the PR has no checks" {
    export FW_TEST_GH_CHECKS_EXIT=1   # gh: "no checks reported"

    run "$FW_BIN" ci --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"feat"* ]]
    [[ "$output" == *"no checks"* ]]
}
