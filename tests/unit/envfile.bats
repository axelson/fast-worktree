load ../test_helper

setup() {
    isolate_env
    source "$FW_ROOT/lib/config.sh"
    source "$FW_ROOT/lib/hooks.sh"
    source "$FW_ROOT/lib/project.sh"
    source "$FW_ROOT/lib/envfile.sh"
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    load_config myproj
}

@test "db_name_for_worktree: applies prefix and sanitizes dashes" {
    [ "$(db_name_for_worktree cool-feature)" = "myproj_cool_feature" ]
}

@test "db_name_for_worktree: appends suffix" {
    [ "$(db_name_for_worktree cool-feature _test)" = "myproj_cool_feature_test" ]
}

@test "db_name_for_worktree: truncates to 63 chars keeping prefix and suffix" {
    local long="a-very-long-worktree-name-that-goes-on-and-on-and-on-and-on-forever"
    local result
    result="$(db_name_for_worktree "$long" _test)"
    [ "${#result}" -le 63 ]
    [[ "$result" == myproj_* ]]
    [[ "$result" == *_test ]]
}

@test "allocate_port_slot: returns a slot in 100-999" {
    local slot
    slot="$(allocate_port_slot)"
    [ "$slot" -ge 100 ]
    [ "$slot" -le 999 ]
}

@test "used_port_slots: reads slots from existing worktree env files" {
    mkdir -p "$worktrees_dir/one" "$worktrees_dir/two"
    echo 'FW_PORT_SLOT=123' >"$worktrees_dir/one/.env.worktree"
    echo 'FW_PORT_SLOT=456' >"$worktrees_dir/two/.env.worktree"

    run used_port_slots
    [ "$output" = $'123\n456' ]
}

@test "used_port_slots: respects a nested env_file path" {
    env_file="services/app/.env.worktree"
    mkdir -p "$worktrees_dir/one/services/app"
    echo 'FW_PORT_SLOT=321' >"$worktrees_dir/one/services/app/.env.worktree"

    run used_port_slots
    [ "$output" = "321" ]
}

@test "used_port_slots: includes the golden checkout's own slot" {
    # The golden checkout (repo_root) is a first-class port holder: its slot
    # must be reserved so no worktree — here or in another project — reuses it.
    echo 'FW_PORT_SLOT=234' >"$repo_root/.env.worktree"

    run used_port_slots
    [[ "$output" == *"234"* ]]
}

@test "used_port_slots: includes another project's golden checkout slot" {
    make_repo "$BATS_TEST_TMPDIR/otherrepo"
    register_project otherproj "$BATS_TEST_TMPDIR/otherrepo"
    echo 'FW_PORT_SLOT=567' >"$BATS_TEST_TMPDIR/otherrepo/.env.worktree"

    run used_port_slots
    [[ "$output" == *"567"* ]]
}

@test "used_port_slots: includes slots claimed by other registered projects" {
    mkdir -p "$worktrees_dir/one"
    echo 'FW_PORT_SLOT=123' >"$worktrees_dir/one/.env.worktree"

    make_repo "$BATS_TEST_TMPDIR/otherrepo"
    register_project otherproj "$BATS_TEST_TMPDIR/otherrepo"
    mkdir -p "$BATS_TEST_TMPDIR/otherproj-worktrees/wt"
    echo 'FW_PORT_SLOT=456' >"$BATS_TEST_TMPDIR/otherproj-worktrees/wt/.env.worktree"

    run used_port_slots
    [[ "$output" == *"123"* ]]
    [[ "$output" == *"456"* ]]
}

@test "used_port_slots: honors another project's env_file setting" {
    make_repo "$BATS_TEST_TMPDIR/otherrepo"
    register_project otherproj "$BATS_TEST_TMPDIR/otherrepo"
    echo 'env_file=services/app/.env.worktree' \
        >>"$FW_CONFIG_DIR/projects/otherproj/config.sh"
    mkdir -p "$BATS_TEST_TMPDIR/otherproj-worktrees/wt/services/app"
    echo 'FW_PORT_SLOT=789' \
        >"$BATS_TEST_TMPDIR/otherproj-worktrees/wt/services/app/.env.worktree"

    run used_port_slots
    [[ "$output" == *"789"* ]]
}

@test "allocate_port_slot: never returns a used or adjacent slot" {
    # Everything used except 499-501: only 500 has both neighbors free.
    used_port_slots() { seq 100 498; seq 502 999; }

    local slot
    slot="$(allocate_port_slot)"
    [ "$slot" = "500" ]
}

@test "allocate_port_slot: errors instead of hanging when no slot is free" {
    used_port_slots() { seq 100 999; }

    run allocate_port_slot
    [ "$status" -ne 0 ]
    [[ "$output" == *"no free port slot"* ]]
}

@test "write_worktree_env: writes canonical FW_* keys" {
    mkdir -p "$worktrees_dir/feat"

    write_worktree_env "$worktrees_dir/feat" feat me/feat

    local f="$worktrees_dir/feat/.env.worktree"
    grep -q '^FW_WORKTREE=feat$' "$f"
    grep -q '^FW_BRANCH=me/feat$' "$f"
    grep -qE '^FW_PORT_SLOT=[0-9]{3}$' "$f"
}

@test "write_worktree_env: no DB keys when db_source is unset" {
    mkdir -p "$worktrees_dir/feat"

    write_worktree_env "$worktrees_dir/feat" feat me/feat

    ! grep -q 'FW_DB_NAME' "$worktrees_dir/feat/.env.worktree"
}

@test "write_worktree_env: DB keys present when db_source is set" {
    db_source=myproj_dev
    mkdir -p "$worktrees_dir/feat"

    write_worktree_env "$worktrees_dir/feat" feat me/feat

    local f="$worktrees_dir/feat/.env.worktree"
    grep -q '^FW_DB_NAME=myproj_feat$' "$f"
    grep -q '^FW_TEST_DB_NAME=myproj_feat_test$' "$f"
}

@test "write_worktree_env: golden checkout keeps the default DB, not a clone" {
    # The golden checkout ("main") runs against the project's default database,
    # so it records db_source verbatim and gets no cloned per-worktree DB.
    db_source=myproj_dev
    write_worktree_env "$repo_root" main main

    local f="$repo_root/.env.worktree"
    grep -q '^FW_WORKTREE=main$' "$f"
    grep -q '^FW_DB_NAME=myproj_dev$' "$f"
    ! grep -q 'FW_TEST_DB_NAME' "$f"
}

@test "write_worktree_env: hook_worktree_env output is appended with FW_* in scope" {
    hook_worktree_env() {
        echo "MY_PORT=40${FW_PORT_SLOT}"
        echo "APP_NAME=${FW_WORKTREE}"
    }
    mkdir -p "$worktrees_dir/feat"

    write_worktree_env "$worktrees_dir/feat" feat me/feat

    local f="$worktrees_dir/feat/.env.worktree"
    grep -qE '^MY_PORT=40[0-9]{3}$' "$f"
    grep -q '^APP_NAME=feat$' "$f"
}

@test "write_worktree_env: hook gets the full FW_* contract and runs in the worktree" {
    hook_worktree_env() {
        echo "HOOK_PATH=${FW_WORKTREE_PATH}"
        echo "HOOK_PROJECT=${FW_PROJECT}"
        echo "HOOK_ROOT=${FW_REPO_ROOT}"
        echo "HOOK_PWD=$(pwd)"
    }
    mkdir -p "$worktrees_dir/feat"

    write_worktree_env "$worktrees_dir/feat" feat me/feat

    local f="$worktrees_dir/feat/.env.worktree"
    grep -q "^HOOK_PATH=$worktrees_dir/feat$" "$f"
    grep -q "^HOOK_PROJECT=myproj$" "$f"
    grep -q "^HOOK_ROOT=$repo_root$" "$f"
    grep -q "^HOOK_PWD=$worktrees_dir/feat$" "$f"
}

@test "write_worktree_env: a failing hook makes it return nonzero" {
    hook_worktree_env() { echo "$UNDEFINED_HOOK_VARIABLE"; }
    mkdir -p "$worktrees_dir/feat"

    run bash -c "
        set -euo pipefail
        source '$FW_ROOT/lib/config.sh'; source '$FW_ROOT/lib/hooks.sh'
        source '$FW_ROOT/lib/envfile.sh'
        load_config myproj
        hook_worktree_env() { echo \"\$UNDEFINED_HOOK_VARIABLE\"; }
        write_worktree_env '$worktrees_dir/feat' feat me/feat && echo UNEXPECTED-SUCCESS
    "
    [[ "$output" != *"UNEXPECTED-SUCCESS"* ]]
}

@test "write_worktree_env: creates nested env_file parent directories" {
    env_file="services/app/.env.worktree"
    mkdir -p "$worktrees_dir/feat"

    write_worktree_env "$worktrees_dir/feat" feat me/feat

    [ -f "$worktrees_dir/feat/services/app/.env.worktree" ]
}

@test "read_worktree_env: round-trips what write_worktree_env wrote" {
    db_source=myproj_dev
    mkdir -p "$worktrees_dir/feat"
    write_worktree_env "$worktrees_dir/feat" feat me/feat

    read_worktree_env "$worktrees_dir/feat"

    [ "$WT_NAME" = "feat" ]
    [ "$WT_BRANCH" = "me/feat" ]
    [[ "$WT_PORT_SLOT" =~ ^[0-9]{3}$ ]]
    [ "$WT_DB_NAME" = "myproj_feat" ]
    [ "$WT_TEST_DB_NAME" = "myproj_feat_test" ]
}

@test "read_worktree_env: fails cleanly when the env file is missing" {
    mkdir -p "$worktrees_dir/feat"

    run read_worktree_env "$worktrees_dir/feat"
    [ "$status" -ne 0 ]
    [[ "$output" == *".env.worktree"* ]]
}
