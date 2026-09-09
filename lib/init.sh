# fw init — register the current repo as a project.

# cmd_init [name]
# Detects the main repo root from cwd (works from a linked worktree too),
# writes projects/<name>/config.sh with repo_root set and the main settings
# documented as comments, ready to uncomment.
cmd_init() {
    local name="${1:-}"

    local common root
    if ! common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
        echo "Error: not in a git repository" >&2
        return 1
    fi
    root="$(realpath "$(dirname "$common")")"

    if [[ -z "$name" ]]; then
        name="$(basename "$root")"
    fi
    name="${name,,}"
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "Error: invalid project name '$name' (lowercase letters, digits, - and _ only)" >&2
        return 1
    fi

    local cfg_dir proj_dir existing
    cfg_dir="$(fw_config_dir)"
    proj_dir="$cfg_dir/projects/$name"

    if [[ -f "$proj_dir/config.sh" ]]; then
        echo "Error: project '$name' is already registered ($proj_dir/config.sh)" >&2
        return 1
    fi

    while IFS= read -r existing; do
        [[ -n "$existing" ]] || continue
        if [[ "$(_project_repo_root "$existing")" == "$root" ]]; then
            echo "Error: this repo is already registered as project '$existing'" >&2
            return 1
        fi
    done < <(list_projects)

    mkdir -p "$proj_dir"
    cat >"$proj_dir/config.sh" <<EOF
# fast-worktree project config for '$name'
# Sourced bash: plain variables, plus optional hook functions.

repo_root=$(printf '%q' "$root")

# Worktrees live in a sibling directory by default:
# worktrees_dir=$(printf '%q' "$(dirname "$root")/${name}-worktrees")

# Branch prefix for 'fw create' (branch becomes <prefix>/<name>):
# branch_prefix=${USER:-you}

# Stack management: auto | graphite | github | none
# ('auto' uses graphite when .git/.graphite_metadata.db exists, else none)
# stack_backend=auto

# Build artifacts copy-on-write-cloned from the main checkout into new worktrees:
# cow_assets=(_build deps assets/node_modules)

# Worktree env file location, relative to the worktree root:
# env_file=.env.worktree

# Postgres: setting db_source enables per-worktree database cloning.
# db_source=${name}_dev
# db_prefix=${name}_
# db_setup_cmd="mix ecto.setup"
# db_template: clone new worktree DBs from this instead of db_source. Point it
# at a golden template DB that hook_sync keeps migrated, so live connections to
# db_source (e.g. the main checkout's dev server) never block the clone. Falls
# back to db_source when unset.
# db_template=${name}_dev_golden

# Ticket links (any tracker; {id} is the extracted ticket id):
# ticket_url="https://linear.app/yourorg/issue/{id}"

# Project commands:
# start_cmd="mix phx.server"
# check_cmd="mix check"

# Hooks (define as functions). A hook defined here chains onto the same hook
# from your global/repo config (both run) -- except hook_tmux_windows, which
# replaces it. Call 'fw_hook_replace hook_name' to override instead of chain,
# or 'fw_hook_chain hook_name' to chain hook_tmux_windows.
# hook_post_create()  { :; }
# hook_pre_delete()   { :; }
# hook_post_switch()  { :; }
# hook_sync()         { :; }
# hook_worktree_env() { :; }
EOF

    # Mark the new project as visited "just now" so it leads `fw switch-project`
    # instead of sinking to the never-switched bucket. This is the project's
    # first visit.
    record_project_visit "$name"

    echo "Registered project '$name' → $root"
    echo "Config written to $proj_dir/config.sh"
    return 0
}
