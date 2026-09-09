# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# Hook execution and the FW_* environment contract.
#
# Hooks are plain functions defined in sourced config. Every hook runs through
# run_hook so the environment, working directory, and failure policy are
# uniform instead of re-decided at each call site.
#
# The create-time hook set (all optional; see _populate_worktree):
#   hook_worktree_env  — appends project-shaped keys to the env file (envfile.sh)
#   hook_pre_db        — project setup that must precede the DB step, e.g. the
#                        env/secret files a db_setup_cmd fallback sources
#   hook_post_create   — setup that needs the worktree DB to exist
# Plus hook_pre_delete / hook_post_switch / hook_sync on their own commands.
#
#   hook_tmux_windows  — lays out a session's tmux windows, called once at
#                        session birth (in _ensure_tmux_session) with the FW_*
#                        contract already exported. Its body calls the core
#                        fw_window helper once per window (lib/switch.sh). The
#                        golden checkout and other projects' main sessions are
#                        born with FW_WORKTREE empty, the signal a hook uses to
#                        give main a different (or no) layout.
#
# Chaining. A hook defined at several config levels chains: every level runs, in
# least-specific-first order, so a project extends rather than silently erases a
# global hook. Composition happens in lib/config.sh at source time, so run_hook
# still just calls the hook by name. All hooks chain by default EXCEPT
# hook_tmux_windows, which replaces (two window layouts would collide). A config
# flips its level's direction with `fw_hook_replace <hook>` / `fw_hook_chain
# <hook>`. Under a fatal policy the chain stops at the first failing level; under
# warn every level runs and each failing level is reported by its scope
# (global/repo/project); under ignore every level runs silently.

# _export_fw_project_env — the project-scoped half of the contract, shared by
# hooks, custom subcommands, and db_setup_cmd.
_export_fw_project_env() {
    export FW_PROJECT="$project"
    export FW_REPO_ROOT="$repo_root"
    export FW_WORKTREES_DIR="$worktrees_dir"
    # FW_BIN lets an exec'd custom command re-invoke the tool: `fw` is only a
    # shell alias, invisible to scripts, so scripts run "$FW_BIN" instead.
    export FW_BIN="$SCRIPT_DIR/fast-worktree"
    # FW_BROWSER carries the browser preference across the exec boundary so
    # custom commands open URLs the same way core's _open_url does. Exported
    # even when empty so `${FW_BROWSER:-…}` falls through cleanly.
    export FW_BROWSER="${default_browser:-}"
}

# _export_fw_env <name> <branch> <wt_path> — full contract including the
# worktree-scoped variables.
_export_fw_env() {
    _export_fw_project_env
    export FW_WORKTREE="$1"
    export FW_BRANCH="$2"
    export FW_WORKTREE_PATH="$3"
}

# _export_fw_session_env <name> <branch> <path> — the FW_* contract as it must
# stand when a tmux session is born, so a project's hook_tmux_windows runs with
# the worktree context. Session birth (in _ensure_tmux_session) runs project
# hook code, so the contract must be exported before it — see the invariant in
# docs/architecture.md. The golden checkout and other projects' main sessions
# have no worktree: callers pass an empty name/branch and the repo root as
# <path>, so FW_WORKTREE lands empty — the documented signal a hook uses to give
# main a different (or no) layout via `[[ -n "$FW_WORKTREE" ]] || return 0`.
# Delegates to _export_fw_env so the contract stays single-sourced.
_export_fw_session_env() {
    _export_fw_env "$1" "$2" "$3"
}

# _run_in_worktree_env <name> <branch> <wt_path> <cmd> — the single env-apply
# prelude: cd into the worktree, export the full FW_* contract, apply the
# worktree's env file, then eval the command in that subshell. Every consumer
# that runs project code with the worktree environment (start/check/fix,
# db_setup_cmd, hook_worktree_env) goes through here, so a new FW_* var
# reaches all of them at once.
_run_in_worktree_env() {
    local name="$1" branch="$2" wt_path="$3" cmd="$4"
    (
        cd "$wt_path" || exit 1
        _export_fw_env "$name" "$branch" "$wt_path"
        set -a
        # shellcheck disable=SC1090  # dynamic source: the env-file path is
        # derived from the worktree/config at runtime, not a literal to follow.
        source "$wt_path/$env_file"
        set +a
        eval "$cmd"
    )
}

# run_hook <fn> <dir> <policy> [args…]
# policy: fatal  — propagate failure to the caller
#         warn   — report and continue
#         ignore — continue silently
# No-op (success) when the hook isn't defined. Export the FW_* contract
# before calling.
run_hook() {
    local fn="$1" dir="$2" policy="$3"
    shift 3
    declare -F "$fn" >/dev/null || return 0

    # A chained hook (see lib/config.sh) is a dispatcher over per-level
    # functions; it reads this to decide whether to stop at the first failing
    # level (fatal) or run them all and report (warn/ignore). local, so it stays
    # visible to the subshell below via dynamic scope without leaking out.
    local __fw_hook_policy="$policy"
    if (cd "$dir" && "$fn" "$@"); then
        return 0
    fi
    # A multi-level chain's dispatcher already reported the failing level(s) by
    # scope; don't stack a generic message on top — just honor the policy's
    # return contract (fatal fails the caller, warn/ignore continue).
    if [[ -n "${__fw_hook_is_chain[$fn]:-}" ]]; then
        [[ "$policy" == fatal ]] && return 1
        return 0
    fi
    case "$policy" in
        fatal)
            echo "Error: $fn failed" >&2
            return 1
            ;;
        warn)
            echo "Warning: $fn failed" >&2
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
