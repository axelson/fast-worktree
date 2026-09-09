load ../test_helper

# Tests for `fw _complete <what>` — the internal command the fish completions
# call to enumerate dynamic candidates live from config.

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    echo 'branch_prefix=jax' >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    cd "$BATS_TEST_TMPDIR/myrepo"

    WTDIR="$BATS_TEST_TMPDIR/myproj-worktrees"
    ALOG="$WTDIR/.fw_archive_log"
    HLOG="$WTDIR/.fw_handoff_log"
}

teardown() { "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true; }

# make_wt <name> <branch> — a fake worktree dir carrying an env file
make_wt() {
    mkdir -p "$WTDIR/$1"
    printf 'FW_WORKTREE=%s\nFW_BRANCH=%s\n' "$1" "$2" >"$WTDIR/$1/.env.worktree"
}

@test "_complete worktrees: lists worktree names plus main" {
    make_wt alpha jax/alpha
    make_wt beta jax/beta
    run "$FW_BIN" _complete worktrees
    [ "$status" -eq 0 ]
    [[ "$output" == *alpha* ]]
    [[ "$output" == *beta* ]]
    [[ "$output" == *main* ]]
}

@test "_complete worktrees: emits both names and branches" {
    # `fw switch` (and every worktree-arg command) resolves a bare branch via
    # resolve_worktree's FW_BRANCH scan, so completion must offer branches too.
    # Names are disjoint from branches (not a substring) so each assertion can
    # only pass if that column is actually emitted.
    make_wt alpha team/foo
    make_wt beta team/bar
    run "$FW_BIN" _complete worktrees
    [ "$status" -eq 0 ]
    [[ "$output" == *alpha* ]]     # name
    [[ "$output" == *team/foo* ]]  # branch
    [[ "$output" == *beta* ]]      # name
    [[ "$output" == *team/bar* ]]  # branch
}

@test "_complete worktrees: only main when no worktrees exist" {
    run "$FW_BIN" _complete worktrees
    [ "$status" -eq 0 ]
    [[ "$output" == *main* ]]
}

@test "_complete commands: includes built-ins and custom commands" {
    mkdir -p "$FW_CONFIG_DIR/commands" "$FW_CONFIG_DIR/projects/myproj/commands"
    printf '#!/bin/sh\n' >"$FW_CONFIG_DIR/commands/globalcmd"
    printf '#!/bin/sh\n' >"$FW_CONFIG_DIR/projects/myproj/commands/projcmd"
    chmod +x "$FW_CONFIG_DIR/commands/globalcmd" "$FW_CONFIG_DIR/projects/myproj/commands/projcmd"
    run "$FW_BIN" _complete commands
    [ "$status" -eq 0 ]
    [[ "$output" == *create* ]]
    [[ "$output" == *restack* ]]
    [[ "$output" == *globalcmd* ]]
    [[ "$output" == *projcmd* ]]
}

@test "_complete prompt-flags: lists claude_prompt_flags keys as bare flags" {
    printf 'declare -gA claude_prompt_flags=([review]="/pr-review" [understand]="/understand")\n' \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    run "$FW_BIN" _complete prompt-flags
    [ "$status" -eq 0 ]
    [[ "$output" == *--review* ]]
    [[ "$output" == *--understand* ]]
}

@test "_complete claude-models: lists claude_model_aliases keys" {
    printf 'declare -gA claude_model_aliases=([opus]="claude-opus" [fable]="claude-fable")\n' \
        >>"$FW_CONFIG_DIR/projects/myproj/config.sh"
    run "$FW_BIN" _complete claude-models
    [ "$status" -eq 0 ]
    [[ "$output" == *opus* ]]
    [[ "$output" == *fable* ]]
}

@test "_complete handoffs: lists saved handoff slugs" {
    mkdir -p "$WTDIR"
    printf '%s\t%s\t%s\t%s\n' 1000 fix-parser "Fix the parser" pending >"$HLOG"
    printf '%s\t%s\t%s\t%s\n' 1001 add-cache "Add cache" done >>"$HLOG"
    run "$FW_BIN" _complete handoffs
    [ "$status" -eq 0 ]
    [[ "$output" == *fix-parser* ]]
    [[ "$output" == *add-cache* ]]
}

@test "_complete archived: lists archived names and branches" {
    mkdir -p "$WTDIR"
    printf '%s\t%s\t%s\t%s\n' 1000 oldwt jax/oldwt "done with it" >"$ALOG"
    run "$FW_BIN" _complete archived
    [ "$status" -eq 0 ]
    [[ "$output" == *oldwt* ]]
    [[ "$output" == *jax/oldwt* ]]
}

@test "_complete projects: lists registered projects without -p" {
    register_project other "$BATS_TEST_TMPDIR/myrepo"
    run "$FW_BIN" _complete projects
    [ "$status" -eq 0 ]
    [[ "$output" == *myproj* ]]
    [[ "$output" == *other* ]]
}

@test "_complete projects: works from outside any project dir" {
    cd "$BATS_TEST_TMPDIR"
    run "$FW_BIN" _complete projects
    [ "$status" -eq 0 ]
    [[ "$output" == *myproj* ]]
}

@test "_complete config-keys: lists scalar keys and excludes array keys" {
    run "$FW_BIN" _complete config-keys
    [ "$status" -eq 0 ]
    [[ "$output" == *stack_backend* ]]
    [[ "$output" == *editor* ]]
    [[ "$output" == *branch_prefix* ]]
    # array / associative-array keys aren't settable, so they aren't offered
    [[ "$output" != *cow_assets* ]]
    [[ "$output" != *claude_prompt_flags* ]]
}

@test "_complete config-keys: works from outside any project dir" {
    cd "$BATS_TEST_TMPDIR"
    run "$FW_BIN" _complete config-keys
    [ "$status" -eq 0 ]
    [[ "$output" == *stack_backend* ]]
}

@test "_complete stack-backends: lists the recognized values" {
    run "$FW_BIN" _complete stack-backends
    [ "$status" -eq 0 ]
    [[ "$output" == *auto* ]]
    [[ "$output" == *graphite* ]]
    [[ "$output" == *github* ]]
    [[ "$output" == *none* ]]
}

@test "_complete: unknown kind errors with rc 1" {
    run "$FW_BIN" _complete bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *unknown* || "$output" == *Unknown* ]]
}

@test "_complete: missing kind errors with rc 1" {
    run "$FW_BIN" _complete
    [ "$status" -eq 1 ]
}

@test "_complete respects -p project flag for worktrees" {
    register_project proj2 "$BATS_TEST_TMPDIR/myrepo"
    local wtdir2="$BATS_TEST_TMPDIR/proj2-worktrees"
    mkdir -p "$wtdir2/gamma"
    printf 'FW_WORKTREE=%s\nFW_BRANCH=%s\n' gamma jax/gamma >"$wtdir2/gamma/.env.worktree"
    cd "$BATS_TEST_TMPDIR"
    run "$FW_BIN" -p proj2 _complete worktrees
    [ "$status" -eq 0 ]
    [[ "$output" == *gamma* ]]
}

@test "_complete is not listed in user-facing usage" {
    run "$FW_BIN" help
    [ "$status" -eq 0 ]
    [[ "$output" != *_complete* ]]
}

@test "_complete is documented in --help-internal" {
    run "$FW_BIN" --help-internal
    [ "$status" -eq 0 ]
    [[ "$output" == *_complete* ]]
}

@test "completions/fast-worktree.fish parses under fish -n" {
    command -v fish >/dev/null || skip "fish not installed"
    run fish -n "$FW_ROOT/completions/fast-worktree.fish"
    [ "$status" -eq 0 ]
}

# fish_complete <cmdline> [alias] — drive real fish completion end-to-end for
# the tool installed under an alias. Autoloads completions/fast-worktree.fish
# as <alias>.fish (as the docs' `ln -s` step does) and puts an <alias> ->
# FW_BIN executable on PATH, so this exercises the command-name binding, the
# __fw_complete delegation, and the backend together — the seam the bats
# `_complete` tests and `fish -n` both skip.
fish_complete() {
    local alias="${2:-fw}"
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$XDG_CONFIG_HOME/fish/completions"
    ln -sf "$FW_BIN" "$BATS_TEST_TMPDIR/bin/$alias"
    ln -sf "$FW_ROOT/completions/fast-worktree.fish" \
        "$XDG_CONFIG_HOME/fish/completions/$alias.fish"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" fish -c "complete -C '$1'"
}

@test "fish: fw sw completes worktree names and branches" {
    command -v fish >/dev/null || skip "fish not installed"
    make_wt alpha team/foo   # name disjoint from branch so each assert is real
    run fish_complete "fw sw "
    [ "$status" -eq 0 ]
    [[ "$output" == *alpha* ]]     # worktree name
    [[ "$output" == *team/foo* ]]  # branch
    [[ "$output" == *main* ]]
}

@test "fish: completions bind to whatever alias the file is installed as" {
    command -v fish >/dev/null || skip "fish not installed"
    make_wt alpha team/foo
    run fish_complete "ftw sw " ftw
    [ "$status" -eq 0 ]
    [[ "$output" == *alpha* ]]
    [[ "$output" == *team/foo* ]]
}

@test "fish: fw config completes its subcommands" {
    command -v fish >/dev/null || skip "fish not installed"
    run fish_complete "fw config "
    [ "$status" -eq 0 ]
    [[ "$output" == *open* ]]
    [[ "$output" == *show* ]]
    [[ "$output" == *get* ]]
    [[ "$output" == *set* ]]
    [[ "$output" == *unset* ]]
}

@test "fish: fw config set completes scalar config keys" {
    command -v fish >/dev/null || skip "fish not installed"
    run fish_complete "fw config set "
    [ "$status" -eq 0 ]
    [[ "$output" == *stack_backend* ]]
}

@test "fish: fw config set stack_backend completes backend values" {
    command -v fish >/dev/null || skip "fish not installed"
    run fish_complete "fw config set stack_backend "
    [ "$status" -eq 0 ]
    [[ "$output" == *none* ]]
    [[ "$output" == *graphite* ]]
}

@test "fish: fw switch-claude completes --project-only" {
    command -v fish >/dev/null || skip "fish not installed"
    run fish_complete "fw switch-claude --project-on"
    [ "$status" -eq 0 ]
    [[ "$output" == *--project-only* ]]
}

@test "fish: fw sc (alias) completes --project-only" {
    command -v fish >/dev/null || skip "fish not installed"
    run fish_complete "fw sc --"
    [ "$status" -eq 0 ]
    [[ "$output" == *--project-only* ]]
}

@test "fish: fw switch completes --quiet" {
    command -v fish >/dev/null || skip "fish not installed"
    run fish_complete "fw switch --qu"
    [ "$status" -eq 0 ]
    [[ "$output" == *--quiet* ]]
}

@test "fish: fw last completes --quiet" {
    command -v fish >/dev/null || skip "fish not installed"
    run fish_complete "fw last --qu"
    [ "$status" -eq 0 ]
    [[ "$output" == *--quiet* ]]
}

@test "fish: fw create completes --no-switch" {
    command -v fish >/dev/null || skip "fish not installed"
    run fish_complete "fw create foo --no-sw"
    [ "$status" -eq 0 ]
    [[ "$output" == *--no-switch* ]]
}

@test "fish: fw pull completes --no-switch" {
    command -v fish >/dev/null || skip "fish not installed"
    run fish_complete "fw pull somebranch --no-sw"
    [ "$status" -eq 0 ]
    [[ "$output" == *--no-switch* ]]
}

@test "fish: fw usage is offered as a subcommand" {
    command -v fish >/dev/null || skip "fish not installed"
    run fish_complete "fw usa"
    [ "$status" -eq 0 ]
    [[ "$output" == *usage* ]]
}

@test "fish: fw usage completes its flags" {
    command -v fish >/dev/null || skip "fish not installed"
    run fish_complete "fw usage --"
    [ "$status" -eq 0 ]
    [[ "$output" == *--since* ]]
    [[ "$output" == *--period* ]]
    [[ "$output" == *--category* ]]
    [[ "$output" == *--weight* ]]
    [[ "$output" == *--json* ]]
}

@test "_complete commands: includes merge switch-claude sc caddy usage" {
    run "$FW_BIN" _complete commands
    [ "$status" -eq 0 ]
    [[ "$output" == *merge* ]]
    [[ "$output" == *switch-claude* ]]
    [[ $'\n'"$output"$'\n' == *$'\nsc\n'* ]]
    [[ "$output" == *caddy* ]]
    [[ "$output" == *usage* ]]
}

@test "fish: -p PROJECT is forwarded so completion scopes to that project" {
    command -v fish >/dev/null || skip "fish not installed"
    make_wt alpha team/foo                       # myproj (resolved from cwd)
    register_project proj2 "$BATS_TEST_TMPDIR/myrepo"
    local wtdir2="$BATS_TEST_TMPDIR/proj2-worktrees"
    mkdir -p "$wtdir2/gamma"
    printf 'FW_WORKTREE=%s\nFW_BRANCH=%s\n' gamma team/gg >"$wtdir2/gamma/.env.worktree"
    run fish_complete "fw -p proj2 sw "
    [ "$status" -eq 0 ]
    [[ "$output" == *gamma* ]]      # proj2's worktree name
    [[ "$output" == *team/gg* ]]    # proj2's branch
    [[ "$output" != *alpha* ]]      # NOT the cwd project's worktree
}

@test "fish: glued -pPROJECT (the form fish inserts) is forwarded too" {
    # Tab-completing the -p flag inserts the glued form `-pproj2`, so it must
    # scope exactly like the spaced form.
    command -v fish >/dev/null || skip "fish not installed"
    make_wt alpha team/foo
    register_project proj2 "$BATS_TEST_TMPDIR/myrepo"
    local wtdir2="$BATS_TEST_TMPDIR/proj2-worktrees"
    mkdir -p "$wtdir2/gamma"
    printf 'FW_WORKTREE=%s\nFW_BRANCH=%s\n' gamma team/gg >"$wtdir2/gamma/.env.worktree"
    run fish_complete "fw -pproj2 sw "
    [ "$status" -eq 0 ]
    [[ "$output" == *gamma* ]]
    [[ "$output" == *team/gg* ]]
    [[ "$output" != *alpha* ]]
}
