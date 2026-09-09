load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    mkdir -p "$BATS_TEST_TMPDIR/myrepo/_build"
    echo v1 >"$BATS_TEST_TMPDIR/myrepo/_build/artifact"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

@test "fw refresh: replaces stale assets from the golden checkout" {
    "$FW_BIN" create feat
    echo v2 >"$BATS_TEST_TMPDIR/myrepo/_build/artifact"

    run "$FW_BIN" refresh feat
    [ "$status" -eq 0 ]

    [ "$(cat "$BATS_TEST_TMPDIR/myproj-worktrees/feat/_build/artifact")" = "v2" ]
    [ ! -e "$BATS_TEST_TMPDIR/myproj-worktrees/feat/_build/_build" ]
}

@test "fw refresh: removes worktree-local files inside asset dirs" {
    "$FW_BIN" create feat
    echo local >"$BATS_TEST_TMPDIR/myproj-worktrees/feat/_build/stale-local-file"

    "$FW_BIN" refresh feat

    [ ! -e "$BATS_TEST_TMPDIR/myproj-worktrees/feat/_build/stale-local-file" ]
}

@test "fw refresh: detects the worktree from cwd" {
    "$FW_BIN" create feat
    echo v2 >"$BATS_TEST_TMPDIR/myrepo/_build/artifact"
    cd "$BATS_TEST_TMPDIR/myproj-worktrees/feat"

    run "$FW_BIN" refresh
    [ "$status" -eq 0 ]
    [ "$(cat _build/artifact)" = "v2" ]
}

@test "fw regen-env: rewrites the env file preserving the port slot" {
    "$FW_BIN" create feat
    local env="$BATS_TEST_TMPDIR/myproj-worktrees/feat/.env.worktree"
    local slot
    slot="$(grep '^FW_PORT_SLOT=' "$env" | cut -d= -f2)"
    echo "STALE_LINE=1" >>"$env"

    run "$FW_BIN" regen-env feat
    [ "$status" -eq 0 ]

    grep -q "^FW_PORT_SLOT=$slot$" "$env"
    ! grep -q "STALE_LINE" "$env"
    grep -q '^FW_WORKTREE=feat$' "$env"
}

@test "fw regen-env: fills a missing FW_BRANCH from the worktree's git branch" {
    "$FW_BIN" create feat
    local env="$BATS_TEST_TMPDIR/myproj-worktrees/feat/.env.worktree"
    # Simulate a legacy-created env file that predates the FW_BRANCH key.
    grep -v '^FW_BRANCH=' "$env" >"$env.tmp" && mv "$env.tmp" "$env"
    ! grep -q '^FW_BRANCH=' "$env"

    run "$FW_BIN" regen-env feat
    [ "$status" -eq 0 ]
    grep -q '^FW_BRANCH=me/feat$' "$env"
}

@test "fw regen-env: from the golden checkout allocates a slot and writes it" {
    cd "$BATS_TEST_TMPDIR/myrepo"

    run "$FW_BIN" regen-env
    [ "$status" -eq 0 ]

    local env="$BATS_TEST_TMPDIR/myrepo/.env.worktree"
    [ -f "$env" ]
    grep -q '^FW_WORKTREE=main$' "$env"
    grep -qE '^FW_PORT_SLOT=[0-9]{3}$' "$env"
}

@test "fw regen-env: re-running on the golden checkout preserves its slot" {
    cd "$BATS_TEST_TMPDIR/myrepo"
    "$FW_BIN" regen-env
    local env="$BATS_TEST_TMPDIR/myrepo/.env.worktree"
    local slot
    slot="$(grep '^FW_PORT_SLOT=' "$env" | cut -d= -f2)"

    run "$FW_BIN" regen-env main
    [ "$status" -eq 0 ]
    grep -q "^FW_PORT_SLOT=$slot$" "$env"
}

@test "fw regen-env: golden checkout slot is distinct from a worktree's slot" {
    cd "$BATS_TEST_TMPDIR/myrepo"
    "$FW_BIN" create feat
    "$FW_BIN" regen-env main

    local main_slot feat_slot
    main_slot="$(grep '^FW_PORT_SLOT=' "$BATS_TEST_TMPDIR/myrepo/.env.worktree" | cut -d= -f2)"
    feat_slot="$(grep '^FW_PORT_SLOT=' "$BATS_TEST_TMPDIR/myproj-worktrees/feat/.env.worktree" | cut -d= -f2)"
    [ -n "$main_slot" ]
    [ "$main_slot" != "$feat_slot" ]
}

@test "fw regen-env: warns when the golden env file is not gitignored" {
    cd "$BATS_TEST_TMPDIR/myrepo"

    run "$FW_BIN" regen-env
    [ "$status" -eq 0 ]
    [[ "$output" == *"gitignore"* ]]
}

@test "fw regen-env: no gitignore warning when the golden env file is ignored" {
    cd "$BATS_TEST_TMPDIR/myrepo"
    echo '.env.worktree' >.gitignore

    run "$FW_BIN" regen-env
    [ "$status" -eq 0 ]
    [[ "$output" != *"gitignore"* ]]
}

@test "fw regen-env: no gitignore warning for a linked worktree" {
    "$FW_BIN" create feat
    cd "$BATS_TEST_TMPDIR/myproj-worktrees/feat"

    run "$FW_BIN" regen-env
    [ "$status" -eq 0 ]
    [[ "$output" != *"gitignore"* ]]
}

@test "fw regen-env: re-runs hook_worktree_env with the preserved slot" {
    "$FW_BIN" create feat
    local env="$BATS_TEST_TMPDIR/myproj-worktrees/feat/.env.worktree"
    local slot
    slot="$(grep '^FW_PORT_SLOT=' "$env" | cut -d= -f2)"
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
hook_worktree_env() { echo "DERIVED_PORT=40${FW_PORT_SLOT}"; }
EOF

    "$FW_BIN" regen-env feat

    grep -q "^DERIVED_PORT=40${slot}$" "$env"
}
