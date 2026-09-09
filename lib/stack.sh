# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# Stack backend dispatch.
#
# A stack backend answers seven questions about branch stacks; everything else
# fw does with stacks is presentation on top of these:
#   stack_branches        — ordered bottom→top, current marked with a leading *
#   stack_parent <branch> — parent branch (trunk when unstacked/unknown)
#   stack_track <branch> <parent>  — register a new branch (cwd = its worktree)
#   stack_adopt <remote-branch>    — fetch a branch + its stack metadata
#   stack_delete_branch <branch>   — remove branch + metadata
#   stack_restack <worktree-dir>   — restack that worktree's branch + everything
#                                    downstack of it; abort a partial restack on
#                                    conflict and return nonzero. Callers walk
#                                    the stack bottom→top so parents land first.
#   stack_sync            — refresh stack state from the remote
#
# Implementations live in lib/stack/<backend>.sh as <backend>_stack_<op>.
# Presentation over these answers (the cmd_* functions) lives in
# lib/stack/present.sh, keeping this file a pure dispatch seam.

# _graphite_metadata_db — path to Graphite's SQLite metadata. Lives in the
# repo's common git dir; when a hand-written config points repo_root at a
# linked worktree (.git is a file), resolve through git.
_graphite_metadata_db() {
    local gitdir="$repo_root/.git"
    if [[ -f "$gitdir" ]]; then
        gitdir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$gitdir")"
    fi
    echo "$gitdir/.graphite_metadata.db"
}

# _stack_adopt_fallback_warn <branch> — called on the local-branch adopt
# fallback, after a fetch/get to origin has already failed. Stays silent when
# origin is reachable and simply lacks the branch (ls-remote exit 2 — the
# normal unpushed case); warns when origin couldn't be reached at all, so a
# network failure isn't mistaken for a deliberate local-only branch.
_stack_adopt_fallback_warn() {
    local rc
    git -C "$repo_root" ls-remote --exit-code --heads origin "$1" >/dev/null 2>&1
    rc=$?
    [[ $rc -eq 2 ]] && return 0
    echo "Warning: could not reach origin to check $1; using the local branch" >&2
}

# _stack_backend_valid_values — the recognized stack_backend values, the one
# source of truth shared by the write-time validator (`fw config set`) and the
# use-time resolver below. `github` is recognized but errors as unimplemented
# when actually resolved.
_stack_backend_valid_values() {
    echo "auto graphite github none"
}

# _config_validate_stack_backend <value> — value-validator hook for the
# `stack_backend` config key (discovered by `fw config set` via the
# `_config_validate_<key>` naming convention). Accepts any recognized value;
# rejects typos.
_config_validate_stack_backend() {
    local value="$1" v expected
    for v in $(_stack_backend_valid_values); do
        [[ "$value" == "$v" ]] && return 0
        expected+="${expected:+, }$v"
    done
    echo "Error: invalid stack_backend '$value' (expected: $expected)" >&2
    return 1
}

# resolve_stack_backend — sets STACK_BACKEND from config; `auto` picks
# graphite when its metadata db exists and gt is installed, else none.
resolve_stack_backend() {
    STACK_BACKEND="$stack_backend"
    if [[ "$STACK_BACKEND" == auto ]]; then
        if [[ -f "$(_graphite_metadata_db)" ]]; then
            if command -v gt >/dev/null 2>&1; then
                STACK_BACKEND=graphite
            else
                echo "Warning: graphite metadata found but gt is not installed; using the none backend" >&2
                STACK_BACKEND=none
            fi
        else
            STACK_BACKEND=none
        fi
    fi
    case "$STACK_BACKEND" in
        graphite)
            if ! command -v gt >/dev/null 2>&1; then
                echo "Error: stack_backend=graphite but gt is not installed" >&2
                return 1
            fi
            ;;
        none) ;;
        github)
            echo "Error: the github stack backend is not implemented yet (use graphite or none)" >&2
            return 1
            ;;
        *)
            echo "Error: unknown stack_backend '$STACK_BACKEND' (expected: $(_stack_backend_valid_values | tr ' ' '/'))" >&2
            return 1
            ;;
    esac
    return 0
}

# shellcheck disable=SC2120,SC2119  # dispatchers forward "$@" uniformly
stack_branches()      { "${STACK_BACKEND}_stack_branches" "$@"; }
stack_parent()        { "${STACK_BACKEND}_stack_parent" "$@"; }
stack_track()         { "${STACK_BACKEND}_stack_track" "$@"; }
stack_adopt()         { "${STACK_BACKEND}_stack_adopt" "$@"; }
stack_delete_branch() { "${STACK_BACKEND}_stack_delete_branch" "$@"; }
stack_restack()       { "${STACK_BACKEND}_stack_restack" "$@"; }
stack_sync()          { "${STACK_BACKEND}_stack_sync" "$@"; }
