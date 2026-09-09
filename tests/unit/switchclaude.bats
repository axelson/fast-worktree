load ../test_helper

# Unit tests for the pure-ish helpers behind `fw switch-claude`
# (lib/switchclaude.sh): cwd→project/worktree location, the live-session
# registry parse, age-band coloring, and the nested row builder. The switch
# action and end-to-end command are covered in tests/integration/switch_claude.bats.

setup() {
    isolate_env
    source "$FW_ROOT/lib/colors.sh"
    source "$FW_ROOT/lib/config.sh"
    source "$FW_ROOT/lib/project.sh"
    source "$FW_ROOT/lib/switchclaude.sh"

    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"

    export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
    export FW_COLOR=never
    fw_color_init
}

# seed_session <file> <pid> <cwd> <status> <age-secs> <tmux> <name> — write one
# registry file. The registry keys files by pid, but our reader takes pid from
# the JSON body, so the file name is free (lets several live rows share $$).
seed_session() {
    local dir="$CLAUDE_CONFIG_DIR/sessions"
    mkdir -p "$dir"
    local supd=$(( ( $(date +%s) - $5 ) * 1000 ))
    cat >"$dir/$1.json" <<EOF
{"pid":$2,"cwd":"$3","status":"$4","statusUpdatedAt":$supd,"updatedAt":$supd,"tmux":"$6","name":"$7"}
EOF
}

@test "_swc_locate: a repo_root maps to main" {
    run _swc_locate "$BATS_TEST_TMPDIR/myrepo"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'myproj\tmain')" ]
}

@test "_swc_locate: a worktree path maps to its name" {
    run _swc_locate "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'myproj\talpha')" ]
}

@test "_swc_locate: a subdir of a worktree still resolves to the worktree" {
    mkdir -p "$BATS_TEST_TMPDIR/myproj-worktrees/alpha/lib/deep"
    run _swc_locate "$BATS_TEST_TMPDIR/myproj-worktrees/alpha/lib/deep"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'myproj\talpha')" ]
}

@test "_swc_locate: a path outside every project returns non-zero" {
    run _swc_locate "$BATS_TEST_TMPDIR/somewhere-else"
    [ "$status" -ne 0 ]
}

# _pt_index <project> — echo the index of <project> in the built project table
# (parallel arrays _SWC_PT_NAME/_ROOT/_WTDIR), or return non-zero if absent.
_pt_index() {
    local i
    for i in "${!_SWC_PT_NAME[@]}"; do
        [[ "${_SWC_PT_NAME[$i]}" == "$1" ]] && { echo "$i"; return 0; }
    done
    return 1
}

@test "_swc_build_project_table: matches the per-project helpers, incl. a stale repo_root" {
    # a project with an explicit worktrees_dir (not the <parent>/<name>-worktrees default)
    make_repo "$BATS_TEST_TMPDIR/wtrepo"
    register_project withwt "$BATS_TEST_TMPDIR/wtrepo"
    mkdir -p "$BATS_TEST_TMPDIR/custom-wts"
    printf 'worktrees_dir=%q\n' "$BATS_TEST_TMPDIR/custom-wts" \
        >>"$FW_CONFIG_DIR/projects/withwt/config.sh"
    # an explicit worktrees_dir that does NOT exist: realpath fails, so the
    # helper keeps the literal path (distinct from the empty-on-failure repo_root).
    make_repo "$BATS_TEST_TMPDIR/missingwt-repo"
    register_project missingwt "$BATS_TEST_TMPDIR/missingwt-repo"
    printf 'worktrees_dir=%q\n' "$BATS_TEST_TMPDIR/no-such-wts" \
        >>"$FW_CONFIG_DIR/projects/missingwt/config.sh"
    # a project whose repo_root does not exist on disk: realpath fails, so
    # _project_repo_root yields empty and the default worktrees_dir yields empty.
    register_project stale "$BATS_TEST_TMPDIR/does-not-exist/ghost"

    _swc_build_project_table

    # every project's cached root+wtdir equals what the standalone helpers derive
    local p i
    for p in myproj withwt missingwt stale; do
        i="$(_pt_index "$p")"
        [ -n "$i" ]
        [ "${_SWC_PT_ROOT[$i]}"  = "$(_project_repo_root "$p")" ]
        [ "${_SWC_PT_WTDIR[$i]}" = "$(_swc_project_worktrees_dir "$p")" ]
    done
    # the stale project's realpath-failed root is empty (the edge the fast path must preserve)
    i="$(_pt_index stale)"
    [ -z "${_SWC_PT_ROOT[$i]}" ]
    [ -z "${_SWC_PT_WTDIR[$i]}" ]
}

@test "_swc_current_project: a repo_root cwd resolves to its project" {
    run _swc_current_project "$BATS_TEST_TMPDIR/myrepo"
    [ "$status" -eq 0 ]
    [ "$output" = "myproj" ]
}

@test "_swc_current_project: a worktree cwd resolves to its project" {
    run _swc_current_project "$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
    [ "$status" -eq 0 ]
    [ "$output" = "myproj" ]
}

@test "_swc_current_project: a cwd outside every project returns non-zero" {
    unset FW_PROJECT
    run _swc_current_project "$BATS_TEST_TMPDIR/somewhere-else"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "_swc_current_project: falls back to a REGISTERED FW_PROJECT when the cwd maps nowhere" {
    FW_PROJECT=myproj run _swc_current_project "$BATS_TEST_TMPDIR/somewhere-else"
    [ "$status" -eq 0 ]
    [ "$output" = "myproj" ]
}

@test "_swc_current_project: an unregistered FW_PROJECT does not resolve" {
    FW_PROJECT=ghost run _swc_current_project "$BATS_TEST_TMPDIR/somewhere-else"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "_swc_sessions_tsv: a target project drops other projects' sessions" {
    make_repo "$BATS_TEST_TMPDIR/otherrepo"
    register_project other "$BATS_TEST_TMPDIR/otherrepo"
    mkdir -p "$BATS_TEST_TMPDIR/other-worktrees/beta"

    seed_session mine  "$$" "$BATS_TEST_TMPDIR/myrepo" idle 30 "s:@1.%1" mine
    seed_session their "$$" "$BATS_TEST_TMPDIR/other-worktrees/beta" idle 40 "s:@2.%2" their

    run _swc_sessions_tsv "$(date +%s)" myproj
    [ "$status" -eq 0 ]
    # only myproj's session survives the target filter
    echo "$output" | awk -F'\t' '$1=="myproj" {f=1} END{exit !f}'
    ! echo "$output" | awk -F'\t' '$1=="other"' | grep -q .
}

@test "_swc_empty_rows: a project header and a non-selectable placeholder" {
    run _swc_empty_rows myproj
    [ "$status" -eq 0 ]
    # first line is the project header, marker H
    [ "$(printf '%s\n' "$output" | sed -n 1p | cut -f1)" = "myproj" ]
    [ "$(printf '%s\n' "$output" | sed -n 1p | cut -f2)" = "H" ]
    # second line is the placeholder message, also marker H (a no-op on pick)
    printf '%s\n' "$output" | sed -n 2p | cut -f1 | grep -q "no active claude sessions"
    [ "$(printf '%s\n' "$output" | sed -n 2p | cut -f2)" = "H" ]
    # nothing is selectable (no S rows)
    ! printf '%s\n' "$output" | awk -F'\t' '$2=="S"' | grep -q .
}

@test "_swc_color_age: idle bands and status colors" {
    export FW_COLOR=always
    fw_color_init
    [ "$(_swc_color_age idle 1800)" = "" ]          # 30m  < 45m  -> default
    [ "$(_swc_color_age idle 3000)" = "$C_ORANGE" ] # 50m  in 45m-1h -> warning
    [ "$(_swc_color_age idle 7200)" = "$C_BLUE" ]   # 2h   in 1h-1d  -> blue
    [ "$(_swc_color_age idle 200000)" = "" ]        # >1d          -> default
    [ "$(_swc_color_age waiting 999999)" = "$C_RED" ]
    [ "$(_swc_color_age busy 5)" = "$C_GREEN" ]
}

@test "_swc_fmt_age: compact buckets" {
    [ "$(_swc_fmt_age 30)" = "now" ]
    [ "$(_swc_fmt_age 120)" = "2m" ]
    [ "$(_swc_fmt_age 7200)" = "2hr" ]
    [ "$(_swc_fmt_age 172800)" = "2d" ]
}

@test "_swc_sessions_tsv: keeps live fw sessions, drops dead and foreign ones" {
    seed_session live "$$" "$BATS_TEST_TMPDIR/myrepo" idle 65 "s:@1.%1" main-sess
    seed_session dead 2147480000 "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" busy 5 "s:@2.%2" dead-sess
    seed_session foreign "$$" "$BATS_TEST_TMPDIR/somewhere-else" idle 10 "" foreign-sess

    run _swc_sessions_tsv "$(date +%s)"
    [ "$status" -eq 0 ]
    # the live main session is present with its mapped project/worktree/status
    echo "$output" | awk -F'\t' '$1=="myproj" && $2=="main" && $3=="idle" {f=1} END{exit !f}'
    # the dead-pid session was dropped
    ! echo "$output" | grep -q dead-sess
    # the session outside every project was dropped
    ! echo "$output" | grep -q foreign-sess
}

@test "_swc_sessions_tsv: a malformed registry file does not sink the good ones" {
    # Registry files are written live by running claude processes, so `sc` can
    # catch a half-written file. A batched jq over all files would abort on the
    # first parse error and drop everything; the reader must still surface every
    # well-formed session (one bad file drops only itself).
    seed_session good1 "$$" "$BATS_TEST_TMPDIR/myrepo" idle 30 "s:@1.%1" g1
    seed_session good2 "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" busy 5 "s:@2.%2" g2
    printf '{ half-written not json\n' >"$CLAUDE_CONFIG_DIR/sessions/aaa-broken.json"

    run _swc_sessions_tsv "$(date +%s)"
    [ "$status" -eq 0 ]
    # both well-formed sessions survive the broken sibling
    echo "$output" | awk -F'\t' '$1=="myproj" && $2=="main"  {f=1} END{exit !f}'
    echo "$output" | awk -F'\t' '$1=="myproj" && $2=="alpha" {f=1} END{exit !f}'
}

@test "_swc_build_rows: nests multi-session worktrees and floats waiting projects first" {
    make_repo "$BATS_TEST_TMPDIR/otherrepo"
    register_project other "$BATS_TEST_TMPDIR/otherrepo"
    mkdir -p "$BATS_TEST_TMPDIR/other-worktrees/beta"

    seed_session m  "$$" "$BATS_TEST_TMPDIR/myrepo" idle 30 "myproj-main:@1.%1" m
    seed_session a1 "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" idle 40 "myproj-alpha:@2.%2" agent-a
    seed_session a2 "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" idle 50 "myproj-alpha:@3.%3" agent-b
    seed_session b  "$$" "$BATS_TEST_TMPDIR/other-worktrees/beta" waiting 12 "other-beta:@4.%4" b

    run _swc_build_rows
    [ "$status" -eq 0 ]

    # the project holding a waiting session floats to the very top
    [ "$(printf '%s\n' "$output" | sed -n 1p | cut -f1)" = "other" ]
    # four selectable session rows (marker S in field 2): main, alpha x2, beta
    [ "$(printf '%s\n' "$output" | awk -F'\t' '$2=="S"' | wc -l | tr -d ' ')" = "4" ]
    # the two-session worktree draws a tree
    printf '%s\n' "$output" | grep -q "├"
    printf '%s\n' "$output" | grep -q "└"
    # a project header is a selectable P row keyed to the project's main worktree
    printf '%s\n' "$output" | awk -F'\t' '$2=="P" && $4=="other" && $5=="main"' | grep -q .
    printf '%s\n' "$output" | awk -F'\t' '$2=="P" && $4=="myproj" && $5=="main"' | grep -q .
    # the multi-session worktree's sub-header is a selectable W row keyed to it
    printf '%s\n' "$output" | awk -F'\t' '$2=="W" && $4=="myproj" && $5=="alpha"' | grep -q .
    # no bare H headers remain among the live rows (only P/W/S)
    ! printf '%s\n' "$output" | awk -F'\t' '$2=="H"' | grep -q .
}

# _swc_pos_rows — the fabricated picker rows shared by the _swc_pos_for cases:
# proj1 (header, one session wtA) then proj2 (header, one session wtB).
#   line 1  proj1 header (P)
#   line 2  proj1/wtA session (S, pane %1)
#   line 3  proj2 header (P)
#   line 4  proj2/wtB session (S, pane %9)
_swc_pos_rows() {
    printf '%s\n' \
        "proj1"$'\t'"P"$'\t'$'\t'"proj1"$'\t'"main" \
        "  wtA"$'\t'"S"$'\t'"s:@1.%1"$'\t'"proj1"$'\t'"wtA" \
        "proj2"$'\t'"P"$'\t'$'\t'"proj2"$'\t'"main" \
        "  wtB"$'\t'"S"$'\t'"s:@9.%9"$'\t'"proj2"$'\t'"wtB"
}

@test "_swc_pos_for: the current pane's session wins over worktree and project" {
    # pane %9 is proj2/wtB (line 4); current project/worktree point at proj1/wtA
    # (which would otherwise select line 2, then line 1) — the pane still wins.
    run _swc_pos_for "$(_swc_pos_rows)" "%9" "proj1" "wtA"
    [ "$status" -eq 0 ]
    [ "$output" = "4" ]
}

@test "_swc_pos_for: the current worktree's session beats the project header" {
    # no pane match; cwd is in proj2/wtB -> its session (line 4), not the proj2
    # header (line 3).
    run _swc_pos_for "$(_swc_pos_rows)" "%none" "proj2" "wtB"
    [ "$status" -eq 0 ]
    [ "$output" = "4" ]
}

@test "_swc_pos_for: no worktree session falls back to the current project's header" {
    # cwd is in proj2/main, which has no session row -> the proj2 header (line 3).
    run _swc_pos_for "$(_swc_pos_rows)" "%none" "proj2" "main"
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
    # and with no worktree at all, still the project header
    run _swc_pos_for "$(_swc_pos_rows)" "%none" "proj2" ""
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

@test "_swc_pos_for: no pane, worktree, or matching project prints nothing (top fallback)" {
    run _swc_pos_for "$(_swc_pos_rows)" "" "" ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # a project not in the rows
    run _swc_pos_for "$(_swc_pos_rows)" "" "ghost" "ghostwt"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_swc_build_rows: an empty tmux field does not shift name into pane" {
    # A session started outside tmux has an empty pane, mid-row. It must keep its
    # name label and leave the pane empty (so the switch routes to the fallback),
    # not swallow the name — the classic IFS-tab coalescing trap.
    seed_session a1 "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" idle 40 "myproj-alpha:@2.%2" agent-a
    seed_session a2 "$$" "$BATS_TEST_TMPDIR/myproj-worktrees/alpha" idle 50 "" agent-b

    run _swc_build_rows
    [ "$status" -eq 0 ]
    # both names render as labels — agent-b is not swallowed
    printf '%s\n' "$output" | grep -q "agent-a"
    printf '%s\n' "$output" | grep -q "agent-b"
    # the no-tmux row's key carries an empty pane (field 3 of a session row)
    printf '%s\n' "$output" | awk -F'\t' '$2=="S" && $1 ~ /agent-b/ { print "["$3"]" }' | grep -q '^\[\]$'
}
