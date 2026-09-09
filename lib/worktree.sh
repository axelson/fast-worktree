# shellcheck disable=SC2154,SC2034  # config globals are assigned by
# load_config; WT_NAME/WT_PATH are set here for callers in other lib files.
#
# Worktree lifecycle: create and delete.

# Lowercase-only: the name feeds Postgres database names, which case-fold
# unless quoted — mixed case would create DBs unreachable from unquoted SQL.
validate_worktree_name() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

# worktree_name_for_path <path> [normalized-root] — the worktree name <path>
# lives under, or return 1 when it isn't inside the worktrees dir. Both sides
# are realpath-normalized (macOS reports /tmp as /private/tmp) so a live session
# cwd matches the configured worktrees_dir; when the path can't be resolved
# (e.g. a not-yet-created dir in tests) it also tries a raw string comparison.
# Pass a pre-normalized root to avoid re-realpathing it once per row.
worktree_name_for_path() {
    local path="$1" root="${2:-}" raw_root="$worktrees_dir" rp rel
    [[ -n "$root" ]] || root="$(realpath "$raw_root" 2>/dev/null || echo "$raw_root")"
    rp="$(realpath "$path" 2>/dev/null || echo "$path")"
    case "$rp" in
        "$root"/*)     rel="${rp#"$root"/}";     echo "${rel%%/*}"; return 0 ;;
        "$raw_root"/*) rel="${rp#"$raw_root"/}"; echo "${rel%%/*}"; return 0 ;;
    esac
    return 1
}

# detect_worktree_name — the worktree containing cwd, from the path layout.
detect_worktree_name() {
    worktree_name_for_path "$PWD"
}

# _in_golden_checkout — true when cwd is the golden checkout (repo_root) or a
# subdir of it. Checked only after detect_worktree_name fails, so a worktrees
# dir nested under repo_root is still recognised as a worktree first.
_in_golden_checkout() {
    local rp root
    rp="$(realpath "$PWD" 2>/dev/null || echo "$PWD")"
    root="$(realpath "$repo_root" 2>/dev/null || echo "$repo_root")"
    [[ "$rp" == "$root" || "$rp" == "$root"/* ]]
}

# current_branch_or_unknown — the current git branch, or "unknown" when HEAD is
# detached or cwd is not a repo. (git prints nothing on a detached HEAD, so the
# -n guard covers that in addition to the command failing.)
current_branch_or_unknown() {
    local b
    b="$(git branch --show-current 2>/dev/null || echo unknown)"
    [[ -n "$b" ]] || b=unknown
    echo "$b"
}

# worktree_name_for_branch <branch> — the name of the worktree whose env file
# records FW_BRANCH=<branch>, or empty when none does. It reads the branch
# recorded at create/pull time, so a branch resolves to its worktree even after
# the branch itself is deleted from git. Shared by resolve_worktree and delete.
worktree_name_for_branch() {
    local branch="$1" f dir
    [[ -n "$branch" ]] || return 0
    for f in "$worktrees_dir"/*/"$env_file"; do
        [[ -f "$f" ]] || continue
        if grep -q -- "^FW_BRANCH=$branch\$" "$f"; then
            dir="${f%"/$env_file"}"
            printf '%s\n' "${dir##*/}"
            return 0
        fi
    done
    return 0
}

# resolve_worktree [name-or-branch] — sets WT_NAME and WT_PATH; explicit name
# wins, else detect from cwd. A branch name resolves to the worktree whose
# env file records it.
resolve_worktree() {
    # --allow-main opts a caller into resolving the golden checkout (an explicit
    # `main`, or cwd inside repo_root) to WT_NAME=main / WT_PATH=repo_root.
    # Without it — the default — the golden checkout is not a worktree and
    # resolution fails, so worktree/branch-scoped commands (ticket, pr, refresh,
    # …) keep reporting "not inside a worktree" there. Only the checkout-scoped
    # commands (open, regen-env, start/stop) and the guards that must *reject*
    # main (archive) pass the flag.
    local allow_main=false
    if [[ "${1:-}" == "--allow-main" ]]; then
        allow_main=true
        shift
    fi
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        if ! name="$(detect_worktree_name)"; then
            if [[ "$allow_main" == true ]] && _in_golden_checkout; then
                name="main"
            else
                echo "Error: not inside a worktree — pass a name (fw <cmd> <name>)" >&2
                return 1
            fi
        fi
    fi

    # The golden checkout is reserved as "main" and lives at repo_root, not
    # under the worktrees dir — resolve it before the worktrees-dir lookup, but
    # only for a caller that opted in.
    if [[ "$allow_main" == true && "$name" == "main" ]]; then
        WT_NAME="main"
        WT_PATH="$repo_root"
        return 0
    fi

    if [[ ! -d "$worktrees_dir/$name" ]]; then
        local resolved
        resolved="$(worktree_name_for_branch "$name")"
        [[ -n "$resolved" ]] && name="$resolved"
    fi

    WT_NAME="$name"
    WT_PATH="$worktrees_dir/$name"
    if [[ ! -d "$WT_PATH" ]]; then
        echo "Error: worktree '$name' not found at $WT_PATH" >&2
        return 1
    fi
    return 0
}

# is_worktree_dir <path> — true when <path> is a managed worktree. The invariant
# is the env file's presence: worktree_names_branches (list), the switch picker,
# and the switch landing all share this one definition. A bare directory that
# carries no env file — a non-worktree sibling like handoffs/, or a worktree
# whose removal raced a running server and left the dir behind without its env
# file — is NOT a worktree and must not surface in pickers or be switched into.
is_worktree_dir() {
    [[ -f "$1/$env_file" ]]
}

# worktree_names_branches — emit "name<TAB>branch" for every worktree in the
# worktrees dir, in directory order (branch empty when its env is unreadable).
# The single source of the "which worktrees exist" loop for list/prs/ci;
# returns 1 (emitting nothing) when none exist so callers share one empty-state
# message.
#
# A worktree is identified by its env file: sibling directories that share the
# worktrees dir but carry no env file (e.g. handoffs/) are skipped, so they
# never surface as phantom worktrees in list/pickers/stop-all. A directory
# whose env file exists but is unreadable/corrupt still counts, with an empty
# branch — that is a broken worktree, not a non-worktree.
worktree_names_branches() {
    local dirs=("$worktrees_dir"/*/)
    [[ -e "${dirs[0]%/}" ]] || return 1
    local dir name branch found=false
    for dir in "${dirs[@]}"; do
        dir="${dir%/}"
        [[ -f "$dir/$env_file" ]] || continue
        name="$(basename "$dir")"
        branch=""
        if read_worktree_env "$dir" 2>/dev/null; then
            branch="$WT_BRANCH"
        fi
        found=true
        printf '%s\t%s\n' "$name" "$branch"
    done
    [[ "$found" == true ]] || return 1
}

# _dirty_check_pathspecs <wt_path> — pathspecs for a "does this worktree have
# uncommitted user work" check that ignore fw's own setup artifacts: the env
# file, the Claude artifacts `fw delete` preserves via archive_claude
# (claude_archive_paths sources, the summary file, .claude/settings.local.json),
# plus any untracked files a post-create hook created (recorded per worktree by
# _populate_worktree). Emits one git pathspec per line so callers read it into an
# array. Used by the list dirty markers and delete's guard.
_dirty_check_pathspecs() {
    local wt_path="$1"
    printf ':(exclude)%s\n' "$env_file"
    # Anything archive_claude keeps is not "work that would be lost" — the delete
    # copies it into the Claude archive — so it must not trip the dirty guard.
    local pair
    for pair in "${claude_archive_paths[@]}"; do
        printf ':(exclude,literal)%s\n' "${pair%%:*}"
    done
    printf ':(exclude,literal)%s\n' "${claude_summary_file:-.fw-summary.md}"
    printf ':(exclude,literal)%s\n' ".claude/settings.local.json"
    local gitdir manifest line
    gitdir="$(git -C "$wt_path" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
    manifest="$gitdir/fw-hook-artifacts"
    [[ -f "$manifest" ]] || return 0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        # Literal match: a recorded filename is an exact path, never a glob.
        printf ':(exclude,literal)%s\n' "$line"
    done <"$manifest"
}

# _remove_worktree_dir <wt_path> — remove a worktree directory, resiliently.
# git worktree remove is tried first, but it can't be trusted on its own: it
# refuses corrupt/stray dirs outright, and — the bug this guards — it can report
# success while leaving the directory behind when a process (a dev server) keeps
# writing files into it faster than git can empty it. So the directory is
# verified gone afterward and force-removed (rm -rf, then prune the admin entry)
# if it survives, retried a few times because a brief burst of regenerated files
# can lose a single race. Returns nonzero when the directory still exists after
# every attempt, so the caller reports the failure instead of claiming success.
_remove_worktree_dir() {
    local wt_path="$1" attempt
    git -C "$repo_root" worktree remove --force "$wt_path" 2>/dev/null || true
    for attempt in 1 2 3; do
        [[ -d "$wt_path" ]] || break
        rm -rf "$wt_path" 2>/dev/null || true
    done
    git -C "$repo_root" worktree prune 2>/dev/null || true
    [[ -d "$wt_path" ]] && return 1
    return 0
}

# worktree_ports <wt_path> — the listening ports `fw stop` may kill. With a
# non-empty stop_port_vars allowlist, collect exactly those variable names
# (exact match, so a bare `PORT` counts and a shared-ingress key can be left
# out). Otherwise fall back to the convention: any key ending in _PORT.
# (FW_PORT_SLOT is a slot, not a port, and doesn't match the convention.)
worktree_ports() {
    local file="$1/$env_file"
    [[ -f "$file" ]] || return 0
    if [[ ${#stop_port_vars[@]} -gt 0 ]]; then
        local var
        for var in "${stop_port_vars[@]}"; do
            grep -E "^${var}=" "$file" 2>/dev/null | cut -d= -f2 | grep -E '^[0-9]+$' || true
        done
        return 0
    fi
    grep -E '^[A-Za-z0-9_]+_PORT=' "$file" 2>/dev/null |
        cut -d= -f2 | grep -E '^[0-9]+$' || true
}

# cmd_stop [name…] — stop listeners on each worktree's ports: one batched
# lsof, SIGTERM first, escalate to SIGKILL only for survivors.
cmd_stop() {
    if [[ $# -eq 0 ]]; then
        set -- ""
    fi

    local name port ports=() lsof_args=()
    for name in "$@"; do
        # --allow-main: the golden checkout's listeners are stoppable too.
        resolve_worktree --allow-main "$name" || return 1
        while IFS= read -r port; do
            [[ -n "$port" ]] || continue
            ports+=("$port")
            lsof_args+=(-i "tcp:$port")
        done < <(worktree_ports "$WT_PATH")
    done
    [[ ${#ports[@]} -gt 0 ]] || return 0

    local pids
    pids="$(lsof -t "${lsof_args[@]}" -sTCP:LISTEN 2>/dev/null || true)"
    [[ -n "$pids" ]] || return 0

    echo "Stopping listeners on port(s): ${ports[*]}"
    echo "$pids" | xargs kill 2>/dev/null || true

    local i
    for i in 1 2 3 4 5; do
        sleep 0.2
        pids="$(lsof -t "${lsof_args[@]}" -sTCP:LISTEN 2>/dev/null || true)"
        [[ -n "$pids" ]] || return 0
    done
    echo "Escalating to SIGKILL..."
    echo "$pids" | xargs kill -9 2>/dev/null || true
    return 0
}

# trunk_branch — the repo's main-line branch: origin/HEAD when set, else a
# local main/master, else whatever the golden checkout is on.
# Memoized via TRUNK_BRANCH: call sites live inside $(…) subshells, so the
# cache must be set eagerly in the parent shell (see _ensure_trunk).
trunk_branch() {
    if [[ -n "${TRUNK_BRANCH:-}" ]]; then
        echo "$TRUNK_BRANCH"
        return 0
    fi
    local ref
    if ref="$(git -C "$repo_root" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"; then
        echo "${ref#origin/}"
        return 0
    fi
    local b
    for b in main master; do
        if git -C "$repo_root" show-ref -q --verify "refs/heads/$b"; then
            echo "$b"
            return 0
        fi
    done
    git -C "$repo_root" branch --show-current
}

# _ensure_trunk — memoize the trunk branch once per invocation, in the parent
# shell where subshell callers can inherit it.
_ensure_trunk() {
    if [[ -z "${TRUNK_BRANCH:-}" ]]; then
        TRUNK_BRANCH="$(trunk_branch)"
    fi
}

# _populate_worktree_fg <name> <branch> <wt_path> — the foreground half of
# worktree setup: env file, CoW assets, hook_pre_db, DB clone, then the Caddy
# refresh and recency stamp. Everything here blocks the switch and is
# rollback-protected (each failure returns non-zero so the caller can
# _rollback_create); db_create sets _db_created=true so rollback drops only a
# database this create made. `fw create` runs this synchronously and only then
# switches in; the slow, arbitrary hook_post_create is deferred to _bg.
#
# hook_pre_db runs before the DB step for project setup a db_setup_cmd fallback
# depends on (env/secret files). It is optional (a no-op when undefined).
_populate_worktree_fg() {
    local name="$1" branch="$2" wt_path="$3"
    write_worktree_env "$wt_path" "$name" "$branch" || return 1
    clone_assets "$wt_path" || return 1
    # Export the FW_* contract up front: db_create and both hooks need it, and
    # db_create re-exports it anyway, so moving it here is harmless and lets the
    # pre-DB hook see it.
    _export_fw_env "$name" "$branch" "$wt_path"

    # Project setup that must exist before the DB step — e.g. env/secret files a
    # db_setup_cmd sources. Runs before db_create, so _db_created is still false:
    # a failure here rolls the create back without dropping a database.
    _run_hook_recording hook_pre_db "$wt_path" || return 1

    db_create_for_worktree "$name" "$branch" "$wt_path" || return 1
    _db_created=true

    # The worktree set changed: refresh the Caddy reverse-proxy map (a no-op
    # unless the domain layer is configured). Shared by create/pull/restore.
    regenerate_caddyfile
    # A new worktree counts as viewed now, so the recency-windowed bare
    # `fw switch` picker offers it before the first switch into it.
    record_viewed "$name"
    return 0
}

# _populate_worktree_bg <name> <branch> <wt_path> — the background half: the
# slow, arbitrary hook_post_create (setup that needs the DB to exist) plus
# recording of the files it creates. Returns non-zero when the hook fails; the
# caller decides what that means — the synchronous composite (pull/restore) rolls
# back, while `fw create`'s backgrounded cmd_create_bg reports it and leaves the
# worktree in place (you are already switched in). Optional (a no-op when the
# hook is undefined). Assumes _populate_worktree_fg has run (env exported).
_populate_worktree_bg() {
    local name="$1" branch="$2" wt_path="$3"
    _run_hook_recording hook_post_create "$wt_path" || return 1
    return 0
}

# _populate_worktree <name> <branch> <wt_path> — synchronous full setup: the
# foreground half then the background half, in order. Used by _materialize_worktree
# (pull/restore) so those keep today's atomic, rollback-on-any-failure behavior;
# `fw create` calls the halves separately across the switch instead.
_populate_worktree() {
    local name="$1" branch="$2" wt_path="$3"
    _populate_worktree_fg "$name" "$branch" "$wt_path" || return 1
    _populate_worktree_bg "$name" "$branch" "$wt_path" || return 1
    return 0
}

# _run_hook_recording <hook> <wt_path> — run a create-time hook (fatal policy),
# recording any untracked files it creates in the worktree's artifact manifest so
# fw's own dirty checks (delete guard, list markers) don't mistake setup output
# for user work. The snapshot and the record both happen in THIS process, back to
# back around the hook, so no state has to cross the create fg→bg boundary and the
# only files attributed to the hook are ones that appeared during its own run —
# not files the user creates after being switched in. A no-op (success) when the
# hook is undefined. The manifest lives in the per-worktree git dir, so it is not
# a working-tree file and dies with the worktree. Consumed by _dirty_check_pathspecs.
_run_hook_recording() {
    local hook="$1" wt_path="$2"
    # Skip the snapshot/diff work entirely when the hook is undefined; run_hook
    # re-checks this itself, so this guard is about avoiding two git ls-files
    # scans, not about correctness.
    declare -F "$hook" >/dev/null || return 0

    local gitdir manifest f
    gitdir="$(git -C "$wt_path" rev-parse --absolute-git-dir 2>/dev/null)" || gitdir=""

    local -A _pre=()
    if [[ -n "$gitdir" ]]; then
        while IFS= read -r -d '' f; do
            _pre["$f"]=1
        done < <(git -C "$wt_path" ls-files --others --exclude-standard -z 2>/dev/null || true)
    fi

    run_hook "$hook" "$wt_path" fatal || return 1

    if [[ -n "$gitdir" ]]; then
        manifest="$gitdir/fw-hook-artifacts"
        while IFS= read -r -d '' f; do
            [[ -n "${_pre[$f]:-}" ]] && continue
            printf '%s\n' "$f" >>"$manifest"
        done < <(git -C "$wt_path" ls-files --others --exclude-standard -z 2>/dev/null || true)
    fi
    return 0
}

# _materialize_worktree <name> <branch> — worktree from an existing branch
# with populate + rollback; shared by pull and restore.
_materialize_worktree() {
    local name="$1" branch="$2"
    local wt_path="$worktrees_dir/$name"
    mkdir -p "$worktrees_dir"
    git -C "$repo_root" worktree add -q "$wt_path" "$branch"

    local _db_created=false
    if ! _populate_worktree "$name" "$branch" "$wt_path"; then
        echo "Error: worktree setup failed — rolling back" >&2
        _rollback_create "$wt_path" "$branch" false
        return 1
    fi
    return 0
}

# _rollback_create <wt_path> <branch> <created_branch>
_rollback_create() {
    local wt_path="$1" branch="$2" created_branch="$3"
    if [[ "$_db_created" == true ]]; then
        db_drop_for_worktree "$wt_path" || true
    fi
    # Best-effort like the rest of rollback: _remove_worktree_dir now returns
    # nonzero if the dir survives, which must not abort the branch cleanup below
    # under set -e.
    _remove_worktree_dir "$wt_path" || true
    if [[ "$created_branch" == true ]]; then
        # Through the backend, so graphite metadata written by stack_track
        # doesn't survive the branch.
        stack_delete_branch "$branch" 2>/dev/null || true
    fi
    # The foreground half already regenerated the Caddy map to include this
    # worktree (regenerate_caddyfile runs in _populate_worktree_fg, before the
    # background hook_post_create that pull/restore still roll back on). Refresh
    # it now the worktree is gone so a rolled-back create/pull leaves no stale
    # reverse-proxy entry. A no-op unless the domain layer is configured.
    regenerate_caddyfile
}

# _switch_after_create <name> <no-switch> — switch into a freshly created
# worktree unless the per-run --no-switch flag or the switch_on_create config
# turns it off. Best-effort: create/pull already succeeded, so a switch failure
# (reported on stderr by cmd_switch) must not fail the create.
_switch_after_create() {
    local name="$1" no_switch="$2"
    [[ "$no_switch" == true ]] && return 0
    [[ "${switch_on_create:-true}" == true ]] || return 0
    cmd_switch "$name" || true
}

# cmd_create <name> [--base BRANCH|.] [--model M] [--claude PROMPT] [--no-switch]
# --base=. resolves to the branch checked out in the invoking cwd (stacking).
cmd_create() {
    local name="" base_override="" model="" claude_prompt="" no_switch=false
    while [[ $# -gt 0 ]]; do
        _parse_claude_flag model claude_prompt "$#" "$1" "${2:-}" || return 1
        if [[ "$_CF_CONSUMED" != 0 ]]; then shift "$_CF_CONSUMED"; continue; fi
        case "$1" in
            --base)
                if [[ $# -lt 2 ]]; then
                    echo "Error: --base requires a branch name" >&2
                    return 1
                fi
                base_override="$2"
                shift 2
                ;;
            --base=*) base_override="${1#--base=}"; shift ;;
            --no-switch) no_switch=true; shift ;;
            -*)
                # A bare flag that matches no built-in is looked up as a
                # configured prompt-flag (--review -> claude_prompt_flags[review]);
                # anything else is a genuine unknown flag.
                if claude_prompt="$(_prompt_flag_for "$1")"; then
                    shift
                else
                    echo "Error: unknown flag '$1'" >&2; return 1
                fi
                ;;
            *) name="$1"; shift ;;
        esac
    done
    if [[ -z "$name" ]]; then
        echo "Error: usage: fw create <name> [--base BRANCH] [--model M] [--claude PROMPT] [--<prompt-flag>]" >&2
        return 1
    fi

    # A slashed argument is a full branch name (branch names may carry any
    # namespace) — take it verbatim and fold it into the worktree name. A bare
    # name gets the configured prefix.
    local branch
    if [[ "$name" == */* ]]; then
        branch="$name"
        name="$(name_from_branch "$name")"
    else
        branch="$name"
        [[ -n "$branch_prefix" ]] && branch="$branch_prefix/$name"
    fi

    if ! validate_worktree_name "$name"; then
        echo "Error: invalid worktree name '$name' (lowercase letters, digits, - and _ only)" >&2
        return 1
    fi
    if [[ "$name" == "main" ]]; then
        echo "Error: 'main' is a reserved worktree name (the golden checkout's session)" >&2
        return 1
    fi

    local wt_path="$worktrees_dir/$name"
    if [[ -e "$wt_path" ]]; then
        echo "Error: worktree '$name' already exists at $wt_path" >&2
        return 1
    fi

    _ensure_trunk
    local branch_exists=false
    if git -C "$repo_root" show-ref -q --verify "refs/heads/$branch"; then
        branch_exists=true
    fi

    # Resolve "." to the branch checked out in the invoking cwd (deliberately not
    # -C "$repo_root": the golden checkout usually sits on trunk, so reading it
    # would defeat the point — we want to stack on whatever worktree you're in).
    if [[ "$base_override" == "." ]]; then
        local current_branch
        current_branch="$(git branch --show-current 2>/dev/null)"
        if [[ -z "$current_branch" ]]; then
            echo "Error: could not determine current branch (detached HEAD, or not in a git worktree?)" >&2
            return 1
        fi
        if [[ "$current_branch" == "$branch" ]]; then
            echo "Error: cannot stack '$branch' on itself" >&2
            return 1
        fi
        base_override="$current_branch"
    fi

    local base
    if [[ -n "$base_override" ]]; then
        if ! git -C "$repo_root" rev-parse --verify -q "refs/heads/$base_override" >/dev/null; then
            echo "Error: base branch '$base_override' not found" >&2
            return 1
        fi
        base="$base_override"
    elif [[ "$branch_exists" == true ]]; then
        # Reusing an existing branch: keep its recorded stack parent (falls
        # back to trunk for untracked branches) so re-tracking never
        # reparents a mid-stack branch onto trunk.
        base="$(stack_parent "$branch")"
    else
        base="$(trunk_branch)"
    fi

    mkdir -p "$worktrees_dir"
    local created_branch=false _db_created=false
    if [[ "$branch_exists" == true ]]; then
        echo "Creating worktree $name (reusing existing branch $branch)..."
        git -C "$repo_root" worktree add -q "$wt_path" "$branch"
    else
        echo "Creating worktree $name (branch $branch from $base)..."
        git -C "$repo_root" worktree add -q -b "$branch" "$wt_path" "$base"
        created_branch=true
    fi
    (cd "$wt_path" && stack_track "$branch" "$base") ||
        echo "Warning: stack tracking failed for $branch" >&2

    # Foreground half: env, assets, hook_pre_db, DB clone. Blocks the switch and
    # keeps atomic rollback — the slow, arbitrary hook_post_create is deferred.
    if ! _populate_worktree_fg "$name" "$branch" "$wt_path"; then
        echo "Error: worktree setup failed — rolling back" >&2
        _rollback_create "$wt_path" "$branch" "$created_branch"
        return 1
    fi

    # Set the Claude model now (foreground), so settings.local.json is ready
    # before anything launches in the session.
    if [[ -n "$model" ]]; then
        _claude_set_model "$wt_path" "$model" ||
            echo "Warning: could not set Claude model" >&2
    fi

    echo "Created $wt_path"

    # Background half: run hook_post_create in the new session's first window so
    # the switch doesn't wait on it. Always births the session (even with
    # --no-switch, which only skips the attach below). No rollback past this
    # point — the worktree is live and about to be switched into.
    _launch_bg_setup_in_worktree "$name" "$wt_path" ||
        echo "Warning: could not start background setup" >&2

    # Launch Claude concurrently with the background setup (true on-birth), in
    # its own window.
    if [[ -n "$claude_prompt" ]]; then
        _claude_launch_in_worktree "$name" "$wt_path" "$claude_prompt" ||
            echo "Warning: could not launch Claude" >&2
    fi

    _switch_after_create "$name" "$no_switch"
    return 0
}

# cmd_create_bg <name> — background half of create, run via send-keys in the new
# session's first window (see _launch_bg_setup_in_worktree). The pane's shell
# does not inherit create's exported FW_*, so re-derive everything from the name,
# then run hook_post_create + record its artifacts. No rollback: the worktree is
# already live and switched into — a failure is reported loudly and left on the
# window's shell prompt for the user to see.
cmd_create_bg() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        echo "Error: usage: fw _create-bg <name>" >&2
        return 1
    fi
    resolve_worktree "$name" || return 1

    local branch=""
    if read_worktree_env "$WT_PATH" 2>/dev/null; then
        # shellcheck disable=SC2153  # WT_BRANCH is set by read_worktree_env
        branch="$WT_BRANCH"
    fi
    _export_fw_env "$WT_NAME" "$branch" "$WT_PATH"

    if ! _populate_worktree_bg "$WT_NAME" "$branch" "$WT_PATH"; then
        echo "Error: background setup failed for $WT_NAME (worktree is left in place)" >&2
        return 1
    fi
    echo "Worktree $WT_NAME setup complete"
    return 0
}

# cmd_delete [--force] <name>
cmd_delete() {
    local force=false name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            -*) echo "Error: unknown flag '$1'" >&2; return 1 ;;
            *) name="$1"; shift ;;
        esac
    done
    if [[ -z "$name" ]]; then
        echo "Error: usage: fw delete [--force] <name-or-branch>" >&2
        return 1
    fi
    # Accept a branch name (e.g. `fw delete me/feat`): map it to the worktree
    # whose env records that branch before validating. Only attempt this when
    # the argument can't be a plain worktree name already — it isn't a direct
    # worktree dir, or it carries a separator. Branch resolution only ever
    # yields a real worktree's basename, so the validate guard below still
    # rejects a path-traversal argument like `../victim` (which matches no
    # recorded branch).
    if [[ ! -d "$worktrees_dir/$name" || "$name" == */* ]]; then
        local resolved
        resolved="$(worktree_name_for_branch "$name")"
        [[ -n "$resolved" ]] && name="$resolved"
    fi
    if ! validate_worktree_name "$name"; then
        echo "Error: invalid worktree name '$name'" >&2
        return 1
    fi
    # "main" is the reserved golden-checkout name; it lives at repo_root, not
    # under the worktrees dir, and is never a delete target.
    if [[ "$name" == "main" ]]; then
        echo "Error: refusing to delete the golden checkout (main)" >&2
        return 1
    fi

    local wt_path="$worktrees_dir/$name"
    if [[ ! -d "$wt_path" ]]; then
        echo "Error: worktree '$name' not found at $wt_path" >&2
        return 1
    fi

    # A stray or corrupt dir must not be judged by an enclosing repo's status
    # (git status walks up), and its failure must be visible.
    local toplevel valid_worktree=true
    toplevel="$(git -C "$wt_path" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -z "$toplevel" || "$(realpath "$toplevel" 2>/dev/null || true)" != "$(realpath "$wt_path")" ]]; then
        valid_worktree=false
        if [[ "$force" != true ]]; then
            echo "Error: $wt_path is not a valid git worktree (use --force to remove it anyway)" >&2
            return 1
        fi
    fi

    if [[ "$force" != true ]]; then
        local dirty _ps
        local -a _pathspecs=()
        while IFS= read -r _ps; do _pathspecs+=("$_ps"); done \
            < <(_dirty_check_pathspecs "$wt_path")
        dirty="$(git -C "$wt_path" status --porcelain -- "${_pathspecs[@]}" 2>/dev/null || true)"
        if [[ -n "$dirty" ]]; then
            echo "Error: worktree '$name' has uncommitted changes (use --force to delete anyway):" >&2
            printf '  %s\n' "${dirty//$'\n'/$'\n'  }" >&2
            return 1
        fi
    fi

    _ensure_trunk
    # Delete the branch recorded at create time — never whatever happens to be
    # checked out in the worktree right now.
    local branch=""
    if read_worktree_env "$wt_path" 2>/dev/null; then
        # shellcheck disable=SC2153  # WT_BRANCH is set by read_worktree_env
        branch="$WT_BRANCH"
    fi

    _export_fw_env "$name" "$branch" "$wt_path"
    run_hook hook_pre_delete "$repo_root" warn

    db_drop_for_worktree "$wt_path"

    # Preserve Claude artifacts (plans, recon, settings, summary) before the
    # worktree is gone; a no-op when there's nothing to keep. archive_claude
    # falls back to the worktree basename when git can't name the branch, so it
    # runs for invalid/corrupt worktrees (force-deletes) too.
    archive_claude "$wt_path" false "$branch"

    # Tear the tmux session down before touching the directory: a session (and
    # the server running inside it) that outlives the worktree keeps rewriting
    # files and races the removal below, stranding a half-deleted phantom dir.
    kill_worktree_session "$name"

    echo "Removing worktree $name..."
    if ! _remove_worktree_dir "$wt_path"; then
        echo "Error: worktree directory $wt_path could not be fully removed — something is still writing into it (a running server or an open shell in that dir). Stop it, then remove the directory manually." >&2
        return 1
    fi
    if [[ -n "$branch" && "$branch" == "$(trunk_branch)" ]]; then
        echo "Note: recorded branch is trunk ($branch); leaving it alone" >&2
    elif [[ -n "$branch" ]]; then
        stack_delete_branch "$branch" ||
            echo "Note: branch $branch was not deleted (missing or in use)" >&2
    else
        [[ "$valid_worktree" == true ]] &&
            echo "Note: no recorded branch found; no branch deleted" >&2
    fi

    # Refresh the Caddy reverse-proxy map now the worktree is gone (a no-op
    # unless the domain layer is configured). Batch callers like `fw clean` set
    # FW_SKIP_CADDY_REGEN to coalesce this into one regen after their loop.
    regenerate_caddyfile
    echo "Deleted $name"
    return 0
}
