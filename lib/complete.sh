# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# Shell-completion data source for fast-worktree.
#
# `fw _complete <what>` prints newline-separated candidates on stdout for the
# static fish completion file to consume (see completions/fast-worktree.fish).
# It reads live config/state rather than a generated file, so completions never
# go stale. Each call must stay cheap (~10-20ms after config load): prefer a
# directory or log read over spawning git/gh/network subprocesses.
#
# Project-scoped kinds run after _require_project has loaded the active project
# (respecting the -p flag); `projects` is project-independent and resolves the
# registry directly.

# _complete_builtin_commands — the dispatchable built-in command names and
# aliases. Hand-maintained to mirror the dispatch case in the `fast-worktree`
# entrypoint; keep the two in sync when adding or renaming a command.
_complete_builtin_commands() {
    printf '%s\n' \
        setup init projects config switch-project sp create delete merge list info \
        refresh regen-env stop start check fix db clean switch sw switch-claude sc \
        stack-switch ss menu copy tmux-open last archive restore purge pull changes \
        stack up down top bottom restack sync open caddy prs pr checks checks-wait \
        retry ci comments ticket claude sessions skills usage shelve open-file \
        handoff handoffs notify logs log help
}

# _complete_worktrees — worktree names and their branches, plus `main` (the
# golden checkout, which `fw switch` accepts but which is not a worktree dir).
# Both name and branch are emitted because resolve_worktree accepts either, so
# every worktree-arg command (switch, delete, info, ...) can be completed by
# branch as well as by name.
_complete_worktrees() {
    {
        worktree_names_branches 2>/dev/null \
            | awk -F'\t' '{ print $1; if ($2 != "") print $2 }' || true
        echo main
    } | sort -u
}

# _complete_commands — built-ins plus the project's custom command executables.
_complete_commands() {
    _complete_builtin_commands
    local cfg_dir dir f
    cfg_dir="$(fw_config_dir)"
    for dir in "$cfg_dir/projects/$project/commands" "$cfg_dir/commands"; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*; do
            [[ -x "$f" && -f "$f" ]] || continue
            basename "$f"
        done
    done
}

# _complete_prompt_flags — the config-driven bare flags, as `--name` tokens
# (one per claude_prompt_flags key), for `fw create`/`fw pull` flag completion.
_complete_prompt_flags() {
    local name
    for name in "${!claude_prompt_flags[@]}"; do
        printf -- '--%s\n' "$name"
    done
}

# _complete_claude_models — keys of the claude_model_aliases map.
_complete_claude_models() {
    printf '%s\n' "${!claude_model_aliases[@]}"
}

# _complete_handoffs — saved handoff slugs (column 2 of the handoff log).
_complete_handoffs() {
    local log="$worktrees_dir/.fw_handoff_log"
    [[ -f "$log" ]] || return 0
    awk -F'\t' '{print $2}' "$log"
}

# _complete_archived — archived worktree names and branches (columns 2 and 3 of
# the archive log). `fw restore`/`purge` accept either form.
_complete_archived() {
    local log="$worktrees_dir/.fw_archive_log"
    [[ -f "$log" ]] || return 0
    awk -F'\t' '{ if ($2 != "") print $2; if ($3 != "") print $3 }' "$log" | sort -u
}

# _complete_projects — registered project names (project-independent).
_complete_projects() {
    list_projects
}

# _complete_config_keys — the managed scalar surface: the config keys that
# `fw config set`/`get`/`unset` accept. Array/associative keys are excluded
# (they're hand-edited via `fw config open`). Project-independent.
_complete_config_keys() {
    local key
    for key in "${_config_vars[@]}"; do
        _config_key_is_array "$key" || printf '%s\n' "$key"
    done
}

# _complete_stack_backends — recognized `stack_backend` values, for
# `fw config set stack_backend <TAB>`. Project-independent.
_complete_stack_backends() {
    _stack_backend_valid_values | tr ' ' '\n'
}

# _complete_copy_items — the item tokens `fw copy <TAB>` accepts. Kept in sync
# with the _copy_dispatch case in lib/copy.sh.
_complete_copy_items() {
    printf '%s\n' branch path pr-link pr-number ticket-url stack-branch
}

# cmd_complete <what> — entrypoint dispatch target. Project-scoped kinds assume
# _require_project already ran; `projects` and unknown kinds are handled here.
cmd_complete() {
    local what="${1:-}"
    case "$what" in
        worktrees)      _complete_worktrees ;;
        commands)       _complete_commands ;;
        prompt-flags)   _complete_prompt_flags ;;
        claude-models)  _complete_claude_models ;;
        handoffs)       _complete_handoffs ;;
        archived)       _complete_archived ;;
        projects)       _complete_projects ;;
        config-keys)    _complete_config_keys ;;
        stack-backends) _complete_stack_backends ;;
        copy-items)     _complete_copy_items ;;
        *)
            echo "Error: unknown completion kind '$what'" >&2
            echo "Valid kinds: worktrees commands prompt-flags claude-models handoffs archived projects config-keys stack-backends copy-items" >&2
            return 1
            ;;
    esac
}
