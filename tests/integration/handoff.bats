load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=jax' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"

    HDIR="$BATS_TEST_TMPDIR/myproj-worktrees/handoffs"
    HLOG="$BATS_TEST_TMPDIR/myproj-worktrees/.fw_handoff_log"
    DOC="$BATS_TEST_TMPDIR/mydoc.md"
    printf '# Resume: fix the parser\n\nSome context.\n' >"$DOC"
}

teardown() { "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true; }

@test "fw handoff save: copies the doc and logs a pending entry" {
    run "$FW_BIN" handoff save "$DOC"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Saved handoff"* ]]

    [ -f "$HDIR/mydoc.md" ]
    line="$(tail -1 "$HLOG")"
    [ "$(printf '%s' "$line" | cut -f2)" = "mydoc" ]        # slug from filename
    [ "$(printf '%s' "$line" | cut -f3)" = "fix the parser" ] # title from heading
    [ "$(printf '%s' "$line" | cut -f4)" = "pending" ]
}

@test "fw handoff save: --name overrides the slug" {
    run "$FW_BIN" handoff save "$DOC" --name parser-work
    [ "$status" -eq 0 ]
    [ -f "$HDIR/parser-work.md" ]
    grep -q $'\tparser-work\t' "$HLOG"
}

@test "fw handoff save: strips a handoff- prefix from the filename slug" {
    cp "$DOC" "$BATS_TEST_TMPDIR/handoff-alpha.md"
    "$FW_BIN" handoff save "$BATS_TEST_TMPDIR/handoff-alpha.md"
    [ -f "$HDIR/alpha.md" ]
}

@test "fw handoff save: errors on a missing file" {
    run "$FW_BIN" handoff save "$BATS_TEST_TMPDIR/nope.md"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "fw handoff save: requires a file argument" {
    run "$FW_BIN" handoff save
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage"* || "$output" == *"file"* ]]
}

@test "fw handoff save: overwriting replaces the doc and keeps one log entry" {
    "$FW_BIN" handoff save "$DOC" --name dup
    printf '# Resume: second version\n' >"$DOC"
    run "$FW_BIN" handoff save "$DOC" --name dup
    [ "$status" -eq 0 ]
    [ "$(grep -c $'\tdup\t' "$HLOG")" -eq 1 ]
    grep -q "second version" "$HDIR/dup.md"
}

@test "fw handoffs: lists saved handoffs; empty-state otherwise" {
    run "$FW_BIN" handoffs
    [ "$status" -eq 0 ]
    [[ "$output" == *"No handoffs"* ]]

    "$FW_BIN" handoff save "$DOC" --name listme
    run "$FW_BIN" handoffs
    [ "$status" -eq 0 ]
    [[ "$output" == *"listme"* ]]
    [[ "$output" == *"fix the parser"* ]]
}

@test "fw handoffs --grep: filters by slug/title/source" {
    "$FW_BIN" handoff save "$DOC" --name keepme
    printf '# Resume: unrelated\n' >"$BATS_TEST_TMPDIR/other.md"
    "$FW_BIN" handoff save "$BATS_TEST_TMPDIR/other.md" --name dropme

    run "$FW_BIN" handoffs --grep keep
    [ "$status" -eq 0 ]
    [[ "$output" == *"keepme"* ]]
    [[ "$output" != *"dropme"* ]]
}

@test "fw handoff show: prints the doc content" {
    "$FW_BIN" handoff save "$DOC" --name shown
    run "$FW_BIN" handoff show shown
    [ "$status" -eq 0 ]
    [[ "$output" == *"Some context."* ]]
}

@test "fw handoff show: picks via fzf when no slug is given" {
    "$FW_BIN" handoff save "$DOC" --name picked
    run "$FW_BIN" handoff show
    [ "$status" -eq 0 ]
    [[ "$output" == *"Some context."* ]]
}

@test "fw handoff show: errors on an unknown slug" {
    run "$FW_BIN" handoff show ghost
    [ "$status" -ne 0 ]
    [[ "$output" == *"No handoff"* ]]
}

@test "fw handoff done: marks a handoff done" {
    "$FW_BIN" handoff save "$DOC" --name finish
    run "$FW_BIN" handoff done finish
    [ "$status" -eq 0 ]
    [[ "$output" == *"done"* ]]
    grep -q $'\tfinish\tfix the parser\tdone\t' "$HLOG"
}

@test "fw handoff done: errors on an unknown slug" {
    "$FW_BIN" handoff save "$DOC" --name real
    run "$FW_BIN" handoff done ghost
    [ "$status" -ne 0 ]
}

@test "fw handoff resume: prints path/instructions and copies both commands to clipboard" {
    export FW_TEST_PBCOPY_LOG="$BATS_TEST_TMPDIR/clip.log"
    "$FW_BIN" handoff save "$DOC" --name resumeme
    run "$FW_BIN" handoff resume resumeme
    [ "$status" -eq 0 ]
    [[ "$output" == *"resumeme"* ]]
    # `fw create` takes a NAME and derives the branch itself, so the suggestion
    # must be the bare slug — 'prefix/slug' would be rejected by create.
    [[ "$output" == *"fw create resumeme"* ]]
    [[ "$output" != *"fw create jax/resumeme"* ]]
    # Both resume commands are copied as separate pbcopy calls, so a clipboard
    # manager (Alfred) captures each in its history.
    grep -q 'cat .*| claude' "$BATS_TEST_TMPDIR/clip.log"
    grep -q "fw create resumeme" "$BATS_TEST_TMPDIR/clip.log"
    ! grep -q "jax/resumeme" "$BATS_TEST_TMPDIR/clip.log"
    # `fw create` is copied last, so it lands on the live clipboard (the first
    # command to run); the `… | claude` pipe sits behind it in history.
    [[ "$(cat "$BATS_TEST_TMPDIR/clip.log")" == *"fw create resumeme" ]]
}

@test "fw handoff resume last: resolves the most recent pending handoff" {
    "$FW_BIN" handoff save "$DOC" --name older
    printf '# Resume: newer\n\nnew\n' >"$BATS_TEST_TMPDIR/n.md"
    "$FW_BIN" handoff save "$BATS_TEST_TMPDIR/n.md" --name newer

    run "$FW_BIN" handoff resume last
    [ "$status" -eq 0 ]
    [[ "$output" == *"newer"* ]]
}

@test "fw handoff: bare shows usage" {
    run "$FW_BIN" handoff
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage"* ]]
}

# --- finding 1: overwrite log-rewrite must be an exact field-2 match ---

@test "fw handoff save: re-saving a bracket-slug handoff preserves other rows" {
    "$FW_BIN" handoff save "$DOC" --name keep
    "$FW_BIN" handoff save "$DOC" --name 'notes[wip'
    # Re-save the bracket slug — this runs the overwrite log-rewrite. A regex
    # interpretation of the slug is an invalid pattern that would empty the log.
    "$FW_BIN" handoff save "$DOC" --name 'notes[wip'
    grep -q $'\tkeep\t' "$HLOG"
    [ "$(grep -c $'\tnotes\[wip\t' "$HLOG")" -eq 1 ]
}

@test "fw handoff save: re-saving a dotted slug doesn't delete lookalike rows" {
    "$FW_BIN" handoff save "$DOC" --name axb
    "$FW_BIN" handoff save "$DOC" --name 'a.b'
    # Re-save 'a.b'; a regex '.' would also match the 'axb' row and delete it.
    "$FW_BIN" handoff save "$DOC" --name 'a.b'
    grep -q $'\taxb\t' "$HLOG"
    [ "$(grep -c $'\ta\.b\t' "$HLOG")" -eq 1 ]
}

# --- finding 2: reject unpickable (whitespace) slugs at save time ---

@test "fw handoff save: rejects a slug containing whitespace" {
    run "$FW_BIN" handoff save "$DOC" --name 'meeting notes'
    [ "$status" -ne 0 ]
    [[ "$output" == *"slug"* ]]
    [ ! -f "$HDIR/meeting notes.md" ]
}

# --- finding 3: value-taking flags as the last argument error cleanly ---

@test "fw handoff save: --name as the last argument errors cleanly" {
    run "$FW_BIN" handoff save "$DOC" --name
    [ "$status" -ne 0 ]
    [[ "$output" == *"--name requires a value"* ]]
}

@test "fw handoffs --grep as the last argument errors cleanly" {
    run "$FW_BIN" handoffs --grep
    [ "$status" -ne 0 ]
    [[ "$output" == *"--grep requires a value"* ]]
}

# --- finding 4: a cancelled picker is a quiet no-op (not an error) ---

@test "fw handoff show: picker cancel is a quiet no-op" {
    "$FW_BIN" handoff save "$DOC" --name c1
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" handoff show
    [ "$status" -eq 0 ]
}

@test "fw handoff done: picker cancel is a quiet no-op" {
    "$FW_BIN" handoff save "$DOC" --name c2
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" handoff done
    [ "$status" -eq 0 ]
}

@test "fw handoff resume: picker cancel is a quiet no-op" {
    "$FW_BIN" handoff save "$DOC" --name c3
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" handoff resume
    [ "$status" -eq 0 ]
}

# --- manual-test finding 6: slugs must be valid `fw create` names ---

@test "fw handoff save: lowercases an uppercase filename slug" {
    cp "$DOC" "$BATS_TEST_TMPDIR/HANDOFF.md"
    run "$FW_BIN" handoff save "$BATS_TEST_TMPDIR/HANDOFF.md"
    [ "$status" -eq 0 ]
    [ -f "$HDIR/handoff.md" ]
    grep -q $'\thandoff\t' "$HLOG"
    # The resume suggestion must be a valid `fw create` name (lowercase only).
    run "$FW_BIN" handoff resume handoff
    [ "$status" -eq 0 ]
    [[ "$output" == *"fw create handoff"* ]]
    [[ "$output" != *"fw create HANDOFF"* ]]
}

@test "fw handoff save: lowercases an uppercase --name slug" {
    run "$FW_BIN" handoff save "$DOC" --name Parser-Work
    [ "$status" -eq 0 ]
    [ -f "$HDIR/parser-work.md" ]
    grep -q $'\tparser-work\t' "$HLOG"
}

# --- finding 12: 'handoff list' is not a hidden second spelling ---

@test "fw handoff list: is not a subcommand (use fw handoffs)" {
    run "$FW_BIN" handoff list
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown handoff subcommand"* ]]
}
