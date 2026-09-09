load ../test_helper

setup() {
    isolate_env
    source "$FW_ROOT/lib/config.sh"
    source "$FW_ROOT/lib/project.sh"
}

# resolve_project [explicit-name] — echoes the resolved project name

@test "resolve_project: explicit name wins over everything" {
    make_repo "$BATS_TEST_TMPDIR/a"
    make_repo "$BATS_TEST_TMPDIR/b"
    register_project aproj "$BATS_TEST_TMPDIR/a"
    register_project bproj "$BATS_TEST_TMPDIR/b"
    export FW_PROJECT=bproj
    cd "$BATS_TEST_TMPDIR/a"

    run resolve_project aproj
    [ "$status" -eq 0 ]
    [ "$output" = "aproj" ]
}

@test "resolve_project: matches cwd inside the main repo" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    cd "$BATS_TEST_TMPDIR/myrepo"

    run resolve_project
    [ "$output" = "myproj" ]
}

@test "resolve_project: matches cwd in a subdirectory of the repo" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    mkdir -p "$BATS_TEST_TMPDIR/myrepo/deep/sub"
    cd "$BATS_TEST_TMPDIR/myrepo/deep/sub"

    run resolve_project
    [ "$output" = "myproj" ]
}

@test "resolve_project: matches cwd inside a linked worktree" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    git -C "$BATS_TEST_TMPDIR/myrepo" worktree add -q \
        "$BATS_TEST_TMPDIR/myproj-worktrees/feat" -b feat
    cd "$BATS_TEST_TMPDIR/myproj-worktrees/feat"

    run resolve_project
    [ "$output" = "myproj" ]
}

@test "resolve_project: matches repo_root through a symlink" {
    make_repo "$BATS_TEST_TMPDIR/real-repo"
    ln -s "$BATS_TEST_TMPDIR/real-repo" "$BATS_TEST_TMPDIR/link-repo"
    register_project myproj "$BATS_TEST_TMPDIR/link-repo"
    cd "$BATS_TEST_TMPDIR/real-repo"

    run resolve_project
    [ "$output" = "myproj" ]
}

@test "resolve_project: falls back to FW_PROJECT outside any repo" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    export FW_PROJECT=myproj
    cd "$BATS_TEST_TMPDIR"

    run resolve_project
    [ "$output" = "myproj" ]
}

@test "resolve_project: falls back to default_project from global config" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'default_project=myproj' >"$FW_CONFIG_DIR/config.sh"
    cd "$BATS_TEST_TMPDIR"

    run resolve_project
    [ "$output" = "myproj" ]
}

@test "resolve_project: cwd in an unregistered repo falls through to FW_PROJECT" {
    make_repo "$BATS_TEST_TMPDIR/known"
    make_repo "$BATS_TEST_TMPDIR/unknown"
    register_project knownproj "$BATS_TEST_TMPDIR/known"
    export FW_PROJECT=knownproj
    cd "$BATS_TEST_TMPDIR/unknown"

    run resolve_project
    [ "$output" = "knownproj" ]
}

@test "resolve_project: errors with fw init hint when nothing matches" {
    cd "$BATS_TEST_TMPDIR"

    run resolve_project
    [ "$status" -ne 0 ]
    [[ "$output" == *"fw init"* ]]
}

@test "list_projects: lists registered project names" {
    make_repo "$BATS_TEST_TMPDIR/a"
    make_repo "$BATS_TEST_TMPDIR/b"
    register_project alpha "$BATS_TEST_TMPDIR/a"
    register_project beta "$BATS_TEST_TMPDIR/b"

    run list_projects
    [ "$output" = $'alpha\nbeta' ]
}

@test "list_projects: empty registry produces no output" {
    run list_projects
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
