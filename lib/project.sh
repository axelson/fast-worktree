# Project registry and resolution.
#
# The registry is the directory tree ~/.config/fast-worktree/projects/<name>/;
# each project's config.sh declares repo_root. Matching a cwd back to a project
# uses git itself: `git rev-parse --git-common-dir` points at the main repo's
# .git from anywhere — the main checkout, any linked worktree, or a
# subdirectory of either.

list_projects() {
    local dir name
    for dir in "$(fw_config_dir)/projects"/*/; do
        if [[ -f "$dir/config.sh" ]]; then
            # basename via parameter expansion (no fork): strip the trailing
            # slash, then everything up to the last remaining one.
            name="${dir%/}"
            printf '%s\n' "${name##*/}"
        fi
    done
    return 0
}

# _project_repo_root <name> — echoes the registered repo_root, tilde/symlink
# resolved; empty if unset.
_project_repo_root() {
    local cfg root
    cfg="$(fw_config_dir)/projects/$1/config.sh"
    root="$(_peek_config_var "$cfg" repo_root)"
    if [[ -n "$root" ]]; then
        realpath "$root" 2>/dev/null || true
    fi
}

# resolve_project [explicit-name]
# Echoes the project name. Order: explicit arg → cwd match against registered
# repo_roots → $FW_PROJECT → default_project from global config → error.
resolve_project() {
    local explicit="${1:-}"
    if [[ -n "$explicit" ]]; then
        echo "$explicit"
        return 0
    fi

    # git >= 2.31 for --path-format=absolute
    local common
    if common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
        local cwd_root name
        cwd_root="$(realpath "$(dirname "$common")" 2>/dev/null)"
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            if [[ "$(_project_repo_root "$name")" == "$cwd_root" ]]; then
                echo "$name"
                return 0
            fi
        done < <(list_projects)
    fi

    if [[ -n "${FW_PROJECT:-}" ]]; then
        echo "$FW_PROJECT"
        return 0
    fi

    local global_cfg
    global_cfg="$(fw_config_dir)/config.sh"
    if [[ -f "$global_cfg" ]]; then
        local default
        default="$(_peek_config_var "$global_cfg" default_project)"
        if [[ -n "$default" ]]; then
            echo "$default"
            return 0
        fi
    fi

    echo "Error: no project found for $(pwd) — run 'fw init' from the repo, pass -p <name>, or set default_project" >&2
    return 1
}
