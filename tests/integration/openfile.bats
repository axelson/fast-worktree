load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"

    # A recording "editor" the config points at (absolute path is fine — this is
    # user config, not the tool's internal PATH seam).
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/rec-editor" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/editor.log"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/rec-editor"
    printf 'editor=%q\n' "$BATS_TEST_TMPDIR/bin/rec-editor" >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    export FW_TEST_OPEN_LOG="$BATS_TEST_TMPDIR/open.log"
    WT="$BATS_TEST_TMPDIR/myproj-worktrees/alpha"
}

teardown() { "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true; }

@test "fw open-file: opens a picked markdown file in the editor" {
    "$FW_BIN" create alpha
    printf '# Notes\n' >"$WT/notes.md"

    run "$FW_BIN" open-file alpha
    [ "$status" -eq 0 ]
    grep -q "notes.md" "$BATS_TEST_TMPDIR/editor.log"
}

@test "fw open-file: opens a picked html file through the browser seam" {
    "$FW_BIN" create alpha
    printf '<html></html>\n' >"$WT/report.html"

    run "$FW_BIN" open-file alpha
    [ "$status" -eq 0 ]
    grep -q "report.html" "$FW_TEST_OPEN_LOG"
    [ ! -f "$BATS_TEST_TMPDIR/editor.log" ]
}

@test "fw open-file: only offers untracked md/html files" {
    "$FW_BIN" create alpha
    # tracked markdown must not appear
    printf '# tracked\n' >"$WT/tracked.md"
    git -C "$WT" add tracked.md
    git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m addmd
    printf '# untracked\n' >"$WT/fresh.md"
    printf 'plain\n' >"$WT/ignore.txt"

    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    "$FW_BIN" open-file alpha
    grep -q "fresh.md" "$BATS_TEST_TMPDIR/offered"
    ! grep -q "tracked.md" "$BATS_TEST_TMPDIR/offered"
    ! grep -q "ignore.txt" "$BATS_TEST_TMPDIR/offered"
}

@test "fw open-file: reports when there are no untracked md/html files" {
    "$FW_BIN" create alpha
    run "$FW_BIN" open-file alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"No untracked"* ]]
    [ ! -f "$BATS_TEST_TMPDIR/editor.log" ]
}

@test "fw open-file: a cancelled picker is a quiet no-op" {
    "$FW_BIN" create alpha
    printf '# Notes\n' >"$WT/notes.md"
    export FW_TEST_FZF_CANCEL=1

    run "$FW_BIN" open-file alpha
    [ "$status" -eq 0 ]
    [ ! -f "$BATS_TEST_TMPDIR/editor.log" ]
}

@test "fw open-file: errors when opening markdown with no editor configured" {
    # Overwrite the config without an editor, and clear EDITOR.
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    "$FW_BIN" create alpha
    printf '# Notes\n' >"$WT/notes.md"

    EDITOR="" run "$FW_BIN" open-file alpha
    [ "$status" -ne 0 ]
    [[ "$output" == *"editor"* ]]
}
