# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# `fw config`: find, read, and edit the layered config files without
# memorizing paths. Bare `fw config` lists the layer paths for the current
# project; `open` edits one layer, creating a commented template when the
# file is missing; `show` prints the effective merged config, or one file
# raw. Precedence (last wins, see lib/config.sh): defaults → global →
# repo-local → user project.

_config_usage() {
    cat <<EOF
Usage: fw config                                          config file paths for the current project
       fw config open  [--global|--repo|--project]        edit a config file (default: project)
       fw config show  [--global|--repo|--project]        effective merged config, or one file raw
       fw config get   [--global|--repo|--project] KEY    a config value (default: effective merged)
       fw config set   [--global|--repo|--project] KEY V  set a scalar config value (default: project)
       fw config unset [--global|--repo|--project] KEY    remove a scalar config value (default: project)
EOF
}

cmd_config() {
    case "${1:-}" in
        "")    _config_overview ;;
        open)  shift; _config_open "$@" ;;
        show)  shift; _config_show "$@" ;;
        get)   shift; _config_get "$@" ;;
        set)   shift; _config_set "$@" ;;
        unset) shift; _config_unset "$@" ;;
        *)
            echo "Error: unknown config subcommand '$1'" >&2
            _config_usage >&2
            return 1
            ;;
    esac
}

# _config_parse_layer <default> [flag...] — echo the layer a --global/--repo/
# --project flag selects; <default> when no flag ("" means merged view).
# Anything beyond one flag is rejected rather than silently dropped.
_config_parse_layer() {
    local default="$1"
    shift
    if [[ $# -gt 1 ]]; then
        echo "Error: unexpected argument '$2'" >&2
        _config_usage >&2
        return 1
    fi
    case "${1:-}" in
        "")        echo "$default" ;;
        --global)  echo global ;;
        --repo)    echo repo ;;
        --project) echo project ;;
        *)
            echo "Error: unknown config flag '$1'" >&2
            _config_usage >&2
            return 1
            ;;
    esac
}

# _config_layer_path <layer> <project> — echo the config path for <layer>.
# For repo, an existing .fw/ fallback wins over the canonical .fast-worktree/
# location so we never point at (or create) a second competing file.
_config_layer_path() {
    local layer="$1" proj="${2:-}"
    case "$layer" in
        global)  echo "$(fw_config_dir)/config.sh" ;;
        project) echo "$(fw_config_dir)/projects/$proj/config.sh" ;;
        repo)
            local root
            root="$(_project_repo_root "$proj")"
            if [[ -z "$root" ]]; then
                echo "Error: project '$proj' has no repo_root registered (run 'fw init' from its repo)" >&2
                return 1
            fi
            if [[ ! -f "$root/.fast-worktree/config.sh" && -f "$root/.fw/config.sh" ]]; then
                echo "$root/.fw/config.sh"
            else
                echo "$root/.fast-worktree/config.sh"
            fi
            ;;
    esac
}

# _config_tilde <path> — abbreviate $HOME to ~ for display.
_config_tilde() {
    printf '%s\n' "${1/#"$HOME"/\~}"
}

_config_overview_line() {
    local layer="$1" path="$2" mark=""
    [[ -f "$path" ]] || mark=" (missing)"
    printf '  %-8s %s%s\n' "$layer" "$(_config_tilde "$path")" "$mark"
}

_config_overview() {
    local proj
    if proj="$(resolve_project "$PROJECT_FLAG" 2>/dev/null)"; then
        echo "Config files for project '$proj' (precedence: last wins):"
        _config_overview_line global "$(_config_layer_path global)"
        local repo_path
        if repo_path="$(_config_layer_path repo "$proj" 2>/dev/null)"; then
            _config_overview_line repo "$repo_path"
        else
            printf '  %-8s %s\n' repo "(no repo_root registered)"
        fi
        _config_overview_line project "$(_config_layer_path project "$proj")"
    else
        echo "Config files (precedence: last wins):"
        _config_overview_line global "$(_config_layer_path global)"
        echo
        echo "No project resolved for $(pwd) — run from a registered repo"
        echo "(or 'fw init' there) to see its repo and project config paths."
    fi

    cat <<EOF

Subcommands:
  open  [--global|--repo|--project]        edit a config file (default: project)
  show  [--global|--repo|--project]        effective merged config, or one file raw
  get   [--global|--repo|--project] KEY    a config value (default: effective merged)
  set   [--global|--repo|--project] KEY V  set a scalar config value (default: project)
  unset [--global|--repo|--project] KEY    remove a scalar config value (default: project)
EOF
}

# _config_template <layer> — commented starter content for a missing config
# file: the layer's role in precedence and a pointer to the variable list,
# nothing uncommented, so creating it never changes behavior.
_config_template() {
    case "$1" in
        global) cat <<'EOF'
# fast-worktree global config — applies to every project.
# Precedence (last wins): defaults -> THIS FILE -> repo-local config
# -> user project config.
#
# Sourced as bash. For the variable list and effective values run
# `fw config show` (defaults: _config_defaults in lib/config.sh).
EOF
            ;;
        repo) cat <<'EOF'
# fast-worktree repo-local config — checked into the repo, shared by
# everyone who works on it.
# Precedence (last wins): defaults -> global config -> THIS FILE
# -> user project config.
#
# Sourced as bash. For the variable list and effective values run
# `fw config show` (defaults: _config_defaults in lib/config.sh).
EOF
            ;;
        project) cat <<'EOF'
# fast-worktree user project config — personal settings for this project;
# wins over every other layer.
# Precedence (last wins): defaults -> global config -> repo-local config
# -> THIS FILE.
#
# Sourced as bash. For the variable list and effective values run
# `fw config show` (defaults: _config_defaults in lib/config.sh).
EOF
            ;;
    esac
}

_config_open() {
    local layer
    layer="$(_config_parse_layer project "$@")" || return 1

    # Load the project's config — it supplies `editor` (and repo_root for
    # --repo). Only the global layer tolerates a missing/unregistered project;
    # the others refuse an unregistered name rather than materializing a
    # phantom projects/<name>/ entry from the template.
    local proj=""
    if [[ "$layer" == global ]]; then
        if proj="$(resolve_project "$PROJECT_FLAG" 2>/dev/null)"; then
            load_config "$proj" 2>/dev/null || proj=""
        fi
    else
        proj="$(resolve_project "$PROJECT_FLAG")" || return 1
        load_config "$proj" || return 1
    fi

    local path
    path="$(_config_layer_path "$layer" "$proj")" || return 1

    if [[ ! -f "$path" ]]; then
        mkdir -p "$(dirname "$path")"
        _config_template "$layer" >"$path"
        echo "Created $(_config_tilde "$path")"
    fi
    _open_in_editor "$path"
}

# _config_print_var <name> — one config variable in readable bash-ish form:
# scalars bare, arrays and associative arrays in initializer syntax
# (declare -p minus the `declare -a`/`-A` prefix).
_config_print_var() {
    local var="$1" decl
    decl="$(declare -p "$var" 2>/dev/null)" || return 0
    case "$decl" in
        "declare -a "* | "declare -A "*)
            printf '%s\n' "${decl#declare -? }"
            ;;
        *)
            printf '%s=%s\n' "$var" "${!var}"
            ;;
    esac
}

_config_show() {
    local layer
    layer="$(_config_parse_layer "" "$@")" || return 1

    if [[ -z "$layer" ]]; then
        # Effective merged view: load config exactly as any other command
        # does, then print the known config surface.
        local proj var
        proj="$(resolve_project "$PROJECT_FLAG")" || return 1
        load_config "$proj" || return 1
        for var in "${_config_vars[@]}"; do
            _config_print_var "$var"
        done
        return 0
    fi

    local proj=""
    if [[ "$layer" != global ]]; then
        proj="$(resolve_project "$PROJECT_FLAG")" || return 1
    fi
    local path
    path="$(_config_layer_path "$layer" "$proj")" || return 1
    if [[ ! -f "$path" ]]; then
        echo "Error: no $layer config at $(_config_tilde "$path")" >&2
        if [[ "$layer" == global ]]; then
            echo "Run 'fw config open --global' to create it" >&2
        fi
        return 1
    fi
    cat "$path"
}

# --- get / set / unset: the managed scalar surface ------------------------
#
# These edit and read a single scalar key in one layer. Array/assoc keys
# (cow_assets, claude_prompt_flags, …) are out of scope — they stay hand-edited via
# `config open`/`show`. Keys are validated against the config surface
# (_config_vars); a value validator runs if a `_config_validate_<key>` hook
# exists (e.g. stack_backend, from lib/stack.sh).

# Two layer parsers exist by design: `_config_parse_layer` (above) is for
# open/show, which take *only* an optional flag and reject any positional;
# `_config_lead_layer` is for get/set/unset, which take a leading flag *plus*
# KEY/VALUE positionals, so it peels just the flag and leaves the rest.
#
# _config_lead_layer <default> <first-arg> — flag-first layer parser: echo
# "<layer> <consumed>" where <consumed> is 1 when a leading --global/--repo/
# --project flag was recognized (caller shifts it off), else 0. Returns nonzero
# for an unrecognized -- flag so the caller can error.
_config_lead_layer() {
    local default="$1"
    case "${2:-}" in
        --global)  echo "global 1" ;;
        --repo)    echo "repo 1" ;;
        --project) echo "project 1" ;;
        --*)       return 1 ;;
        *)         echo "$default 0" ;;
    esac
}

# _config_validate_key <key> — the key must be part of the config surface.
_config_validate_key() {
    local key="$1" v
    for v in "${_config_vars[@]}"; do
        [[ "$key" == "$v" ]] && return 0
    done
    echo "Error: unknown config key '$key'" >&2
    _config_usage >&2
    return 1
}

# _config_key_is_array <key> — true when the key's default is declared as an
# array/associative array (so set/get/unset must refuse it). Read the type back
# off _config_defaults in a subshell so there's no second list to keep in sync.
_config_key_is_array() {
    local key="$1" decl
    decl="$( _config_defaults; declare -p "$key" 2>/dev/null )"
    [[ "$decl" == "declare -a"* || "$decl" == "declare -A"* ]]
}

# _config_reject_array <key> <hint> — print the standard array-key refusal.
_config_reject_array() {
    echo "Error: '$1' is an array/associative config value — $2" >&2
    return 1
}

# _config_quote_value <value> — single-quote for bash, escaping embedded single
# quotes as '\''. Uniform quoting keeps every written value safe.
_config_quote_value() {
    local v="$1" out="'" i c
    for (( i = 0; i < ${#v}; i++ )); do
        c="${v:i:1}"
        if [[ "$c" == "'" ]]; then
            out+="'\\''"
        else
            out+="$c"
        fi
    done
    printf "%s'" "$out"
}

# _config_has_active <path> <key> — true when <path> has an uncommented
# assignment of <key>.
_config_has_active() {
    local path="$1" key="$2"
    [[ -f "$path" ]] && grep -Eq "^[[:space:]]*${key}=" "$path"
}

# _config_rewrite <path> <re> [replacement] — rewrite the first line matching
# <re>: replace it with <replacement> when given, else delete it. Atomic
# (temp + mv), leaving every other line untouched.
#
# The replacement travels through ENVIRON (read raw by awk), never `awk -v`,
# which would run backslash-escape processing and mangle the `'\''` escaping
# _config_quote_value emits. `re` via -v is safe — keys are bare identifiers.
_config_rewrite() {
    local path="$1" re="$2"
    local tmp="$path.fw-tmp.$$"
    local rc=0
    if [[ $# -ge 3 ]]; then
        FW_REPL="$3" awk -v re="$re" \
            '!done && $0 ~ re { print ENVIRON["FW_REPL"]; done = 1; next } { print }' \
            "$path" >"$tmp" || rc=$?
    else
        awk -v re="$re" \
            '!done && $0 ~ re { done = 1; next } { print }' \
            "$path" >"$tmp" || rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$path"
}

# _config_write_var <path> <key> <value> — idempotent, comment-aware write:
# replace an active assignment in place; else uncomment+rewrite a `# key=`
# template line in place; else append. All other lines are preserved.
_config_write_var() {
    local path="$1" key="$2" value="$3"
    local line
    line="$key=$(_config_quote_value "$value")"
    if grep -Eq "^[[:space:]]*${key}=" "$path" 2>/dev/null; then
        _config_rewrite "$path" "^[[:space:]]*${key}=" "$line"
    elif grep -Eq "^[[:space:]]*#[[:space:]]*${key}=" "$path" 2>/dev/null; then
        _config_rewrite "$path" "^[[:space:]]*#[[:space:]]*${key}=" "$line"
    else
        printf '%s\n' "$line" >>"$path"
    fi
}

# _config_delete_var <path> <key> — drop the first active assignment of <key>,
# leaving comments and other lines untouched.
_config_delete_var() {
    _config_rewrite "$1" "^[[:space:]]*${2}="
}

# _config_layer_rank <layer> — precedence rank (higher wins): last one loaded.
_config_layer_rank() {
    case "$1" in
        defaults) echo 0 ;;
        global)   echo 1 ;;
        repo)     echo 2 ;;
        project)  echo 3 ;;
        *)        echo -1 ;;
    esac
}

# _config_winning_layer <proj> <key> — the highest-precedence layer that has an
# active assignment of <key>, or `defaults` if none does.
_config_winning_layer() {
    local proj="$1" key="$2" layer path
    for layer in project repo global; do
        path="$(_config_layer_path "$layer" "$proj" 2>/dev/null)" || continue
        if _config_has_active "$path" "$key"; then
            echo "$layer"
            return 0
        fi
    done
    echo defaults
}

_config_set() {
    local parsed layer
    parsed="$(_config_lead_layer project "${1:-}")" || {
        echo "Error: unknown config flag '$1'" >&2; _config_usage >&2; return 1; }
    layer="${parsed% *}"
    [[ "${parsed##* }" == 1 ]] && shift

    if [[ $# -ne 2 ]]; then
        echo "Error: 'config set' needs a key and a value" >&2
        _config_usage >&2
        return 1
    fi
    local key="$1" value="$2"

    _config_validate_key "$key" || return 1
    if _config_key_is_array "$key"; then
        _config_reject_array "$key" "edit it by hand with 'fw config open' (see 'fw config show')"
        return 1
    fi
    if declare -F "_config_validate_$key" >/dev/null; then
        "_config_validate_$key" "$value" || return 1
    fi

    local proj=""
    if [[ "$layer" == global ]]; then
        if proj="$(resolve_project "$PROJECT_FLAG" 2>/dev/null)"; then
            load_config "$proj" 2>/dev/null || proj=""
        fi
    else
        proj="$(resolve_project "$PROJECT_FLAG")" || return 1
        load_config "$proj" || return 1
    fi

    local path
    path="$(_config_layer_path "$layer" "$proj")" || return 1
    if [[ ! -f "$path" ]]; then
        mkdir -p "$(dirname "$path")"
        _config_template "$layer" >"$path"
        echo "Created $(_config_tilde "$path")"
    fi
    _config_write_var "$path" "$key" "$value"
    echo "Set $key = $(_config_quote_value "$value") ($layer: $(_config_tilde "$path"))"

    # Shadow warning: a higher-precedence layer would override this write.
    if [[ -n "$proj" ]]; then
        local winner
        winner="$(_config_winning_layer "$proj" "$key")"
        if [[ "$winner" != "$layer" ]] \
            && [[ "$(_config_layer_rank "$winner")" -gt "$(_config_layer_rank "$layer")" ]]; then
            echo "note: $key is also set in the $winner layer, which takes precedence" >&2
        fi
    fi
}

_config_get() {
    local parsed layer
    parsed="$(_config_lead_layer '' "${1:-}")" || {
        echo "Error: unknown config flag '$1'" >&2; _config_usage >&2; return 1; }
    layer="${parsed% *}"
    [[ "${parsed##* }" == 1 ]] && shift

    if [[ $# -ne 1 ]]; then
        echo "Error: 'config get' needs a key" >&2
        _config_usage >&2
        return 1
    fi
    local key="$1"
    _config_validate_key "$key" || return 1
    if _config_key_is_array "$key"; then
        _config_reject_array "$key" "use 'fw config show'"
        return 1
    fi

    if [[ -z "$layer" ]]; then
        # Effective merged value — defaults guarantee one, so this always exits 0.
        local proj
        proj="$(resolve_project "$PROJECT_FLAG")" || return 1
        load_config "$proj" || return 1
        printf '%s\n' "${!key}"
        return 0
    fi

    local proj=""
    if [[ "$layer" != global ]]; then
        proj="$(resolve_project "$PROJECT_FLAG")" || return 1
    fi
    local path
    path="$(_config_layer_path "$layer" "$proj")" || return 1
    # Not set in this layer → empty stdout, nonzero (scriptable "unset here").
    if [[ ! -f "$path" ]] || ! _config_has_active "$path" "$key"; then
        return 1
    fi
    _peek_config_var "$path" "$key"
}

_config_unset() {
    local parsed layer
    parsed="$(_config_lead_layer project "${1:-}")" || {
        echo "Error: unknown config flag '$1'" >&2; _config_usage >&2; return 1; }
    layer="${parsed% *}"
    [[ "${parsed##* }" == 1 ]] && shift

    if [[ $# -ne 1 ]]; then
        echo "Error: 'config unset' needs a key" >&2
        _config_usage >&2
        return 1
    fi
    local key="$1"
    _config_validate_key "$key" || return 1
    if _config_key_is_array "$key"; then
        _config_reject_array "$key" "edit it by hand with 'fw config open'"
        return 1
    fi

    local proj=""
    if [[ "$layer" == global ]]; then
        if proj="$(resolve_project "$PROJECT_FLAG" 2>/dev/null)"; then
            load_config "$proj" 2>/dev/null || proj=""
        fi
    else
        proj="$(resolve_project "$PROJECT_FLAG")" || return 1
        load_config "$proj" || return 1
    fi

    local path
    path="$(_config_layer_path "$layer" "$proj")" || return 1
    if [[ ! -f "$path" ]] || ! _config_has_active "$path" "$key"; then
        echo "$key was not set in $layer — nothing to do"
        return 0
    fi
    _config_delete_var "$path" "$key"
    echo "Unset $key in $layer ($(_config_tilde "$path"))"

    # Report the value that now takes effect after removal.
    if [[ -n "$proj" ]]; then
        load_config "$proj" 2>/dev/null || true
        local winner
        winner="$(_config_winning_layer "$proj" "$key")"
        printf "now resolves to '%s' (%s)\n" "${!key}" "$winner"
    fi
}
