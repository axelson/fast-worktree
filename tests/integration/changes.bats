load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

commit_in() {
    echo "$3" >"$1/$2"
    git -C "$1" add "$2"
    git -C "$1" -c user.email=t@t -c user.name=t commit -qm "add $2"
}

@test "fw changes: shows committed changes vs trunk" {
    "$FW_BIN" create feat
    commit_in "$BATS_TEST_TMPDIR/myproj-worktrees/feat" feature.txt "the feature"

    run "$FW_BIN" changes feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"feature.txt"* ]]
    [[ "$output" == *"the feature"* ]]
}

@test "fw changes: includes uncommitted work" {
    "$FW_BIN" create feat
    echo wip >"$BATS_TEST_TMPDIR/myproj-worktrees/feat/wip.txt"
    git -C "$BATS_TEST_TMPDIR/myproj-worktrees/feat" add wip.txt

    run "$FW_BIN" changes feat
    [[ "$output" == *"wip.txt"* ]]
}

@test "fw changes: --stat gives a summary" {
    "$FW_BIN" create feat
    commit_in "$BATS_TEST_TMPDIR/myproj-worktrees/feat" feature.txt "x"

    run "$FW_BIN" changes --stat feat
    [[ "$output" == *"1 file changed"* ]]
}

@test "fw changes: detects the worktree from cwd" {
    "$FW_BIN" create feat
    commit_in "$BATS_TEST_TMPDIR/myproj-worktrees/feat" feature.txt "x"
    cd "$BATS_TEST_TMPDIR/myproj-worktrees/feat"

    run "$FW_BIN" changes
    [[ "$output" == *"feature.txt"* ]]
}

@test "fw changes: diffs against the graphite stack parent, not trunk" {
    "$FW_BIN" create part1
    commit_in "$BATS_TEST_TMPDIR/myproj-worktrees/part1" part1.txt "one"
    "$FW_BIN" create part2 --base me/part1
    commit_in "$BATS_TEST_TMPDIR/myproj-worktrees/part2" part2.txt "two"
    sqlite3 "$BATS_TEST_TMPDIR/myrepo/.git/.graphite_metadata.db" "
        CREATE TABLE branch_metadata (
            branch_name TEXT PRIMARY KEY,
            parent_branch_name TEXT,
            children TEXT
        );
        INSERT INTO branch_metadata VALUES ('me/part1', 'main', '[\"me/part2\"]');
        INSERT INTO branch_metadata VALUES ('me/part2', 'me/part1', '[]');
    "
    echo 'stack_backend=graphite' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    run "$FW_BIN" changes part2
    [ "$status" -eq 0 ]
    [[ "$output" == *"part2.txt"* ]]
    [[ "$output" != *"part1.txt"* ]]
}
