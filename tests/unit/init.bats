load ../test_helper

setup() {
    isolate_env
    source "$FW_ROOT/lib/config.sh"
    source "$FW_ROOT/lib/project.sh"
    source "$FW_ROOT/lib/switch.sh"
    source "$FW_ROOT/lib/init.sh"
}

@test "cmd_init: registers the current repo, name defaulting to repo basename" {
    make_repo "$BATS_TEST_TMPDIR/myapp"
    cd "$BATS_TEST_TMPDIR/myapp"

    run cmd_init
    [ "$status" -eq 0 ]
    [ -f "$FW_CONFIG_DIR/projects/myapp/config.sh" ]
    grep -q "repo_root=" "$FW_CONFIG_DIR/projects/myapp/config.sh"
}

@test "cmd_init: records the new project as visited (project_log row)" {
    make_repo "$BATS_TEST_TMPDIR/myapp"
    cd "$BATS_TEST_TMPDIR/myapp"

    run cmd_init
    [ "$status" -eq 0 ]

    local log="$FW_CONFIG_DIR/project_log"
    [ -f "$log" ]
    # A "<ts>\t<name>" row naming the new project, so switch-project floats it up.
    run awk -F'\t' '$2 == "myapp" && $1 ~ /^[0-9]+$/ { found=1 } END { exit !found }' "$log"
    [ "$status" -eq 0 ]
}

@test "cmd_init: explicit name overrides the default" {
    make_repo "$BATS_TEST_TMPDIR/myapp"
    cd "$BATS_TEST_TMPDIR/myapp"

    run cmd_init custom
    [ "$status" -eq 0 ]
    [ -f "$FW_CONFIG_DIR/projects/custom/config.sh" ]
}

@test "cmd_init: registered config round-trips through load_config" {
    make_repo "$BATS_TEST_TMPDIR/myapp"
    cd "$BATS_TEST_TMPDIR/myapp"
    cmd_init

    load_config myapp

    [ "$repo_root" = "$(realpath "$BATS_TEST_TMPDIR")/myapp" ]
    [ "$worktrees_dir" = "$(realpath "$BATS_TEST_TMPDIR")/myapp-worktrees" ]
}

@test "cmd_init: from a linked worktree registers the main repo root" {
    make_repo "$BATS_TEST_TMPDIR/myapp"
    git -C "$BATS_TEST_TMPDIR/myapp" worktree add -q "$BATS_TEST_TMPDIR/wt" -b feat
    cd "$BATS_TEST_TMPDIR/wt"

    run cmd_init
    [ "$status" -eq 0 ]
    load_config myapp
    [ "$repo_root" = "$(realpath "$BATS_TEST_TMPDIR")/myapp" ]
}

@test "cmd_init: fails outside a git repo" {
    cd "$BATS_TEST_TMPDIR"

    run cmd_init
    [ "$status" -ne 0 ]
    [[ "$output" == *"not"*"git repo"* ]]
}

@test "cmd_init: fails when the name is already registered" {
    make_repo "$BATS_TEST_TMPDIR/myapp"
    register_project myapp "$BATS_TEST_TMPDIR/elsewhere"
    cd "$BATS_TEST_TMPDIR/myapp"

    run cmd_init
    [ "$status" -ne 0 ]
    [[ "$output" == *"already registered"* ]]
}

@test "cmd_init: fails when the repo is already registered under another name" {
    make_repo "$BATS_TEST_TMPDIR/myapp"
    register_project othername "$BATS_TEST_TMPDIR/myapp"
    cd "$BATS_TEST_TMPDIR/myapp"

    run cmd_init
    [ "$status" -ne 0 ]
    [[ "$output" == *"othername"* ]]
}

@test "cmd_init: generated config documents the main settings as comments" {
    make_repo "$BATS_TEST_TMPDIR/myapp"
    cd "$BATS_TEST_TMPDIR/myapp"
    cmd_init

    local cfg="$FW_CONFIG_DIR/projects/myapp/config.sh"
    grep -q '^# *cow_assets=' "$cfg"
    grep -q '^# *stack_backend=' "$cfg"
    grep -q '^# *db_source=' "$cfg"
}

@test "cmd_init: rejects names with path separators" {
    make_repo "$BATS_TEST_TMPDIR/myapp"
    cd "$BATS_TEST_TMPDIR/myapp"

    run cmd_init "team/api"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid project name"* ]]
    [ ! -e "$FW_CONFIG_DIR/projects/team" ]

    run cmd_init "../evil"
    [ "$status" -ne 0 ]
    [ ! -e "$FW_CONFIG_DIR/evil" ]
}

@test "cmd_init: lowercases the derived project name" {
    make_repo "$BATS_TEST_TMPDIR/MyApp"
    cd "$BATS_TEST_TMPDIR/MyApp"

    run cmd_init
    [ "$status" -eq 0 ]
    [ -f "$FW_CONFIG_DIR/projects/myapp/config.sh" ]
}

@test "cmd_init: prints where the config was written" {
    make_repo "$BATS_TEST_TMPDIR/myapp"
    cd "$BATS_TEST_TMPDIR/myapp"

    run cmd_init
    [[ "$output" == *"projects/myapp/config.sh"* ]]
}
