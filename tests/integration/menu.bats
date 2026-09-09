load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=me' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"
}

teardown() {
    "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true
}

@test "fw menu: offers the built-in entries" {
    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_CANCEL=1

    run "$FW_BIN" menu
    [ "$status" -eq 0 ]

    grep -q "Open PR on GitHub" "$BATS_TEST_TMPDIR/offered"
    grep -q "CI checks" "$BATS_TEST_TMPDIR/offered"
    grep -q "Switch worktree" "$BATS_TEST_TMPDIR/offered"
    # Entries carry a hidden command field.
    grep -q $'Open PR on GitHub\tpr open' "$BATS_TEST_TMPDIR/offered"
}

@test "fw menu: appends the menu_extra_entries provider and dispatches the pick" {
    mkdir -p "$FW_CONFIG_DIR/projects/myproj/commands"
    cat >"$FW_CONFIG_DIR/projects/myproj/commands/_menutest" <<EOF
#!/bin/sh
echo ran >"\$HOME/menu-ran"
EOF
    chmod +x "$FW_CONFIG_DIR/projects/myproj/commands/_menutest"
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
menu_extra_entries() { printf '%s\t%s\n' "Run Thing" "_menutest"; }
EOF

    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_SELECT="Run Thing"

    run "$FW_BIN" menu
    [ "$status" -eq 0 ]

    grep -q "Run Thing" "$BATS_TEST_TMPDIR/offered"
    [ -f "$HOME/menu-ran" ]
}

@test "fw menu: offers 'Open local server' when web_port_var is set" {
    echo 'web_port_var=WEB_PORT' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_CANCEL=1

    run "$FW_BIN" menu
    [ "$status" -eq 0 ]

    grep -q $'Open local server\topen' "$BATS_TEST_TMPDIR/offered"
    # A browser-opening entry has no wait marker.
    ! grep -q $'Open local server\topen\twait' "$BATS_TEST_TMPDIR/offered"
}

@test "fw menu: hides 'Open local server' when web_port_var is unset" {
    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_CANCEL=1

    run "$FW_BIN" menu
    [ "$status" -eq 0 ]

    ! grep -q "Open local server" "$BATS_TEST_TMPDIR/offered"
}

@test "fw menu: menu_order floats named entries to the top in order" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
menu_order=("Switch project" "CI checks")
EOF
    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_CANCEL=1

    run "$FW_BIN" menu
    [ "$status" -eq 0 ]

    [ "$(cut -f1 <"$BATS_TEST_TMPDIR/offered" | sed -n 1p)" = "Switch project" ]
    [ "$(cut -f1 <"$BATS_TEST_TMPDIR/offered" | sed -n 2p)" = "CI checks" ]
}

@test "fw menu: cancel is a quiet no-op" {
    export FW_TEST_FZF_CANCEL=1
    run "$FW_BIN" menu
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "fw menu: dispatches a command with a quoted spaced argument intact" {
    mkdir -p "$FW_CONFIG_DIR/projects/myproj/commands"
    cat >"$FW_CONFIG_DIR/projects/myproj/commands/_argecho" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >"\$HOME/menu-args"
EOF
    chmod +x "$FW_CONFIG_DIR/projects/myproj/commands/_argecho"
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
menu_extra_entries() { printf '%s\t%s\n' "Hold It" '_argecho --reason "on hold"'; }
EOF

    export FW_TEST_FZF_SELECT="Hold It"
    run "$FW_BIN" menu
    [ "$status" -eq 0 ]

    [ "$(sed -n 1p "$HOME/menu-args")" = "--reason" ]
    [ "$(sed -n 2p "$HOME/menu-args")" = "on hold" ]
}

@test "fw menu: output-producing core entries carry the wait marker" {
    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_CANCEL=1

    run "$FW_BIN" menu
    [ "$status" -eq 0 ]

    grep -q $'CI checks\tchecks\twait' "$BATS_TEST_TMPDIR/offered"
    grep -q $'PR info\tpr info\twait' "$BATS_TEST_TMPDIR/offered"
    grep -q $'diff --stat\tchanges --stat\twait' "$BATS_TEST_TMPDIR/offered"
    # A browser-opening entry has no wait marker.
    grep -q $'Open PR on GitHub\tpr open' "$BATS_TEST_TMPDIR/offered"
    ! grep -q $'Open PR on GitHub\tpr open\twait' "$BATS_TEST_TMPDIR/offered"
}

@test "fw menu: a failing non-wait entry surfaces the failure and preserves its exit code" {
    # A popup (display-popup -E) closes when the command exits, so a failing
    # non-wait entry must announce the failure (legacy menu_run parity) rather
    # than flashing and vanishing. Without a tty the pause is skipped so the
    # test can't hang.
    mkdir -p "$FW_CONFIG_DIR/projects/myproj/commands"
    printf '#!/bin/sh\necho boom >&2\nexit 3\n' \
        >"$FW_CONFIG_DIR/projects/myproj/commands/_boom"
    chmod +x "$FW_CONFIG_DIR/projects/myproj/commands/_boom"
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
menu_extra_entries() { printf '%s\t%s\n' "Boom" "_boom"; }
EOF

    export FW_TEST_FZF_SELECT="Boom"
    run "$FW_BIN" menu
    [ "$status" -eq 3 ]
    [[ "$output" == *"Command failed"* ]]
}

@test "fw menu: a provider entry overrides the core entry with the same label" {
    mkdir -p "$FW_CONFIG_DIR/projects/myproj/commands"
    cat >"$FW_CONFIG_DIR/projects/myproj/commands/_customchecks" <<EOF
#!/bin/sh
echo ran-custom >"\$HOME/which-ran"
EOF
    chmod +x "$FW_CONFIG_DIR/projects/myproj/commands/_customchecks"
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
menu_extra_entries() { printf '%s\t%s\n' "CI checks" "_customchecks"; }
EOF

    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_SELECT="CI checks"
    run "$FW_BIN" menu
    [ "$status" -eq 0 ]

    # "CI checks" appears exactly once (no duplicate core+provider entry)...
    [ "$(cut -f1 <"$BATS_TEST_TMPDIR/offered" | grep -c '^CI checks$')" -eq 1 ]
    # ...and the provider's command won (last wins).
    [ -f "$HOME/which-ran" ]
}

@test "fw menu: menu_order emits a repeated label only once" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
menu_order=("CI checks" "CI checks")
EOF
    export FW_TEST_FZF_LINES="$BATS_TEST_TMPDIR/offered"
    export FW_TEST_FZF_CANCEL=1

    run "$FW_BIN" menu
    [ "$status" -eq 0 ]

    [ "$(cut -f1 <"$BATS_TEST_TMPDIR/offered" | grep -c '^CI checks$')" -eq 1 ]
    [ "$(cut -f1 <"$BATS_TEST_TMPDIR/offered" | sed -n 1p)" = "CI checks" ]
}
