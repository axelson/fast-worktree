load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

@test "fw archive: refuses the golden checkout even once it has an env file" {
    cd "$BATS_TEST_TMPDIR/myrepo"
    # Once main has a golden env, its branch IS recorded, so archive's generic
    # "no recorded branch" refusal no longer protects it — an explicit guard must.
    "$FW_BIN" regen-env main

    run "$FW_BIN" archive --reason "nope" main
    [ "$status" -ne 0 ]
    [[ "$output" == *"golden checkout"* ]]
    [ -d "$BATS_TEST_TMPDIR/myrepo/.git" ]
    [ ! -f "$BATS_TEST_TMPDIR/myproj-worktrees/.fw_archive_log" ]
}

@test "fw archive: refuses the golden checkout detected from cwd" {
    cd "$BATS_TEST_TMPDIR/myrepo"
    "$FW_BIN" regen-env main

    run "$FW_BIN" archive --reason "nope"
    [ "$status" -ne 0 ]
    [[ "$output" == *"golden checkout"* ]]
    [ -d "$BATS_TEST_TMPDIR/myrepo/.git" ]
}

@test "fw archive: removes the worktree but keeps the branch, logging the reason" {
    "$FW_BIN" create feat

    run "$FW_BIN" archive --reason "waiting on review" feat
    [ "$status" -eq 0 ]

    [ ! -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
    run git -C "$BATS_TEST_TMPDIR/myrepo" branch --list me/feat
    [ -n "$output" ]
    grep -q "waiting on review" "$BATS_TEST_TMPDIR/myproj-worktrees/.fw_archive_log"
}

@test "fw archive: commits loose untracked files onto the branch first" {
    "$FW_BIN" create feat
    echo "notes" >"$BATS_TEST_TMPDIR/myproj-worktrees/feat/NOTES.md"

    run "$FW_BIN" archive --reason done feat
    [ "$status" -eq 0 ]

    run git -C "$BATS_TEST_TMPDIR/myrepo" show me/feat:NOTES.md
    [ "$output" = "notes" ]
}

@test "fw archive: commits loose files even when the env file is gitignored" {
    # Real projects gitignore the per-worktree env file. The rescue commit must
    # not choke on it: `git add .` errors on an explicitly-ignored path.
    echo '.env.worktree' >"$BATS_TEST_TMPDIR/myrepo/.gitignore"
    git -C "$BATS_TEST_TMPDIR/myrepo" add .gitignore
    git -C "$BATS_TEST_TMPDIR/myrepo" -c user.email=t@t -c user.name=t commit -qm gitignore
    "$FW_BIN" create feat
    echo "notes" >"$BATS_TEST_TMPDIR/myproj-worktrees/feat/NOTES.md"

    run "$FW_BIN" archive --reason done feat
    [ "$status" -eq 0 ]
    run git -C "$BATS_TEST_TMPDIR/myrepo" show me/feat:NOTES.md
    [ "$output" = "notes" ]
    # The gitignored env file must never land in the rescue commit.
    run git -C "$BATS_TEST_TMPDIR/myrepo" show me/feat:.env.worktree
    [ "$status" -ne 0 ]
}

@test "fw archive: refuses modified tracked files" {
    echo base >"$BATS_TEST_TMPDIR/myrepo/tracked.txt"
    git -C "$BATS_TEST_TMPDIR/myrepo" add tracked.txt
    git -C "$BATS_TEST_TMPDIR/myrepo" -c user.email=t@t -c user.name=t commit -qm add
    "$FW_BIN" create feat
    echo changed >"$BATS_TEST_TMPDIR/myproj-worktrees/feat/tracked.txt"

    run "$FW_BIN" archive --reason x feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"modified"* ]]
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

@test "fw restore: recreates an archived worktree from its branch" {
    "$FW_BIN" create feat
    echo "notes" >"$BATS_TEST_TMPDIR/myproj-worktrees/feat/NOTES.md"
    "$FW_BIN" archive --reason pause feat

    run "$FW_BIN" restore feat
    [ "$status" -eq 0 ]

    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
    [ "$(cat "$BATS_TEST_TMPDIR/myproj-worktrees/feat/NOTES.md")" = "notes" ]
    run git -C "$BATS_TEST_TMPDIR/myproj-worktrees/feat" branch --show-current
    [ "$output" = "me/feat" ]
}

@test "fw restore: records recency so the bare switch picker sees the worktree" {
    "$FW_BIN" create feat
    "$FW_BIN" archive --reason pause feat
    rm -f "$BATS_TEST_TMPDIR/myproj-worktrees/.fw_recent"

    run "$FW_BIN" restore feat
    [ "$status" -eq 0 ]
    grep -q $'\tfeat$' "$BATS_TEST_TMPDIR/myproj-worktrees/.fw_recent"
}

@test "fw list --archived: shows archived entries" {
    "$FW_BIN" create feat
    "$FW_BIN" archive --reason "on hold" feat

    run "$FW_BIN" list --archived
    [ "$status" -eq 0 ]
    [[ "$output" == *"feat"* ]]
    [[ "$output" == *"on hold"* ]]
}

@test "fw purge: deletes an archived branch" {
    "$FW_BIN" create feat
    "$FW_BIN" archive --reason done feat

    run "$FW_BIN" purge feat
    [ "$status" -eq 0 ]

    run git -C "$BATS_TEST_TMPDIR/myrepo" branch --list me/feat
    [ -z "$output" ]
}

@test "fw archive: --reason with no value prints a usage error" {
    "$FW_BIN" create feat

    run "$FW_BIN" archive feat --reason
    [ "$status" -ne 0 ]
    [ -n "$output" ]
    [[ "$output" == *"--reason"* ]]
}

@test "fw archive: refuses when the checked-out branch differs from the recorded one" {
    "$FW_BIN" create feat
    git -C "$BATS_TEST_TMPDIR/myproj-worktrees/feat" checkout -q -b sidetrack

    run "$FW_BIN" archive --reason x feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"sidetrack"* ]]
    [[ "$output" == *"me/feat"* ]]
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

@test "fw archive: refuses a worktree with no recorded branch" {
    "$FW_BIN" create feat
    rm "$BATS_TEST_TMPDIR/myproj-worktrees/feat/.env.worktree"

    run "$FW_BIN" archive --reason x feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"recorded branch"* ]]
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

@test "fw archive: refuses untracked binary files" {
    "$FW_BIN" create feat
    printf '\x00\x01\x02\x03binary' >"$BATS_TEST_TMPDIR/myproj-worktrees/feat/blob.bin"

    run "$FW_BIN" archive --reason x feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"blob.bin"* ]]
    [ -d "$BATS_TEST_TMPDIR/myproj-worktrees/feat" ]
}

@test "fw archive: refuses oversized untracked files" {
    "$FW_BIN" create feat
    dd if=/dev/zero of="$BATS_TEST_TMPDIR/myproj-worktrees/feat/huge.txt" \
        bs=1024 count=1500 2>/dev/null
    # make it text so only the size rule triggers
    printf 'x%.0s' {1..100} >>"$BATS_TEST_TMPDIR/myproj-worktrees/feat/huge.txt"

    run "$FW_BIN" archive --reason x feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"huge.txt"* ]]
}

@test "fw restore: pops the rescue commit so loose files return to untracked" {
    "$FW_BIN" create feat
    echo notes >"$BATS_TEST_TMPDIR/myproj-worktrees/feat/NOTES.md"
    "$FW_BIN" archive --reason pause feat

    "$FW_BIN" restore feat

    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/feat"
    [ "$(cat "$wt/NOTES.md")" = "notes" ]
    run git -C "$wt" log -1 --format=%s
    [[ "$output" != *"fw archive"* ]]
    run git -C "$wt" status --porcelain -- NOTES.md
    [[ "$output" == "?? NOTES.md" ]]
}

@test "fw restore: retires the archive-log entry" {
    "$FW_BIN" create feat
    "$FW_BIN" archive --reason pause feat
    "$FW_BIN" restore feat

    run "$FW_BIN" list --archived
    [[ "$output" != *"feat"* ]]

    run "$FW_BIN" purge feat
    [ "$status" -ne 0 ]
}

@test "fw purge: retires the entry after deleting the branch" {
    "$FW_BIN" create feat
    "$FW_BIN" archive --reason done feat
    "$FW_BIN" purge feat

    run "$FW_BIN" list --archived
    [[ "$output" != *"feat"* ]]

    run "$FW_BIN" purge feat
    [ "$status" -ne 0 ]
}

@test "fw purge: refuses when a live worktree uses the archived branch" {
    "$FW_BIN" create feat
    "$FW_BIN" archive --reason hold feat
    "$FW_BIN" create feat

    run "$FW_BIN" purge feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"delete"* ]]
    run git -C "$BATS_TEST_TMPDIR/myrepo" branch --list me/feat
    [ -n "$output" ]
}

@test "fw purge: refuses a branch that was never archived" {
    "$FW_BIN" create feat

    run "$FW_BIN" purge feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"archive"* ]]
}

@test "fw purge: bare picker offers archived entries and purges the selection" {
    "$FW_BIN" create feat
    "$FW_BIN" archive --reason done feat
    "$FW_BIN" create other
    "$FW_BIN" archive --reason hold other

    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_SELECT=feat

    run "$FW_BIN" purge
    [ "$status" -eq 0 ]

    # Both archived worktrees were offered to fzf...
    grep -q "feat" "$BATS_TEST_TMPDIR/offered"
    grep -q "other" "$BATS_TEST_TMPDIR/offered"

    # ...and only the picked one was purged.
    run "$FW_BIN" list --archived
    [[ "$output" != *"feat"* ]]
    [[ "$output" == *"other"* ]]
}

@test "fw purge: bare picker multi-select purges every chosen entry" {
    "$FW_BIN" create feat
    "$FW_BIN" archive --reason done feat
    "$FW_BIN" create other
    "$FW_BIN" archive --reason hold other

    export FW_TEST_FZF_SELECT_LINES=$'feat\nother'
    run "$FW_BIN" purge
    [ "$status" -eq 0 ]

    run "$FW_BIN" list --archived
    [[ "$output" != *"feat"* ]]
    [[ "$output" != *"other"* ]]
}

@test "fw purge: bare picker on an empty archive log is a message, not an error" {
    run "$FW_BIN" purge
    [ "$status" -eq 0 ]
    [[ "$output" == *"No archived worktrees"* ]]
}

@test "fw purge: bare picker cancel purges nothing" {
    "$FW_BIN" create feat
    "$FW_BIN" archive --reason done feat

    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" purge
    [ "$status" -eq 0 ]

    run "$FW_BIN" list --archived
    [[ "$output" == *"feat"* ]]
}

@test "fw archive: archives Claude artifacts before removal" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
claude_archive_paths=(".claude/plans:plans")
EOF
    "$FW_BIN" create feat
    echo '.claude/' >"$BATS_TEST_TMPDIR/myproj-worktrees/feat/.gitignore"
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/feat/.claude/plans"
    echo "# plan" >"$BATS_TEST_TMPDIR/myproj-worktrees/feat/.claude/plans/p.md"

    run "$FW_BIN" archive --reason "keep it" feat
    [ "$status" -eq 0 ]
    [ -f "$FW_CONFIG_DIR/projects/myproj/claude-archive/me-feat/plans/p.md" ]
}

@test "fw archive: archives a file-pair artifact (not just directories)" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
claude_archive_paths=("STATUS.md:status.md")
EOF
    "$FW_BIN" create feat
    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/feat"
    # STATUS.md is gitignored, so the loose-file rescue commit can't preserve
    # it — only archive_claude's file branch can (this is the SEC-7 fix).
    echo 'STATUS.md' >"$wt/.gitignore"
    echo "in progress" >"$wt/STATUS.md"

    run "$FW_BIN" archive --reason "keep it" feat
    [ "$status" -eq 0 ]
    [ -f "$FW_CONFIG_DIR/projects/myproj/claude-archive/me-feat/status.md" ]
    [ "$(cat "$FW_CONFIG_DIR/projects/myproj/claude-archive/me-feat/status.md")" = "in progress" ]
}

@test "fw archive/restore: a file-pair artifact survives a full round trip" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
claude_archive_paths=("STATUS.md:status.md")
EOF
    "$FW_BIN" create feat
    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/feat"
    echo 'STATUS.md' >"$wt/.gitignore"
    echo "in progress" >"$wt/STATUS.md"

    "$FW_BIN" archive --reason pause feat
    [ ! -d "$wt" ]

    run "$FW_BIN" restore feat
    [ "$status" -eq 0 ]
    [ -d "$wt" ]
    [ "$(cat "$wt/STATUS.md")" = "in progress" ]
    # Move semantics: the archived copy leaves the archive dir on restore,
    # symmetric with retiring the archive-log entry.
    [ ! -f "$FW_CONFIG_DIR/projects/myproj/claude-archive/me-feat/status.md" ]
}

@test "fw archive/restore: a directory-pair artifact survives a full round trip" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
claude_archive_paths=(".claude/plans:plans")
EOF
    "$FW_BIN" create feat
    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/feat"
    echo '.claude/' >"$wt/.gitignore"
    mkdir -p "$wt/.claude/plans"
    echo "# plan" >"$wt/.claude/plans/p.md"

    "$FW_BIN" archive --reason pause feat
    [ ! -d "$wt" ]

    run "$FW_BIN" restore feat
    [ "$status" -eq 0 ]
    [ -d "$wt" ]
    [ "$(cat "$wt/.claude/plans/p.md")" = "# plan" ]
}

@test "fw archive/restore: a dotfile inside a directory-pair round-trips, leaving the archive retired" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
claude_archive_paths=(".claude/plans:plans")
EOF
    "$FW_BIN" create feat
    local wt="$BATS_TEST_TMPDIR/myproj-worktrees/feat"
    echo '.claude/' >"$wt/.gitignore"
    mkdir -p "$wt/.claude/plans"
    echo "# plan" >"$wt/.claude/plans/p.md"
    echo "hidden" >"$wt/.claude/plans/.secret"

    "$FW_BIN" archive --reason pause feat
    [ ! -d "$wt" ]

    run "$FW_BIN" restore feat
    [ "$status" -eq 0 ]
    [ -d "$wt" ]
    # Both the visible and the hidden file must come back.
    [ "$(cat "$wt/.claude/plans/p.md")" = "# plan" ]
    [ "$(cat "$wt/.claude/plans/.secret")" = "hidden" ]
    # Move semantics: nothing (visible or hidden) is left stranded in the archive.
    [ ! -e "$FW_CONFIG_DIR/projects/myproj/claude-archive/me-feat/plans" ]
}
