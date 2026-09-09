load ../test_helper

# Tests for `fw setup` — first-run onboarding: symlink the fish completions and
# drop a commented-out global config template.

setup() {
    isolate_env
    FISH_COMP="$XDG_CONFIG_HOME/fish/completions"
    GLOBAL_CFG="$FW_CONFIG_DIR/config.sh"
    REPO_COMP="$FW_ROOT/completions/fast-worktree.fish"
}

@test "setup: symlinks the completion file under the invoked name" {
    # Invoked as its real basename (fast-worktree), so the link is named to match.
    run "$FW_BIN" setup
    [ "$status" -eq 0 ]
    [ -L "$FISH_COMP/fast-worktree.fish" ]
    [ "$(readlink "$FISH_COMP/fast-worktree.fish")" = "$REPO_COMP" ]
}

@test "setup: names the link after the alias it was invoked as" {
    ln -sf "$FW_BIN" "$BATS_TEST_TMPDIR/fw"
    run "$BATS_TEST_TMPDIR/fw" setup
    [ "$status" -eq 0 ]
    [ -L "$FISH_COMP/fw.fish" ]
    [ "$(readlink "$FISH_COMP/fw.fish")" = "$REPO_COMP" ]
}

@test "setup: --name overrides the completion link name" {
    run "$FW_BIN" setup --name ftw
    [ "$status" -eq 0 ]
    [ -L "$FISH_COMP/ftw.fish" ]
}

@test "setup: writes a commented-out global config when none exists" {
    [ ! -e "$GLOBAL_CFG" ]
    run "$FW_BIN" setup
    [ "$status" -eq 0 ]
    [ -f "$GLOBAL_CFG" ]
    grep -q '^# default_project' "$GLOBAL_CFG"
    grep -q '^# branch_prefix' "$GLOBAL_CFG"
    # The template must be inert — sourcing it sets nothing.
    run bash -c "source '$GLOBAL_CFG'; echo \"[\${default_project:-unset}]\""
    [[ "$output" == *'[unset]'* ]]
}

@test "setup: never overwrites an existing global config" {
    mkdir -p "$FW_CONFIG_DIR"
    printf 'default_project=mine\n' >"$GLOBAL_CFG"
    run "$FW_BIN" setup
    [ "$status" -eq 0 ]
    [ "$(cat "$GLOBAL_CFG")" = "default_project=mine" ]
}

@test "setup: is idempotent — re-running repoints the link and succeeds" {
    run "$FW_BIN" setup
    [ "$status" -eq 0 ]
    # A stale/foreign link is replaced, not errored on.
    ln -sf /somewhere/else.fish "$FISH_COMP/fast-worktree.fish"
    run "$FW_BIN" setup
    [ "$status" -eq 0 ]
    [ "$(readlink "$FISH_COMP/fast-worktree.fish")" = "$REPO_COMP" ]
}

@test "setup: is a user-facing command listed in help" {
    run "$FW_BIN" help
    [ "$status" -eq 0 ]
    [[ "$output" == *setup* ]]
}
