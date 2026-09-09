# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# fw switch / tmux-open / last — moving between worktrees.
# Each worktree gets a tmux session named <project>-<worktree>; switching
# records recency in <worktrees_dir>/.fw_recent for `fw last` and (later)
# recency-sorted pickers.

_recent_log() {
    echo "$worktrees_dir/.fw_recent"
}

# _compact_recent_log <log> — once a "<ts>\t<name>" log grows past 200 lines,
# keep only the latest line per name, preserving chronological order. Cost is
# paid on write, not on read. Shared by record_viewed (worktrees) and
# record_project_visit (projects).
_compact_recent_log() {
    local log="$1"
    [[ -f "$log" ]] || return 0
    if [[ "$(wc -l <"$log" | tr -d ' ')" -gt 200 ]]; then
        local tmp="$log.tmp.$$"
        awk -F'\t' '
            { lines[NR] = $0; names[NR] = $2 }
            END {
                c = 0
                for (i = NR; i >= 1; i--)
                    if (!(names[i] in seen)) { seen[names[i]] = 1; keep[++c] = lines[i] }
                for (i = c; i >= 1; i--) print keep[i]
            }
        ' "$log" >"$tmp"
        mv "$tmp" "$log"
    fi
}

record_viewed() {
    mkdir -p "$worktrees_dir"
    local log
    log="$(_recent_log)"
    printf '%s\t%s\n' "$(date +%s)" "$1" >>"$log"
    _compact_recent_log "$log"
}

# _project_log — the global project recency log path (under fw_config_dir).
_project_log() {
    echo "$(fw_config_dir)/project_log"
}

# record_project_visit <name> — stamp a project visit to the top of the project
# MRU ordering by appending "<ts>\t<name>" to project_log, then compacting like
# record_viewed. A visit is either landing a project via `fw switch-project` or
# registering one via `fw init` (a project's first visit). Kept distinct from
# _shelve_projects, which deliberately back-dates a row instead of stamping now.
record_project_visit() {
    local log
    log="$(_project_log)"
    mkdir -p "$(dirname "$log")"
    printf '%s\t%s\n' "$(date +%s)" "$1" >>"$log"
    _compact_recent_log "$log"
}

# recent_names [cutoff-epoch] [log-path] — distinct names, most recently
# recorded first, from a "<ts>\t<name>" log. Ordering is by each name's most
# recent timestamp (descending), with the log's append position breaking ties
# so same-second switches keep append order. Ordering is deliberately
# timestamp-driven, not file-position driven: `fw shelve` back-dates a row and
# re-appends it, so a position-ordered list would wrongly float it to the top.
# With a cutoff, names whose most recent timestamp is older than it are dropped
# (used by `fw ci` for its 48h window); without one, the full history is
# returned. The log path defaults to the worktree recency log but is overridable
# so `_recent_projects` can reuse the same parse over project_log.
recent_names() {
    local cutoff="${1:-}" log="${2:-}"
    [[ -n "$log" ]] || log="$(_recent_log)"
    [[ -f "$log" ]] || return 0
    awk -F'\t' -v cutoff="$cutoff" '
        {
            n = $2
            # Keep each name keyed on its most recent row: a larger timestamp
            # wins, and for equal timestamps the later append position wins.
            if (!(n in bts) || $1 > bts[n] || ($1 == bts[n] && NR > bpos[n])) {
                bts[n] = $1; bpos[n] = NR
            }
        }
        END {
            for (n in bts) {
                if (cutoff != "" && bts[n] < cutoff) continue
                print bts[n] "\t" bpos[n] "\t" n
            }
        }
    ' "$log" | sort -t$'\t' -k1,1nr -k2,2nr | cut -f3
}

# last_viewed_ts <name> [log] — the most recent recorded timestamp for a name in
# a "<ts>\t<name>" log, or empty when it has never been recorded. The log path
# defaults to the worktree recency log but is overridable so project shelve and
# the project picker can read the same parse over project_log.
last_viewed_ts() {
    local log="${2:-}"
    [[ -n "$log" ]] || log="$(_recent_log)"
    [[ -f "$log" ]] || return 0
    awk -F'\t' -v name="$1" '$2 == name { t = $1 } END { if (t != "") print t }' "$log"
}

# _first_recent_dir [exclude] — echo the most recent visit-history name that
# still resolves to a real checkout, walking past deleted AND phantom worktrees.
# main is the golden checkout at repo_root (the guaranteed floor); every other
# name must be a real worktree — the env file, not mere directory existence, so
# a partially-deleted dir left behind by a raced removal is skipped like a
# deleted one rather than chosen and then rejected at the switch landing (which
# would make `sp`/`last` error). With an <exclude> name, that name is skipped
# (e.g. `fw last` skips the worktree you're already in). Echoes nothing when
# none resolve, leaving the empty-case policy (main floor vs. error) to the
# caller.
_first_recent_dir() {
    local exclude="${1:-}" name
    while IFS= read -r name; do
        [[ -n "$name" && "$name" != "$exclude" ]] || continue
        if [[ "$name" == "main" ]]; then
            [[ -d "$repo_root" ]] || continue
        else
            is_worktree_dir "$worktrees_dir/$name" || continue
        fi
        printf '%s\n' "$name"
        return 0
    done < <(recent_names)
    return 0
}

# parse_duration <NmM|NhH|NdD> — echo the duration in seconds, or return 1 on a
# malformed value. Used by `fw shelve`.
parse_duration() {
    local input="$1"
    local num="${input%[mhdMHD]}"
    local unit="${input##*[0-9]}"
    if [[ ! "$num" =~ ^[0-9]+$ || -z "$unit" ]]; then
        return 1
    fi
    case "$unit" in
        m|M) echo $(( num * 60 )) ;;
        h|H) echo $(( num * 3600 )) ;;
        d|D) echo $(( num * 86400 )) ;;
        *) return 1 ;;
    esac
}

# _shelve_projects <duration_secs> [name...] — push registered project(s) down
# the `fw sp` switch list by back-dating their project_log row. With no name,
# shelves the current project (honoring the global -p selector). Cross-project by
# nature: it touches only the global project_log, so it needs no loaded project
# context. Never warns — every registered project always shows in the picker
# (_recent_projects reads with no recency window).
_shelve_projects() {
    local duration_secs="$1"; shift
    local -a names=("$@")

    if [[ ${#names[@]} -eq 0 ]]; then
        local current
        current="$(resolve_project "${PROJECT_FLAG:-}")" || return 1
        names+=("$current")
    fi

    local cfg_dir log now_epoch
    cfg_dir="$(fw_config_dir)"
    log="$(_project_log)"
    now_epoch="$(date +%s)"

    local name rc=0
    for name in "${names[@]}"; do
        if [[ ! -f "$cfg_dir/projects/$name/config.sh" ]]; then
            echo "Error: project '$name' is not registered (fw projects lists them)" >&2
            rc=1
            continue
        fi

        local ts
        ts="$(last_viewed_ts "$name" "$log")"
        if [[ -z "$ts" || "$ts" == "0" ]]; then
            echo "Project '$name' has no switch history yet — nothing to shelve."
            continue
        fi

        local new_ts=$(( ts - duration_secs ))
        local tmp="$log.tmp.$$"
        awk -F'\t' -v name="$name" '$2 != name' "$log" >"$tmp"
        printf '%s\t%s\n' "$new_ts" "$name" >>"$tmp"
        mv "$tmp" "$log"

        local age
        age="$(format_age "$new_ts" "$now_epoch")"
        echo "Shelved project '$name' — now shows as ${age} ago in the project list"
    done
    return "$rc"
}

# cmd_shelve [-t DURATION] [--project|-p] [name...] — push worktree(s) down the
# switch list by rewriting their recency timestamp into the past (default one
# day). With no name, shelves the current worktree. Warns when the new age falls
# past the picker's default window (switch_recent_days), which would hide it from
# bare `fw switch`. With --project/-p the names are registered projects and the
# push happens in the global project_log instead (see _shelve_projects).
cmd_shelve() {
    local duration_secs=86400
    local project_mode=false
    local -a names=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t)
                duration_secs="$(parse_duration "${2:-}")" \
                    || { echo "Error: invalid duration '${2:-}' (use e.g. 10m, 2h, 1d)" >&2; return 1; }
                shift 2 ;;
            --project|-p) project_mode=true; shift ;;
            *) names+=("$1"); shift ;;
        esac
    done

    if [[ "$project_mode" == true ]]; then
        _shelve_projects "$duration_secs" ${names[@]+"${names[@]}"}
        return
    fi

    # Worktree mode needs a loaded project ($worktrees_dir, $switch_recent_days);
    # project mode above deliberately does not, so the gate lives here, not in
    # dispatch.
    _require_project

    if [[ ${#names[@]} -eq 0 ]]; then
        local current
        if ! current="$(detect_worktree_name)" || [[ -z "$current" ]]; then
            echo "Error: not inside a worktree — pass a name (fw shelve <name>)" >&2
            return 1
        fi
        names+=("$current")
    fi

    local log now_epoch cutoff_epoch days="${switch_recent_days:-7}"
    log="$(_recent_log)"
    now_epoch="$(date +%s)"
    cutoff_epoch=$(( now_epoch - days * 86400 ))

    local name rc=0
    for name in "${names[@]}"; do
        # Accept a branch name too: map it to its worktree before touching the
        # recency log (which is keyed by worktree name). A name that resolves to
        # no worktree falls through unchanged and hits the no-recency error below.
        if resolve_worktree "$name" 2>/dev/null; then
            name="$WT_NAME"
        fi
        local ts
        ts="$(last_viewed_ts "$name")"
        if [[ -z "$ts" || "$ts" == "0" ]]; then
            echo "Error: no recency entry for '$name'" >&2
            rc=1
            continue
        fi

        local new_ts=$(( ts - duration_secs ))
        if [[ "$new_ts" -lt "$cutoff_epoch" ]]; then
            echo "Warning: shelving hides '$name' from the default switch picker (past the ${days}-day window)"
        fi

        local tmp="$log.tmp.$$"
        awk -F'\t' -v name="$name" '$2 != name' "$log" >"$tmp"
        printf '%s\t%s\n' "$new_ts" "$name" >>"$tmp"
        mv "$tmp" "$log"

        local age
        age="$(format_age "$new_ts" "$now_epoch")"
        echo "Shelved '$name' — now shows as ${age} ago in the switch list"
    done
    return "$rc"
}

_tmux_session_for() {
    echo "${project}-$1"
}

# kill_worktree_session <name> — tear down the worktree's tmux session, if one
# exists. Called on delete so a live session (and whatever server runs inside
# it) can't outlive its worktree and race the directory removal — the failure
# that leaves a half-deleted phantom dir behind. Best-effort: a no-op when tmux
# is absent or no such session exists.
kill_worktree_session() {
    command -v tmux >/dev/null 2>&1 || return 0
    local session
    session="$(_tmux_session_for "$1")"
    tmux kill-session -t "=$session" 2>/dev/null || true
}

_ensure_tmux_session() {
    local session="$1" path="$2"
    if ! tmux has-session -t "=$session" 2>/dev/null; then
        tmux new-session -d -s "$session" -c "$path"
        _fw_build_windows "$session" "$path"
    fi
}

# _fw_build_windows <session> <path> — run the project's hook_tmux_windows (if
# any) to lay out a freshly-born session's windows. Sets the shell globals the
# fw_window helper reads, then runs the hook under the `warn` policy so a partial
# failure still lands you in the session. A project with no hook is a no-op — the
# bare single-window session new-session already created.
#
# Selection is applied to tmux directly by fw_window (later windows are created
# detached, and --select focuses inline), not handed back through a global:
# run_hook executes the hook in a subshell, so any variable fw_window sets there
# would be lost on return.
_fw_build_windows() {
    local session="$1" path="$2"
    _fw_win_session="$session"
    _fw_win_root="$path"
    _fw_win_count=0
    run_hook hook_tmux_windows "$path" warn
    unset _fw_win_session _fw_win_root _fw_win_count
}

# fw_window [--select] <name> [<dir>] [<cmd>] — declare one tmux window for the
# session being born. Called only from a project's hook_tmux_windows.
#   <name>     tmux window name (required)
#   <dir>      start dir relative to the worktree root (default "." = the root)
#   <cmd>      typed into the window via send-keys … Enter (omit for an idle shell)
#   --select   focus this window on landing; without any marker the first window
#              (window 0) stays focused, since later windows are created detached.
#
# The first call reuses the session's initial window (the one new-session made at
# the worktree root) — renaming it and, when a subdir is asked for, re-homing it
# with a `cd` keystroke (an existing window's start dir can't be changed). Later
# calls are real detached new-windows. A <dir> that doesn't exist makes new-window
# -c fail for just that window (dirs a hook_post_create will create aren't
# pre-validated); the warn policy contains the blast radius. A `claude` window
# here composes with `fw create --claude`: _claude_launch_in_worktree reuses an
# existing claude window rather than adding a second (lib/claude.sh) — so a
# project pre-creating one should leave it idle (no <cmd>) and let create own the
# launch.
#
# Windows are addressed by their tmux id (@N), captured at create time, not by
# "session:name" or ":0": an id is immune to the user's base-index (their first
# window may be index 1, not 0) and to two windows sharing a name.
fw_window() {
    local marked=false
    if [[ "${1:-}" == "--select" ]]; then
        marked=true
        shift
    fi
    local name="${1:-}" dir="${2:-.}" cmd="${3:-}"

    if [[ -z "${_fw_win_session:-}" ]]; then
        echo "Error: fw_window must be called from hook_tmux_windows" >&2
        return 1
    fi
    if [[ -z "$name" ]]; then
        echo "Error: fw_window requires a window name" >&2
        return 1
    fi

    local session="$_fw_win_session" root="$_fw_win_root" target
    if [[ "$_fw_win_count" -eq 0 ]]; then
        # The session's active window at birth is its sole initial window.
        target="$(tmux display-message -p -t "=$session" '#{window_id}')"
        tmux rename-window -t "$target" "$name"
        if [[ "$dir" != "." ]]; then
            local cd_cmd
            printf -v cd_cmd 'cd %q' "$root/$dir"
            tmux send-keys -t "$target" "$cd_cmd" Enter
        fi
    else
        target="$(tmux new-window -d -P -F '#{window_id}' \
            -t "=$session" -n "$name" -c "$root/$dir")"
    fi
    _fw_win_count=$((_fw_win_count + 1))

    [[ -n "$cmd" ]] && tmux send-keys -t "$target" "$cmd" Enter
    [[ "$marked" == true ]] && tmux select-window -t "$target"
    return 0
}

_attach_tmux_session() {
    local session="$1"
    if [[ -n "${TMUX:-}" ]]; then
        tmux switch-client -t "=$session"
    elif [[ -t 0 ]]; then
        tmux attach-session -t "=$session"
    else
        echo "Session $session ready — attach with: tmux attach -t $session"
    fi
}

# _launch_bg_setup_in_worktree <name> <wt_path> — birth the worktree's tmux
# session and run the slow background half of create (`fw _create-bg`) in its
# first window, so `fw create` can switch in before hook_post_create finishes.
# The FW_* contract is already exported by cmd_create (via _populate_worktree_fg),
# so session birth (and its hook_tmux_windows) run with the worktree context.
#
# The command is sent into the session's first window, reused as-is: after
# hook_tmux_windows has run, the first fw_window may have renamed it, and the
# user's tmux base-index may not be 0 — so target it by lowest window index →
# window-id (the same id-addressing fw_window itself uses).
_launch_bg_setup_in_worktree() {
    local name="$1" wt_path="$2"
    local session
    session="$(_tmux_session_for "$name")"
    _ensure_tmux_session "$session" "$wt_path"

    local first_win
    first_win="$(tmux list-windows -t "=$session" -F '#{window_index} #{window_id}' \
        2>/dev/null | sort -n | head -1 | cut -d' ' -f2)"
    [[ -n "$first_win" ]] || return 1

    # fw is only a shell alias, invisible in the pane's shell — call the real
    # entrypoint by absolute path (this is why FW_BIN exists).
    local cmd
    printf -v cmd '%q _create-bg %q' "$SCRIPT_DIR/fast-worktree" "$name"
    tmux send-keys -t "$first_win" "$cmd" Enter
}

cmd_tmux_open() {
    resolve_worktree "${1:-}" || return 1
    record_viewed "$WT_NAME"
    local session
    session="$(_tmux_session_for "$WT_NAME")"
    # Export the FW_* contract before session birth so hook_tmux_windows runs
    # with the worktree context, even on a direct `fw tmux-open` (no switch).
    # shellcheck disable=SC2153  # WT_PATH is set by resolve_worktree
    _export_fw_session_env "$WT_NAME" "${WT_BRANCH:-}" "$WT_PATH"
    _ensure_tmux_session "$session" "$WT_PATH"
    _attach_tmux_session "$session"
}

# _current_worktree_name — the worktree cwd sits in for picker preselection:
# a name under worktrees_dir, or "main" when inside the golden checkout. Empty
# when cwd is elsewhere, so the caller simply skips preselection.
_current_worktree_name() {
    local name
    if name="$(detect_worktree_name 2>/dev/null)" && [[ -n "$name" ]]; then
        printf '%s' "$name"
        return 0
    fi
    local rp_pwd rp_root
    rp_pwd="$(realpath "$PWD" 2>/dev/null || echo "$PWD")"
    rp_root="$(realpath "$repo_root" 2>/dev/null || echo "$repo_root")"
    if [[ "$rp_pwd" == "$rp_root" || "$rp_pwd" == "$rp_root"/* ]]; then
        printf 'main'
    fi
}

# _switch_candidates <all:true|false> — echo the switch candidates, one name per
# line: "main" first, then worktrees most-recently-viewed first. By default only
# names viewed within switch_recent_days are included; a recency name whose
# worktree dir no longer exists is dropped. Under --all the window filter is
# lifted and every remaining existing worktree is appended (recency order first,
# never-viewed worktrees last). Shared by the picker and `cmd_switch_data`.
_switch_candidates() {
    local show_all="$1"
    local -a names=("main")
    local -A seen=([main]=1)
    local cutoff="" n days="${switch_recent_days:-7}"
    [[ "$show_all" == true ]] || cutoff=$(( $(date +%s) - days * 86400 ))
    while IFS= read -r n; do
        [[ -n "$n" && -z "${seen[$n]:-}" ]] || continue
        is_worktree_dir "$worktrees_dir/$n" || continue
        seen[$n]=1
        names+=("$n")
    done < <(recent_names "$cutoff")
    if [[ "$show_all" == true ]]; then
        while IFS=$'\t' read -r n _; do
            [[ -n "$n" && -z "${seen[$n]:-}" ]] || continue
            seen[$n]=1
            names+=("$n")
        done < <(worktree_names_branches 2>/dev/null || true)
    fi
    printf '%s\n' "${names[@]}"
}

# _switch_reload_cmd <all:true|false> — the shell command fzf runs on its `load`
# event to enrich the picker (phase 2). FW_COLOR=always keeps color through the
# pipe (the auto gate strips it otherwise). The binary and project are pinned so
# the fresh subprocess enriches the *same* thing phase 1 listed:
#   - $FW_SELF (not a bare `fw`) is the resolved running binary, %q-quoted so an
#     install path with a space/metacharacter survives fzf's `sh -c`.
#   - -p "$project" pins the resolved project; without it the child re-resolves
#     from its cwd and could enrich a different project (or none) than phase 1.
# --all propagates as an argument, matching cmd_switch_data's own flag.
_switch_reload_cmd() {
    local show_all="$1" cmd
    printf -v cmd 'FW_COLOR=always %q -p %q _switch-data' "$FW_SELF" "$project"
    [[ "$show_all" == true ]] && cmd+=" --all"
    printf '%s' "$cmd"
}

# _switch_refresh_secs — the normalized picker refresh interval in seconds:
#   - a bare non-negative integer is taken as-is (0 => refresh disabled);
#   - empty (the user cleared it) also disables (0);
#   - any other value (non-numeric) falls back to the 10s default, so a typo
#     can never inject a non-integer into the `sleep` the loop runs.
_switch_refresh_secs() {
    local v="${switch_refresh_secs-}"
    if [[ -z "$v" ]]; then
        printf '0'
    elif [[ "$v" =~ ^[0-9]+$ ]]; then
        printf '%s' "$v"
    else
        printf '10'
    fi
}

# _switch_refresh_cmd <all> <secs> <cache> — the shell command fzf's `load` loop
# runs to enrich the picker when refresh is enabled. Same resolved-binary/project
# pinning as _switch_reload_cmd (see there), but it invokes `_switch-refresh`,
# the cache+pace wrapper, so the expensive enrichment runs at most once per <secs>
# no matter how often fzf re-fires the loop. <cache> (%q-quoted; a TMPDIR path can
# carry a space) is the per-picker cache the wrapper reads and writes.
_switch_refresh_cmd() {
    local show_all="$1" secs="$2" cache="$3" cmd
    printf -v cmd 'FW_COLOR=always %q -p %q _switch-refresh --secs %s --cache %q' \
        "$FW_SELF" "$project" "$secs" "$cache"
    [[ "$show_all" == true ]] && cmd+=" --all"
    printf '%s' "$cmd"
}

# _switch_pick <all:true|false> — echo the picked worktree name. Returns 0 with
# a name, 1 on a cancelled picker (quiet no-op for the caller), 2 when fzf is
# missing or errors (the error is already on stderr).
#
# Two-phase picker. Phase 1 is instant: each candidate (_switch_candidates)
# renders as "<name> <colored viewed-age>\t<name>" straight from the recency log
# — no git/claude subprocesses. Phase 2 enriches on fzf's `load` event, which
# reload-syncs the enrichment (FW_COLOR=always, since its stdout is a pipe the
# auto gate would strip) in place and preselects the current worktree via pos(N).
# With refresh enabled (switch_refresh_secs > 0, the default) the load bind is a
# self-perpetuating loop that re-enriches so the live Claude badge stays current:
# the reload is a *direct* reload-sync of `_switch-refresh` (never gated behind a
# transform, so the first — Claude-latency-bearing — enrich always commits rather
# than being superseded by the loop's next iteration), and `_switch-refresh`
# caches+paces so the expensive query runs at most once per N seconds. A separate
# reload-free transform applies pos(N) on the first load only, so later refreshes
# don't yank the cursor. Disabled (switch_refresh_secs=0), it enriches once and
# unbinds — the pre-refresh behavior, verbatim. On selection the whole line comes
# back; cut -f2 recovers the name from the trailing "\t<name>" key.
_switch_pick() {
    local show_all="$1"
    local days="${switch_recent_days:-7}"
    local -a names=()
    local n
    while IFS= read -r n; do names+=("$n"); done < <(_switch_candidates "$show_all")

    local header="Select worktree (last ${days}d)"
    [[ "$show_all" == true ]] && header="Select worktree (all)"

    # Name column width: longest candidate, capped at 55 (matches cmd_switch_data
    # so phase 1 and phase 2 align and the swap doesn't jump).
    local max_name=0
    for n in "${names[@]}"; do
        [[ ${#n} -gt $max_name ]] && max_name=${#n}
    done
    [[ $max_name -gt 55 ]] && max_name=55

    local now_epoch
    now_epoch="$(date +%s)"

    local -a lines=()
    local display_name viewed_ts
    for n in "${names[@]}"; do
        display_name="$n"
        [[ ${#display_name} -gt $max_name ]] && display_name="${display_name:0:$((max_name - 1))}…"
        display_name="$(printf "%-${max_name}s" "$display_name")"
        [[ "$n" == "main" ]] && display_name="${C_GREEN}${display_name}${C_RESET}"
        viewed_ts="$(last_viewed_ts "$n")"
        lines+=("$(printf '%s  %s\t%s' \
            "$display_name" "$(format_age_colored "$viewed_ts" "$now_epoch")" "$n")")
    done

    # Preselect the current worktree (fzf pos() is 1-based). Applied only on the
    # first enrich — re-applying it on every refresh would yank the cursor back
    # while the user navigates. Degrades safely: the shim ignores it, and a real
    # fzf without a match just starts at the top.
    local pos_action="" current i
    current="$(_current_worktree_name)"
    if [[ -n "$current" ]]; then
        for i in "${!names[@]}"; do
            [[ "${names[$i]}" == "$current" ]] && { pos_action="pos($((i + 1)))"; break; }
        done
    fi

    # The load bind. fzf's `load` event fires each time input finishes loading,
    # including after a reload, so binding it to a `reload-sync` re-arms itself —
    # enrich → enrich → … for as long as the picker is open. Crucially the reload
    # is issued *directly* (not from inside a transform): a transform-gated reload
    # gets superseded by the loop's own next iteration before its first, slow
    # (Claude-latency-bearing) enrich can commit, which left the picker stuck on
    # the un-enriched phase-1 rows. The interval lives inside `_switch-refresh`
    # (cache + pace), not in the bind, so the reload command stays constant and
    # the first enrich is never behind a `sleep`. pos() is applied once via a
    # separate reload-free transform that consumes a marker on the first load.
    # Disabled (interval 0) emits the pre-refresh single-shot bind verbatim.
    local secs load_action scratch=""
    secs="$(_switch_refresh_secs)"
    if [[ "$secs" -gt 0 ]]; then
        scratch="$(mktemp -d "${TMPDIR:-/tmp}/fw-switch.XXXXXX")" || return 2
        local marker="$scratch/pos" cache="$scratch/cache"
        : >"$marker"   # the first load consumes it to pos() once
        local refresh_cmd
        refresh_cmd="$(_switch_refresh_cmd "$show_all" "$secs" "$cache")"
        load_action="reload-sync($refresh_cmd)"
        if [[ -n "$pos_action" ]]; then
            # pos_action is a bare `pos(N)` (no quotes), safe inside the echo.
            local mq; printf -v mq '%q' "$marker"
            load_action+="+transform:if [ -e $mq ]; then rm -f $mq; echo '$pos_action'; else echo; fi"
        fi
    else
        local reload_cmd
        reload_cmd="$(_switch_reload_cmd "$show_all")"
        load_action="reload-sync($reload_cmd)+unbind(load)"
        [[ -n "$pos_action" ]] && load_action+="+$pos_action"
    fi

    local -a fzf_args=(
        --reverse --ansi --no-hscroll --tiebreak=begin
        --header="$header"
        --bind "change:first"
        --bind "load:$load_action"
    )

    # `|| rc=$?` keeps the command-substitution failure (fzf cancel/missing)
    # from tripping the entrypoint's errexit before we can inspect the code.
    local selected rc=0
    selected="$(printf '%s\n' "${lines[@]}" | _fzf_pick_line "${fzf_args[@]}")" || rc=$?
    # The refresh scratch dir (pos marker + enrichment cache/ts/lock) is one-shot
    # per-picker state; drop it on every exit path so nothing leaks between runs.
    [[ -n "$scratch" ]] && rm -rf "$scratch"
    case $rc in
        0) ;;              # selection in $selected
        1) return 1 ;;     # cancelled / nothing selected
        *) return 2 ;;     # fzf missing or real error (message already printed)
    esac
    # Recover the name from the trailing "\t<name>" key. Every row carries exactly
    # one tab (cmd_switch_data sanitizes free-form fields), so field 2 is the name.
    printf '%s' "$(cut -f2 <<<"$selected")"
    return 0
}

# cmd_switch_data [--all] — emit the phase-2 enriched picker rows, one per
# switch candidate (_switch_candidates). Each visible half is
#   "<name>  <viewed-age> <commit-age> <claude> <summary>"
# (name green for main; viewed-age recency-colored; claude green/yellow), then
# the branch is pushed far right and a trailing "\t<name>" key is appended for
# _switch_pick to cut out on selection. Internal: fzf's load event reloads this
# with FW_COLOR=always (its stdout is a pipe, which the default gate would strip)
# — see lib/colors.sh. Claude status is matched by worktree name, not path
# prefix as legacy did.
cmd_switch_data() {
    local show_all=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) show_all=true; shift ;;
            *) echo "Error: unknown argument '$1'" >&2; return 1 ;;
        esac
    done

    local -a names=()
    local n
    while IFS= read -r n; do names+=("$n"); done < <(_switch_candidates "$show_all")

    local -A claude_by_wt=()
    build_claude_status_map claude_by_wt

    local now_epoch summary_file max_name=0
    now_epoch="$(date +%s)"
    summary_file="${claude_summary_file:-.fw-summary.md}"

    # Name column width: the longest candidate, capped at 55.
    for n in "${names[@]}"; do
        [[ ${#n} -gt $max_name ]] && max_name=${#n}
    done
    [[ $max_name -gt 55 ]] && max_name=55

    local name wt_path viewed_ts commit_epoch commit_age
    local claude_status claude_display summary display_name branch visible
    for name in "${names[@]}"; do
        # main lives at the golden checkout; every other candidate under worktrees_dir.
        if [[ "$name" == "main" ]]; then wt_path="$repo_root"; else wt_path="$worktrees_dir/$name"; fi

        viewed_ts="$(last_viewed_ts "$name")"

        commit_epoch="$(git -C "$wt_path" log -1 --format=%ct 2>/dev/null)" || commit_epoch=""
        [[ -n "$commit_epoch" ]] || commit_epoch="$now_epoch"
        commit_age="$(format_age "$commit_epoch" "$now_epoch")"

        claude_status="${claude_by_wt[$name]:-}"
        claude_display=""
        case "$claude_status" in
            waiting) claude_display="${C_YELLOW} waiting${C_RESET}" ;;
            running) claude_display="${C_GREEN} running${C_RESET}" ;;
        esac

        summary=""
        if [[ -f "$wt_path/$summary_file" ]]; then
            summary="$(head -1 "$wt_path/$summary_file" | sed 's/^#* *//')"
            [[ ${#summary} -gt 60 ]] && summary="${summary:0:57}…"
        fi

        display_name="$name"
        [[ ${#display_name} -gt $max_name ]] && display_name="${display_name:0:$((max_name - 1))}…"
        display_name="$(printf "%-${max_name}s" "$display_name")"
        [[ "$name" == "main" ]] && display_name="${C_GREEN}${display_name}${C_RESET}"

        branch="$(git -C "$wt_path" branch --show-current 2>/dev/null || true)"

        # Strip tabs/newlines from free-form fields so they can't forge the
        # trailing key column.
        summary="${summary//[$'\t\n']/ }"
        branch="${branch//[$'\t\n']/ }"

        printf -v visible "%s  %s %-5s %s %s" \
            "$display_name" "$(format_age_colored "$viewed_ts" "$now_epoch")" \
            "$commit_age" "$claude_display" "$summary"
        printf "%-200s %s\t%s\n" "$visible" "$branch" "$name"
    done
}

# cmd_switch_refresh --secs <N> --cache <file> [--all] — the picker's phase-2
# reload with caching + pacing (dispatched as the internal `_switch-refresh`).
# fzf's self-perpetuating `load` loop re-runs this every cycle; here we make the
# expensive enrichment (git + Claude) run at most once per <N> seconds:
#   - empty/stale cache → regenerate now (no sleep). The first call of a picker
#     hits this, so the initial enrich is prompt and never superseded.
#   - fresh cache (< N s old) → sleep out the remainder of the interval, then
#     serve the cache. The sleep both paces the Claude query and throttles the
#     load loop, which would otherwise spin on the now-cheap reload.
# A mkdir lock collapses the startup/interval-boundary thundering herd: a caller
# that loses the race waits for the winner's cache instead of duplicating work.
# The cache/ts/lock live under the caller's --cache dir, which _switch_pick rm's
# on exit, so nothing persists between pickers. Without --cache it degrades to a
# plain one-shot enrichment.
cmd_switch_refresh() {
    local secs=10 cache="" all=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --secs)  secs="$2"; shift 2 ;;
            --cache) cache="$2"; shift 2 ;;
            --all)   all=true; shift ;;
            *) echo "Error: unknown argument '$1'" >&2; return 1 ;;
        esac
    done

    if [[ -z "$cache" ]]; then
        if [[ "$all" == true ]]; then cmd_switch_data --all; else cmd_switch_data; fi
        return
    fi

    local ts="$cache.ts" lock="$cache.lock" now last age
    now="$(date +%s)"
    last="$(cat "$ts" 2>/dev/null || echo 0)"
    age=$(( now - last ))

    if [[ -s "$cache" && "$age" -lt "$secs" ]]; then
        sleep "$(( secs - age ))"
        cat "$cache"
        return 0
    fi

    if mkdir "$lock" 2>/dev/null; then
        # Only publish (and stamp) the cache on a clean enrich, so a transient
        # failure isn't frozen in for the whole interval; a failed pass falls
        # through to serving whatever the previous cache held.
        if { if [[ "$all" == true ]]; then cmd_switch_data --all; else cmd_switch_data; fi; } >"$cache.tmp"; then
            mv "$cache.tmp" "$cache"
            date +%s >"$ts"
        else
            rm -f "$cache.tmp"
        fi
        rmdir "$lock" 2>/dev/null || true
        cat "$cache" 2>/dev/null
    else
        # A peer is regenerating; wait (bounded) for its cache, then serve it
        # rather than launch a duplicate Claude query.
        local i=0
        while [[ ! -s "$cache" && "$i" -lt 50 ]]; do sleep 1; i=$(( i + 1 )); done
        if [[ -s "$cache" ]]; then cat "$cache"
        elif [[ "$all" == true ]]; then cmd_switch_data --all
        else cmd_switch_data; fi
    fi
}

# _switch_to_main — open the golden-checkout (main) tmux session. `main` is
# reserved: it has no worktree dir under worktrees_dir, so it can't go through
# resolve_worktree; its checkout is the project's repo_root and its session is
# the same "<project>-main" that switch-project lands in.
_switch_to_main() {
    local quiet="${1:-false}"
    record_viewed "main"
    local session="${project}-main"
    [[ "$quiet" == true ]] || echo "Switching to main"
    # main has no worktree: FW_WORKTREE lands empty so a hook can give it a
    # different (or no) layout. Exported before session birth all the same.
    _export_fw_session_env "" "" "$repo_root"
    run_hook hook_post_switch "$repo_root" warn
    _ensure_tmux_session "$session" "$repo_root"
    _attach_tmux_session "$session"
}

cmd_switch() {
    local name="" show_all=false quiet=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) show_all=true; shift ;;
            --quiet) quiet=true; shift ;;
            -*) echo "Error: unknown flag '$1'" >&2; return 1 ;;
            *) name="$1"; shift ;;
        esac
    done

    if [[ -z "$name" ]]; then
        local rc=0
        name="$(_switch_pick "$show_all")" || rc=$?
        case $rc in
            0) ;;              # got a selection
            1) return 0 ;;     # cancelled — quiet no-op
            *) return 1 ;;     # fzf missing / error already reported
        esac
    fi

    if [[ "$name" == "main" ]]; then
        _switch_to_main "$quiet"
        return
    fi

    resolve_worktree "$name" || return 1

    # The directory alone isn't proof of a worktree: a removal that raced a
    # running server can leave the dir behind without its env file. Refuse to
    # land a session in such a phantom rather than cd-ing into a non-worktree.
    if ! is_worktree_dir "$WT_PATH"; then
        echo "Error: '$WT_NAME' is not a worktree (no $env_file at $WT_PATH) — it may be a leftover from a partial delete" >&2
        return 1
    fi

    read_worktree_env "$WT_PATH" 2>/dev/null || true
    _export_fw_env "$WT_NAME" "${WT_BRANCH:-}" "$WT_PATH"
    run_hook hook_post_switch "$WT_PATH" warn

    [[ "$quiet" == true ]] || echo "Switching to $WT_NAME"
    cmd_tmux_open "$WT_NAME"
}

# cmd_switch_project <name> — jump to another registered project, landing in the
# session you were last in there (its most recent switch-history entry — a
# worktree or main), not unconditionally its main. Because the active project is
# derived from cwd, "switching" is just landing a tmux session in the other repo.
# _recent_projects — registered project names, most-recently-switched first
# (from project_log), with any never-switched projects appended in registry
# order.
_recent_projects() {
    local cfg_dir
    cfg_dir="$(fw_config_dir)"
    local -A seen=()
    local name
    # Recency comes from the shared "<ts>\t<name>" parser; the config-existence
    # filter (a stale project_log entry may name a since-removed project) stays
    # local to project switching.
    while IFS= read -r name; do
        [[ -n "$name" && -z "${seen[$name]:-}" ]] || continue
        [[ -f "$cfg_dir/projects/$name/config.sh" ]] || continue
        seen[$name]=1
        echo "$name"
    done < <(recent_names "" "$(_project_log)")
    while IFS= read -r name; do
        [[ -n "$name" && -z "${seen[$name]:-}" ]] || continue
        seen[$name]=1
        echo "$name"
    done < <(list_projects)
}

# _switch_project_pick — echo the picked project name. Same return contract as
# _switch_pick (0 name, 1 cancelled, 2 fzf missing).
#
# Each row renders as "<name>  <colored last-switched-age>\t<name>" — the age
# from project_log (format_age_colored shows "-" for a never-switched project),
# then a trailing "\t<name>" key cut back out on selection. Single phase: the
# only per-project cost is one project_log lookup, so there is nothing to enrich
# asynchronously the way the worktree picker does.
_switch_project_pick() {
    local -a names=()
    local n
    while IFS= read -r n; do
        [[ -n "$n" ]] && names+=("$n")
    done < <(_recent_projects)
    if [[ ${#names[@]} -eq 0 ]]; then
        echo "Error: no projects registered — run 'fw init' in a repo first" >&2
        return 2
    fi

    local log now_epoch max_name=0
    log="$(_project_log)"
    now_epoch="$(date +%s)"

    # Name column width: the longest candidate, capped at 55 (matches the
    # worktree picker so the layouts read the same).
    for n in "${names[@]}"; do
        [[ ${#n} -gt $max_name ]] && max_name=${#n}
    done
    [[ $max_name -gt 55 ]] && max_name=55

    local -a lines=()
    local display_name switched_ts
    for n in "${names[@]}"; do
        display_name="$n"
        [[ ${#display_name} -gt $max_name ]] && display_name="${display_name:0:$((max_name - 1))}…"
        display_name="$(printf "%-${max_name}s" "$display_name")"
        switched_ts="$(last_viewed_ts "$n" "$log")"
        lines+=("$(printf '%s  %s\t%s' \
            "$display_name" "$(format_age_colored "$switched_ts" "$now_epoch")" "$n")")
    done

    local selected rc=0
    selected="$(printf '%s\n' "${lines[@]}" | _fzf_pick_line --reverse --ansi --header='Select project')" || rc=$?
    case $rc in
        0) ;;
        1) return 1 ;;     # cancelled / nothing selected
        *) return 2 ;;     # fzf missing or real error (message already printed)
    esac
    # Recover the name from the trailing "\t<name>" key.
    printf '%s' "$(cut -f2 <<<"$selected")"
    return 0
}

cmd_switch_project() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        local rc=0
        name="$(_switch_project_pick)" || rc=$?
        case $rc in
            0) ;;
            1) return 0 ;;
            *) return 1 ;;
        esac
    fi

    if [[ ! -f "$(fw_config_dir)/projects/$name/config.sh" ]]; then
        echo "Error: project '$name' is not registered (fw projects lists them)" >&2
        return 1
    fi
    load_config "$name" || return 1

    record_project_visit "$name"

    # Land where you last were in this project: the most recent visit-history
    # entry whose checkout still exists. main is the guaranteed floor — its
    # checkout always exists — so an empty/all-deleted log lands there and `sp`
    # never errors. load_config has repointed the globals, so _first_recent_dir
    # reads this project's .fw_recent.
    local landing
    landing="$(_first_recent_dir)"
    [[ -n "$landing" ]] || landing="main"

    # Delegate the actual landing: cmd_switch routes main -> _switch_to_main and a
    # worktree -> cmd_tmux_open, so recreate-if-missing, record_viewed, and the
    # "Switching to …" message all come from the one shared path.
    cmd_switch "$landing"
}

cmd_last() {
    local quiet=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quiet) quiet=true; shift ;;
            -*) echo "Error: unknown flag '$1'" >&2; return 1 ;;
            *) shift ;;
        esac
    done

    # Toggle to the previous worktree: the most recent existing entry other than
    # the current one (top of the list), skipping any deleted since. Unlike `sp`,
    # there's no main floor — nothing to toggle to is a genuine error.
    local prev
    prev="$(_first_recent_dir "$(recent_names | sed -n 1p)")"
    if [[ -n "$prev" ]]; then
        local args=("$prev")
        [[ "$quiet" == true ]] && args+=(--quiet)
        cmd_switch "${args[@]}"
        return
    fi
    echo "Error: no previous worktree to switch to" >&2
    return 1
}
