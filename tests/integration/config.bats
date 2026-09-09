load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    cd "$BATS_TEST_TMPDIR/myrepo"

    # A recording "editor" configs can point at (absolute path is fine — this
    # is user config, not the tool's internal PATH seam).
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/rec-editor" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/editor.log"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/rec-editor"
}

use_rec_editor() {
    printf 'editor=%q\n' "$BATS_TEST_TMPDIR/bin/rec-editor" \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
}

# --- bare `fw config` ---

@test "fw config: lists the three layer paths, marking missing files" {
    run "$FW_BIN" config
    [ "$status" -eq 0 ]
    [[ "$output" == *"myproj"* ]]
    echo "$output" | grep -F '.config/fast-worktree/config.sh' | grep -qF '(missing)'
    echo "$output" | grep -F '.fast-worktree/config.sh' | grep -qF '(missing)'
    echo "$output" | grep -F 'projects/myproj/config.sh' | grep -vqF '(missing)'
}

@test "fw config: shows the subcommand summary" {
    run "$FW_BIN" config
    [ "$status" -eq 0 ]
    [[ "$output" == *"open  [--global|--repo|--project]"* ]]
    [[ "$output" == *"show  [--global|--repo|--project]"* ]]
    [[ "$output" == *"set   [--global|--repo|--project] KEY V"* ]]
    [[ "$output" == *"get   [--global|--repo|--project] KEY"* ]]
    [[ "$output" == *"unset [--global|--repo|--project] KEY"* ]]
}

@test "fw config: works without a resolvable project" {
    cd "$BATS_TEST_TMPDIR"
    run "$FW_BIN" config
    [ "$status" -eq 0 ]
    [[ "$output" == *".config/fast-worktree/config.sh"* ]]
    [[ "$output" == *"fw init"* ]]
}

@test "fw config: repo line shows the .fw fallback when the repo uses it" {
    mkdir -p "$BATS_TEST_TMPDIR/myrepo/.fw"
    echo '# fallback' >"$BATS_TEST_TMPDIR/myrepo/.fw/config.sh"
    run "$FW_BIN" config
    [ "$status" -eq 0 ]
    [[ "$output" == *"/.fw/config.sh"* ]]
    echo "$output" | grep -F '/.fw/config.sh' | grep -vqF '(missing)'
}

@test "fw config: unknown subcommand errors with usage" {
    run "$FW_BIN" config bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
}

# --- fw config open ---

@test "config open: defaults to the project layer" {
    use_rec_editor
    run "$FW_BIN" config open
    [ "$status" -eq 0 ]
    grep -qF "projects/myproj/config.sh" "$BATS_TEST_TMPDIR/editor.log"
}

@test "config open --global: creates a commented template and opens it" {
    use_rec_editor
    run "$FW_BIN" config open --global
    [ "$status" -eq 0 ]
    [ -f "$FW_CONFIG_DIR/config.sh" ]
    grep -qF "$FW_CONFIG_DIR/config.sh" "$BATS_TEST_TMPDIR/editor.log"
    # header names the layer; nothing uncommented
    grep -qi 'global' "$FW_CONFIG_DIR/config.sh"
    ! grep -qvE '^(#|$)' "$FW_CONFIG_DIR/config.sh"
}

@test "config open --repo: creates the canonical .fast-worktree template" {
    use_rec_editor
    run "$FW_BIN" config open --repo
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/myrepo/.fast-worktree/config.sh" ]
    grep -qF ".fast-worktree/config.sh" "$BATS_TEST_TMPDIR/editor.log"
    ! grep -qvE '^(#|$)' "$BATS_TEST_TMPDIR/myrepo/.fast-worktree/config.sh"
}

@test "config open --repo: prefers an existing .fw fallback" {
    use_rec_editor
    mkdir -p "$BATS_TEST_TMPDIR/myrepo/.fw"
    echo '# existing fallback' >"$BATS_TEST_TMPDIR/myrepo/.fw/config.sh"
    run "$FW_BIN" config open --repo
    [ "$status" -eq 0 ]
    grep -qF "/.fw/config.sh" "$BATS_TEST_TMPDIR/editor.log"
    # no competing canonical file created
    [ ! -e "$BATS_TEST_TMPDIR/myrepo/.fast-worktree" ]
}

@test "config open: does not clobber an existing file" {
    use_rec_editor
    echo '# my prized config' >"$FW_CONFIG_DIR/config.sh"
    run "$FW_BIN" config open --global
    [ "$status" -eq 0 ]
    [ "$(cat "$FW_CONFIG_DIR/config.sh")" = "# my prized config" ]
}

@test "config open: falls back to \$EDITOR when no editor config" {
    EDITOR="$BATS_TEST_TMPDIR/bin/rec-editor" run "$FW_BIN" config open
    [ "$status" -eq 0 ]
    grep -qF "projects/myproj/config.sh" "$BATS_TEST_TMPDIR/editor.log"
}

@test "config open: errors when no editor is configured" {
    EDITOR="" run "$FW_BIN" config open
    [ "$status" -ne 0 ]
    [[ "$output" == *"editor"* ]]
}

@test "config open --global: works without a resolvable project" {
    cd "$BATS_TEST_TMPDIR"
    EDITOR="$BATS_TEST_TMPDIR/bin/rec-editor" run "$FW_BIN" config open --global
    [ "$status" -eq 0 ]
    grep -qF "$FW_CONFIG_DIR/config.sh" "$BATS_TEST_TMPDIR/editor.log"
}

@test "config open --repo: errors without a resolvable project" {
    cd "$BATS_TEST_TMPDIR"
    run "$FW_BIN" config open --repo
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
    [ ! -f "$BATS_TEST_TMPDIR/editor.log" ]
}

@test "config open: refuses an unregistered project name" {
    cd "$BATS_TEST_TMPDIR"
    FW_PROJECT=bogus EDITOR="" run "$FW_BIN" config open
    [ "$status" -ne 0 ]
    [[ "$output" == *"not registered"* ]]
    # no phantom project materialized, nothing opened
    [ ! -e "$FW_CONFIG_DIR/projects/bogus" ]
    [ ! -f "$BATS_TEST_TMPDIR/editor.log" ]
}

@test "config open: rejects extra arguments" {
    use_rec_editor
    run "$FW_BIN" config open --global extra
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
    [ ! -f "$BATS_TEST_TMPDIR/editor.log" ]
}

@test "config show: rejects contradictory layer flags" {
    run "$FW_BIN" config show --repo --project
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
}

@test "config open: unknown flag errors with usage" {
    run "$FW_BIN" config open --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
    [ ! -f "$BATS_TEST_TMPDIR/editor.log" ]
}

# --- fw config show ---

@test "config show: merged view reflects layer precedence" {
    mkdir -p "$FW_CONFIG_DIR"
    echo 'branch_prefix=fromglobal' >"$FW_CONFIG_DIR/config.sh"
    mkdir -p "$BATS_TEST_TMPDIR/myrepo/.fast-worktree"
    echo 'branch_prefix=fromrepo' >"$BATS_TEST_TMPDIR/myrepo/.fast-worktree/config.sh"
    echo 'branch_prefix=fromproject' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"

    run "$FW_BIN" config show
    [ "$status" -eq 0 ]
    [[ "$output" == *"branch_prefix=fromproject"* ]]
    [[ "$output" != *"fromrepo"* ]]
    [[ "$output" != *"fromglobal"* ]]
    [[ "$output" == *"project=myproj"* ]]
}

@test "config show: renders arrays and associative arrays" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
cow_assets=(one "two words")
claude_prompt_flags=([review]="/pr-review")
EOF
    run "$FW_BIN" config show
    [ "$status" -eq 0 ]
    [[ "$output" == *'cow_assets=('* ]]
    [[ "$output" == *'two words'* ]]
    [[ "$output" == *'claude_prompt_flags=('* ]]
    [[ "$output" == *'[review]="/pr-review"'* ]]
}

@test "config show --repo: cats the one file raw" {
    mkdir -p "$BATS_TEST_TMPDIR/myrepo/.fast-worktree"
    printf '# repo config\nbranch_prefix=x\n' \
        >"$BATS_TEST_TMPDIR/myrepo/.fast-worktree/config.sh"
    run "$FW_BIN" config show --repo
    [ "$status" -eq 0 ]
    [ "$output" = '# repo config
branch_prefix=x' ]
}

@test "config show --project: cats the one file raw" {
    run "$FW_BIN" config show --project
    [ "$status" -eq 0 ]
    [[ "$output" == "repo_root="* ]]
}

@test "config show --global: missing file errors with a creation hint" {
    run "$FW_BIN" config show --global
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error: no global config at"* ]]
    [[ "$output" == *"config open --global"* ]]
}

@test "config show --repo: missing file is an error" {
    run "$FW_BIN" config show --repo
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error: no repo config at"* ]]
}

@test "config show: unknown flag errors with usage" {
    run "$FW_BIN" config show --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
}

@test "config show: includes the fw usage classification surface" {
    cat >>"$FW_CONFIG_DIR/projects/myproj/config.sh" <<'EOF'
usage_own_prefixes=(claude 'app-[0-9]*')
usage_extra_prefixes=("cloer:review")
usage_tz="-10:HST"
EOF
    run "$FW_BIN" config show
    [ "$status" -eq 0 ]
    [[ "$output" == *'usage_own_prefixes=('* ]]
    [[ "$output" == *'app-[0-9]*'* ]]
    [[ "$output" == *'cloer:review'* ]]
    [[ "$output" == *'usage_tz=-10:HST'* ]]
}

# --- guard: the declared config surface matches _config_defaults ---

@test "config surface guard: _config_vars matches _config_defaults" {
    run bash -c '
        set -u
        source "$1/lib/config.sh"
        declared="" expected="" vars_before="" vars_after=""
        vars_before="$(compgen -v | sort)"
        _config_defaults
        vars_after="$(compgen -v | sort)"
        declared="$(comm -13 <(printf "%s\n" "$vars_before") <(printf "%s\n" "$vars_after"))"
        expected="$(printf "%s\n" "${_config_vars[@]}" | sort)"
        diff <(printf "%s\n" "$declared") <(printf "%s\n" "$expected")
    ' guard "$FW_ROOT"
    echo "$output"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
