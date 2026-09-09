load ../test_helper

setup() {
    isolate_env
    source "$FW_ROOT/lib/colors.sh"
    source "$FW_ROOT/lib/config.sh"
    source "$FW_ROOT/lib/switch.sh"
    source "$FW_ROOT/lib/worktree.sh"
    source "$FW_ROOT/lib/claude.sh"
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    load_config myproj
    mkdir -p "$worktrees_dir"
}

@test "format_age: buckets seconds into now/m/hr/d/7d+" {
    [ "$(format_age $((1000)) $((1000)))" = "now" ]
    [ "$(format_age $((1000)) $((1000 + 300)))" = "5m" ]
    [ "$(format_age $((1000)) $((1000 + 3 * 3600)))" = "3hr" ]
    [ "$(format_age $((1000)) $((1000 + 2 * 86400)))" = "2d" ]
    [ "$(format_age $((1000)) $((1000 + 30 * 86400)))" = "7d+" ]
}

@test "format_age: empty for a zero/blank timestamp" {
    [ -z "$(format_age 0 12345)" ]
    [ -z "$(format_age '' 12345)" ]
}

# strip_ansi <s> — echo s with CSI color sequences removed, for width asserts.
strip_ansi() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }

@test "format_age_colored: recency buckets pick the legacy colors" {
    FW_COLOR=always fw_color_init
    local now=100000
    # <45m -> bright blue
    [[ "$(format_age_colored $((now - 600)) $now)" == "$C_BLUE_BRIGHT"*"$C_RESET" ]]
    # <1h -> yellow
    [[ "$(format_age_colored $((now - 3000)) $now)" == "$C_YELLOW"*"$C_RESET" ]]
    # <8h -> cyan
    [[ "$(format_age_colored $((now - 7200)) $now)" == "$C_CYAN"*"$C_RESET" ]]
    # >=8h -> neutral (no escape codes at all)
    local old
    old="$(format_age_colored $((now - 20 * 3600)) $now)"
    [ "$old" = "$(strip_ansi "$old")" ]
}

@test "format_age_colored: visible text is padded to 5 columns" {
    FW_COLOR=always fw_color_init
    local now=100000 v
    # colored (<45m) and neutral (>=8h) rows both measure 5 visible columns.
    v="$(strip_ansi "$(format_age_colored $((now - 600)) $now)")"
    [ "${#v}" -eq 5 ]
    v="$(strip_ansi "$(format_age_colored $((now - 20 * 3600)) $now)")"
    [ "${#v}" -eq 5 ]
}

@test "format_age_colored: never-viewed renders a neutral 5-wide dash" {
    FW_COLOR=always fw_color_init
    local out
    out="$(format_age_colored 0 100000)"
    [ "$out" = "$(strip_ansi "$out")" ]      # no color for never-viewed
    [ "${#out}" -eq 5 ]                       # "-" left-padded to width 5
    [[ "$out" == "-"* ]]
}


@test "_mtime_or_0: real mtime for a file, 0 when missing" {
    local f="$worktrees_dir/afile"
    echo hi >"$f"
    local m
    m=$(_mtime_or_0 "$f")
    [[ "$m" =~ ^[0-9]+$ ]]
    [ "$m" -gt 0 ]
    [ "$(_mtime_or_0 "$worktrees_dir/nope")" = "0" ]
}

@test "resolve_model: maps an alias, passes through the unknown" {
    claude_model_aliases=([opus]="claude-opus-4-8[1m]")
    [ "$(resolve_model opus)" = "claude-opus-4-8[1m]" ]
    [ "$(resolve_model some-literal-id)" = "some-literal-id" ]
}

@test "_prompt_flag_for: maps a configured bare flag to its prompt" {
    claude_prompt_flags=([review]="/pr-review")
    [ "$(_prompt_flag_for --review)" = "/pr-review" ]
}

@test "_prompt_flag_for: fails for a flag that isn't configured" {
    claude_prompt_flags=([review]="/pr-review")
    run _prompt_flag_for --nope
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "_parse_claude_flag: --claude passes a literal prompt through (no alias lookup)" {
    claude_prompt_flags=([review]="/pr-review")
    local model="" prompt=""
    _parse_claude_flag model prompt 2 --claude review
    # 'review' is a prompt-flag alias, but --claude no longer resolves it.
    [ "$prompt" = "review" ]
    [ "$_CF_CONSUMED" = 2 ]
}

@test "_claude_wt_display_name: worktree, main, and external" {
    [ "$(_claude_wt_display_name "$worktrees_dir/alpha")" = "alpha" ]
    [ "$(_claude_wt_display_name "$worktrees_dir/alpha/services/app")" = "alpha" ]
    [ "$(_claude_wt_display_name "$repo_root")" = "main" ]
    [ "$(_claude_wt_display_name "$repo_root/sub")" = "main" ]
    [ "$(_claude_wt_display_name "/tmp/elsewhere")" = "elsewhere (external)" ]
}

@test "worktree_name_for_path: names the worktree, or fails outside it" {
    mkdir -p "$worktrees_dir/api" "$worktrees_dir/api-fix"
    [ "$(worktree_name_for_path "$worktrees_dir/api")" = "api" ]
    [ "$(worktree_name_for_path "$worktrees_dir/api/services/app")" = "api" ]
    # A prefix sibling is a different worktree, never a substring match.
    [ "$(worktree_name_for_path "$worktrees_dir/api-fix")" = "api-fix" ]
    run worktree_name_for_path "$repo_root"
    [ "$status" -ne 0 ]
}

@test "last_viewed_ts: returns the most recent switch timestamp" {
    printf '100\talpha\n200\tbeta\n300\talpha\n' >"$worktrees_dir/.fw_recent"
    [ "$(last_viewed_ts alpha)" = "300" ]
    [ "$(last_viewed_ts beta)" = "200" ]
    [ -z "$(last_viewed_ts never)" ]
}

@test "build_claude_status_map: buckets by worktree name, waiting outranks running" {
    FW_TEST_CLAUDE_AGENTS_JSON="$(cat <<JSON
[
  {"cwd": "$worktrees_dir/alpha", "status": "busy"},
  {"cwd": "$worktrees_dir/alpha", "status": "waiting"},
  {"cwd": "$worktrees_dir/beta",  "status": "busy"}
]
JSON
)"
    export FW_TEST_CLAUDE_AGENTS_JSON
    local -A by_wt=()
    build_claude_status_map by_wt
    [ "${by_wt[alpha]}" = "waiting" ]
    [ "${by_wt[beta]}" = "running" ]
    [ "${#by_wt[@]}" -eq 2 ]
}

@test "build_claude_status_map: a session in the golden checkout buckets under main" {
    FW_TEST_CLAUDE_AGENTS_JSON="$(cat <<JSON
[
  {"cwd": "$repo_root",              "status": "busy"},
  {"cwd": "$worktrees_dir/alpha",    "status": "busy"}
]
JSON
)"
    export FW_TEST_CLAUDE_AGENTS_JSON
    local -A by_wt=()
    build_claude_status_map by_wt
    # repo_root is not under worktrees_dir, but the picker renders a main row, so
    # its Claude session must be attributed to "main" (parity with fw claude).
    [ "${by_wt[main]}" = "running" ]
    [ "${by_wt[alpha]}" = "running" ]
}

@test "build_claude_status_map: a session in a repo-root subdir buckets under main" {
    mkdir -p "$repo_root/services/app"
    FW_TEST_CLAUDE_AGENTS_JSON="$(cat <<JSON
[
  {"cwd": "$repo_root/services/app", "status": "waiting"}
]
JSON
)"
    export FW_TEST_CLAUDE_AGENTS_JSON
    local -A by_wt=()
    build_claude_status_map by_wt
    [ "${by_wt[main]}" = "waiting" ]
}

@test "build_claude_status_map: a session outside repo and worktrees is dropped" {
    FW_TEST_CLAUDE_AGENTS_JSON="$(cat <<JSON
[
  {"cwd": "$BATS_TEST_TMPDIR/elsewhere", "status": "busy"}
]
JSON
)"
    export FW_TEST_CLAUDE_AGENTS_JSON
    local -A by_wt=()
    build_claude_status_map by_wt
    [ "${#by_wt[@]}" -eq 0 ]
}

@test "build_claude_status_map: empty when there are no agents" {
    export FW_TEST_CLAUDE_AGENTS_JSON='[]'
    local -A by_wt=()
    build_claude_status_map by_wt
    [ "${#by_wt[@]}" -eq 0 ]
}

@test "_claude_stale_worktrees: keeps never-viewed and old, drops recent" {
    local now
    now="$(date +%s)"
    printf '%s\trecent\n' "$now" >"$worktrees_dir/.fw_recent"
    printf '%s\told\n' "$((now - 30 * 86400))" >>"$worktrees_dir/.fw_recent"

    run _claude_stale_worktrees "$((now - 7 * 86400))" recent old never
    [ "$status" -eq 0 ]
    [[ "$output" == *old* ]]
    [[ "$output" == *never* ]]
    [[ "$output" != *recent* ]]
}
