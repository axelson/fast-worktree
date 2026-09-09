load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
    RECENT="$BATS_TEST_TMPDIR/myproj-worktrees/.fw_recent"
}

teardown() { "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true; }

# ts_for <name> — the most recent recorded timestamp for a worktree.
ts_for() {
    awk -F'\t' -v n="$1" '$2 == n { t = $1 } END { print t }' "$RECENT"
}

# plog — the global project switch log.
plog() { echo "$FW_CONFIG_DIR/project_log"; }

# pts_for <name> — the most recent recorded switch timestamp for a project.
pts_for() {
    awk -F'\t' -v n="$1" '$2 == n { t = $1 } END { print t }' "$(plog)"
}

# seed_project <name> [ts] — record a project switch (now, or an explicit epoch).
seed_project() {
    printf '%s\t%s\n' "${2:-$(date +%s)}" "$1" >>"$(plog)"
}

@test "fw shelve: pushes the recency timestamp back one day by default" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" switch alpha
    before="$(ts_for alpha)"

    run "$FW_BIN" shelve alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"Shelved"* ]]
    [[ "$output" == *"alpha"* ]]

    after="$(ts_for alpha)"
    [ "$(( before - after ))" -eq 86400 ]
}

@test "fw shelve: -t sets the shelve duration" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" switch alpha
    before="$(ts_for alpha)"

    run "$FW_BIN" shelve -t 2h alpha
    [ "$status" -eq 0 ]

    after="$(ts_for alpha)"
    [ "$(( before - after ))" -eq 7200 ]
}

@test "fw shelve: accepts a branch name" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" switch alpha
    before="$(ts_for alpha)"

    run "$FW_BIN" shelve me/alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"Shelved"* ]]
    [[ "$output" == *"alpha"* ]]

    after="$(ts_for alpha)"
    [ "$(( before - after ))" -eq 86400 ]
}

@test "fw shelve: leaves only one recency line for the shelved worktree" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" switch alpha
    "$FW_BIN" switch alpha

    "$FW_BIN" shelve alpha
    [ "$(grep -c $'\talpha$' "$RECENT")" -eq 1 ]
}

@test "fw shelve: errors when the worktree has no recency entry" {
    "$FW_BIN" create --no-switch alpha
    # Create records recency now, so simulate a lost/never-written log.
    rm -f "$BATS_TEST_TMPDIR/myproj-worktrees/.fw_recent"
    run "$FW_BIN" shelve alpha
    [ "$status" -ne 0 ]
    [[ "$output" == *"no recency"* ]]
}

@test "fw shelve: defaults to the current worktree" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" switch alpha
    before="$(ts_for alpha)"

    cd "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    run "$FW_BIN" shelve
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]

    after="$(ts_for alpha)"
    [ "$(( before - after ))" -eq 86400 ]
}

@test "fw shelve: warns when shelving hides the worktree past the picker cutoff" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" switch alpha

    run "$FW_BIN" shelve -t 30d alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning"* ]]
}

@test "fw shelve: rejects an invalid duration" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" switch alpha
    run "$FW_BIN" shelve -t bogus alpha
    [ "$status" -ne 0 ]
    [[ "$output" == *"duration"* ]]
}

# --- finding 11: shelving must lower recency, not raise it ---

@test "fw shelve: orders the shelved worktree below a more recent one" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" create --no-switch beta
    "$FW_BIN" switch alpha
    "$FW_BIN" switch beta
    # Shelve appends a back-dated 'alpha' row LAST in the log; recency ordering
    # must key off the timestamp, not the file position.
    "$FW_BIN" shelve alpha

    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" switch
    [ "$status" -eq 0 ]
    # Rows are "<display>  <age>\t<name>"; the trailing tab field is the key.
    beta_line="$(cut -f2 "$BATS_TEST_TMPDIR/offered" | grep -n '^beta$' | head -1 | cut -d: -f1)"
    alpha_line="$(cut -f2 "$BATS_TEST_TMPDIR/offered" | grep -n '^alpha$' | head -1 | cut -d: -f1)"
    [ -n "$beta_line" ] && [ -n "$alpha_line" ]
    [ "$beta_line" -lt "$alpha_line" ]
}

@test "fw last: does not treat a freshly shelved worktree as current" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" create --no-switch beta
    "$FW_BIN" switch alpha
    "$FW_BIN" switch beta
    "$FW_BIN" shelve alpha

    # beta is the current (most-recent) worktree; `fw last` must go to alpha,
    # not treat the just-shelved alpha as current and bounce to beta.
    run "$FW_BIN" last
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
}

@test "fw shelve: can shelve several worktrees at once" {
    "$FW_BIN" create --no-switch alpha
    "$FW_BIN" create --no-switch beta
    "$FW_BIN" switch alpha
    "$FW_BIN" switch beta
    a_before="$(ts_for alpha)"
    b_before="$(ts_for beta)"

    run "$FW_BIN" shelve alpha beta
    [ "$status" -eq 0 ]

    [ "$(( a_before - $(ts_for alpha) ))" -eq 86400 ]
    [ "$(( b_before - $(ts_for beta) ))" -eq 86400 ]
}

# --- project shelve (--project / -p) ---

@test "fw shelve --project: back-dates the project log one day by default" {
    seed_project myproj
    before="$(pts_for myproj)"

    run "$FW_BIN" shelve --project myproj
    [ "$status" -eq 0 ]
    [[ "$output" == *"Shelved project"* ]]
    [[ "$output" == *"myproj"* ]]

    after="$(pts_for myproj)"
    [ "$(( before - after ))" -eq 86400 ]
}

@test "fw shelve --project: -t sets the shelve duration" {
    seed_project myproj
    before="$(pts_for myproj)"

    run "$FW_BIN" shelve -t 2h -p myproj
    [ "$status" -eq 0 ]

    after="$(pts_for myproj)"
    [ "$(( before - after ))" -eq 7200 ]
}

@test "fw shelve --project: shelves several projects at once" {
    make_repo "$BATS_TEST_TMPDIR/repo2"
    register_project proj2 "$BATS_TEST_TMPDIR/repo2"
    seed_project myproj
    seed_project proj2
    a_before="$(pts_for myproj)"
    b_before="$(pts_for proj2)"

    run "$FW_BIN" shelve -p myproj proj2
    [ "$status" -eq 0 ]

    [ "$(( a_before - $(pts_for myproj) ))" -eq 86400 ]
    [ "$(( b_before - $(pts_for proj2) ))" -eq 86400 ]
}

@test "fw shelve --project: defaults to the current project" {
    seed_project myproj
    before="$(pts_for myproj)"

    # setup() already cd'd into myrepo, whose project is myproj.
    run "$FW_BIN" shelve --project
    [ "$status" -eq 0 ]
    [[ "$output" == *"myproj"* ]]

    after="$(pts_for myproj)"
    [ "$(( before - after ))" -eq 86400 ]
}

@test "fw shelve --project: errors on an unregistered project" {
    run "$FW_BIN" shelve -p nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"nope"* ]]
    [[ "$output" == *"not registered"* ]]
}

@test "fw shelve --project: no switch history is a friendly no-op" {
    # myproj is registered but never switched to, so it has no project_log row.
    run "$FW_BIN" shelve -p myproj
    [ "$status" -eq 0 ]
    [[ "$output" == *"no switch history"* ]]
    [[ "$output" != *"Error"* ]]
    # Nothing was written for it.
    [ ! -f "$(plog)" ] || ! grep -q $'\tmyproj$' "$(plog)"
}

@test "fw shelve --project: works from outside any registered project" {
    make_repo "$BATS_TEST_TMPDIR/repo2"
    register_project proj2 "$BATS_TEST_TMPDIR/repo2"
    seed_project proj2
    before="$(pts_for proj2)"

    cd "$BATS_TEST_TMPDIR"   # not inside any registered project's repo
    run "$FW_BIN" shelve -p proj2
    [ "$status" -eq 0 ]

    after="$(pts_for proj2)"
    [ "$(( before - after ))" -eq 86400 ]
}

@test "fw shelve: worktree mode still requires a project" {
    cd "$BATS_TEST_TMPDIR"   # not inside any registered project's repo
    run "$FW_BIN" shelve alpha
    [ "$status" -ne 0 ]
}
