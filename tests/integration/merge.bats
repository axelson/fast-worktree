load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
    REPO="$BATS_TEST_TMPDIR/myrepo"
    WT="$BATS_TEST_TMPDIR/myproj-worktrees/feat"
}

teardown() {
    "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true
}

# commit_in <dir> <file> <content> <msg> — commit a tracked file in <dir>
commit_in() {
    echo "$3" >"$1/$2"
    git -C "$1" add "$2"
    git -C "$1" -c user.email=t@t -c user.name=t commit -q -m "$4"
}

@test "fw merge: fast-forwards the branch into main and deletes the worktree" {
    "$FW_BIN" create --no-switch feat
    commit_in "$WT" f.txt hello "work"

    run "$FW_BIN" merge feat
    [ "$status" -eq 0 ]

    run git -C "$REPO" log --oneline
    [[ "$output" == *"work"* ]]
    [ ! -d "$WT" ]
    run git -C "$REPO" branch --list me/feat
    [ -z "$output" ]
}

@test "fw merge: kills the source worktree's tmux session" {
    "$FW_BIN" create --no-switch feat
    commit_in "$WT" f.txt hello "work"
    "$FW_BIN" tmux-open feat
    run "$FW_ROOT/tests/shims/tmux" has-session -t "=myproj-feat"
    [ "$status" -eq 0 ]

    run "$FW_BIN" merge feat
    [ "$status" -eq 0 ]

    run "$FW_ROOT/tests/shims/tmux" has-session -t "=myproj-feat"
    [ "$status" -ne 0 ]
}

@test "fw merge: --no-ff creates a merge commit" {
    "$FW_BIN" create --no-switch feat
    commit_in "$WT" f.txt hello "work"

    run "$FW_BIN" merge --no-ff feat
    [ "$status" -eq 0 ]

    run git -C "$REPO" log --merges --oneline
    [ -n "$output" ]
    [ ! -d "$WT" ]
}

@test "fw merge: refuses when the source worktree has tracked modifications" {
    "$FW_BIN" create --no-switch feat
    commit_in "$WT" f.txt v1 "work"
    echo v2 >"$WT/f.txt"   # tracked, uncommitted

    run "$FW_BIN" merge feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"uncommitted"* ]]
    [ -d "$WT" ]
    run git -C "$REPO" log --oneline
    [[ "$output" != *"work"* ]]
}

@test "fw merge: -y merges past untracked files and deletes the worktree" {
    "$FW_BIN" create --no-switch feat
    commit_in "$WT" f.txt hello "work"
    echo scratch >"$WT/scratch.txt"   # untracked

    run "$FW_BIN" merge -y feat
    [ "$status" -eq 0 ]
    [ ! -d "$WT" ]
    run git -C "$REPO" log --oneline
    [[ "$output" == *"work"* ]]
}

@test "fw merge: untracked prompt aborts on 'n' and preserves the worktree" {
    "$FW_BIN" create --no-switch feat
    commit_in "$WT" f.txt hello "work"
    echo scratch >"$WT/scratch.txt"

    run bash -c "echo n | '$FW_BIN' merge feat"
    [ "$status" -ne 0 ]
    [[ "$output" == *"untracked"* ]]
    [ -d "$WT" ]
    run git -C "$REPO" log --oneline
    [[ "$output" != *"work"* ]]
}

@test "fw merge: untracked prompt lists up to 5 files with an overflow count" {
    "$FW_BIN" create --no-switch feat
    commit_in "$WT" f.txt hello "work"
    local i
    for i in 1 2 3 4 5 6 7; do echo x >"$WT/u$i.txt"; done

    run bash -c "echo n | '$FW_BIN' merge feat"
    [ "$status" -ne 0 ]
    [[ "$output" == *"and 2 more"* ]]
}

@test "fw merge: refuses when the main worktree is dirty" {
    "$FW_BIN" create --no-switch feat
    commit_in "$WT" f.txt hello "work"
    echo dirty >"$REPO/mainfile"   # untracked in the golden checkout

    run "$FW_BIN" merge feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"main worktree"* ]]
    [ -d "$WT" ]
}

@test "fw merge: refuses when run from inside the target worktree" {
    "$FW_BIN" create --no-switch feat
    commit_in "$WT" f.txt hello "work"

    run bash -c "cd '$WT' && '$FW_BIN' -p myproj merge feat"
    [ "$status" -ne 0 ]
    [[ "$output" == *"inside"* ]]
    [ -d "$WT" ]
}

@test "fw merge: rejects --no-ff and --ff-only together" {
    run "$FW_BIN" merge --no-ff --ff-only feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"mutually exclusive"* ]]
}

@test "fw merge: refuses to merge the trunk branch" {
    "$FW_BIN" create --no-switch feat
    # Simulate a corrupted/hand-edited env file recording trunk as the branch.
    # Portable in-place rewrite (BSD and GNU `sed -i` disagree on the backup arg).
    sed 's|^FW_BRANCH=.*|FW_BRANCH=main|' "$WT/.env.worktree" >"$WT/.env.worktree.new"
    mv "$WT/.env.worktree.new" "$WT/.env.worktree"

    run "$FW_BIN" merge feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"trunk"* ]]
    [ -d "$WT" ]
}

@test "fw merge: refuses when the main worktree is already on the source branch" {
    "$FW_BIN" create --no-switch feat
    # Free me/feat in the worktree, then check it out in the main worktree.
    git -C "$WT" checkout -q -b sidetrack
    git -C "$REPO" checkout -q me/feat

    run "$FW_BIN" merge feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"already on"* ]]
    [ -d "$WT" ]
}

@test "fw merge: a conflicting merge aborts and preserves the worktree" {
    commit_in "$REPO" c.txt base "base"
    "$FW_BIN" create --no-switch feat
    commit_in "$WT" c.txt feat "feat-change"
    commit_in "$REPO" c.txt main "main-change"

    run "$FW_BIN" merge feat
    [ "$status" -ne 0 ]
    [ -d "$WT" ]
    run git -C "$REPO" branch --list me/feat
    [ -n "$output" ]
    # The failed merge was aborted: the golden checkout is clean again.
    run git -C "$REPO" status --porcelain
    [ -z "$output" ]
}

@test "fw merge: --ff-only that cannot fast-forward aborts and preserves the worktree" {
    "$FW_BIN" create --no-switch feat
    commit_in "$WT" f.txt hello "work"
    # Advance main past the branch point so the branch is no longer a
    # fast-forward (different file, so this is divergence, not a conflict).
    commit_in "$REPO" m.txt main "main-advance"

    run "$FW_BIN" merge --ff-only feat
    [ "$status" -ne 0 ]
    [ -d "$WT" ]
    run git -C "$REPO" branch --list me/feat
    [ -n "$output" ]
    # No half-merge left behind.
    run git -C "$REPO" status --porcelain
    [ -z "$output" ]
    run git -C "$REPO" log --oneline
    [[ "$output" != *"work"* ]]
}

@test "fw merge: errors on an unknown worktree" {
    run "$FW_BIN" merge nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"nope"* ]]
}

@test "fw merge: runs fw sync as its last step by default" {
    "$FW_BIN" create --no-switch feat
    commit_in "$WT" f.txt hello "work"

    run "$FW_BIN" merge feat
    [ "$status" -eq 0 ]
    [ ! -d "$WT" ]
    # sync's completion banner proves the golden checkout was synced after merge.
    [[ "$output" == *"Golden checkout synced."* ]]
}

@test "fw merge: skips the sync step when the main worktree is not on trunk" {
    "$FW_BIN" create --no-switch feat
    commit_in "$WT" f.txt hello "work"
    # Move the golden checkout off trunk onto a feature branch, then merge into it.
    git -C "$REPO" checkout -q -b dev

    run "$FW_BIN" merge feat
    [ "$status" -eq 0 ]
    [ ! -d "$WT" ]
    # dev is not trunk, so the sync step is skipped even without --no-sync.
    [[ "$output" != *"Golden checkout synced."* ]]
    run git -C "$REPO" log --oneline
    [[ "$output" == *"work"* ]]
}

@test "fw merge: --no-sync merges and deletes but skips the sync step" {
    "$FW_BIN" create --no-switch feat
    commit_in "$WT" f.txt hello "work"

    run "$FW_BIN" merge --no-sync feat
    [ "$status" -eq 0 ]
    [ ! -d "$WT" ]
    # No sync banner: the sync step was skipped.
    [[ "$output" != *"Golden checkout synced."* ]]

    run git -C "$REPO" log --oneline
    [[ "$output" == *"work"* ]]
}

@test "fw merge: accepts a branch name argument" {
    "$FW_BIN" create --no-switch feat
    commit_in "$WT" f.txt hello "work"

    run "$FW_BIN" merge me/feat
    [ "$status" -eq 0 ]
    [ ! -d "$WT" ]
    run git -C "$REPO" branch --list me/feat
    [ -z "$output" ]
}
