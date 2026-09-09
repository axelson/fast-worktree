load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    cd "$BATS_TEST_TMPDIR/myrepo"
    PROJ_CFG="$FW_CONFIG_DIR/projects/myproj/config.sh"
    GLOBAL_CFG="$FW_CONFIG_DIR/config.sh"
    REPO_CFG="$BATS_TEST_TMPDIR/myrepo/.fast-worktree/config.sh"
}

# --- set ---

@test "config set: writes stack_backend to the project layer and reads back" {
    run "$FW_BIN" config set stack_backend none
    [ "$status" -eq 0 ]
    [[ "$output" == *"Set stack_backend = 'none'"* ]]
    [[ "$output" == *"project"* ]]
    grep -q "^stack_backend='none'$" "$PROJ_CFG"

    run "$FW_BIN" config get stack_backend
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

@test "config set: creates the project config as a template when missing" {
    rm -f "$PROJ_CFG"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"   # minimal repo_root only
    run "$FW_BIN" config set stack_backend none
    [ "$status" -eq 0 ]
    grep -q "^stack_backend='none'$" "$PROJ_CFG"
}

@test "config set --global: writes the global layer" {
    run "$FW_BIN" config set --global stack_backend none
    [ "$status" -eq 0 ]
    grep -q "^stack_backend='none'$" "$GLOBAL_CFG"
    [ ! -f "$PROJ_CFG" ] || ! grep -q "^stack_backend=" "$PROJ_CFG"
}

@test "config set --repo: writes the repo-local layer" {
    run "$FW_BIN" config set --repo stack_backend none
    [ "$status" -eq 0 ]
    grep -q "^stack_backend='none'$" "$REPO_CFG"
}

@test "config set: rejects an unknown key" {
    run "$FW_BIN" config set bogus_key none
    [ "$status" -ne 0 ]
    [[ "$output" == *"bogus_key"* ]]
}

@test "config set: rejects an array key with a pointer to open/show" {
    run "$FW_BIN" config set cow_assets whatever
    [ "$status" -ne 0 ]
    [[ "$output" == *"cow_assets"* ]]
    [[ "$output" == *"open"* || "$output" == *"show"* ]]
}

@test "config set: rejects an invalid stack_backend value" {
    run "$FW_BIN" config set stack_backend nnone
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid stack_backend"* ]]
    [ ! -f "$PROJ_CFG" ] || ! grep -q 'nnone' "$PROJ_CFG"
}

@test "config set: accepts github (recognized value)" {
    run "$FW_BIN" config set stack_backend github
    [ "$status" -eq 0 ]
    grep -q "^stack_backend='github'$" "$PROJ_CFG"
}

@test "config set: warns when a higher layer shadows the write" {
    # project layer already sets it; setting at global is inert
    printf "stack_backend='graphite'\n" >>"$PROJ_CFG"
    run "$FW_BIN" config set --global stack_backend none
    [ "$status" -eq 0 ]
    [[ "$output" == *"project"* ]]
    [[ "$output" == *"precedence"* || "$output" == *"overrides"* || "$output" == *"takes precedence"* ]]
}

@test "config set: requires a value (flag-first arg shape)" {
    run "$FW_BIN" config set stack_backend
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage"* ]]
}

# --- get ---

@test "config get: merged view returns the default when unset" {
    run "$FW_BIN" config get stack_backend
    [ "$status" -eq 0 ]
    [ "$output" = "auto" ]
}

@test "config get --project: exits nonzero when the key is not set in that layer" {
    run "$FW_BIN" config get --project stack_backend
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "config get --global: returns that layer's raw value" {
    printf "stack_backend='none'\n" >"$GLOBAL_CFG"
    run "$FW_BIN" config get --global stack_backend
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

@test "config get: rejects an unknown key" {
    run "$FW_BIN" config get bogus_key
    [ "$status" -ne 0 ]
    [[ "$output" == *"bogus_key"* ]]
}

# --- unset ---

@test "config unset: removes the key and reports the new effective value" {
    "$FW_BIN" config set stack_backend none
    run "$FW_BIN" config unset stack_backend
    [ "$status" -eq 0 ]
    [[ "$output" == *"Unset stack_backend"* ]]
    [[ "$output" == *"auto"* ]]        # reverts to the default
    ! grep -q "^stack_backend=" "$PROJ_CFG"
}

@test "config unset: no-op note when the key is not set in the layer" {
    run "$FW_BIN" config unset stack_backend
    [ "$status" -eq 0 ]
    [[ "$output" == *"not set"* ]]
}
