load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/repo-a"
    make_repo "$BATS_TEST_TMPDIR/repo-b"
    register_project aproj "$BATS_TEST_TMPDIR/repo-a"
    register_project bproj "$BATS_TEST_TMPDIR/repo-b"
    cd "$BATS_TEST_TMPDIR"
}

teardown() {
    "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true
}

# mk_worktree <project> <name> — create a resolvable worktree under the
# project's worktrees dir (dirname(repo_root)/<project>-worktrees). Writes the
# env file too, since that — not mere directory existence — is what marks a real
# worktree (a bare dir is a phantom the switch guard refuses to land on).
mk_worktree() {
    mkdir -p "$BATS_TEST_TMPDIR/$1-worktrees/$2"
    printf 'FW_WORKTREE=%s\nFW_BRANCH=%s\n' "$2" "$2" \
        >"$BATS_TEST_TMPDIR/$1-worktrees/$2/.env.worktree"
}

# seed_recent <project> <name>... — append switch-history rows to a project's
# .fw_recent, oldest-first (increasing timestamps), so the last name listed is
# the most recent. Names need not correspond to existing dirs — that's how a
# deleted-worktree entry is simulated.
seed_recent() {
    local proj="$1"; shift
    local log="$BATS_TEST_TMPDIR/$proj-worktrees/.fw_recent"
    mkdir -p "$(dirname "$log")"
    local ts=1000000000 n
    for n in "$@"; do
        printf '%s\t%s\n' "$ts" "$n" >>"$log"
        ts=$((ts + 1))
    done
}

@test "fw switch-project: opens the project's main session at its repo root" {
    run "$FW_BIN" switch-project bproj
    [ "$status" -eq 0 ]
    [[ "$output" == *"bproj-main"* ]]

    run "$FW_ROOT/tests/shims/tmux" list-panes -t "=bproj-main" -F '#{pane_current_path}'
    [ "$(realpath "$output")" = "$(realpath "$BATS_TEST_TMPDIR/repo-b")" ]
}

@test "fw switch-project: works from inside another project" {
    cd "$BATS_TEST_TMPDIR/repo-a"

    run "$FW_BIN" sp bproj
    [ "$status" -eq 0 ]
    [[ "$output" == *"bproj-main"* ]]
}

@test "fw switch-project: records project recency" {
    "$FW_BIN" switch-project aproj
    "$FW_BIN" switch-project bproj

    local log="$XDG_CONFIG_HOME/fast-worktree/project_log"
    [ -f "$log" ]
    grep -q "aproj" "$log"
    grep -q "bproj" "$log"
}

@test "fw switch-project: errors on an unregistered project" {
    run "$FW_BIN" switch-project nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"nope"* ]]
}

@test "fw switch-project: bare picker offers registered projects and opens the pick" {
    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_SELECT=bproj

    run "$FW_BIN" switch-project
    [ "$status" -eq 0 ]
    [[ "$output" == *"bproj-main"* ]]

    # Rows are "<display>  <age>\t<name>"; the trailing tab field is the key.
    cut -f2 "$BATS_TEST_TMPDIR/offered" | grep -q "^aproj$"
    cut -f2 "$BATS_TEST_TMPDIR/offered" | grep -q "^bproj$"
}

@test "fw switch-project: bare picker orders most-recently-switched first" {
    "$FW_BIN" switch-project aproj
    "$FW_BIN" switch-project bproj

    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_SELECT=aproj
    run "$FW_BIN" sp
    [ "$status" -eq 0 ]

    # bproj was switched to most recently, so it leads the offered list.
    [ "$(cut -f2 "$BATS_TEST_TMPDIR/offered" | head -1)" = "bproj" ]
}

@test "fw switch-project: bare picker shows a dash for a never-switched project" {
    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" sp
    [ "$status" -eq 0 ]

    # aproj has never been switched to, so its recency column renders "-".
    row="$(awk -F'\t' '$NF == "aproj"' "$BATS_TEST_TMPDIR/offered")"
    [ -n "$row" ]
    [[ "$row" == *"-"* ]]
}

@test "fw switch-project: bare picker cancel is a quiet no-op" {
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" sp
    [ "$status" -eq 0 ]
}

@test "fw switch-project: a freshly init'd project leads the picker" {
    make_repo "$BATS_TEST_TMPDIR/repo-c"
    ( cd "$BATS_TEST_TMPDIR/repo-c" && "$FW_BIN" init cproj )

    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" sp
    [ "$status" -eq 0 ]

    # init marked cproj visited "just now", so it outranks the never-switched
    # aproj/bproj and leads the offered list.
    [ "$(cut -f2 "$BATS_TEST_TMPDIR/offered" | head -1)" = "cproj" ]
}

@test "fw switch-project: lands on the project's most recently active worktree" {
    mk_worktree bproj feat
    seed_recent bproj feat

    run "$FW_BIN" switch-project bproj
    [ "$status" -eq 0 ]
    [[ "$output" == *"bproj-feat"* ]]

    run "$FW_ROOT/tests/shims/tmux" list-panes -t "=bproj-feat" -F '#{pane_current_path}'
    [ "$(realpath "$output")" = "$(realpath "$BATS_TEST_TMPDIR/bproj-worktrees/feat")" ]
}

@test "fw switch-project: main competes as a peer (lands main when it is most recent)" {
    mk_worktree bproj feat
    seed_recent bproj feat main

    run "$FW_BIN" switch-project bproj
    [ "$status" -eq 0 ]
    [[ "$output" == *"bproj-main"* ]]

    run "$FW_ROOT/tests/shims/tmux" list-panes -t "=bproj-main" -F '#{pane_current_path}'
    [ "$(realpath "$output")" = "$(realpath "$BATS_TEST_TMPDIR/repo-b")" ]
}

@test "fw switch-project: skips a deleted most-recent entry" {
    mk_worktree bproj feat
    seed_recent bproj feat gone   # 'gone' is most recent but has no worktree dir

    run "$FW_BIN" switch-project bproj
    [ "$status" -eq 0 ]
    [[ "$output" == *"bproj-feat"* ]]
}

@test "fw switch-project: skips a phantom most-recent entry (dir without env file)" {
    # A partially-deleted worktree leaves its dir behind with no env file. It is
    # not a worktree, so landing must skip it like a deleted entry (sp never
    # errors), not try to land a session in it.
    mk_worktree bproj feat
    mkdir -p "$BATS_TEST_TMPDIR/bproj-worktrees/phantom"   # dir only, no env file
    seed_recent bproj feat phantom                          # phantom is most recent

    run "$FW_BIN" switch-project bproj
    [ "$status" -eq 0 ]
    [[ "$output" == *"bproj-feat"* ]]
    [[ "$output" != *"bproj-phantom"* ]]
}

@test "fw switch-project: all-deleted history falls back to main" {
    seed_recent bproj gone        # only a deleted worktree in the log

    run "$FW_BIN" switch-project bproj
    [ "$status" -eq 0 ]
    [[ "$output" == *"bproj-main"* ]]

    run "$FW_ROOT/tests/shims/tmux" list-panes -t "=bproj-main" -F '#{pane_current_path}'
    [ "$(realpath "$output")" = "$(realpath "$BATS_TEST_TMPDIR/repo-b")" ]
}
