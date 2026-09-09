# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# fw switch-claude / sc — a cross-project picker over Claude Code's live-session
# registry (~/.claude/sessions/*.json), one file per running `claude` process.
#
# Unlike `fw claude` (project-scoped, reads `claude agents --json`), this reads
# the registry directly for two fields that view needs: `tmux` (the session's
# session:@window.%pane, so selecting a row jumps to the exact pane with no
# PID->pane tree-walk) and `statusUpdatedAt` (when the session entered its
# current state — the true "last active" clock). Each session's cwd is mapped to
# an fw (project, worktree) by prefix-matching every registered project's
# repo_root and worktrees_dir; sessions outside every project are dropped.
#
# The picker is single-phase (the mapping is pure string work, so there is
# nothing slow to enrich asynchronously the way `fw switch` does). Rows are a
# nested tree grouped by project -> worktree, ordered by urgency (a worktree
# holding a waiting session floats its project up), and colored by status and
# idle staleness.

# Idle age-color band edges (seconds). The bands are ordered (default < warn <
# blue < old), so they are constants rather than a single config knob that could
# invert the ordering. See _swc_color_age.
SWC_WARN_SECS=2700    # 45m: idle beyond this is a "just went stale" warning
SWC_BLUE_SECS=3600    # 1h:  beyond the warning band, a calm parked blue
SWC_OLD_SECS=86400    # 1d:  beyond this, old news — back to the default color

# _swc_sessions_dir — the live-session registry directory. CLAUDE_CONFIG_DIR is
# Claude Code's own override (also honored by lib/skills.sh, lib/usage.sh); the
# test seam points it at a fixture dir.
_swc_sessions_dir() {
    printf '%s/sessions' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

# _swc_project_worktrees_dir <name> — a registered project's worktrees_dir,
# realpath-normalized: the config value if set, else the load_config default of
# <dirname repo_root>/<project>-worktrees. Empty when the project has no
# repo_root. Mirrors _project_repo_root so the picker maps cwds without a full
# load_config per project.
_swc_project_worktrees_dir() {
    local name="$1" cfg wd root
    cfg="$(fw_config_dir)/projects/$name/config.sh"
    wd="$(_peek_config_var "$cfg" worktrees_dir)"
    if [[ -n "$wd" ]]; then
        realpath "$wd" 2>/dev/null || printf '%s' "$wd"
        return 0
    fi
    root="$(_project_repo_root "$name")"
    [[ -n "$root" ]] || return 0
    printf '%s/%s-worktrees' "$(dirname "$root")" "$name"
}

# Project path table — every registered project's name, realpath'd repo_root,
# and realpath'd worktrees_dir, as parallel arrays. _swc_build_project_table
# fills it once; _swc_locate consults it. Hoisting this out of the per-session
# loop is the whole speedup: it turns O(sessions x projects) config sourcings
# (each _project_repo_root / _swc_project_worktrees_dir sources a config.sh in a
# subshell) into O(projects). _SWC_PT_READY guards the one-time build so a
# standalone _swc_locate (e.g. in tests) still self-primes.
_SWC_PT_NAME=()
_SWC_PT_ROOT=()
_SWC_PT_WTDIR=()
_SWC_PT_READY=0

# _swc_peek_root_wtdir <name> — a project's realpath'd (repo_root, worktrees_dir),
# emitted on two lines. This is _project_repo_root and _swc_project_worktrees_dir
# fused into a single config source (they otherwise source the config up to three
# times between them). The resolution semantics are preserved exactly:
#   repo_root     — realpath the raw value; EMPTY when it is unset or realpath
#                   fails (mirrors _project_repo_root's `|| true`).
#   worktrees_dir — if set, realpath it, keeping the LITERAL value on failure;
#                   else default to <dirname repo_root>/<name>-worktrees, or
#                   empty when repo_root did not resolve.
# Two lines (not tab-joined): an empty repo_root as a leading field would be lost
# to IFS-tab coalescing on read; separate lines with `IFS= read` preserve empties.
# <name> is the project name (for the default worktrees_dir suffix); <cfg> is its
# config path, passed in so the caller resolves fw_config_dir once for the whole
# table rather than per project.
_swc_peek_root_wtdir() {
    local name="$1" cfg="$2"
    (
        set +eu
        unset repo_root worktrees_dir
        # shellcheck disable=SC1090  # dynamic user config path
        source "$cfg" >/dev/null 2>&1
        local root="" wd="" parent
        if [[ -n "${repo_root:-}" ]]; then
            root="$(realpath "$repo_root" 2>/dev/null || true)"
        fi
        if [[ -n "${worktrees_dir:-}" ]]; then
            wd="$(realpath "$worktrees_dir" 2>/dev/null || printf '%s' "$worktrees_dir")"
        elif [[ -n "$root" ]]; then
            # dirname via parameter expansion (no fork); a root-level path like
            # "/x" strips to "" — restore the "/" dirname would return.
            parent="${root%/*}"
            [[ -n "$parent" ]] || parent="/"
            wd="$parent/$name-worktrees"
        fi
        printf '%s\n%s\n' "$root" "$wd"
    )
}

# _swc_build_project_table — (re)derive the project table. Always rebuilds from
# scratch, so a long-lived shell whose registrations changed re-derives on the
# next call. _swc_sessions_tsv calls this once before its file loop.
_swc_build_project_table() {
    _SWC_PT_NAME=()
    _SWC_PT_ROOT=()
    _SWC_PT_WTDIR=()
    local cfgbase name root wd
    cfgbase="$(fw_config_dir)/projects"
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        { IFS= read -r root; IFS= read -r wd; } \
            < <(_swc_peek_root_wtdir "$name" "$cfgbase/$name/config.sh")
        _SWC_PT_NAME+=("$name")
        _SWC_PT_ROOT+=("$root")
        _SWC_PT_WTDIR+=("$wd")
    done < <(list_projects)
    _SWC_PT_READY=1
}

# _swc_locate <cwd> — map a session's cwd to "<project>\t<worktree>" (worktree is
# "main" at/under repo_root), or return 1 when it is under no registered project.
# A worktree match is tried before the repo_root match; both sides are
# realpath-normalized so a symlinked /tmp or a subdirectory still resolves.
# Reads the prebuilt project table (built lazily on first call if a caller has
# not primed it), so it forks only the single cwd realpath — no per-project
# config sourcing. The table is built once per process; a caller that mutates
# project registrations mid-run must call _swc_build_project_table to refresh it
# (the production caller, _swc_sessions_tsv, re-primes on every run).
_swc_locate() {
    local cwd="$1" rp i name root wd rest wt
    (( _SWC_PT_READY )) || _swc_build_project_table
    rp="$(realpath "$cwd" 2>/dev/null || printf '%s' "$cwd")"
    for i in "${!_SWC_PT_NAME[@]}"; do
        name="${_SWC_PT_NAME[$i]}"
        wd="${_SWC_PT_WTDIR[$i]}"
        if [[ -n "$wd" && "$rp" == "$wd/"* ]]; then
            rest="${rp#"$wd"/}"
            wt="${rest%%/*}"
            if [[ -n "$wt" ]]; then
                printf '%s\t%s\n' "$name" "$wt"
                return 0
            fi
        fi
        root="${_SWC_PT_ROOT[$i]}"
        if [[ -n "$root" && ( "$rp" == "$root" || "$rp" == "$root/"* ) ]]; then
            printf '%s\tmain\n' "$name"
            return 0
        fi
    done
    return 1
}

# _swc_split <tab-line> — split a tab-separated line into the SWC_FIELDS array,
# preserving empty fields. `IFS=$'\t' read` cannot be used for this: tab is an
# IFS-whitespace character, so read coalesces runs of tabs and drops empty
# non-terminal fields. The registry's tmux (pane) and name fields are optional
# and sit mid-row, so an empty one would otherwise shift every later field left.
_swc_split() {
    local line="$1"
    SWC_FIELDS=()
    while true; do
        SWC_FIELDS+=("${line%%$'\t'*}")
        [[ "$line" == *$'\t'* ]] || break
        line="${line#*$'\t'}"
    done
}

# The jq filter extracting one @tsv row per registry file: the six fields
# _swc_sessions_tsv needs, with defaults so a missing key never shifts columns.
_SWC_JQ_ROW='[
    (.pid // "" | tostring),
    (.cwd // ""),
    (.status // "unknown"),
    ((.statusUpdatedAt // .updatedAt // 0) | tostring),
    (.tmux // ""),
    (.name // "")
] | @tsv'

# _swc_raw_rows <dir> — emit _SWC_JQ_ROW for every *.json in <dir>, one line per
# file in glob order. Fast path: a single jq over all files (one fork, not one
# per file). A registry file is written live by a running claude process, so a
# half-written/corrupt file is possible; it aborts the batch (jq stops at the
# first parse error), so on any nonzero exit we discard the partial output and
# fall back to a per-file jq — where one bad file drops only itself. Capturing
# the batch output (rather than streaming it) is what makes the fallback safe:
# rows the batch emitted before aborting would otherwise duplicate.
_swc_raw_rows() {
    local dir="$1" files f out
    files=( "$dir"/*.json )
    [[ -e "${files[0]}" ]] || return 0
    if out="$(jq -r "$_SWC_JQ_ROW" "${files[@]}" 2>/dev/null)"; then
        [[ -n "$out" ]] && printf '%s\n' "$out"
        return 0
    fi
    for f in "${files[@]}"; do
        jq -r "$_SWC_JQ_ROW" "$f" 2>/dev/null || true
    done
}

# _swc_sessions_tsv <now-epoch> [target-project] — one normalized row per live,
# fw-mapped session:
#   project<TAB>worktree<TAB>status<TAB>age_secs<TAB>pane<TAB>name
# A registry file is live when its pid is still running (kill -0), guarding
# against a crash that skipped cleanup. age_secs is now - statusUpdatedAt (which
# the registry stamps in epoch millis). Sessions outside every project, or with
# a dead pid, are dropped. When <target-project> is non-empty, sessions in any
# other project are dropped too (the `--project-only` scope). Prints nothing
# (never errors) when the registry dir is absent, so callers can pipe it
# straight into a read loop.
_swc_sessions_tsv() {
    local now_s="$1" target="${2:-}" dir
    dir="$(_swc_sessions_dir)"
    [[ -d "$dir" ]] || return 0
    # Derive every project's paths once, up front — the per-session _swc_locate
    # calls below then reuse this table instead of re-sourcing configs per file.
    _swc_build_project_table
    local line pid cwd status supd pane name age loc project worktree
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        # A read here would coalesce an empty tmux field (a session started
        # outside tmux), shifting name into pane; split preserves empties.
        _swc_split "$line"
        pid="${SWC_FIELDS[0]:-}"
        cwd="${SWC_FIELDS[1]:-}"
        status="${SWC_FIELDS[2]:-}"
        supd="${SWC_FIELDS[3]:-}"
        pane="${SWC_FIELDS[4]:-}"
        name="${SWC_FIELDS[5]:-}"
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        kill -0 "$pid" 2>/dev/null || continue
        [[ -n "$cwd" ]] || continue
        loc="$(_swc_locate "$cwd")" || continue
        IFS=$'\t' read -r project worktree <<<"$loc"
        [[ -z "$target" || "$project" == "$target" ]] || continue
        age=0
        if [[ "$supd" =~ ^[0-9]+$ && "$supd" -gt 0 ]]; then
            age=$(( now_s - supd / 1000 ))
            if (( age < 0 )); then age=0; fi
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$project" "$worktree" "$status" "$age" "$pane" "$name"
    done < <(_swc_raw_rows "$dir")
    return 0
}

# _swc_color_age <status> <age-secs> — the color code for the age column. Status
# drives it outright for waiting/busy (their age is self-explanatory); an idle
# age is banded: default <45m, warning (orange) 45m-1h, blue 1h-1d, default >1d.
# Prints the empty string for the default (no color), so callers wrap only when
# it is non-empty.
_swc_color_age() {
    local status="$1" secs="$2"
    case "$status" in
        waiting) printf '%s' "$C_RED"; return 0 ;;
        busy)    printf '%s' "$C_GREEN"; return 0 ;;
    esac
    [[ "$secs" =~ ^[0-9]+$ ]] || return 0
    if   (( secs < SWC_WARN_SECS )); then :
    elif (( secs < SWC_BLUE_SECS )); then printf '%s' "$C_ORANGE"
    elif (( secs < SWC_OLD_SECS  )); then printf '%s' "$C_BLUE"
    fi
    return 0
}

# _swc_status_cell <status> — the colored, fixed-width "<glyph> <word>" status
# cell: waiting red, busy green, idle dim. Padding is applied to the plain text
# before the color wraps it so the escape bytes never skew alignment.
_swc_status_cell() {
    local status="$1" glyph gpad word color plain
    case "$status" in
        waiting) glyph="⏸"; gpad=""; word="waiting"; color="$C_RED" ;;
        busy)    glyph="⚡"; gpad=""; word="busy";    color="$C_GREEN" ;;
        idle)    glyph="—"; gpad=" "; word="idle";    color="$C_DIM" ;;
        *)       glyph="—"; gpad=" "; word="$status"; color="$C_DIM" ;;
    esac
    # ⚡/⏸ render two display cells wide but count as one character; the em-dash
    # is one cell. gpad pads the narrow glyph so the glyph slot is a uniform two
    # columns, keeping the age column aligned across statuses.
    printf -v plain '%s%s %-7s' "$glyph" "$gpad" "$word"
    printf '%s%s%s' "$color" "$plain" "$C_RESET"
}

# _swc_fmt_age <secs> — compact relative age (now / 5m / 3hr / 2d / 7d+),
# mirroring format_age but taking a pre-computed seconds delta.
_swc_fmt_age() {
    local s="$1"
    [[ "$s" =~ ^[0-9]+$ ]] || { printf '?'; return 0; }
    if   (( s < 60 ));     then printf 'now'
    elif (( s < 3600 ));   then printf '%dm' "$(( s / 60 ))"
    elif (( s < 86400 ));  then printf '%dhr' "$(( s / 3600 ))"
    elif (( s < 604800 )); then printf '%dd' "$(( s / 86400 ))"
    else printf '7d+'
    fi
    return 0
}

# _swc_label <text> — a worktree/session label padded to a fixed width and
# truncated with an ellipsis, tabs/newlines flattened so it can't forge the
# trailing key columns.
_swc_label() {
    local s="$1" w=22
    s="${s//[$'\t\n']/ }"
    if (( ${#s} > w )); then s="${s:0:w-1}…"; fi
    printf "%-${w}s" "$s"
}

# _swc_render — turn the ranked, sorted rows on stdin (see _swc_build_rows) into
# display lines. Emits a dim project header on each project change, a dim
# worktree sub-header for multi-session worktrees, and one selectable row per
# session. Every line ends with a tab-separated key; all three kinds are
# selectable and share the session key shape (empty pane on the headers), so
# cmd_switch_claude dispatches them through the one _swc_goto:
#   project header  -> "…\tP\t\t<project>\tmain"       (Enter -> main worktree)
#   worktree header -> "…\tW\t\t<project>\t<worktree>"  (Enter -> that worktree)
#   session         -> "…\tS\t<pane>\t<project>\t<worktree>"
# A single-session worktree renders inline (its worktree name is the label); a
# multi-session worktree renders its sessions as ├/└ children labeled by name.
_swc_render() {
    local prev_project="" prev_wt="" wt_seen=0
    local project worktree wcount status sage pane name
    local agetxt color age_col statuscell glyph label line
    # split (not read): the pane and name fields can be empty and would otherwise
    # coalesce, misaligning the row.
    while IFS= read -r line; do
        _swc_split "$line"
        project="${SWC_FIELDS[2]:-}"
        worktree="${SWC_FIELDS[5]:-}"
        wcount="${SWC_FIELDS[8]:-}"
        status="${SWC_FIELDS[11]:-}"
        sage="${SWC_FIELDS[12]:-}"
        pane="${SWC_FIELDS[13]:-}"
        name="${SWC_FIELDS[14]:-}"
        [[ -n "$project" ]] || continue
        if [[ "$project" != "$prev_project" ]]; then
            printf '%s%s%s\tP\t\t%s\tmain\n' "$C_DIM" "$project" "$C_RESET" "$project"
            prev_project="$project"
            prev_wt=""
        fi

        agetxt="$(printf '%-4s' "$(_swc_fmt_age "$sage")")"
        color="$(_swc_color_age "$status" "$sage")"
        if [[ -n "$color" ]]; then age_col="${color}${agetxt}${C_RESET}"; else age_col="$agetxt"; fi
        statuscell="$(_swc_status_cell "$status")"

        if (( wcount > 1 )); then
            if [[ "$worktree" != "$prev_wt" ]]; then
                printf '  %s%s%s\tW\t\t%s\t%s\n' "$C_DIM" "$worktree" "$C_RESET" "$project" "$worktree"
                prev_wt="$worktree"
                wt_seen=0
            fi
            wt_seen=$(( wt_seen + 1 ))
            glyph="├"
            if (( wt_seen == wcount )); then glyph="└"; fi
            label="$(_swc_label "$name")"
            printf '    %s %s  %s  %s\tS\t%s\t%s\t%s\n' \
                "$glyph" "$label" "$statuscell" "$age_col" "$pane" "$project" "$worktree"
        else
            label="$(_swc_label "$worktree")"
            printf '  %s  %s  %s\tS\t%s\t%s\t%s\n' \
                "$label" "$statuscell" "$age_col" "$pane" "$project" "$worktree"
        fi
    done
}

# _swc_current_project [cwd] — the project the cwd sits in, for `--project-only`.
# Reuses _swc_locate (the very mapping the session rows use, so the picker's scope
# is symmetric with what it lists), then FW_PROJECT (exported into fw-managed
# panes). It deliberately does NOT consult default_project the way resolve_project
# does: `--project-only` must never silently scope to a project the cwd is not in.
# Both paths resolve only to a *registered* project — a cwd match is a table entry
# by construction, and an FW_PROJECT fallback is honored only when it still names
# a registered project (never a stale/unknown name). Prints the project name, or
# returns non-zero (the caller errors out) when nothing registered resolves.
_swc_current_project() {
    local cwd="${1:-$PWD}" loc name
    if loc="$(_swc_locate "$cwd")"; then
        printf '%s' "${loc%%$'\t'*}"
        return 0
    fi
    if [[ -n "${FW_PROJECT:-}" ]]; then
        # _swc_locate primed the table above; guard so a standalone call still works.
        (( _SWC_PT_READY )) || _swc_build_project_table
        for name in "${_SWC_PT_NAME[@]}"; do
            if [[ "$name" == "$FW_PROJECT" ]]; then
                printf '%s' "$FW_PROJECT"
                return 0
            fi
        done
    fi
    return 1
}

# _swc_pos_for <rows> <cur-pane-id> <cur-project> <cur-worktree> — the 1-based
# line index in <rows> to preselect the fzf cursor on, or empty (→ fzf's default
# top). Pure: it reads only its arguments, so the caller gathers the live inputs
# (the tmux pane id, the current project/worktree) and this stays unit-testable.
# Priority, matching the request:
#   1. the current pane's own session — the S row whose pane id (the %N tail of
#      session:@win.%pane) equals <cur-pane-id>. Wins regardless of which project
#      it sits in, so it is checked first and returns immediately.
#   2. the current worktree's session — the first S row keyed to
#      <cur-project>/<cur-worktree> (the worktree the cwd sits in). Lands on a
#      live session even when the current pane itself is not one.
#   3. the current project's header — the first P row keyed to <cur-project>.
#   4. none → nothing, so the picker opens at the top (a project header).
# Empty <cur-pane-id> (not inside tmux), <cur-worktree> (cwd not in a worktree),
# or <cur-project> (cwd maps nowhere) simply skip their branch. Only the first
# match of each kind matters, so the scan records the worktree/project positions
# lazily and short-circuits on the pane match; worktree beats project on return.
_swc_pos_for() {
    local rows="$1" cur_pane="$2" cur_proj="$3" cur_wt="$4"
    local line i=0 marker pane proj wt wt_pos="" proj_pos=""
    while IFS= read -r line; do
        i=$(( i + 1 ))
        _swc_split "$line"
        marker="${SWC_FIELDS[1]:-}"
        pane="${SWC_FIELDS[2]:-}"
        proj="${SWC_FIELDS[3]:-}"
        wt="${SWC_FIELDS[4]:-}"
        if [[ "$marker" == "S" && -n "$cur_pane" && -n "$pane" \
              && "${pane##*.}" == "$cur_pane" ]]; then
            printf '%s' "$i"
            return 0
        fi
        if [[ -z "$wt_pos" && "$marker" == "S" && -n "$cur_wt" \
              && "$proj" == "$cur_proj" && "$wt" == "$cur_wt" ]]; then
            wt_pos="$i"
        fi
        if [[ -z "$proj_pos" && "$marker" == "P" && -n "$cur_proj" \
              && "$proj" == "$cur_proj" ]]; then
            proj_pos="$i"
        fi
    done <<<"$rows"
    if   [[ -n "$wt_pos"   ]]; then printf '%s' "$wt_pos"
    elif [[ -n "$proj_pos" ]]; then printf '%s' "$proj_pos"
    fi
    return 0
}

# _swc_empty_rows <project> — the `--project-only` empty state: a dim project
# header plus a single non-selectable "no active claude sessions" placeholder,
# indented like a worktree sub-header. Both carry the H marker (the one
# non-selectable kind — cmd_switch_claude's dispatch no-ops it), deliberately
# unlike the live P/W headers _swc_render emits: with zero sessions there is
# nothing to act on, so this view is a predictable no-op landing.
_swc_empty_rows() {
    local project="$1"
    printf '%s%s%s\tH\n' "$C_DIM" "$project" "$C_RESET"
    printf '  %s%s%s\tH\n' "$C_DIM" "no active claude sessions" "$C_RESET"
}

# _swc_build_rows [target-project] — the picker's row list. Reads the live
# registry (scoped to <target-project> when given), ranks each session (status
# waiting<busy<idle, then freshest age), aggregates the best rank per worktree and
# per project, sorts so a project/worktree floats up on its most urgent session
# (sessions within a worktree stay contiguous), and renders the nested tree.
# Empty (return 0, no output) when there are no live fw sessions in scope.
_swc_build_rows() {
    local target="${1:-}" now_s tsv sorted
    now_s="$(date +%s)"
    tsv="$(_swc_sessions_tsv "$now_s" "$target")"
    [[ -n "$tsv" ]] || return 0

    # Pass 1 (awk): rank each session and compute per-worktree / per-project
    # urgency. Pass 2 (sort): order by project urgency, then project name, then
    # worktree urgency, then worktree name, then the session's own rank/age — so
    # the render pass sees projects and worktrees already grouped and ordered.
    sorted="$(printf '%s\n' "$tsv" | awk -F'\t' '
        function srank(s) { return s == "waiting" ? 0 : (s == "busy" ? 1 : (s == "idle" ? 2 : 3)) }
        {
            proj = $1; wt = $2; st = $3; age = $4 + 0
            n++; L[n] = $0; PJ[n] = proj; WT[n] = wt; SR[n] = srank(st); AG[n] = age
            wk = proj SUBSEP wt
            if (!(wk in wsr) || SR[n] < wsr[wk]) wsr[wk] = SR[n]
            if (!(wk in wag) || age  < wag[wk]) wag[wk] = age
            wc[wk]++
            if (!(proj in psr) || SR[n] < psr[proj]) psr[proj] = SR[n]
            if (!(proj in pag) || age  < pag[proj]) pag[proj] = age
        }
        END {
            for (i = 1; i <= n; i++) {
                wk = PJ[i] SUBSEP WT[i]
                printf "%d\t%d\t%s\t%d\t%d\t%s\t%d\t%d\t%d\t%s\n",
                    psr[PJ[i]], pag[PJ[i]], PJ[i], wsr[wk], wag[wk], WT[i], SR[i], AG[i], wc[wk], L[i]
            }
        }' | sort -t$'\t' -k1,1n -k2,2n -k3,3 -k4,4n -k5,5n -k6,6 -k7,7n -k8,8n)"

    printf '%s\n' "$sorted" | _swc_render
}

# _swc_goto <pane> <project> <worktree> — switch to a selected session. Loads the
# target project (so recency and the fallback resolve in its context), then jumps
# to the exact registry pane (switch-client + select-window + select-pane) when
# it still exists. Falls back to the worktree's fw session (cmd_tmux_open, or the
# golden checkout for main) when the pane is empty (session not under tmux) or
# gone (crashed without cleanup).
_swc_goto() {
    local pane="$1" project="$2" worktree="$3"
    load_config "$project" || return 1

    local sess="" rest="" win="" pn=""
    if [[ -n "$pane" ]]; then
        sess="${pane%%:*}"
        rest="${pane#*:}"
        win="${rest%%.*}"
        pn="${rest#*.}"
    fi

    if [[ -n "$pane" ]] && tmux has-session -t "=$sess" 2>/dev/null; then
        _attach_tmux_session "$sess"
        # Window/pane ids (@N / %N) are server-global, so they select without the
        # session prefix; guarded so a vanished pane can't abort the switch.
        tmux select-window -t "$win" 2>/dev/null || true
        tmux select-pane -t "$pn" 2>/dev/null || true
        record_viewed "$worktree"
        return 0
    fi

    if [[ "$worktree" == "main" ]]; then
        _switch_to_main true
    else
        cmd_tmux_open "$worktree"
    fi
}

# cmd_switch_claude_data [--project <name>] — emit the picker's rows (the nested
# project->worktree session tree). This is the phase-2 reload target: fzf's `load`
# event reloads it so the live registry (statuses flipping, sessions appearing/
# vanishing) stays current while the picker is open. It calls the SAME
# _swc_build_rows the initial paint uses, so the two never drift. Cross-project by
# default (no _require_project): it reads the global registry, so it runs from
# anywhere. Under `--project <name>` (the `--project-only` picker's reload) it
# scopes to that project and, when the project has no live sessions, re-emits the
# "no active claude sessions" placeholder so a refresh never blanks the picker —
# mirroring cmd_switch_claude's own empty state so the reload never drifts from
# the initial paint. Internal; the reload invokes it with FW_COLOR=always (its
# stdout is a pipe the default gate would strip) — fw_color_init here honors that.
cmd_switch_claude_data() {
    local target=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) target="$2"; shift 2 ;;
            *) echo "Error: unknown argument '$1'" >&2; return 1 ;;
        esac
    done
    fw_color_init
    local rows
    rows="$(_swc_build_rows "$target")"
    if [[ -z "$rows" && -n "$target" ]]; then
        rows="$(_swc_empty_rows "$target")"
    fi
    [[ -n "$rows" ]] && printf '%s\n' "$rows"
    return 0
}

# _swc_reload_cmd [target-project] — the shell command fzf runs on `load` to
# re-list the picker when refresh is disabled (one-shot). FW_COLOR=always keeps
# color through the pipe; $FW_SELF (the resolved running binary, %q-quoted so an
# install path with a space survives fzf's `sh -c`) is pinned, not a bare `fw`.
# With no target the reload is cross-project (re-lists the whole registry); with
# one it appends `--project <name>` so a `--project-only` picker stays scoped
# across reloads.
_swc_reload_cmd() {
    local target="${1:-}" cmd
    printf -v cmd 'FW_COLOR=always %q _switch-claude-data' "$FW_SELF"
    [[ -n "$target" ]] && printf -v cmd '%s --project %q' "$cmd" "$target"
    printf '%s' "$cmd"
}

# _swc_refresh_cmd <secs> <cache> [target-project] — the shell command fzf's
# `load` loop runs to re-list the picker when refresh is enabled. Same
# resolved-binary pinning as _swc_reload_cmd, but it invokes the
# `_switch-claude-refresh` cache+pace wrapper, so the registry read runs at most
# once per <secs> however often fzf re-fires the loop. <cache> (%q-quoted; a
# TMPDIR path can carry a space) is the per-picker cache the wrapper reads and
# writes. A non-empty target appends `--project <name>` so the `--project-only`
# picker's paced reload stays scoped.
_swc_refresh_cmd() {
    local secs="$1" cache="$2" target="${3:-}" cmd
    printf -v cmd 'FW_COLOR=always %q _switch-claude-refresh --secs %s --cache %q' \
        "$FW_SELF" "$secs" "$cache"
    [[ -n "$target" ]] && printf -v cmd '%s --project %q' "$cmd" "$target"
    printf '%s' "$cmd"
}

# _swc_refresh_secs — the normalized picker refresh interval in seconds, read
# from the GLOBAL config (switch-claude is cross-project, so there is no project
# config to consult): a bare non-negative integer is taken as-is (0 => disabled);
# unset or any non-numeric value falls back to the 10s default, so the feature
# stays on and a typo can never inject a non-integer into the loop's `sleep`.
_swc_refresh_secs() {
    local v
    v="$(_peek_config_var "$(fw_config_dir)/config.sh" switch_claude_refresh_secs)"
    if [[ "$v" =~ ^[0-9]+$ ]]; then
        printf '%s' "$v"
    else
        printf '10'
    fi
}

# cmd_switch_claude_refresh --secs <N> --cache <file> — the picker's phase-2
# reload with caching + pacing (dispatched as internal `_switch-claude-refresh`).
# fzf's self-perpetuating `load` loop re-runs this every cycle; here we make the
# registry read run at most once per <N> seconds:
#   - empty/stale cache -> regenerate now (no sleep). The first call of a picker
#     hits this, so the initial list is prompt and never superseded.
#   - fresh cache (< N s old) -> sleep out the remainder of the interval, then
#     serve the cache. The sleep both paces the read and throttles the load loop,
#     which would otherwise spin on the now-cheap reload.
# A mkdir lock collapses the startup/interval-boundary thundering herd. The
# cache/ts/lock live under the caller's --cache dir, which cmd_switch_claude rm's
# on exit, so nothing persists between pickers. Without --cache it degrades to a
# plain one-shot list. Mirrors cmd_switch_refresh (lib/switch.sh).
cmd_switch_claude_refresh() {
    local secs=10 cache="" target=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --secs)    secs="$2"; shift 2 ;;
            --cache)   cache="$2"; shift 2 ;;
            --project) target="$2"; shift 2 ;;
            *) echo "Error: unknown argument '$1'" >&2; return 1 ;;
        esac
    done

    # Forward the scope to every regeneration below (empty target = cross-project).
    local data_args=()
    [[ -n "$target" ]] && data_args=(--project "$target")

    if [[ -z "$cache" ]]; then
        cmd_switch_claude_data "${data_args[@]}"
        return
    fi

    local ts="$cache.ts" lock="$cache.lock" now last age
    now="$(date +%s)"
    last="$(cat "$ts" 2>/dev/null || echo 0)"
    age=$(( now - last ))

    # Pace on the freshness stamp, not on cache size. Unlike switch (whose
    # candidate list is never empty), _swc_build_rows legitimately emits NOTHING
    # when zero sessions are live, so a `-s "$cache"` gate would make every reload
    # miss this branch and hot-spin the registry read while an empty picker stays
    # open. A stamped ts (written only after a clean pass, empty or not) means a
    # read already ran this interval, so serve the cache — empty or not.
    if [[ -f "$ts" && "$age" -lt "$secs" ]]; then
        sleep "$(( secs - age ))"
        cat "$cache" 2>/dev/null
        return 0
    fi

    if mkdir "$lock" 2>/dev/null; then
        # Only publish (and stamp) the cache on a clean list, so a transient
        # failure isn't frozen in for the whole interval; a failed pass falls
        # through to serving whatever the previous cache held.
        if cmd_switch_claude_data "${data_args[@]}" >"$cache.tmp"; then
            mv "$cache.tmp" "$cache"
            date +%s >"$ts"
        else
            rm -f "$cache.tmp"
        fi
        rmdir "$lock" 2>/dev/null || true
        cat "$cache" 2>/dev/null
    else
        # A peer is regenerating; wait (bounded) for its cache, then serve it
        # rather than launch a duplicate registry read.
        local i=0
        while [[ ! -s "$cache" && "$i" -lt 50 ]]; do sleep 1; i=$(( i + 1 )); done
        if [[ -s "$cache" ]]; then cat "$cache"
        else cmd_switch_claude_data "${data_args[@]}"; fi
    fi
}

# cmd_switch_claude — the `fw switch-claude` / `sc` entry point. Cross-project by
# design (no _require_project): it reads the global registry, so it runs from
# anywhere. FW_COLOR=always keeps the picker's color through fzf's pipe (the auto
# gate would strip it). A missing fzf is a hard error (rc 2 propagates), distinct
# from a cancel (rc 1 -> quiet no-op); the only non-selectable row is the empty
# state's H placeholder (selecting it returns a no-op).
#
# Two-phase, continuously-refreshing picker. Phase 1 paints _swc_build_rows
# straight to fzf. Phase 2 re-lists on fzf's `load` event, which — because `load`
# re-fires each time a reload completes — self-perpetuates into a refresh loop so
# the live registry stays current while the picker is open. The reload is issued
# *directly* (a plain reload-sync, never gated behind a transform: a transform-
# gated reload gets superseded by the loop's own next iteration before its first
# read commits — the bd186f8 bug in switch). The interval lives inside the
# `_switch-claude-refresh` cache+pace wrapper, not in the bind, so the reload
# command is constant and the first read is never behind a `sleep`. Disabled
# (switch_claude_refresh_secs=0) lists once and unbinds.
#
# Preselect: the cursor opens on the current pane's own session if it has one,
# else the current worktree's session, else the current project's header, else
# the top (see _swc_pos_for). It is a
# once-only pos(N): applied on the first load via a marker file the transform
# consumes, so the refresh loop never yanks the cursor on later reloads (the
# _switch_pick pattern). Caveat: N indexes the phase-1 rows, so a status flip in
# the sub-second before the first reload could shift a row under the fixed index
# — an inherent, negligible property this already-live-refreshing picker has.
cmd_switch_claude() {
    local project_only=0 arg
    for arg in "$@"; do
        case "$arg" in
            --project-only) project_only=1 ;;
            *) echo "fw switch-claude: unknown argument '$arg'" >&2; return 2 ;;
        esac
    done

    FW_COLOR=always fw_color_init

    # --project-only scopes the picker to the project the cwd sits in; a cwd that
    # maps to no registered project is a hard error (strict — never guess).
    local target="" header='Select Claude session'
    if (( project_only )); then
        target="$(_swc_current_project)" || {
            echo "fw switch-claude --project-only: not inside a registered project" >&2
            return 1
        }
        header="Select Claude session — $target"
    fi

    local rows
    rows="$(_swc_build_rows "$target")"
    if [[ -z "$rows" ]]; then
        if (( project_only )); then
            # Still open the picker, labeled — the header + a non-selectable
            # "no active claude sessions" placeholder — so the keybinding always
            # lands in a predictable, project-scoped view.
            rows="$(_swc_empty_rows "$target")"
        else
            echo "No active Claude sessions."
            return 0
        fi
    fi

    # Preselect the cursor (fzf pos() is 1-based). The current pane id comes from
    # tmux (empty when not inside tmux → no pane match), the current project from
    # the same resolver the rows use. _swc_pos_for is pure, so both live inputs
    # are gathered here and passed in.
    local pos_action="" pos_n cur_pane cur_proj cur_wt="" loc
    cur_pane="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
    # Under --project-only, `target` already IS the current project (resolved
    # above), so reuse it; cross-project (target empty) resolves here.
    cur_proj="${target:-$(_swc_current_project 2>/dev/null || true)}"
    # The current worktree, from the same cwd→(project,worktree) mapping the rows
    # use — only trusted when its project matches cur_proj (so an FW_PROJECT
    # fallback that differs from the cwd never pins a stray worktree).
    loc="$(_swc_locate "$PWD" 2>/dev/null || true)"
    [[ -n "$loc" && "${loc%%$'\t'*}" == "$cur_proj" ]] && cur_wt="${loc#*$'\t'}"
    pos_n="$(_swc_pos_for "$rows" "$cur_pane" "$cur_proj" "$cur_wt")"
    [[ -n "$pos_n" ]] && pos_action="pos($pos_n)"

    # The load bind. fzf's `load` fires each time input finishes loading (a reload
    # included), so a `reload-sync` on it re-arms itself. The interval is inside
    # `_switch-claude-refresh` (cache+pace), never a `sleep` in the bind. Disabled
    # emits the single-shot list-then-unbind. The preselect pos() is applied ONCE:
    # under refresh via a marker-guarded transform the first load consumes (so
    # later refreshes don't yank the cursor); disabled, appended directly to the
    # one-shot bind. The reload-sync stays direct either way (never transform-
    # gated — the bd186f8 bug).
    local secs load_action scratch=""
    secs="$(_swc_refresh_secs)"
    if [[ "$secs" -gt 0 ]]; then
        scratch="$(mktemp -d "${TMPDIR:-/tmp}/fw-switch-claude.XXXXXX")" || return 2
        local cache="$scratch/cache" refresh_cmd
        refresh_cmd="$(_swc_refresh_cmd "$secs" "$cache" "$target")"
        load_action="reload-sync($refresh_cmd)"
        if [[ -n "$pos_action" ]]; then
            local mq; printf -v mq '%q' "$scratch/pos"
            : >"$scratch/pos"   # the first load consumes it to pos() once
            load_action+="+transform:if [ -e $mq ]; then rm -f $mq; echo '$pos_action'; else echo; fi"
        fi
    else
        local reload_cmd
        reload_cmd="$(_swc_reload_cmd "$target")"
        load_action="reload-sync($reload_cmd)+unbind(load)"
        [[ -n "$pos_action" ]] && load_action+="+$pos_action"
    fi

    # --with-nth=1 shows only the visible first field; the marker/pane/project/
    # worktree key columns after the first tab stay in the line (recovered on
    # selection) but off the display. Search still spans the whole line, so an
    # untruncated worktree name in the hidden columns is still typeable.
    local selected rc=0
    selected="$(printf '%s\n' "$rows" \
        | _fzf_pick_line --ansi --reverse --no-hscroll \
            --delimiter=$'\t' --with-nth=1 --header="$header" \
            --bind "load:$load_action")" || rc=$?
    # The refresh scratch dir (per-picker cache/ts/lock) is one-shot state; drop
    # it on every exit path so nothing leaks between pickers.
    [[ -n "$scratch" ]] && rm -rf "$scratch"
    case $rc in
        0) ;;              # selection in $selected
        1) return 0 ;;     # cancelled — quiet no-op
        2) return 2 ;;     # fzf missing — hard error (message already on stderr)
        *) return 3 ;;     # a real fzf failure
    esac

    # split (not read): a no-tmux session's pane is empty and would coalesce,
    # shifting project/worktree left.
    local kind pane project worktree
    _swc_split "$selected"
    kind="${SWC_FIELDS[1]:-}"
    pane="${SWC_FIELDS[2]:-}"
    project="${SWC_FIELDS[3]:-}"
    worktree="${SWC_FIELDS[4]:-}"
    # All three selectable kinds route through the one _swc_goto: a session (S)
    # jumps to its pane; a project header (P, empty pane, worktree=main) and a
    # worktree sub-header (W, empty pane) fall through _swc_goto's empty-pane path
    # to the worktree's fw session (main → _switch_to_main, else cmd_tmux_open).
    # The empty state's H placeholder is the only no-op.
    case "$kind" in
        S|P|W) _swc_goto "$pane" "$project" "$worktree" ;;
        *) return 0 ;;
    esac
}
