# Shared setup for fast-worktree bats tests.
#
# Every test runs in an isolated environment: a scratch HOME (so user config,
# git config, and XDG paths never touch the real machine) and tests/shims/
# first on PATH (so fake external tools win over real ones).

FW_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
FW_BIN="$FW_ROOT/fast-worktree"
FW_CONFIG_DIR=""   # set by isolate_env

isolate_env() {
    # Drop any git repo-local env vars (GIT_DIR, GIT_INDEX_FILE, GIT_WORK_TREE,
    # ...) inherited from the caller. Git exports these into hooks, so a suite
    # run from a pre-commit hook would otherwise see the scratch `git init`s
    # redirected at the real repo. rev-parse prints the canonical var list.
    unset $(git rev-parse --local-env-vars) 2>/dev/null || true

    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    # Pin the cache root too: `fw usage` keeps its rebuildable SQLite cache
    # under XDG_CACHE_HOME, which a developer may export machine-wide.
    export XDG_CACHE_HOME="$HOME/.cache"
    FW_CONFIG_DIR="$XDG_CONFIG_HOME/fast-worktree"
    mkdir -p "$FW_CONFIG_DIR/projects"
    export PATH="$FW_ROOT/tests/shims:$PATH"
    unset FW_PROJECT
    # Keep skills discovery hermetic even when the developer's own machine
    # points Claude Code at a custom config dir.
    unset CLAUDE_CONFIG_DIR
    # The suite may itself run inside the user's tmux; the tool under test
    # must not think it's attached to the isolated test server.
    unset TMUX
    cd "$BATS_TEST_TMPDIR"
}

# make_repo <dir> — scratch git repo with one commit on main
make_repo() {
    mkdir -p "$1"
    git -C "$1" init -q -b main
    git -C "$1" -c user.email=test@test -c user.name=test \
        commit -q --allow-empty -m init
}

# register_project <name> <repo_root> — minimal project config; tests append
# extra lines to $FW_CONFIG_DIR/projects/<name>/config.sh directly
register_project() {
    local dir="$FW_CONFIG_DIR/projects/$1"
    mkdir -p "$dir"
    printf 'repo_root=%q\n' "$2" >"$dir/config.sh"
}
