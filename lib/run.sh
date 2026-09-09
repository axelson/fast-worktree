# shellcheck disable=SC2154  # config globals (start_cmd, …) are assigned by
# load_config.
#
# Configurable project commands: `fw start`, `fw check`, `fw fix`.
#
# Each runs the matching config command (start_cmd/check_cmd/fix_cmd) inside
# the worktree directory with the full FW_* environment contract plus the
# worktree's env-file keys — the same environment hooks and db_setup_cmd see.
# The command's exit status is the command's, so `check`/`fix` fail the shell
# when the underlying tooling fails.
#
# The legacy felt-worktree hardcoded felt's app/frontend command split (mix
# credo/dialyzer, pnpm checks) and backgrounded the Phoenix server with a
# port-in-use check and a log file; all of that is project-specific and lives
# in the project's own command (or the felt extension layer), not core. Core
# runs the configured command in the foreground.
#
# Legacy cmd_check/cmd_fix announced failures through the notify layer; the
# port deliberately drops that — auto voice/desktop alerts on every fast lint
# failure would be noise (checks-wait wires notify because announcement is
# intrinsic there). A project that wants it can call `fw notify fix "check
# failed"` from its check_cmd/fix_cmd, or add it in the extension layer.

# _run_worktree_cmd <cmd-var> <label> [name]
_run_worktree_cmd() {
    local cmd_var="$1" label="$2" wt_arg="${3:-}"
    local cmd="${!cmd_var}"

    if [[ -z "$cmd" ]]; then
        echo "Error: '$label' is not configured for project '$project' (set $cmd_var)" >&2
        return 1
    fi

    # --allow-main: start/check/fix run the project command in the golden
    # checkout too (its dev server, its checks on trunk).
    resolve_worktree --allow-main "$wt_arg" || return 1
    # shellcheck disable=SC2153  # WT_PATH is set by resolve_worktree
    read_worktree_env "$WT_PATH" || return 1

    _run_in_worktree_env "$WT_NAME" "$WT_BRANCH" "$WT_PATH" "$cmd"
}

cmd_start() { _run_worktree_cmd start_cmd start "${1:-}"; }
cmd_check() { _run_worktree_cmd check_cmd check "${1:-}"; }
cmd_fix()   { _run_worktree_cmd fix_cmd fix "${1:-}"; }
