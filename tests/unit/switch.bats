load ../test_helper

setup() {
    isolate_env
    source "$FW_ROOT/lib/colors.sh"
    source "$FW_ROOT/lib/config.sh"
    source "$FW_ROOT/lib/switch.sh"
    source "$FW_ROOT/lib/worktree.sh"
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    load_config myproj
    mkdir -p "$worktrees_dir"
}

# make_wt <name> — a worktree dir the candidate builder will accept: it exists
# and carries an env file (so worktree_names_branches lists it under --all).
make_wt() {
    mkdir -p "$worktrees_dir/$1"
    printf 'WT_BRANCH=me/%s\n' "$1" >"$worktrees_dir/$1/$env_file"
}

# Recency + worktrees fixture shared by the tests below:
#   alpha  viewed most recently, beta earlier, stale 30d ago (past the window),
#   gamma  a real worktree never switched-to, ghost a recency row with no dir.
seed_fixture() {
    make_wt alpha; make_wt beta; make_wt gamma; make_wt stale
    local now
    now="$(date +%s)"
    {
        printf '%s\tbeta\n'  "$((now - 200))"
        printf '%s\talpha\n' "$((now - 100))"
        printf '%s\tghost\n' "$((now - 50))"
        printf '%s\tstale\n' "$((now - 30 * 86400))"
    } >"$worktrees_dir/.fw_recent"
}

# line_index <name> <output> — 1-based line number of an exact name, or empty.
line_index() { printf '%s\n' "$2" | grep -nx "$1" | cut -d: -f1; }

@test "record_project_visit: appends a <ts>\\t<name> row to project_log" {
    local log="$FW_CONFIG_DIR/project_log"
    [ ! -f "$log" ]

    record_project_visit newproj

    [ -f "$log" ]
    run awk -F'\t' '$2 == "newproj" && $1 ~ /^[0-9]+$/ { found=1 } END { exit !found }' "$log"
    [ "$status" -eq 0 ]
}

@test "_switch_reload_cmd: pins the resolved binary and project, forwards --all" {
    FW_SELF="/opt/tools/fast-worktree"
    run _switch_reload_cmd false
    [ "$status" -eq 0 ]
    [[ "$output" == "FW_COLOR=always "* ]]
    [[ "$output" == *"/opt/tools/fast-worktree"* ]]
    # The active project is pinned so the phase-2 subprocess enriches the same
    # project phase 1 listed, instead of re-resolving from the reload's cwd.
    [[ "$output" == *"-p myproj _switch-data"* ]]
    [[ "$output" != *"--all"* ]]

    run _switch_reload_cmd true
    [[ "$output" == *"_switch-data --all"* ]]
}

@test "_switch_reload_cmd: a binary path with a space survives shell re-parsing" {
    FW_SELF="/opt/my tools/fast-worktree"
    run _switch_reload_cmd false
    [ "$status" -eq 0 ]
    # fzf runs the reload via sh -c, so the path must be quoted: a shell that
    # re-splits the command keeps the binary as a single token, not "/opt/my".
    run bash -c "args=($output); printf '%s' \"\${args[1]}\""
    [ "$output" = "/opt/my tools/fast-worktree" ]
}

@test "_switch_candidates: windowed — main first, recency order, window+dir filtered" {
    seed_fixture
    run _switch_candidates false
    [ "$status" -eq 0 ]
    # main is always the first candidate.
    [ "$(printf '%s\n' "$output" | sed -n 1p)" = "main" ]
    # most-recently-viewed first: alpha before beta.
    [ "$(line_index alpha "$output")" -lt "$(line_index beta "$output")" ]
    # stale is past switch_recent_days; ghost has no worktree dir.
    ! grep -qx stale <<<"$output"
    ! grep -qx ghost <<<"$output"
    # gamma was never viewed — absent without --all.
    ! grep -qx gamma <<<"$output"
}

@test "_switch_candidates: --all — drops the window, appends never-viewed last" {
    seed_fixture
    run _switch_candidates true
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | sed -n 1p)" = "main" ]
    # window filter is gone: stale (30d) now appears.
    grep -qx stale <<<"$output"
    # never-viewed gamma is appended after the recency-ordered names.
    grep -qx gamma <<<"$output"
    [ "$(line_index stale "$output")" -lt "$(line_index gamma "$output")" ]
    # ghost still dropped — no worktree dir backs it.
    ! grep -qx ghost <<<"$output"
}

@test "_switch_refresh_secs: numeric as-is, 0/empty disable, non-numeric -> 10" {
    switch_refresh_secs=10; [ "$(_switch_refresh_secs)" = 10 ]
    switch_refresh_secs=3;  [ "$(_switch_refresh_secs)" = 3 ]
    switch_refresh_secs=0;  [ "$(_switch_refresh_secs)" = 0 ]
    switch_refresh_secs="";  [ "$(_switch_refresh_secs)" = 0 ]
    switch_refresh_secs=abc; [ "$(_switch_refresh_secs)" = 10 ]
    switch_refresh_secs=1.5; [ "$(_switch_refresh_secs)" = 10 ]
    switch_refresh_secs='5; rm -rf /'; [ "$(_switch_refresh_secs)" = 10 ]
}

@test "cmd_switch_refresh: empty cache regenerates and populates it" {
    make_wt alpha
    local cache="$BATS_TEST_TMPDIR/cache"
    run cmd_switch_refresh --secs 10 --cache "$cache"
    [ "$status" -eq 0 ]
    # Enriched rows came back (main is always a candidate)...
    printf '%s\n' "$output" | grep -q "main"
    # ...and the cache is now populated for subsequent refresh cycles.
    [ -s "$cache" ]
}

@test "cmd_switch_refresh: a fresh cache is served verbatim (no regeneration)" {
    local cache="$BATS_TEST_TMPDIR/cache"
    printf 'SENTINEL-ROW\tsentinel\n' >"$cache"
    date +%s >"$cache.ts"
    # secs=1 so the pacing sleep is at most ~1s; a fresh cache must be returned
    # as-is rather than rebuilt from the real worktrees.
    run cmd_switch_refresh --secs 1 --cache "$cache"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'SENTINEL-ROW\tsentinel')" ]
}

@test "cmd_switch_refresh: a stale cache is regenerated" {
    make_wt alpha
    local cache="$BATS_TEST_TMPDIR/cache"
    printf 'SENTINEL-ROW\tsentinel\n' >"$cache"
    printf '%s\n' "$(( $(date +%s) - 100 ))" >"$cache.ts"
    run cmd_switch_refresh --secs 10 --cache "$cache"
    [ "$status" -eq 0 ]
    # The stale sentinel is gone, replaced by real enriched rows.
    ! printf '%s\n' "$output" | grep -q "SENTINEL-ROW"
    printf '%s\n' "$output" | grep -q "main"
}

@test "cmd_switch_refresh: without --cache it is a plain one-shot enrichment" {
    make_wt alpha
    run cmd_switch_refresh --secs 10
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q "main"
    # No cache files were created anywhere we pointed it (there was no --cache).
    [ ! -e "$BATS_TEST_TMPDIR/cache" ]
}
