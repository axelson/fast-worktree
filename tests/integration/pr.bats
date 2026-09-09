load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

teardown() { "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true; }

pr_json() {
    printf '{"number":%s,"url":"https://github.com/owner/repo/pull/%s","state":"%s","isDraft":%s,"title":"%s","assignees":%s,"reviewDecision":"%s","baseRefName":"%s","author":{"login":"%s"}}' \
        "${1:-42}" "${1:-42}" "${2:-OPEN}" "${3:-false}" "${4:-Add feature}" \
        "${5:-[]}" "${6:-}" "${7:-main}" "${8:-bob}"
}

# A `gh pr list` array element keyed by headRefName (the branch fw matches on).
pr_list_row() {
    printf '{"headRefName":"%s","number":%s,"state":"%s","isDraft":%s,"title":"%s","url":"https://github.com/owner/repo/pull/%s"}' \
        "${1:-me/feat}" "${2:-42}" "${3:-OPEN}" "${4:-false}" "${5:-Add feature}" "${2:-42}"
}

@test "fw prs: lists worktrees with their PR" {
    "$FW_BIN" create feat
    export FW_TEST_GH_PR_LIST_JSON="[$(pr_list_row me/feat 42 OPEN false 'Add feature')]"

    run "$FW_BIN" prs
    [ "$status" -eq 0 ]
    [[ "$output" == *"me/feat"* ]]
    [[ "$output" == *"#42"* ]]
    [[ "$output" == *"Add feature"* ]]
    [[ "$output" == *"open"* ]]
}

@test "fw prs: --merged filters out open PRs" {
    "$FW_BIN" create feat
    export FW_TEST_GH_PR_LIST_JSON="[$(pr_list_row me/feat 42 OPEN false 'Add feature')]"

    run "$FW_BIN" prs --merged
    [ "$status" -eq 0 ]
    [[ "$output" != *"#42"* ]]
}

@test "fw prs: shows a placeholder row for a worktree with no PR" {
    "$FW_BIN" create feat
    export FW_TEST_GH_PR_LIST_JSON='[]'

    run "$FW_BIN" prs
    [ "$status" -eq 0 ]
    [[ "$output" == *"me/feat"* ]]
    # placeholder columns: STATUS/PR/TITLE all "-"
    [[ "$output" == *"-"* ]]
}

@test "fw prs: a placeholder-less filter drops PR-less worktrees" {
    "$FW_BIN" create feat
    export FW_TEST_GH_PR_LIST_JSON='[]'

    run "$FW_BIN" prs --merged
    [ "$status" -eq 0 ]
    [[ "$output" != *"me/feat"* ]]
}

@test "fw prs: reports when there are no worktrees" {
    run "$FW_BIN" prs
    [ "$status" -eq 0 ]
    [[ "$output" == *"No worktrees"* ]]
}

@test "fw prs: rejects an unknown flag" {
    run "$FW_BIN" prs --bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"nknown flag"* ]]
}

@test "fw prs --open: a single PR opens directly without a picker" {
    "$FW_BIN" create feat
    export FW_TEST_GH_PR_LIST_JSON="[$(pr_list_row me/feat 42 OPEN false 'Add feature')]"
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"
    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"

    run "$FW_BIN" prs --open
    [ "$status" -eq 0 ]
    grep -q 'pull/42' "$FW_TEST_OPEN_LOG"
    # A lone PR skips fzf entirely.
    [ ! -f "$FW_TEST_FZF_LOG" ]
}

@test "fw prs --open: multiple PRs go through the fzf picker" {
    "$FW_BIN" create feat
    "$FW_BIN" create other
    export FW_TEST_GH_PR_LIST_JSON="[$(pr_list_row me/feat 42 OPEN false 'Feat'),$(pr_list_row me/other 43 OPEN false 'Other')]"
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"
    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_SELECT="#43"

    run "$FW_BIN" prs --open
    [ "$status" -eq 0 ]
    grep -q "#42" "$BATS_TEST_TMPDIR/offered"
    grep -q "#43" "$BATS_TEST_TMPDIR/offered"
    grep -q 'pull/43' "$FW_TEST_OPEN_LOG"
    ! grep -q 'pull/42' "$FW_TEST_OPEN_LOG"
}

@test "fw prs --open: reports when there are no PRs to open" {
    "$FW_BIN" create feat
    export FW_TEST_GH_PR_LIST_JSON='[]'

    run "$FW_BIN" prs --open
    [ "$status" -eq 0 ]
    [[ "$output" == *"No PRs to open"* ]]
}

@test "fw prs --open: cancelling the picker opens nothing" {
    "$FW_BIN" create feat
    "$FW_BIN" create other
    export FW_TEST_GH_PR_LIST_JSON="[$(pr_list_row me/feat 42 OPEN false 'Feat'),$(pr_list_row me/other 43 OPEN false 'Other')]"
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"
    export FW_TEST_FZF_CANCEL=1

    run "$FW_BIN" prs --open
    [ "$status" -eq 0 ]
    [ ! -f "$FW_TEST_OPEN_LOG" ]
}

@test "fw prs: bare 'open' arg suggests --open" {
    run "$FW_BIN" prs open
    [ "$status" -ne 0 ]
    [[ "$output" == *"--open"* ]]
}

@test "fw pr info: prints PR details for a worktree" {
    "$FW_BIN" create feat
    export FW_TEST_GH_PR_JSON="$(pr_json 42 OPEN false 'Add feature' '[{"login":"alice"}]' APPROVED main bob)"

    run "$FW_BIN" pr info feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"Branch:"*"me/feat"* ]]
    [[ "$output" == *"#42"* ]]
    [[ "$output" == *"Add feature"* ]]
    [[ "$output" == *"approved"* ]]
    [[ "$output" == *"alice"* ]]
    [[ "$output" != *"Merge into"* ]]
}

@test "fw pr info: shows the merge target when the base is not trunk" {
    "$FW_BIN" create feat
    export FW_TEST_GH_PR_JSON="$(pr_json 42 OPEN false 'Add feature' '[]' '' me/base bob)"

    run "$FW_BIN" pr info feat
    [ "$status" -eq 0 ]
    # Assert per line: the base belongs on the "Merge into:" line, not merely
    # somewhere after it (an empty assignees field once collapsed fields left,
    # leaking the base onto a stray Assignees line while this glob still matched).
    local merge_line
    merge_line="$(printf '%s\n' "$output" | grep '^Merge into:')"
    [[ "$merge_line" == *"me/base"* ]]
}

@test "fw pr info: a PR with no assignees keeps every field aligned" {
    "$FW_BIN" create feat
    # No assignees + a non-trunk base: the empty assignees field used to collapse
    # under tab-IFS and shift Title/Merge-into/Assignees all one field left.
    export FW_TEST_GH_PR_JSON="$(pr_json 42 OPEN false 'Add feature' '[]' '' me/base bob)"

    run "$FW_BIN" pr info feat
    [ "$status" -eq 0 ]
    local title_line merge_line
    title_line="$(printf '%s\n' "$output" | grep '^Title:')"
    merge_line="$(printf '%s\n' "$output" | grep '^Merge into:')"
    [[ "$title_line" == *"Add feature"* ]]
    [[ "$merge_line" == *"me/base"* ]]
    # No assignees -> no Assignees line at all.
    [[ "$output" != *"Assignees:"* ]]
}

@test "fw pr info: no assignees but a review decision still shows the title" {
    "$FW_BIN" create feat
    # The live #21653 case: empty assignees, non-empty reviewDecision, trunk base.
    export FW_TEST_GH_PR_JSON="$(pr_json 42 OPEN false 'Add feature' '[]' REVIEW_REQUIRED main bob)"

    run "$FW_BIN" pr info feat
    [ "$status" -eq 0 ]
    local title_line
    title_line="$(printf '%s\n' "$output" | grep '^Title:')"
    [[ "$title_line" == *"Add feature"* ]]
    [[ "$output" != *"Assignees:"* ]]
    [[ "$output" != *"Merge into"* ]]
}

@test "fw pr info: errors when the branch has no PR" {
    "$FW_BIN" create feat
    # FW_TEST_GH_PR_JSON unset -> the shim reports no PR

    run "$FW_BIN" pr info feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"No PR"* || "$output" == *"no PR"* ]]
}

@test "fw pr open: opens exactly the PR URL via the open seam" {
    "$FW_BIN" create feat
    export FW_TEST_GH_PR_JSON="$(pr_json 77 OPEN false 'Feat')"
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"

    run "$FW_BIN" pr open feat
    [ "$status" -eq 0 ]
    [ "$(cat "$FW_TEST_OPEN_LOG")" = "https://github.com/owner/repo/pull/77" ]
}

@test "fw pr open: honors the default_browser config" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/mybrowser" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/browser.log"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/mybrowser"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    echo 'default_browser=mybrowser' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    "$FW_BIN" create feat
    export FW_TEST_GH_PR_JSON="$(pr_json 88 OPEN false 'Feat')"

    run "$FW_BIN" pr open feat
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/browser.log")" = "https://github.com/owner/repo/pull/88" ]
}

@test "fw pr open: honors a multi-word default_browser config" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/mybrowser" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/browser.log"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/mybrowser"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    echo 'default_browser="mybrowser --new-tab"' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    "$FW_BIN" create feat
    export FW_TEST_GH_PR_JSON="$(pr_json 55 OPEN false 'Feat')"

    run "$FW_BIN" pr open feat
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/browser.log")" = "--new-tab https://github.com/owner/repo/pull/55" ]
}

@test "fw pr open: treats a non-command default_browser as a macOS open -a app name" {
    # A default_browser that isn't an executable on PATH (e.g. a macOS app name
    # like "Google Chrome") must route through `open -a "<app>"` instead of
    # being word-split and exec'd as a command (which would exit 127).
    echo 'default_browser="Some Browser"' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    "$FW_BIN" create feat
    export FW_TEST_GH_PR_JSON="$(pr_json 66 OPEN false 'Feat')"
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"

    run "$FW_BIN" pr open feat
    [ "$status" -eq 0 ]
    [ "$(cat "$FW_TEST_OPEN_LOG")" = "-a Some Browser https://github.com/owner/repo/pull/66" ]
}

@test "fw pr: defaults to open when no subcommand is given" {
    "$FW_BIN" create feat
    export FW_TEST_GH_PR_JSON="$(pr_json 99 OPEN false 'Feat')"
    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"

    run "$FW_BIN" pr feat
    [ "$status" -eq 0 ]
    grep -q 'pull/99' "$FW_TEST_OPEN_LOG"
}

@test "fw pr: bare invocation reaches pr-open (no silent death)" {
    # From the repo root (not a worktree): the shift guard must let cmd_pr
    # reach _gh_resolve_target, which then reports it can't detect a worktree.
    run "$FW_BIN" pr
    [ "$status" -ne 0 ]
    [[ "$output" == *"not inside a worktree"* ]]
}

@test "fw pr: an unknown subcommand errors instead of misrouting to a branch target" {
    # `diff` is neither a worktree nor an existing branch, so cmd_pr must not
    # treat it as a branch target (which yields the misleading
    # "no PR found for branch 'diff'"); it should name the valid subcommands.
    "$FW_BIN" create feat
    run "$FW_BIN" pr diff
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown pr subcommand"*"diff"* ]]
    [[ "$output" != *"no PR found for branch 'diff'"* ]]
}

# --- pr assign ---

@test "fw pr assign: roster exact match by alias assigns via gh pr edit" {
    "$FW_BIN" create feat
    printf 'team_members=("vince:binaryseed" "me:axelson:jason")\n' \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GH_PR_JSON="$(pr_json 42 OPEN false 'Add feature')"
    export FW_TEST_GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"

    run "$FW_BIN" pr assign vince feat
    [ "$status" -eq 0 ]
    [[ "$output" == *"binaryseed"* ]]
    grep -q 'pr edit.*--add-assignee binaryseed' "$FW_TEST_GH_LOG"
    # An exact match never opens the picker.
    [ ! -f "$FW_TEST_FZF_LOG" ]
}

@test "fw pr assign: roster exact match by github login assigns that login" {
    "$FW_BIN" create feat
    printf 'team_members=("vince:binaryseed" "me:axelson:jason")\n' \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GH_PR_JSON="$(pr_json 42 OPEN false 'Add feature')"
    export FW_TEST_GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"

    run "$FW_BIN" pr assign axelson feat
    [ "$status" -eq 0 ]
    grep -q 'pr edit.*--add-assignee axelson' "$FW_TEST_GH_LOG"
    [ ! -f "$FW_TEST_FZF_LOG" ]
}

@test "fw pr assign: unmatched arg falls through to the roster picker seeded as query" {
    "$FW_BIN" create feat
    printf 'team_members=("vince:binaryseed" "me:axelson:jason")\n' \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GH_PR_JSON="$(pr_json 42 OPEN false 'Add feature')"
    export FW_TEST_GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
    export FW_TEST_FZF_SELECT="me (axelson)"

    run "$FW_BIN" pr assign nomatch feat
    [ "$status" -eq 0 ]
    # Roster lines are "alias (github)".
    grep -q 'vince (binaryseed)' "$BATS_TEST_TMPDIR/offered"
    grep -q 'me (axelson)' "$BATS_TEST_TMPDIR/offered"
    # The unmatched arg seeds the picker query.
    grep -q -- '--query nomatch' "$FW_TEST_FZF_LOG"
    grep -q 'pr edit.*--add-assignee axelson' "$FW_TEST_GH_LOG"
}

@test "fw pr assign: cancelling the picker assigns nobody" {
    "$FW_BIN" create feat
    printf 'team_members=("vince:binaryseed" "me:axelson:jason")\n' \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GH_PR_JSON="$(pr_json 42 OPEN false 'Add feature')"
    export FW_TEST_GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    export FW_TEST_FZF_CANCEL=1

    run "$FW_BIN" pr assign nomatch feat
    [ "$status" -eq 0 ]
    [ ! -f "$FW_TEST_GH_LOG" ] || ! grep -q 'pr edit' "$FW_TEST_GH_LOG"
}

@test "fw pr assign: empty roster falls back to gh collaborators" {
    "$FW_BIN" create feat
    # team_members left at its empty default.
    export FW_TEST_GH_PR_JSON="$(pr_json 42 OPEN false 'Add feature')"
    export FW_TEST_GH_COLLABORATORS_JSON='[{"login":"octocat"},{"login":"hubber"}]'
    export FW_TEST_GH_LOG="$BATS_TEST_TMPDIR/gh.log"

    run "$FW_BIN" pr assign octocat feat
    [ "$status" -eq 0 ]
    grep -q 'pr edit.*--add-assignee octocat' "$FW_TEST_GH_LOG"
}

@test "fw pr assign: empty-roster picker offers bare collaborator logins" {
    "$FW_BIN" create feat
    export FW_TEST_GH_PR_JSON="$(pr_json 42 OPEN false 'Add feature')"
    export FW_TEST_GH_COLLABORATORS_JSON='[{"login":"octocat"},{"login":"hubber"}]'
    export FW_TEST_GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_SELECT="hubber"

    run "$FW_BIN" pr assign zzz feat
    [ "$status" -eq 0 ]
    grep -qx 'octocat' "$BATS_TEST_TMPDIR/offered"
    grep -qx 'hubber' "$BATS_TEST_TMPDIR/offered"
    grep -q 'pr edit.*--add-assignee hubber' "$FW_TEST_GH_LOG"
}

@test "fw pr assign: draft PR warns and assigns when confirmed" {
    "$FW_BIN" create feat
    printf 'team_members=("vince:binaryseed")\n' \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GH_PR_JSON="$(pr_json 42 OPEN true 'Draft feature')"
    export FW_TEST_GH_LOG="$BATS_TEST_TMPDIR/gh.log"

    run bash -c "printf 'y\n' | '$FW_BIN' pr assign vince feat"
    [ "$status" -eq 0 ]
    [[ "$output" == *"draft"* ]]
    grep -q 'pr edit.*--add-assignee binaryseed' "$FW_TEST_GH_LOG"
}

@test "fw pr assign: draft PR declined assigns nobody" {
    "$FW_BIN" create feat
    printf 'team_members=("vince:binaryseed")\n' \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GH_PR_JSON="$(pr_json 42 OPEN true 'Draft feature')"
    export FW_TEST_GH_LOG="$BATS_TEST_TMPDIR/gh.log"

    run bash -c "printf 'n\n' | '$FW_BIN' pr assign vince feat"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cancelled"* ]]
    ! grep -q 'pr edit' "$FW_TEST_GH_LOG"
}

@test "fw pr assign: rejects an unknown flag" {
    "$FW_BIN" create feat
    run "$FW_BIN" pr assign --bogus feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"nknown flag"* ]]
}

@test "fw pr assign: errors when the branch has no PR" {
    "$FW_BIN" create feat
    # FW_TEST_GH_PR_JSON unset -> the shim reports no PR
    run "$FW_BIN" pr assign vince feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"No PR"* || "$output" == *"no PR"* ]]
}

@test "fw pr assign: paginates the collaborator fallback" {
    "$FW_BIN" create feat
    export FW_TEST_GH_PR_JSON="$(pr_json 42 OPEN false 'Add feature')"
    export FW_TEST_GH_COLLABORATORS_JSON='[{"login":"octocat"}]'
    export FW_TEST_GH_LOG="$BATS_TEST_TMPDIR/gh.log"

    run "$FW_BIN" pr assign octocat feat
    [ "$status" -eq 0 ]
    grep -q -- '--paginate' "$FW_TEST_GH_LOG"
}

@test "fw pr assign: a collaborator-list failure is reported distinctly" {
    "$FW_BIN" create feat
    export FW_TEST_GH_PR_JSON="$(pr_json 42 OPEN false 'Add feature')"
    export FW_TEST_GH_COLLABORATORS_EXIT=1

    run "$FW_BIN" pr assign octocat feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"failed to list"*"collaborators"* ]]
    [[ "$output" != *"no assignee candidates"* ]]
}

@test "fw pr assign: draft confirm accepts an uppercase Y" {
    "$FW_BIN" create feat
    printf 'team_members=("vince:binaryseed")\n' \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GH_PR_JSON="$(pr_json 42 OPEN true 'Draft feature')"
    export FW_TEST_GH_LOG="$BATS_TEST_TMPDIR/gh.log"

    run bash -c "printf 'Y\n' | '$FW_BIN' pr assign vince feat"
    [ "$status" -eq 0 ]
    grep -q 'pr edit.*--add-assignee binaryseed' "$FW_TEST_GH_LOG"
}

@test "fw pr assign: draft confirm on closed stdin declines cleanly" {
    "$FW_BIN" create feat
    printf 'team_members=("vince:binaryseed")\n' \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GH_PR_JSON="$(pr_json 42 OPEN true 'Draft feature')"
    export FW_TEST_GH_LOG="$BATS_TEST_TMPDIR/gh.log"

    run bash -c "'$FW_BIN' pr assign vince feat </dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cancelled"* ]]
    [ ! -f "$FW_TEST_GH_LOG" ] || ! grep -q 'pr edit' "$FW_TEST_GH_LOG"
}

@test "fw pr assign: a malformed roster entry is not offered as a picker line" {
    "$FW_BIN" create feat
    printf 'team_members=("::" "vince:binaryseed")\n' \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_GH_PR_JSON="$(pr_json 42 OPEN false 'Add feature')"
    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_CANCEL=1

    run "$FW_BIN" pr assign nomatch feat
    [ "$status" -eq 0 ]
    grep -q 'vince (binaryseed)' "$BATS_TEST_TMPDIR/offered"
    # The malformed "::" entry must never yield a selectable " ()" line.
    ! grep -q ' ()' "$BATS_TEST_TMPDIR/offered"
}
