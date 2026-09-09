# bats file_tags=core
load ../test_helper

setup() { isolate_env; }

@test "harness: tests run under bash >= 4" {
    [ "${BASH_VERSINFO[0]}" -ge 4 ]
}

@test "harness: HOME is isolated per test" {
    [[ "$HOME" == "$BATS_TEST_TMPDIR"/* ]]
    [ -d "$XDG_CONFIG_HOME/fast-worktree/projects" ]
}

@test "harness: shims dir wins on PATH" {
    mkdir -p "$FW_ROOT/tests/shims"
    [[ ":$PATH:" == *":$FW_ROOT/tests/shims:"* ]]
}

@test "harness: make_repo creates a git repo with a main branch" {
    make_repo "$BATS_TEST_TMPDIR/repo"
    run git -C "$BATS_TEST_TMPDIR/repo" branch --show-current
    [ "$output" = "main" ]
}

@test "harness: git global config is isolated (no real user leakage)" {
    run git config --global user.email
    [ "$status" -ne 0 ]
}

@test "harness: isolate_env clears leaked git env vars" {
    # git exports these into hooks; if isolate_env let them through, the suite's
    # scratch `git init`/`commit` would operate on whatever real repo invoked us.
    export GIT_DIR=/real/repo/.git
    export GIT_INDEX_FILE=/real/repo/.git/index
    export GIT_WORK_TREE=/real/repo
    export GIT_COMMON_DIR=/real/repo/.git
    isolate_env
    [ -z "${GIT_DIR:-}" ]
    [ -z "${GIT_INDEX_FILE:-}" ]
    [ -z "${GIT_WORK_TREE:-}" ]
    [ -z "${GIT_COMMON_DIR:-}" ]
}
