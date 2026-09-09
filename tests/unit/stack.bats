load ../test_helper

setup() {
    isolate_env
    export SCRIPT_DIR="$FW_ROOT"
    source "$FW_ROOT/lib/config.sh"
    source "$FW_ROOT/lib/project.sh"
    source "$FW_ROOT/lib/worktree.sh"
    source "$FW_ROOT/lib/stack.sh"
    source "$FW_ROOT/lib/stack/none.sh"
    source "$FW_ROOT/lib/stack/graphite.sh"
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    load_config myproj
}

# make_graphite_db <repo> — fixture metadata: main → me/b1 → me/b2
make_graphite_db() {
    sqlite3 "$1/.git/.graphite_metadata.db" "
        CREATE TABLE branch_metadata (
            branch_name TEXT PRIMARY KEY,
            parent_branch_name TEXT,
            children TEXT
        );
        INSERT INTO branch_metadata VALUES ('me/b1', 'main', '[\"me/b2\"]');
        INSERT INTO branch_metadata VALUES ('me/b2', 'me/b1', '[]');
    "
}

@test "resolve_stack_backend: auto → none without graphite metadata" {
    resolve_stack_backend
    [ "$STACK_BACKEND" = "none" ]
}

@test "resolve_stack_backend: auto → graphite when metadata db exists" {
    touch "$repo_root/.git/.graphite_metadata.db"
    resolve_stack_backend
    [ "$STACK_BACKEND" = "graphite" ]
}

@test "resolve_stack_backend: explicit none wins over metadata presence" {
    touch "$repo_root/.git/.graphite_metadata.db"
    stack_backend=none
    resolve_stack_backend
    [ "$STACK_BACKEND" = "none" ]
}

@test "resolve_stack_backend: auto falls back to none with a warning when gt is absent" {
    touch "$repo_root/.git/.graphite_metadata.db"

    local out
    out="$(PATH="/usr/bin:/bin" resolve_stack_backend 2>&1)"
    PATH="/usr/bin:/bin" resolve_stack_backend 2>/dev/null
    [ "$STACK_BACKEND" = "none" ]
    [[ "$out" == *"gt"* ]]
}

@test "resolve_stack_backend: explicit graphite errors when gt is absent" {
    stack_backend=graphite

    run bash -c "PATH=/usr/bin:/bin; $(declare -f resolve_stack_backend); stack_backend=graphite; repo_root='$repo_root'; resolve_stack_backend"
    [ "$status" -ne 0 ]
    [[ "$output" == *"gt"*"not installed"* ]]
}

@test "graphite: delete of a missing branch returns nonzero (parity with none)" {
    stack_backend=graphite
    resolve_stack_backend

    run stack_delete_branch me/never-existed
    [ "$status" -ne 0 ]
}

@test "graphite: a failing gt delete is surfaced, branch still removed" {
    stack_backend=graphite
    resolve_stack_backend
    git -C "$repo_root" branch me/feat
    # Shim gt succeeds but does nothing, simulating gt deleting metadata only;
    # force a *failure* instead via a failing gt on PATH for this call.
    mkdir -p "$BATS_TEST_TMPDIR/failbin"
    printf '#!/bin/sh\necho "gt: some gt error" >&2\nexit 1\n' >"$BATS_TEST_TMPDIR/failbin/gt"
    chmod +x "$BATS_TEST_TMPDIR/failbin/gt"

    run bash -c "
        set -uo pipefail
        source '$FW_ROOT/lib/config.sh'; source '$FW_ROOT/lib/project.sh'
        source '$FW_ROOT/lib/worktree.sh'; source '$FW_ROOT/lib/stack.sh'
        source '$FW_ROOT/lib/stack/none.sh'; source '$FW_ROOT/lib/stack/graphite.sh'
        load_config myproj
        stack_backend=graphite; resolve_stack_backend
        PATH='$BATS_TEST_TMPDIR/failbin':\$PATH
        stack_delete_branch me/feat
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"gt delete failed"* ]]
    [[ "$output" == *"some gt error"* ]]

    run git -C "$repo_root" branch --list me/feat
    [ -z "$output" ]
}

@test "resolve_stack_backend: github errors as not implemented" {
    stack_backend=github
    run resolve_stack_backend
    [ "$status" -ne 0 ]
    [[ "$output" == *"not implemented"* ]]
}

@test "none: stack_branches marks the current branch, empty on trunk" {
    resolve_stack_backend
    git -C "$repo_root" checkout -q -b me/feat
    cd "$repo_root"

    run stack_branches
    [ "$output" = "*me/feat" ]

    git -C "$repo_root" checkout -q main
    run stack_branches
    [ -z "$output" ]
}

@test "none: stack_parent is trunk" {
    resolve_stack_backend
    run stack_parent me/feat
    [ "$output" = "main" ]
}

@test "none: stack_track is a successful no-op" {
    resolve_stack_backend
    stack_track me/feat main
}

@test "none: stack_delete_branch deletes the branch" {
    resolve_stack_backend
    git -C "$repo_root" branch me/feat

    stack_delete_branch me/feat

    run git -C "$repo_root" branch --list me/feat
    [ -z "$output" ]
}

@test "none: stack_restack errors" {
    resolve_stack_backend
    run stack_restack
    [ "$status" -ne 0 ]
}

@test "graphite: stack_branches walks the sqlite metadata from a worktree" {
    make_graphite_db "$repo_root"
    stack_backend=graphite
    resolve_stack_backend
    git -C "$repo_root" branch me/b1
    git -C "$repo_root" branch me/b2
    git -C "$repo_root" worktree add -q "$BATS_TEST_TMPDIR/wt-b1" me/b1
    cd "$BATS_TEST_TMPDIR/wt-b1"

    run stack_branches
    [ "$output" = $'*me/b1\nme/b2' ]
}

@test "graphite: stack_branches survives a branch name containing a quote" {
    sqlite3 "$repo_root/.git/.graphite_metadata.db" "
        CREATE TABLE branch_metadata (
            branch_name TEXT PRIMARY KEY,
            parent_branch_name TEXT,
            children TEXT
        );
        INSERT INTO branch_metadata VALUES ('me/don''t-merge', 'main', '[]');
    "
    stack_backend=graphite
    resolve_stack_backend
    git -C "$repo_root" branch "me/don't-merge"
    git -C "$repo_root" worktree add -q "$BATS_TEST_TMPDIR/wt-q" "me/don't-merge"
    cd "$BATS_TEST_TMPDIR/wt-q"

    run stack_branches
    [ "$status" -eq 0 ]
    [ "$output" = "*me/don't-merge" ]
}

@test "trunk_branch: honors a memoized TRUNK_BRANCH without forking git" {
    cd "$BATS_TEST_TMPDIR"
    TRUNK_BRANCH=custom-trunk

    run trunk_branch
    [ "$output" = "custom-trunk" ]
}

@test "graphite: stack_parent reads the sqlite metadata" {
    make_graphite_db "$repo_root"
    stack_backend=graphite
    resolve_stack_backend

    run stack_parent me/b2
    [ "$output" = "me/b1" ]
}

@test "graphite: stack_parent falls back to trunk for unknown branches" {
    make_graphite_db "$repo_root"
    stack_backend=graphite
    resolve_stack_backend

    run stack_parent me/unknown
    [ "$output" = "main" ]
}

# make_origin — fixture remote with a feat branch, wired into $repo_root
make_origin() {
    make_repo "$BATS_TEST_TMPDIR/origin"
    git -C "$BATS_TEST_TMPDIR/origin" checkout -q -b feat
    git -C "$BATS_TEST_TMPDIR/origin" -c user.email=t@t -c user.name=t \
        commit -q --allow-empty -m "feat work"
    git -C "$BATS_TEST_TMPDIR/origin" checkout -q main
    git -C "$repo_root" remote add origin "$BATS_TEST_TMPDIR/origin"
}

@test "none: stack_adopt creates a local branch at the remote tip" {
    resolve_stack_backend
    make_origin

    stack_adopt feat

    run git -C "$repo_root" rev-parse feat
    [ "$output" = "$(git -C "$BATS_TEST_TMPDIR/origin" rev-parse feat)" ]
}

@test "none: stack_adopt updates an existing branch after a remote rewrite" {
    resolve_stack_backend
    make_origin
    stack_adopt feat
    git -C "$BATS_TEST_TMPDIR/origin" checkout -q feat
    git -C "$BATS_TEST_TMPDIR/origin" -c user.email=t@t -c user.name=t \
        commit -q --amend --allow-empty -m "feat rewritten"
    git -C "$BATS_TEST_TMPDIR/origin" checkout -q main

    stack_adopt feat

    run git -C "$repo_root" rev-parse feat
    [ "$output" = "$(git -C "$BATS_TEST_TMPDIR/origin" rev-parse feat)" ]
}

@test "none: stack_adopt errors clearly when the branch is checked out" {
    resolve_stack_backend
    make_origin
    stack_adopt feat
    git -C "$repo_root" worktree add -q "$BATS_TEST_TMPDIR/wt-feat" feat

    run stack_adopt feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"checked out"* ]]
}

@test "none: stack_adopt adopts a local-only branch when the remote lacks it" {
    resolve_stack_backend
    make_origin
    git -C "$repo_root" fetch -q origin
    git -C "$repo_root" branch local-only main
    local tip
    tip="$(git -C "$repo_root" rev-parse local-only)"

    run stack_adopt local-only
    [ "$status" -eq 0 ]
    [ "$(git -C "$repo_root" rev-parse local-only)" = "$tip" ]
    # A branch that simply isn't on the remote is the normal unpushed case — no warning.
    [[ "$output" != *"Warning"* ]]
}

@test "none: stack_adopt warns but adopts the local branch when origin is unreachable" {
    resolve_stack_backend
    make_origin
    git -C "$repo_root" fetch -q origin
    git -C "$repo_root" branch local-copy main
    # Break the remote so it can't be reached at all.
    git -C "$repo_root" remote set-url origin "$BATS_TEST_TMPDIR/gone"

    run stack_adopt local-copy
    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning"* ]]
    [[ "$output" == *"local-copy"* ]]
}

@test "none: stack_adopt errors when the branch exists neither on the remote nor locally" {
    resolve_stack_backend
    make_origin

    run stack_adopt ghost
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found on origin or locally"* ]]
}

@test "none: stack_sync tolerates a repo with no origin" {
    resolve_stack_backend

    run stack_sync
    [ "$status" -eq 0 ]
}

@test "graphite: stack_adopt and stack_sync go through gt" {
    stack_backend=graphite
    resolve_stack_backend
    export FW_TEST_GT_LOG="$BATS_TEST_TMPDIR/gt.log"

    stack_adopt some-branch
    stack_sync

    grep -q "get some-branch" "$FW_TEST_GT_LOG"
    grep -q "sync --no-interactive" "$FW_TEST_GT_LOG"
}

@test "graphite: stack_track invokes gt with the parent" {
    stack_backend=graphite
    resolve_stack_backend
    export FW_TEST_GT_LOG="$BATS_TEST_TMPDIR/gt.log"

    stack_track me/feat main

    grep -q "track --parent main" "$FW_TEST_GT_LOG"
}

@test "graphite: stack_delete_branch falls back to git when gt is a no-op" {
    stack_backend=graphite
    resolve_stack_backend
    git -C "$repo_root" branch me/feat

    stack_delete_branch me/feat

    run git -C "$repo_root" branch --list me/feat
    [ -z "$output" ]
}
