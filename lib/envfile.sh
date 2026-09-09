# shellcheck disable=SC2154,SC2034  # config globals ($db_prefix, …) are assigned
# by load_config; WT_* are set here for callers.
#
# The .env.worktree contract.
#
# Core allocates a unique port slot and writes canonical FW_* keys; the
# project's hook_worktree_env appends project-shaped lines (derived ports,
# renamed DB vars, …) with the FW_* values in scope. Location within the
# worktree comes from $env_file config (default: repo root).
#
# Convention: any appended key ending in _PORT is a real listening port that
# `fw stop` may kill processes on.

# db_name_for_worktree <name> [suffix]
# Postgres identifiers cap at 63 bytes; truncate the name, never the
# prefix/suffix.
db_name_for_worktree() {
    local name="$1" suffix="${2:-}"
    local sanitized="${name//-/_}"
    local db_name="${db_prefix}${sanitized}${suffix}"
    if [[ ${#db_name} -gt 63 ]]; then
        local max_name_len=$((63 - ${#db_prefix} - ${#suffix}))
        sanitized="${sanitized:0:$max_name_len}"
        db_name="${db_prefix}${sanitized}${suffix}"
    fi
    echo "$db_name"
}

# _scan_port_slots — slots claimed by whatever project the
# $worktrees_dir/$repo_root/$env_file globals currently describe, one per line:
# every linked worktree plus the golden checkout itself, which is a first-class
# port holder (its slot is written by `fw regen-env` in the main checkout).
_scan_port_slots() {
    local f
    for f in "$worktrees_dir"/*/"$env_file" "$repo_root/$env_file"; do
        if [[ -f "$f" ]]; then
            grep '^FW_PORT_SLOT=' "$f" | cut -d= -f2
        fi
    done
    return 0
}

# used_port_slots — slots claimed by existing worktrees across ALL registered
# projects, one per line. Slots share the single 100-999 range, and hooks in
# different projects may derive real ports from the same base, so a slot
# claimed anywhere is unavailable everywhere. Other projects' configs are
# loaded in a subshell so their globals never leak into this invocation.
used_port_slots() {
    _scan_port_slots
    local p
    while IFS= read -r p; do
        [[ -n "$p" && "$p" != "$project" ]] || continue
        (
            load_config "$p" >/dev/null 2>&1 || exit 0
            _scan_port_slots
        )
    done < <(list_projects)
    return 0
}

# _slot_available <used> <slot> — a slot is available only when it AND both
# neighbors are unclaimed: hooks commonly derive ports as base+slot and
# base+slot+1, so adjacent slots collide at the derived-port level.
_slot_available() {
    local used="$1" slot="$2"
    [[ "$used" != *$'\n'"$slot"$'\n'* &&
       "$used" != *$'\n'"$((slot - 1))"$'\n'* &&
       "$used" != *$'\n'"$((slot + 1))"$'\n'* ]]
}

# allocate_port_slot — random available slot in 100–999; after 100 random
# misses, linear-scan the range; error out rather than spin forever.
allocate_port_slot() {
    local used slot attempt
    used=$'\n'"$(used_port_slots)"$'\n'
    for ((attempt = 0; attempt < 100; attempt++)); do
        slot=$((RANDOM % 900 + 100))
        if _slot_available "$used" "$slot"; then
            echo "$slot"
            return 0
        fi
    done
    for ((slot = 100; slot <= 999; slot++)); do
        if _slot_available "$used" "$slot"; then
            echo "$slot"
            return 0
        fi
    done
    echo "Error: no free port slot in 100-999 (delete some worktrees first)" >&2
    return 1
}

# write_worktree_env <wt_path> <name> <branch> [slot]
# Without a slot, allocates a fresh one; regen passes the existing slot.
write_worktree_env() {
    local wt_path="$1" name="$2" branch="$3"
    local file="$wt_path/$env_file"
    local slot="${4:-}"
    if [[ -z "$slot" ]]; then
        slot="$(allocate_port_slot)"
    fi

    mkdir -p "$(dirname "$file")"
    {
        echo "FW_WORKTREE=$name"
        echo "FW_BRANCH=$branch"
        echo "FW_PORT_SLOT=$slot"
        if [[ -n "$db_source" ]]; then
            if [[ "$name" == "main" ]]; then
                # The golden checkout uses the project's default database, not a
                # cloned per-worktree one — record db_source verbatim.
                echo "FW_DB_NAME=$db_source"
            else
                echo "FW_DB_NAME=$(db_name_for_worktree "$name")"
                echo "FW_TEST_DB_NAME=$(db_name_for_worktree "$name" _test)"
            fi
        fi
    } >"$file"

    # The hook sees the same FW_* contract as every other hook, plus the
    # file's keys, and runs inside the worktree. The helper sources the file
    # before the appended output lands, so the read completes ahead of the
    # write.
    if declare -F hook_worktree_env >/dev/null; then
        _run_in_worktree_env "$name" "$branch" "$wt_path" hook_worktree_env >>"$file"
    fi
}

# cmd_regen_env [name] — rewrite the env file from current config, keeping
# the worktree's identity and port slot.
cmd_regen_env() {
    # --allow-main: the golden checkout is a valid regen target — this is how it
    # first joins the port map (allocate-if-missing below).
    resolve_worktree --allow-main "${1:-}" || return 1

    local slot="" branch=""
    # shellcheck disable=SC2153  # WT_PATH is set by resolve_worktree
    if [[ -f "$WT_PATH/$env_file" ]]; then
        read_worktree_env "$WT_PATH" || return 1
        slot="$WT_PORT_SLOT"
        branch="$WT_BRANCH"
    elif [[ "$WT_NAME" == "main" ]]; then
        # First-time golden env: no file to preserve, so allocate a fresh slot
        # (write_worktree_env does this when slot is empty) and derive the
        # branch from trunk — this is how the main checkout joins the port map.
        branch="$(trunk_branch)"
    else
        # A worktree with no env file is a real error, not something to allocate.
        read_worktree_env "$WT_PATH" || return 1
    fi

    write_worktree_env "$WT_PATH" "$WT_NAME" "$branch" "$slot"
    # The golden checkout must stay clean, but its env file lands in the tracked
    # working tree — warn (never auto-fix) when it isn't excluded, so the user
    # can add it to .gitignore or .git/info/exclude themselves.
    if [[ "$WT_NAME" == "main" ]] &&
        ! git -C "$WT_PATH" check-ignore -q "$env_file" 2>/dev/null; then
        echo "Warning: $env_file is not gitignored — add it to .gitignore or" \
            ".git/info/exclude to keep the golden checkout clean" >&2
    fi
    # Re-read so WT_* (and the reported slot) reflect any freshly allocated slot.
    read_worktree_env "$WT_PATH"
    # A re-derived env file may change the web port, so refresh the Caddy map
    # (no-op unless the domain layer is configured).
    regenerate_caddyfile
    echo "Regenerated $env_file for $WT_NAME (slot $WT_PORT_SLOT)"
    return 0
}

# read_worktree_env <wt_path> — sets WT_NAME, WT_BRANCH, WT_PORT_SLOT,
# WT_DB_NAME, WT_TEST_DB_NAME from the worktree's env file.
read_worktree_env() {
    local wt_path="$1"
    local file="$wt_path/$env_file"
    if [[ ! -f "$file" ]]; then
        echo "Error: no $env_file found in $wt_path" >&2
        return 1
    fi
    WT_NAME="" WT_BRANCH="" WT_PORT_SLOT="" WT_DB_NAME="" WT_TEST_DB_NAME=""
    local key val
    while IFS='=' read -r key val; do
        case "$key" in
            FW_WORKTREE)    WT_NAME="$val" ;;
            FW_BRANCH)      WT_BRANCH="$val" ;;
            FW_PORT_SLOT)   WT_PORT_SLOT="$val" ;;
            FW_DB_NAME)     WT_DB_NAME="$val" ;;
            FW_TEST_DB_NAME) WT_TEST_DB_NAME="$val" ;;
        esac
    done <"$file"
    # Legacy-created env files predate FW_BRANCH; fall back to the worktree's
    # actual git branch so regen-env (and branch-keyed archive/delete/lookup)
    # get a real value instead of persisting an empty one.
    if [[ -z "$WT_BRANCH" ]]; then
        WT_BRANCH="$(git -C "$wt_path" branch --show-current 2>/dev/null || true)"
    fi
    return 0
}
