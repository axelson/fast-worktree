# bats file_tags=core
load ../test_helper

# The real stack backend (gt-stack-fast.sh) excludes trunk from the picker, so
# a "pick trunk" scenario can't be produced end-to-end. These unit tests drive
# cmd_stack_switch with stubbed collaborators to prove the trunk-pick routing:
# picking trunk routes to the golden-checkout switch (like `fw switch main`),
# and the "already there" notice appears only inside the golden checkout.

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
}

run_stack_switch() {
    local current_wt="$1"
    bash -c '
        set -uo pipefail
        SCRIPT_DIR="'"$FW_ROOT"'"
        source "$SCRIPT_DIR/lib/config.sh"
        source "$SCRIPT_DIR/lib/project.sh"
        source "$SCRIPT_DIR/lib/worktree.sh"
        source "$SCRIPT_DIR/lib/fzf.sh"
        source "$SCRIPT_DIR/lib/switch.sh"
        source "$SCRIPT_DIR/lib/stack.sh"
        source "$SCRIPT_DIR/lib/stack/none.sh"
        source "$SCRIPT_DIR/lib/stack/present.sh"
        load_config myproj
        # Stub the collaborators cmd_stack_switch leans on.
        _stack_require_cwd_in_project() { return 0; }
        _ensure_trunk() { TRUNK_BRANCH=main; }
        trunk_branch() { echo main; }
        stack_branches() { printf "*me/feat\n"; }
        _current_worktree_name() { echo "'"$current_wt"'"; }
        # Picker returns the trunk row (hidden field 2 = main).
        _fzf_pick_line() { printf "  main\tmain\n"; }
        cmd_switch() { echo "CMD_SWITCH: $*"; }
        cmd_stack_switch
    '
}

@test "stack-switch: trunk pick routes to the main switch outside the golden checkout" {
    run run_stack_switch "feat"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CMD_SWITCH: main"* ]]
    [[ "$output" != *"nothing to switch to"* ]]
}

@test "stack-switch: trunk pick inside the golden checkout says nothing to switch to" {
    run run_stack_switch "main"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to switch to"* ]]
    [[ "$output" != *"CMD_SWITCH"* ]]
}
