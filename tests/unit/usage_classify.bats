load ../test_helper

setup() {
    isolate_env
    source "$FW_ROOT/lib/config.sh"
    source "$FW_ROOT/lib/usage.sh"
    _config_defaults
    branch_prefix=jason
}

# --- config surface ---

@test "config defaults: the usage classification seams are declared, felt-neutral" {
    # declare -p, not ${#…}: an undeclared array also reads as empty, which
    # would let this pass before the defaults exist.
    [[ "$(declare -p usage_own_prefixes)" == "declare -a usage_own_prefixes="* ]]
    [[ "$(declare -p usage_extra_prefixes)" == "declare -a usage_extra_prefixes="* ]]
    [ "${#usage_own_prefixes[@]}" -eq 0 ]
    [ "${#usage_extra_prefixes[@]}" -eq 0 ]
    [ "$usage_tz" = "" ]
}

# --- default classifier ---

@test "classify: the user's own branch prefix is own work" {
    [ "$(_usage_classify_worktree jason-fix-thing)" = "own|branch_prefix" ]
    [ "$(_usage_classify_worktree jason/fix-thing)" = "own|branch_prefix" ]
}

@test "classify: a teammate's alias, github login, or branch prefix is review" {
    team_members=("chris:ChrisLoer:cloer" "me:axelson:jason")
    [ "$(_usage_classify_worktree chris-map-fix)" = "review|branch_prefix" ]
    [ "$(_usage_classify_worktree chrisloer-map-fix)" = "review|branch_prefix" ]
    [ "$(_usage_classify_worktree cloer/map-fix)" = "review|branch_prefix" ]
}

@test "classify: the 'me' roster entry never becomes a review prefix" {
    team_members=("me:axelson:jason")
    [ "$(_usage_classify_worktree axelson-thing)" = "misc|fallback" ]
}

@test "classify: teammate prefixes are checked before the own-work prefixes" {
    team_members=("pat:patuser:fix")
    usage_own_prefixes=(fix)
    [ "$(_usage_classify_worktree fix-a-bug)" = "review|branch_prefix" ]
}

@test "classify: usage_own_prefixes claims own work, globs included" {
    usage_own_prefixes=(claude 'app-[0-9]*')
    [ "$(_usage_classify_worktree claude-refactor)" = "own|branch_prefix" ]
    [ "$(_usage_classify_worktree app-10873-ls-tables)" = "own|branch_prefix" ]
    [ "$(_usage_classify_worktree app-10873)" = "own|branch_prefix" ]
    [ "$(_usage_classify_worktree apples-and-pears)" = "misc|fallback" ]
}

@test "classify: usage_extra_prefixes assigns the configured category" {
    usage_extra_prefixes=("cloer:review" "worktree:review" "spike:misc")
    [ "$(_usage_classify_worktree cloer-tiles)" = "review|extra_prefix" ]
    [ "$(_usage_classify_worktree worktree/pr-123)" = "review|extra_prefix" ]
    [ "$(_usage_classify_worktree spike-idea)" = "misc|extra_prefix" ]
}

@test "classify: an unrecognized name falls back to misc, eligible for reclassification" {
    [ "$(_usage_classify_worktree some-random-branch)" = "misc|fallback" ]
}

# --- hook contract ---

@test "classify: a hook that claims the session wins over the default" {
    hook_usage_classify() { echo "ignore|numbered_worktree"; }
    [ "$(_usage_classify_worktree 42)" = "ignore|numbered_worktree" ]
}

@test "classify: a hook that declines falls through to the default classifier" {
    hook_usage_classify() { [[ "$1" == exp-* ]] && { echo "misc|experiment"; return 0; }; return 1; }
    [ "$(_usage_classify_worktree exp-thing)" = "misc|experiment" ]
    [ "$(_usage_classify_worktree jason-thing)" = "own|branch_prefix" ]
}

@test "classify: a hook category outside own|review|misc|ignore is a loud error" {
    hook_usage_classify() { echo "urgent|whatever"; }
    run _usage_classify_worktree some-worktree
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
    [[ "$output" == *"hook_usage_classify"* ]]
    [[ "$output" == *"urgent"* ]]
}

@test "classify: a hook claim without a source field is a loud error" {
    hook_usage_classify() { echo "own"; }
    run _usage_classify_worktree some-worktree
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
}

@test "classify: a hook claim with empty output is a loud error" {
    hook_usage_classify() { echo ""; }
    run _usage_classify_worktree some-worktree
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
}

# --- timezone ---

@test "usage_tz: an offset:label pair sets the display zone" {
    usage_tz="-10:HST"
    _usage_load_tz
    [ "$USAGE_TZ_LABEL" = "HST" ]
    [ "$USAGE_TZ_MINUTES" -eq -600 ]
}

@test "usage_tz: an empty setting reads the system zone once per run" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/date" <<'EOF'
#!/bin/sh
echo "$1 called" >>"$DATE_CALLS"
case "$1" in
    +%z) echo "-0500" ;;
    +%Z) echo "EST" ;;
    *) exec /bin/date "$@" ;;
esac
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/date"
    export DATE_CALLS="$BATS_TEST_TMPDIR/date.log"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"

    usage_tz=""
    _usage_load_tz
    _usage_load_tz
    [ "$USAGE_TZ_LABEL" = "EST" ]
    [ "$USAGE_TZ_MINUTES" -eq -300 ]
    [ "$(grep -c '+%z called' "$DATE_CALLS")" -eq 1 ]
}

@test "usage_tz: a half-hour zone keeps its minutes" {
    usage_tz="+0530:IST"
    _usage_load_tz
    [ "$USAGE_TZ_MINUTES" -eq 330 ]
}

@test "usage_tz: a malformed setting is a loud error" {
    usage_tz="banana"
    run _usage_load_tz
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
    [[ "$output" == *"usage_tz"* ]]
}

@test "usage_tz: an offset without a label is a loud error" {
    usage_tz="-10"
    run _usage_load_tz
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage_tz"* ]]
}

@test "_usage_since_utc: a local calendar date becomes the UTC instant it begins" {
    command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"
    usage_tz="-10:HST"
    [ "$(_usage_since_utc 2026-08-18)" = "2026-08-18T10:00:00Z" ]
}

@test "_usage_since_utc: an eastern-of-UTC zone rolls back to the previous day" {
    command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"
    usage_tz="+0530:IST"
    [ "$(_usage_since_utc 2026-08-18)" = "2026-08-17T18:30:00Z" ]
}

@test "_usage_local_sql: renders stored UTC in the display zone" {
    command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"
    usage_tz="-10:HST"
    _usage_load_tz
    run sqlite3 :memory: "SELECT $(_usage_local_sql "'2026-08-18T10:00:00Z'");"
    [ "$output" = "2026-08-18 00:00:00" ]
}

@test "_usage_compute_since: --period resolves to a local calendar date" {
    [ "$(_usage_compute_since "" all)" = "2020-01-01" ]
    [ "$(_usage_compute_since 2026-01-02 30d)" = "2026-01-02" ]
    [[ "$(_usage_compute_since "" 7d)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

@test "_usage_compute_since: a malformed --since is a loud error" {
    run _usage_compute_since "last tuesday" 30d
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
}

@test "_usage_compute_since: a malformed --period is a loud error" {
    run _usage_compute_since "" 7days
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
}

@test "_usage_compute_since: a period-shaped --since points at --period" {
    run _usage_compute_since "1d" 30d
    [ "$status" -ne 0 ]
    [[ "$output" == *"--period"* ]]

    run _usage_compute_since "all" 30d
    [ "$status" -ne 0 ]
    [[ "$output" == *"--period"* ]]
}
