load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
    WTDIR="$BATS_TEST_TMPDIR/myproj-worktrees"
}

teardown() {
    "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true
    [ -n "${LOCKED_DIR:-}" ] && chmod -R u+rwx "$LOCKED_DIR" 2>/dev/null || true
}

# --- fw claude ---

@test "fw claude: tabulates running instances by worktree" {
    "$FW_BIN" create alpha
    export FW_TEST_CLAUDE_AGENTS_JSON="$(cat <<JSON
[{"pid":111,"cwd":"$WTDIR/alpha","status":"busy","kind":"agent","name":"work","startedAt":0}]
JSON
)"
    run "$FW_BIN" claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"busy"* ]]
    [[ "$output" == *"1 busy"* ]]
}

@test "fw claude: summary joins statuses with a comma and space" {
    "$FW_BIN" create alpha
    "$FW_BIN" create beta
    export FW_TEST_CLAUDE_AGENTS_JSON="$(cat <<JSON
[{"pid":1,"cwd":"$WTDIR/alpha","status":"busy","startedAt":0},
 {"pid":2,"cwd":"$WTDIR/alpha","status":"busy","startedAt":0},
 {"pid":3,"cwd":"$WTDIR/beta","status":"waiting","startedAt":0}]
JSON
)"
    run "$FW_BIN" claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 busy, 1 waiting"* ]]
}

@test "fw claude: tolerates a non-integer startedAt" {
    "$FW_BIN" create alpha
    export FW_TEST_CLAUDE_AGENTS_JSON="$(cat <<JSON
[{"pid":1,"cwd":"$WTDIR/alpha","status":"busy","kind":"agent","name":"work","startedAt":"2020-01-01T00:00:00Z"}]
JSON
)"
    run "$FW_BIN" claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
}

@test "fw claude: no instances reports cleanly" {
    export FW_TEST_CLAUDE_AGENTS_JSON="[]"
    run "$FW_BIN" claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"No Claude instances running."* ]]
}

@test "fw claude --json: emits an empty JSON array when nothing is running" {
    export FW_TEST_CLAUDE_AGENTS_JSON="[]"
    run "$FW_BIN" claude --json
    [ "$status" -eq 0 ]
    # Valid JSON, not prose.
    [ "$(echo "$output" | jq -r 'length')" = "0" ]
    [[ "$output" != *"No Claude instances"* ]]
}

@test "fw claude --json: enriches each entry with its worktree" {
    "$FW_BIN" create alpha
    export FW_TEST_CLAUDE_AGENTS_JSON="$(cat <<JSON
[{"pid":111,"cwd":"$WTDIR/alpha","status":"busy","startedAt":0}]
JSON
)"
    run "$FW_BIN" claude --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.[0].worktree')" = "alpha" ]
}

@test "fw claude --active: hides idle instances" {
    export FW_TEST_CLAUDE_AGENTS_JSON="$(cat <<JSON
[{"pid":1,"cwd":"/tmp/x","status":"idle","startedAt":0}]
JSON
)"
    run "$FW_BIN" claude --active
    [ "$status" -eq 0 ]
    [[ "$output" == *"No active Claude instances."* ]]
}

# --- fw list Claude column ---

@test "fw list: shows a Claude status column" {
    "$FW_BIN" create alpha
    export FW_TEST_CLAUDE_AGENTS_JSON="$(cat <<JSON
[{"pid":1,"cwd":"$WTDIR/alpha","status":"waiting","startedAt":0}]
JSON
)"
    run "$FW_BIN" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"waiting"* ]]
}

@test "fw list: rejects unknown flags and positional args" {
    run "$FW_BIN" list --bogus
    [ "$status" -ne 0 ]
    run "$FW_BIN" list alpha
    [ "$status" -ne 0 ]
}

# --- create --model / --claude ---

@test "fw create --model: writes the model into settings.local.json" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
claude_model_aliases=([opus]="claude-opus-4-8[1m]")
EOF
    "$FW_BIN" create alpha --model opus
    local settings="$WTDIR/alpha/.claude/settings.local.json"
    [ -f "$settings" ]
    [ "$(jq -r .model "$settings")" = "claude-opus-4-8[1m]" ]
}

@test "fw create --model=literal: passes an unknown value through" {
    "$FW_BIN" create alpha --model=some-model-id
    [ "$(jq -r .model "$WTDIR/alpha/.claude/settings.local.json")" = "some-model-id" ]
}

@test "fw create --review: a configured bare prompt-flag starts Claude in a tmux claude window" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
claude_prompt_flags=([review]="/pr-review")
EOF
    export FW_TEST_CLAUDE_LOG="$BATS_TEST_TMPDIR/claude.log"
    "$FW_BIN" create alpha --review

    run "$FW_ROOT/tests/shims/tmux" list-windows -t "=myproj-alpha" -F '#{window_name}'
    [[ "$output" == *"claude"* ]]

    # The pane runs `claude /pr-review`; wait for the shim to record it.
    local i
    for i in $(seq 1 25); do
        [ -f "$FW_TEST_CLAUDE_LOG" ] && grep -q -- "/pr-review" "$FW_TEST_CLAUDE_LOG" && break
        sleep 0.2
    done
    grep -q -- "/pr-review" "$FW_TEST_CLAUDE_LOG"
}

# --- delete-time archiving ---

@test "fw delete: archives Claude artifacts before removal" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
claude_archive_paths=(".claude/plans:plans")
EOF
    "$FW_BIN" create alpha
    mkdir -p "$WTDIR/alpha/.claude/plans"
    echo "# plan" >"$WTDIR/alpha/.claude/plans/p.md"

    run "$FW_BIN" delete --force alpha
    [ "$status" -eq 0 ]
    [ -f "$FW_CONFIG_DIR/projects/myproj/claude-archive/me-alpha/plans/p.md" ]
}

@test "fw delete --force: archives Claude artifacts even for an invalid worktree" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
claude_archive_paths=(".claude/plans:plans")
EOF
    "$FW_BIN" create alpha
    mkdir -p "$WTDIR/alpha/.claude/plans"
    echo "# plan" >"$WTDIR/alpha/.claude/plans/p.md"
    # Corrupt the worktree so it is no longer a valid git worktree.
    rm -f "$WTDIR/alpha/.git"

    run "$FW_BIN" delete --force alpha
    [ "$status" -eq 0 ]
    [ ! -d "$WTDIR/alpha" ]
    [ -f "$FW_CONFIG_DIR/projects/myproj/claude-archive/me-alpha/plans/p.md" ]
}

@test "fw delete: completes even when Claude archiving fails" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<EOF
claude_archive_paths=(".claude/plans:plans")
claude_archive_dir="$BATS_TEST_TMPDIR/locked/archive"
EOF
    LOCKED_DIR="$BATS_TEST_TMPDIR/locked"
    mkdir -p "$LOCKED_DIR"
    chmod 000 "$LOCKED_DIR"

    "$FW_BIN" create alpha
    mkdir -p "$WTDIR/alpha/.claude/plans"
    echo "# plan" >"$WTDIR/alpha/.claude/plans/p.md"

    run "$FW_BIN" delete --force alpha
    [ "$status" -eq 0 ]
    [ ! -d "$WTDIR/alpha" ]
}

@test "fw delete: no archive note when there is nothing to keep" {
    "$FW_BIN" create alpha
    run "$FW_BIN" delete alpha
    [ "$status" -eq 0 ]
    [[ "$output" != *"Archived Claude artifacts"* ]]
    [ ! -d "$FW_CONFIG_DIR/projects/myproj/claude-archive" ]
}

# --- sessions close-old ---

@test "fw sessions close-old: reports when no sessions exist" {
    export FW_TEST_CLAUDE_AGENTS_JSON="[]"
    run "$FW_BIN" sessions close-old
    [ "$status" -eq 0 ]
    [[ "$output" == *"No active Claude sessions found in worktrees."* ]]
}

@test "fw sessions close-old: recently-viewed sessions are not stale" {
    "$FW_BIN" create alpha
    "$FW_BIN" switch alpha
    export FW_TEST_CLAUDE_AGENTS_JSON="$(cat <<JSON
[{"pid":1,"cwd":"$WTDIR/alpha","status":"waiting","startedAt":0}]
JSON
)"
    run "$FW_BIN" sessions close-old --days 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"No Claude sessions older than 7d found."* ]]
}

@test "fw sessions: unknown subcommand errors with usage" {
    run "$FW_BIN" sessions bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"close-old"* ]]
}
