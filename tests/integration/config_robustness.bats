load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

@test "a config ending in a false conditional does not kill fw" {
    echo '[[ -d /nonexistent ]] && branch_prefix=other' \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    run "$FW_BIN" create feat
    [ "$status" -eq 0 ]
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

@test "a global config ending in a false conditional does not kill fw" {
    printf 'github_username=x\n[[ -f /nonexistent ]] && github_username=y\n' \
        >"$FW_CONFIG_DIR/config.sh"

    run "$FW_BIN" projects
    [ "$status" -eq 0 ]
    [ "$output" = "myproj" ]
}

@test "an associative-array config does not break project resolution" {
    # The repo_root peek sources the config before its arrays are declared -A;
    # under set -eu that assignment would abort the peek. Resolution must still
    # find the project from cwd.
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
claude_prompt_flags=([review]="/pr-review")
EOF

    run "$FW_BIN" create feat
    [ "$status" -eq 0 ]
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}
