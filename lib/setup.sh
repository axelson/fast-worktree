# shellcheck disable=SC2154  # config globals assigned by load_config.
#
# fw setup — first-run onboarding. Symlinks the shipped fish completions (so
# repo updates flow through without re-running) under whatever name the tool is
# invoked as, and drops a commented-out global config template if none exists.

# _setup_completions <name> — link completions/fast-worktree.fish into fish's
# completions dir as <name>.fish. The name matches the command being completed,
# per fish's autoload convention and the completion file's own basename binding.
_setup_completions() {
    local name="$1"
    local src="$SCRIPT_DIR/completions/fast-worktree.fish"
    local dir="${XDG_CONFIG_HOME:-$HOME/.config}/fish/completions"
    local dest="$dir/$name.fish"

    if [[ ! -f "$src" ]]; then
        echo "Error: completion file not found at $src" >&2
        return 1
    fi
    mkdir -p "$dir"
    ln -sf "$src" "$dest"
    echo "Installing fish completions..."
    echo "  Linked $dest -> $src"
}

# _setup_global_config — write a commented-out global config template, but only
# when none exists; an existing config is never touched.
_setup_global_config() {
    local cfg_dir cfg
    cfg_dir="$(fw_config_dir)"
    cfg="$cfg_dir/config.sh"

    if [[ -f "$cfg" ]]; then
        echo "Global config already exists at $cfg — leaving it untouched"
        return 0
    fi
    mkdir -p "$cfg_dir"
    cat >"$cfg" <<'TEMPLATE'
# fast-worktree global config — applies to every project.
# Per-project files (~/.config/fast-worktree/projects/<name>/config.sh) override these.
# Uncomment and edit as needed.

# default_project=""        # project to use when cwd matches none
# branch_prefix="$USER"     # prefix for new branches (e.g. jason/my-feature)
# github_username=""        # GitHub login for PR / assignment lookups
# stack_backend=auto        # auto | graphite | none
TEMPLATE
    echo "Writing global config..."
    echo "  Wrote $cfg (commented template)"
}

# cmd_setup [--name NAME] — install completions + config template. NAME defaults
# to the basename the tool was invoked as ($0), so the completion binds to the
# same alias; override it when invoking by full path but completing under a
# shorter alias.
cmd_setup() {
    local name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                [[ $# -ge 2 && -n "$2" ]] || { echo "Error: --name requires a value" >&2; return 1; }
                name="$2"; shift 2 ;;
            --name=*)
                name="${1#--name=}"
                [[ -n "$name" ]] || { echo "Error: --name requires a value" >&2; return 1; }
                shift ;;
            -*) echo "Error: unknown flag '$1'" >&2; return 1 ;;
            *) echo "Error: unexpected argument '$1'" >&2; return 1 ;;
        esac
    done
    if [[ -z "$name" ]]; then
        name="$(basename "$0")"
        # $0 can be a login shell name (bash) when sourced oddly; fall back.
        [[ -n "$name" && "$name" != bash && "$name" != -* ]] || name="fast-worktree"
    fi

    _setup_completions "$name" || return 1
    _setup_global_config || return 1
    echo "Done. Restart fish or run: exec fish"
}
