load ../test_helper

setup() {
    isolate_env
    source "$FW_ROOT/lib/config.sh"
}

@test "load_config: fails with a clear error for an unregistered project" {
    run load_config nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"nope"* ]]
    [[ "$output" == *"not registered"* ]]
}

@test "load_config: reads repo_root from the project config" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"

    load_config myproj

    [ "$repo_root" = "$BATS_TEST_TMPDIR/myrepo" ]
    [ "$project" = "myproj" ]
}

@test "load_config: global config values are visible" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'github_username=someone' >"$FW_CONFIG_DIR/config.sh"

    load_config myproj

    [ "$github_username" = "someone" ]
}

@test "load_config: project config overrides global config" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=global-prefix' >"$FW_CONFIG_DIR/config.sh"
    echo 'branch_prefix=proj-prefix' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    load_config myproj

    [ "$branch_prefix" = "proj-prefix" ]
}

@test "load_config: repo-local .fast-worktree/config.sh is honored" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    mkdir -p "$BATS_TEST_TMPDIR/myrepo/.fast-worktree"
    echo 'ticket_url=https://example.com/{id}' >"$BATS_TEST_TMPDIR/myrepo/.fast-worktree/config.sh"

    load_config myproj

    [ "$ticket_url" = "https://example.com/{id}" ]
}

@test "load_config: repo-local .fw/config.sh honored when .fast-worktree absent" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    mkdir -p "$BATS_TEST_TMPDIR/myrepo/.fw"
    echo 'ticket_url=https://fw.example/{id}' >"$BATS_TEST_TMPDIR/myrepo/.fw/config.sh"

    load_config myproj

    [ "$ticket_url" = "https://fw.example/{id}" ]
}

@test "load_config: .fast-worktree preferred over .fw when both exist" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    mkdir -p "$BATS_TEST_TMPDIR/myrepo/.fast-worktree" "$BATS_TEST_TMPDIR/myrepo/.fw"
    echo 'ticket_url=preferred' >"$BATS_TEST_TMPDIR/myrepo/.fast-worktree/config.sh"
    echo 'ticket_url=ignored' >"$BATS_TEST_TMPDIR/myrepo/.fw/config.sh"

    load_config myproj

    [ "$ticket_url" = "preferred" ]
}

@test "load_config: user project config wins over repo-local config" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    mkdir -p "$BATS_TEST_TMPDIR/myrepo/.fast-worktree"
    echo 'branch_prefix=repo-local' >"$BATS_TEST_TMPDIR/myrepo/.fast-worktree/config.sh"
    echo 'branch_prefix=user-level' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    load_config myproj

    [ "$branch_prefix" = "user-level" ]
}

@test "load_config: defaults are Elixir-shaped" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"

    load_config myproj

    [ "$env_file" = ".env.worktree" ]
    [ "$stack_backend" = "auto" ]
    [ "${cow_assets[0]}" = "_build" ]
    [ "${cow_assets[1]}" = "deps" ]
    [ "${cow_assets[2]}" = "assets/node_modules" ]
}

@test "load_config: worktrees_dir defaults to sibling <project>-worktrees" {
    make_repo "$BATS_TEST_TMPDIR/nested/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/nested/myrepo"

    load_config myproj

    [ "$worktrees_dir" = "$BATS_TEST_TMPDIR/nested/myproj-worktrees" ]
}

@test "load_config: worktrees_dir override from config is kept" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo "worktrees_dir=$BATS_TEST_TMPDIR/elsewhere" >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    load_config myproj

    [ "$worktrees_dir" = "$BATS_TEST_TMPDIR/elsewhere" ]
}

@test "load_config: tolerates a config whose last statement is a false conditional" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo '[[ -d /nonexistent-dir ]] && branch_prefix=conditional' \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    (set -e; load_config myproj)
    load_config myproj
    [ "$repo_root" = "$BATS_TEST_TMPDIR/myrepo" ]
}

@test "load_config: an inherited repo_root env var does not leak into the peek" {
    make_repo "$BATS_TEST_TMPDIR/real"
    register_project myproj "$BATS_TEST_TMPDIR/real"
    mkdir -p "$BATS_TEST_TMPDIR/real/.fast-worktree"
    echo 'ticket_url=from-repo-local' >"$BATS_TEST_TMPDIR/real/.fast-worktree/config.sh"

    # Simulate a stale global: project config that never sets repo_root,
    # while the variable is already set in the environment to a bogus repo
    # that also has a repo-local config.
    make_repo "$BATS_TEST_TMPDIR/bogus"
    mkdir -p "$BATS_TEST_TMPDIR/bogus/.fast-worktree"
    echo 'ticket_url=from-bogus' >"$BATS_TEST_TMPDIR/bogus/.fast-worktree/config.sh"
    mkdir -p "$FW_CONFIG_DIR/projects/noroot"
    : >"$FW_CONFIG_DIR/projects/noroot/config.sh"

    repo_root="$BATS_TEST_TMPDIR/bogus"
    load_config noroot

    [ "$ticket_url" != "from-bogus" ]
}

# --- hook chaining -----------------------------------------------------------

@test "load_config: a chain-default hook runs every level, least-specific first" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    local log="$BATS_TEST_TMPDIR/order"
    printf 'hook_post_switch() { echo global >>%q; }\n' "$log" \
        >"$FW_CONFIG_DIR/config.sh"
    printf 'hook_post_switch() { echo project >>%q; }\n' "$log" \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    load_config myproj
    hook_post_switch

    [ "$(sed -n 1p "$log")" = global ]
    [ "$(sed -n 2p "$log")" = project ]
}

@test "load_config: fw_hook_replace suppresses less-specific levels of a hook" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    local log="$BATS_TEST_TMPDIR/order"
    printf 'hook_post_switch() { echo global >>%q; }\n' "$log" \
        >"$FW_CONFIG_DIR/config.sh"
    {
        printf 'hook_post_switch() { echo project >>%q; }\n' "$log"
        printf 'fw_hook_replace hook_post_switch\n'
    } >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    load_config myproj
    hook_post_switch

    [ "$(cat "$log")" = project ]
}

@test "load_config: hook_tmux_windows replaces less-specific levels by default" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    local log="$BATS_TEST_TMPDIR/order"
    printf 'hook_tmux_windows() { echo global >>%q; }\n' "$log" \
        >"$FW_CONFIG_DIR/config.sh"
    printf 'hook_tmux_windows() { echo project >>%q; }\n' "$log" \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    load_config myproj
    hook_tmux_windows

    [ "$(cat "$log")" = project ]
}

@test "load_config: fw_hook_chain opts hook_tmux_windows into chaining" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    local log="$BATS_TEST_TMPDIR/order"
    printf 'hook_tmux_windows() { echo global >>%q; }\n' "$log" \
        >"$FW_CONFIG_DIR/config.sh"
    {
        printf 'hook_tmux_windows() { echo project >>%q; }\n' "$log"
        printf 'fw_hook_chain hook_tmux_windows\n'
    } >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    load_config myproj
    hook_tmux_windows

    [ "$(sed -n 1p "$log")" = global ]
    [ "$(sed -n 2p "$log")" = project ]
}

@test "run_hook: a warn-policy chain runs every level despite a failure" {
    source "$FW_ROOT/lib/hooks.sh"
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    local log="$BATS_TEST_TMPDIR/order"
    printf 'hook_sync() { echo global >>%q; return 1; }\n' "$log" \
        >"$FW_CONFIG_DIR/config.sh"
    printf 'hook_sync() { echo project >>%q; }\n' "$log" \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    load_config myproj
    run_hook hook_sync "$BATS_TEST_TMPDIR" warn

    [ "$(sed -n 1p "$log")" = global ]
    [ "$(sed -n 2p "$log")" = project ]
}

@test "run_hook: a warn-policy chain names the failing level by scope" {
    source "$FW_ROOT/lib/hooks.sh"
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    printf 'hook_sync() { return 1; }\n' >"$FW_CONFIG_DIR/config.sh"
    printf 'hook_sync() { :; }\n' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    load_config myproj
    run run_hook hook_sync "$BATS_TEST_TMPDIR" warn

    [ "$status" -eq 0 ]
    [[ "$output" == *Warning* ]]
    [[ "$output" == *hook_sync* ]]
    [[ "$output" == *global* ]]
    [[ "$output" != *project* ]]   # the project level succeeded
}

@test "run_hook: a fatal-policy chain stops at the first failing level" {
    source "$FW_ROOT/lib/hooks.sh"
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    local log="$BATS_TEST_TMPDIR/order"
    printf 'hook_pre_db() { echo global >>%q; return 1; }\n' "$log" \
        >"$FW_CONFIG_DIR/config.sh"
    printf 'hook_pre_db() { echo project >>%q; }\n' "$log" \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    load_config myproj
    run run_hook hook_pre_db "$BATS_TEST_TMPDIR" fatal

    [ "$status" -ne 0 ]
    [ "$(cat "$log")" = global ]
}

@test "load_config: a single-level hook runs and receives its arguments" {
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    local log="$BATS_TEST_TMPDIR/order"
    printf 'hook_post_switch() { echo "got $1" >>%q; }\n' "$log" \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    load_config myproj
    hook_post_switch hello

    [ "$(cat "$log")" = "got hello" ]
}

@test "load_config: hooks do not leak between two loads in one shell" {
    make_repo "$BATS_TEST_TMPDIR/repoA"
    make_repo "$BATS_TEST_TMPDIR/repoB"
    register_project projA "$BATS_TEST_TMPDIR/repoA"
    register_project projB "$BATS_TEST_TMPDIR/repoB"
    printf 'hook_post_switch() { :; }\n' \
        >>"$FW_CONFIG_DIR/projects/projA/config.sh"

    load_config projA
    declare -F hook_post_switch >/dev/null   # A defines it
    load_config projB

    ! declare -F hook_post_switch >/dev/null  # B must not inherit A's
}

@test "fw_config_dir: honors XDG_CONFIG_HOME" {
    [ "$(fw_config_dir)" = "$XDG_CONFIG_HOME/fast-worktree" ]
}

@test "fw_config_dir: falls back to ~/.config without XDG_CONFIG_HOME" {
    unset XDG_CONFIG_HOME
    [ "$(fw_config_dir)" = "$HOME/.config/fast-worktree" ]
}
