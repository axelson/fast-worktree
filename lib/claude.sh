# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# Claude Code integration. This stays in core by design (see
# docs/plans/2026-08-16-generalize-design.md): it is part of the tool's pitch
# ("worktree manager for Claude Code + Elixir"), and keeping it core avoids
# needing a list-column provider protocol. All project-specific paths are
# driven by config (claude_archive_dir/paths, claude_summary_file) so nothing
# felt-specific lives here.

# format_age <ts> <now> — compact relative age (now / 5m / 3hr / 2d / 7d+);
# empty for a zero or blank timestamp.
format_age() {
    local ts="$1" now="$2"
    [[ -n "$ts" && "$ts" != "0" ]] || return 0
    local secs=$((now - ts))
    if [[ $secs -lt 60 ]]; then echo "now"
    elif [[ $secs -lt 3600 ]]; then echo "$((secs / 60))m"
    elif [[ $secs -lt 86400 ]]; then echo "$((secs / 3600))hr"
    elif [[ $secs -lt $((7 * 86400)) ]]; then echo "$((secs / 86400))d"
    else echo "7d+"
    fi
}

# format_age_colored <ts> <now> — format_age padded to 5 visible columns and
# tinted by recency: bright blue <45m, yellow <1h, cyan <8h, neutral beyond
# (and for a never-viewed "-"). Padding is applied to the visible text before
# the color wraps it, so the escape bytes never skew column alignment. Colors
# come from lib/colors.sh and are blank strings when color is gated off, in
# which case this degrades to a plain 5-wide age. Used by the `fw switch` picker.
format_age_colored() {
    local ts="$1" now="$2"
    local age display
    age="$(format_age "$ts" "$now")"
    display="$(printf '%-5s' "${age:--}")"
    if [[ -n "$ts" && "$ts" != "0" ]]; then
        local secs=$((now - ts))
        if [[ $secs -lt 2700 ]]; then display="${C_BLUE_BRIGHT}${display}${C_RESET}"
        elif [[ $secs -lt 3600 ]]; then display="${C_YELLOW}${display}${C_RESET}"
        elif [[ $secs -lt 28800 ]]; then display="${C_CYAN}${display}${C_RESET}"
        fi
    fi
    printf '%s' "$display"
}

# _mtime_or_0 <file> — file modification time in epoch seconds, or 0 when the
# file is missing. Tries BSD stat (-f%m) then GNU stat (-c %Y) so the result is
# a real mtime on both macOS and Linux; a missing file is distinguished
# explicitly ([[ -f ]]) rather than conflated with a stat failure.
_mtime_or_0() {
    local f="$1"
    [[ -f "$f" ]] || { echo 0; return 0; }
    stat -f%m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0
}

# last_viewed_ts lives in lib/switch.sh, beside the other recency-log helpers.

# --- Claude agent discovery ---

# _claude_available — true when the claude CLI is on PATH.
_claude_available() { command -v claude >/dev/null 2>&1; }

# _claude_agents_tsv — one normalized row per running agent, tab-separated:
#   pid<TAB>cwd<TAB>status<TAB>kind<TAB>name<TAB>startedAt
# The single parse of `claude agents --json`: status hedges .status // .state,
# missing scalars fall back to empty/"unknown"/0, and @tsv escapes any embedded
# tabs/newlines so every record stays on one line. Emits nothing (never an
# error) when claude is absent or returns nothing, so callers can pipe it
# straight into a read loop at zero cost when the CLI isn't installed.
_claude_agents_tsv() {
    _claude_available || return 0
    local json
    json="$(claude agents --json 2>/dev/null)" || return 0
    printf '%s' "$json" | jq -r '
        .[] | [
            (.pid // "" | tostring),
            (.cwd // ""),
            (.status // .state // "unknown"),
            (.kind // "unknown"),
            (.name // ""),
            (.startedAt // 0 | tostring)
        ] | @tsv
    ' 2>/dev/null || true
}

# _claude_wt_display_name <cwd> — map a session's cwd to a worktree label:
# under worktrees_dir -> the worktree name; at/under repo_root -> "main";
# anything else -> "<basename> (external)".
_claude_wt_display_name() {
    local cwd="$1" name
    if name="$(worktree_name_for_path "$cwd")"; then
        echo "$name"
    elif [[ "$cwd" == "$repo_root" || "$cwd" == "$repo_root/"* ]]; then
        echo "main"
    else
        echo "$(basename "$cwd") (external)"
    fi
}

# fetch_claude_statuses — CWD<tab>STATUS lines (running|waiting) for every
# busy/waiting session; empty when claude is absent. Call once per `fw list`,
# then bucket the result by worktree name (see cmd_list).
fetch_claude_statuses() {
    _claude_agents_tsv | awk -F'\t' '
        $3 == "busy"    { print $2 "\trunning" }
        $3 == "waiting" { print $2 "\twaiting" }
    '
}

# build_claude_status_map <assoc-name> — fill the named assoc array (via
# nameref) with worktree-name -> status ("running"|"waiting") for every busy or
# waiting Claude session, from a single fetch_claude_statuses call. Waiting
# outranks running when a worktree has multiple sessions; sessions whose cwd is
# outside the worktrees dir are dropped. The map is left empty when claude is
# absent (fetch emits nothing). Shared by `fw list` and the `fw switch` picker
# so both bucket identically. Writes through a nameref — call it directly, never
# in a $()-subshell.
build_claude_status_map() {
    local -n _bcsm_map="$1"
    local claude_statuses
    claude_statuses="$(fetch_claude_statuses)" || claude_statuses=""
    [[ -n "$claude_statuses" ]] || return 0
    local wt_root rp_root cwd st sname rp_cwd
    wt_root="$(realpath "$worktrees_dir" 2>/dev/null || echo "$worktrees_dir")"
    rp_root="$(realpath "$repo_root" 2>/dev/null || echo "$repo_root")"
    while IFS=$'\t' read -r cwd st; do
        [[ -n "$cwd" ]] || continue
        # A worktree session buckets under its name; a session in the golden
        # checkout (repo_root, which is not under worktrees_dir) buckets under
        # "main" so the picker's main row is badged, matching _claude_wt_display_name
        # / `fw claude`. Anything elsewhere is dropped.
        if ! sname="$(worktree_name_for_path "$cwd" "$wt_root")"; then
            rp_cwd="$(realpath "$cwd" 2>/dev/null || echo "$cwd")"
            if [[ "$rp_cwd" == "$rp_root" || "$rp_cwd" == "$rp_root"/* ]]; then
                sname="main"
            else
                continue
            fi
        fi
        if [[ "$st" == "waiting" || -z "${_bcsm_map["$sname"]:-}" ]]; then
            _bcsm_map["$sname"]="$st"
        fi
    done <<<"$claude_statuses"
}

# --- create/pull: --model and --claude ---

# resolve_model <alias-or-id> — a model id from claude_model_aliases, else the
# argument unchanged (model ids are version-specific, so unknown values pass
# through to `claude` rather than erroring).
resolve_model() {
    local m="$1"
    if [[ -n "${claude_model_aliases[$m]:-}" ]]; then
        echo "${claude_model_aliases[$m]}"
    else
        echo "$m"
    fi
}

# _prompt_flag_for <flag> — echo the Claude prompt bound to a bare flag like
# --review when its name (sans leading --) is a key in claude_prompt_flags;
# return 1 (emitting nothing) otherwise. This is what makes felt-style
# `fw pull <PR> --review` work: project config declares the flag→prompt map, so
# new review modes are config, not code. Matched as a last resort by cmd_pull /
# cmd_create so a real built-in flag always wins over a config collision.
_prompt_flag_for() {
    local name="${1#--}"
    [[ -n "${claude_prompt_flags[$name]:-}" ]] || return 1
    echo "${claude_prompt_flags[$name]}"
}

# _parse_claude_flag <model-var> <prompt-var> <remaining> <arg> [next] — the
# shared --model/--claude parsing for create and pull. Resolves a matched flag
# into the named vars and sets _CF_CONSUMED to how many argv entries it took (0
# when <arg> is not one of these flags, so the caller handles it). Returns 1
# (with a message) when a value-taking flag has no value. It writes through
# namerefs, so it must be called directly — never in a $()-subshell.
_parse_claude_flag() {
    local -n _cf_model="$1" _cf_prompt="$2"
    local remaining="$3" arg="$4" next="${5:-}"
    _CF_CONSUMED=0
    case "$arg" in
        --model)
            (( remaining >= 2 )) || { echo "Error: --model requires a value" >&2; return 1; }
            _cf_model="$(resolve_model "$next")"; _CF_CONSUMED=2 ;;
        --model=*) _cf_model="$(resolve_model "${arg#--model=}")"; _CF_CONSUMED=1 ;;
        --claude)
            (( remaining >= 2 )) || { echo "Error: --claude requires a prompt" >&2; return 1; }
            _cf_prompt="$next"; _CF_CONSUMED=2 ;;
        --claude=*) _cf_prompt="${arg#--claude=}"; _CF_CONSUMED=1 ;;
    esac
    return 0
}

# _claude_set_model <wt_path> <model> — write the model into the worktree's
# .claude/settings.local.json so a Claude launched there picks it up.
_claude_set_model() {
    local wt_path="$1" model="$2"
    local settings="$wt_path/.claude/settings.local.json"
    mkdir -p "$wt_path/.claude"
    # Seed an empty object when there's no settings file yet, then always merge
    # through jq — one path, no hand-rolled JSON string to escape.
    [[ -f "$settings" ]] || echo '{}' >"$settings"
    jq --arg m "$model" '. + {model: $m}' "$settings" >"$settings.tmp" &&
        mv "$settings.tmp" "$settings"
}

# _claude_launch_in_worktree <name> <wt_path> <prompt> — ensure the worktree's
# tmux session has a "claude" window and start Claude there with the prompt.
# Detached: create/pull start the session in the background; the user attaches
# with `fw switch`.
_claude_launch_in_worktree() {
    local name="$1" wt_path="$2" prompt="$3"
    local session
    session="$(_tmux_session_for "$name")"
    _ensure_tmux_session "$session" "$wt_path"
    if ! tmux list-windows -t "=$session" -F '#{window_name}' 2>/dev/null |
        grep -qx claude; then
        tmux new-window -t "=$session" -n claude -c "$wt_path"
    fi
    local cmd
    printf -v cmd 'claude %q' "$prompt"
    tmux send-keys -t "=$session:claude" "$cmd" Enter
}

# apply_claude_create_opts <name> <wt_path> <model> <prompt> — shared tail for
# create/pull: set the model (if any), then launch Claude (if a prompt was
# given). model/prompt are already resolved. Empty strings skip each step.
# Failures warn rather than abort: the worktree already exists and is usable,
# so a Claude-setup hiccup must not turn a successful create into an error.
apply_claude_create_opts() {
    local name="$1" wt_path="$2" model="$3" prompt="$4"
    if [[ -n "$model" ]]; then
        _claude_set_model "$wt_path" "$model" ||
            echo "Warning: could not set Claude model" >&2
    fi
    if [[ -n "$prompt" ]]; then
        _claude_launch_in_worktree "$name" "$wt_path" "$prompt" ||
            echo "Warning: could not launch Claude" >&2
    fi
    return 0
}

# --- delete-time archiving ---

# _claude_archive_target — the archive root for the active project, defaulting
# under the config dir when claude_archive_dir is unset.
_claude_archive_target() {
    if [[ -n "${claude_archive_dir:-}" ]]; then
        echo "$claude_archive_dir"
    else
        echo "$(fw_config_dir)/projects/$project/claude-archive"
    fi
}

# _transfer_dir_contents <src> <dest> <move_flag> — copy the full contents of
# directory <src> (including dotfiles) into existing directory <dest>. When
# move_flag is true, remove <src> afterward so it behaves as a move. `cp -a
# "$src"/.` is used both ways so hidden files round-trip symmetrically — a bare
# `mv "$src"/*` (no dotglob) silently strands dotfiles. Shared by
# archive_claude and restore_claude for their directory-pair artifacts.
_transfer_dir_contents() {
    local src="$1" dest="$2" move_flag="$3"
    cp -a "$src"/. "$dest/" 2>/dev/null || true
    if [[ "$move_flag" == true ]]; then
        rm -rf "$src" 2>/dev/null || true
    fi
}

# archive_claude <wt_path> [move] [branch] — copy (or move) a worktree's
# Claude artifacts (claude_archive_paths + settings.local.json + the summary
# file) into <archive>/<safe-branch>/ before the worktree is removed. A no-op,
# with a note, when there is nothing to archive.
archive_claude() {
    local wt_path="$1"
    local move_flag="${2:-false}"
    local branch="${3:-}"
    if [[ -z "$branch" ]]; then
        branch=$(git -C "$wt_path" rev-parse --symbolic-full-name --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        # During rebase/merge HEAD is detached — fall back to the worktree dir.
        [[ "$branch" == "HEAD" ]] && branch=$(basename "$wt_path")
    fi

    local summary_file="${claude_summary_file:-.fw-summary.md}"

    local has_content=false pair src
    for pair in "${claude_archive_paths[@]}"; do
        src="$wt_path/${pair%%:*}"
        # A pair's source may be a non-empty directory or a plain file.
        if [[ -d "$src" && -n "$(ls -A "$src" 2>/dev/null)" ]] || [[ -f "$src" ]]; then
            has_content=true
            break
        fi
    done
    [[ -f "$wt_path/.claude/settings.local.json" ]] && has_content=true
    [[ -f "$wt_path/$summary_file" ]] && has_content=true

    if [[ "$has_content" != true ]]; then
        echo "No Claude artifacts to archive"
        return 0
    fi

    local safe_name="${branch//\//-}"
    local dest
    dest="$(_claude_archive_target)/$safe_name"
    # A hiccup here (unwritable archive dir) must not abort the caller mid-delete
    # after the DB is already dropped: warn and leave the worktree removal to
    # proceed, exactly as apply_claude_create_opts tolerates setup failures.
    if ! mkdir -p "$dest" 2>/dev/null; then
        echo "Warning: could not create Claude archive dir $dest" >&2
        return 0
    fi

    local subdir
    for pair in "${claude_archive_paths[@]}"; do
        src="$wt_path/${pair%%:*}"
        subdir="${pair#*:}"
        if [[ -d "$src" && -n "$(ls -A "$src" 2>/dev/null)" ]]; then
            mkdir -p "$dest/$subdir"
            _transfer_dir_contents "$src" "$dest/$subdir" "$move_flag"
        elif [[ -f "$src" ]]; then
            # File pair: the dest side ($subdir) names a file, not a directory.
            # mkdir its parent so a dest like "docs/status.md" works too.
            mkdir -p "$(dirname "$dest/$subdir")"
            if [[ "$move_flag" == true ]]; then
                mv "$src" "$dest/$subdir" 2>/dev/null || true
            else
                cp "$src" "$dest/$subdir" 2>/dev/null || true
            fi
        fi
    done

    if [[ -f "$wt_path/.claude/settings.local.json" ]]; then
        if [[ "$move_flag" == true ]]; then
            mv "$wt_path/.claude/settings.local.json" "$dest/settings.local.json" 2>/dev/null || true
        else
            cp "$wt_path/.claude/settings.local.json" "$dest/settings.local.json" 2>/dev/null || true
        fi
    fi

    if [[ -f "$wt_path/$summary_file" ]]; then
        cp "$wt_path/$summary_file" "$dest/summary.md" 2>/dev/null || true
    fi

    echo "Archived Claude artifacts to $dest"
    return 0
}

# restore_claude <wt_path> [branch] [move] — the inverse of archive_claude:
# copy (or, by default, move) a branch's archived Claude artifacts
# (claude_archive_paths dirs AND files + settings.local.json + the summary
# file) from <archive>/<safe-branch>/ back into a freshly restored worktree.
# A no-op when there's no archive dir for the branch. Archived content wins:
# callers run this after hook_post_create so it overwrites any freshly-stamped
# template. Move is the default because cmd_restore retires the archive-log
# entry — leaving the artifacts behind would orphan them under a branch no
# longer tracked; moving them out is the symmetric choice.
restore_claude() {
    local wt_path="$1"
    local branch="${2:-}"
    local move_flag="${3:-true}"
    [[ -n "$branch" ]] || return 0

    local safe_name="${branch//\//-}"
    local src_dir
    src_dir="$(_claude_archive_target)/$safe_name"
    [[ -d "$src_dir" ]] || return 0

    local pair dest subdir src_sub
    for pair in "${claude_archive_paths[@]}"; do
        dest="$wt_path/${pair%%:*}"
        subdir="${pair#*:}"
        src_sub="$src_dir/$subdir"
        if [[ -d "$src_sub" && -n "$(ls -A "$src_sub" 2>/dev/null)" ]]; then
            mkdir -p "$dest"
            _transfer_dir_contents "$src_sub" "$dest" "$move_flag"
        elif [[ -f "$src_sub" ]]; then
            mkdir -p "$(dirname "$dest")"
            if [[ "$move_flag" == true ]]; then
                mv "$src_sub" "$dest" 2>/dev/null || true
            else
                cp "$src_sub" "$dest" 2>/dev/null || true
            fi
        fi
    done

    if [[ -f "$src_dir/settings.local.json" ]]; then
        mkdir -p "$wt_path/.claude"
        if [[ "$move_flag" == true ]]; then
            mv "$src_dir/settings.local.json" "$wt_path/.claude/settings.local.json" 2>/dev/null || true
        else
            cp "$src_dir/settings.local.json" "$wt_path/.claude/settings.local.json" 2>/dev/null || true
        fi
    fi

    local summary_file="${claude_summary_file:-.fw-summary.md}"
    if [[ -f "$src_dir/summary.md" ]]; then
        if [[ "$move_flag" == true ]]; then
            mv "$src_dir/summary.md" "$wt_path/$summary_file" 2>/dev/null || true
        else
            cp "$src_dir/summary.md" "$wt_path/$summary_file" 2>/dev/null || true
        fi
    fi

    # On a move restore the archive dir should be gone once its known contents
    # are back; rmdir succeeds only when nothing unexpected remains, so any
    # stray content (e.g. from a since-changed config) is left untouched.
    [[ "$move_flag" == true ]] && rmdir "$src_dir" 2>/dev/null || true
    return 0
}

# --- fw claude ---

cmd_claude() {
    local filter="" json_output=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --active) filter="active"; shift ;;
            --json) json_output=true; shift ;;
            -h|--help)
                echo "Usage: fw claude [--active] [--json]"
                echo
                echo "Show running Claude instances and which worktree they're in."
                echo
                echo "Options:"
                echo "  --active   Show only busy/waiting/blocked instances (hide idle)"
                echo "  --json     Output enriched JSON (adds worktree field)"
                return 0
                ;;
            *)
                echo "Error: unknown option '$1'" >&2
                echo "Usage: fw claude [--active] [--json]" >&2
                return 1
                ;;
        esac
    done

    if ! _claude_available; then
        echo "Error: claude CLI not found" >&2
        return 1
    fi

    if [[ "$json_output" == true ]]; then
        # Enrich each agent with its worktree label in a single jq pass. The
        # labels are computed in bash (so the realpath/repo_root mapping is
        # shared with the table path) and handed to jq as positional args,
        # aligned by array index — no O(n^2) accumulate-into-jq loop.
        local agents_json
        agents_json="$(claude agents --json 2>/dev/null)" || agents_json="[]"
        agents_json="$(printf '%s' "$agents_json" | jq 'sort_by(.startedAt)')"
        local count
        count=$(printf '%s' "$agents_json" | jq 'length')
        if [[ "$count" -eq 0 ]]; then
            # --json must always emit valid JSON, never prose.
            echo "[]"
            return 0
        fi
        local -a wt_names=() ; local cwd
        while IFS= read -r cwd; do
            wt_names+=("$(_claude_wt_display_name "$cwd")")
        done < <(printf '%s' "$agents_json" | jq -r '.[].cwd // ""')
        printf '%s' "$agents_json" | jq --arg active "$filter" --args '
            to_entries
            | map(.value + {worktree: $ARGS.positional[.key]})
            | if $active == "active"
              then map(select((.status // .state // "unknown") != "idle"))
              else . end
        ' "${wt_names[@]}"
        return 0
    fi

    local now_epoch
    now_epoch=$(date +%s)

    local tsv
    tsv="$(_claude_agents_tsv)"
    if [[ -z "$tsv" ]]; then
        echo "No Claude instances running."
        return 0
    fi
    # Oldest first by startedAt (column 6).
    tsv="$(printf '%s\n' "$tsv" | sort -t$'\t' -k6,6n)"

    # Build display rows, status counts, and column widths in one read loop —
    # no per-agent jq, no awk|wc count pipelines, no cut forks per field.
    local -a rows=()
    local total=0 busy_count=0 waiting_count=0 blocked_count=0 idle_count=0
    local max_wt=8 max_name=4
    local pid cwd status kind name started_at
    while IFS=$'\t' read -r pid cwd status kind name started_at; do
        [[ -n "$cwd" ]] || continue
        [[ "$filter" == "active" && "$status" == "idle" ]] && continue

        # The real CLI may report startedAt as an ISO string rather than epoch
        # millis; guard the arithmetic so a non-integer can't abort fw under
        # set -e — fall back to a "-" age column.
        local age="-"
        [[ "$started_at" =~ ^[0-9]+$ ]] && age=$(format_age "$(( started_at / 1000 ))" "$now_epoch")

        local wt_name
        wt_name=$(_claude_wt_display_name "$cwd")
        rows+=("${wt_name}"$'\t'"${kind}"$'\t'"${status}"$'\t'"${age}"$'\t'"${name}")
        (( total++ )) || true
        case "$status" in
            busy)    (( busy_count++ )) || true ;;
            waiting) (( waiting_count++ )) || true ;;
            blocked) (( blocked_count++ )) || true ;;
            idle)    (( idle_count++ )) || true ;;
        esac
        [[ ${#wt_name} -gt $max_wt ]] && max_wt=${#wt_name}
        [[ ${#name} -gt $max_name ]] && max_name=${#name}
    done <<<"$tsv"

    if [[ $total -eq 0 ]]; then
        echo "No active Claude instances."
        return 0
    fi
    [[ $max_wt -gt 45 ]] && max_wt=45
    [[ $max_name -gt 40 ]] && max_name=40

    local summary_parts=()
    [[ "$busy_count" -gt 0 ]]    && summary_parts+=("${busy_count} busy")
    [[ "$waiting_count" -gt 0 ]] && summary_parts+=("${waiting_count} waiting")
    [[ "$blocked_count" -gt 0 ]] && summary_parts+=("${blocked_count} blocked")
    [[ "$idle_count" -gt 0 ]]    && summary_parts+=("${idle_count} idle")
    # Join with ", " explicitly — assigning IFS to join via ${arr[*]} uses only
    # the first IFS char (giving "2 busy,1 waiting") and leaves IFS clobbered.
    local summary_line="" part
    for part in "${summary_parts[@]}"; do
        summary_line+="${summary_line:+, }$part"
    done
    echo "Claude Instances (${total} total: ${summary_line})"
    echo

    printf "%-${max_wt}s %-12s %-9s %-5s %s\n" "WORKTREE" "KIND" "STATUS" "AGE" "NAME"
    printf "%-${max_wt}s %-12s %-9s %-5s %s\n" "--------" "----" "------" "---" "----"

    local row
    for row in "${rows[@]}"; do
        local r_wt r_kind r_status r_age r_name
        IFS=$'\t' read -r r_wt r_kind r_status r_age r_name <<<"$row"
        [[ ${#r_wt} -gt $max_wt ]] && r_wt="${r_wt:0:$((max_wt - 2))}.."
        [[ ${#r_name} -gt $max_name ]] && r_name="${r_name:0:$((max_name - 2))}.."
        printf "%-${max_wt}s %-12s %-9s %-5s %s\n" "$r_wt" "$r_kind" "$r_status" "$r_age" "$r_name"
    done
}

# --- fw sessions ---

# _claude_stale_worktrees <cutoff-epoch> [wt_name…] — of the given worktree
# names, emit those whose last-viewed timestamp is older than the cutoff (or
# that were never viewed). The testable core of `sessions close-old`'s age gate.
_claude_stale_worktrees() {
    local cutoff="$1"; shift
    local wt_name viewed_ts
    for wt_name in "$@"; do
        viewed_ts=$(last_viewed_ts "$wt_name")
        if [[ -z "$viewed_ts" || "$viewed_ts" == "0" || "$viewed_ts" -lt "$cutoff" ]]; then
            echo "$wt_name"
        fi
    done
}

cmd_sessions_close_old() {
    local max_days=7
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days)
                [[ $# -ge 2 ]] || { echo "Error: --days requires a value" >&2; return 1; }
                max_days="$2"; shift 2 ;;
            --days=*) max_days="${1#--days=}"; shift ;;
            *) echo "Error: unknown argument '$1'" >&2; return 1 ;;
        esac
    done

    if ! _claude_available; then
        echo "Error: claude CLI not found" >&2
        return 1
    fi

    local now_epoch cutoff_epoch
    now_epoch=$(date +%s)
    cutoff_epoch=$(( now_epoch - max_days * 86400 ))

    # Snapshot both maps the discovery loop needs, once each: tmux pane PID ->
    # pane target, and every process's parent PID. Together they replace the
    # per-agent `ps` fork in the parent walk below.
    declare -A pane_targets=()
    local ppid target
    while IFS=' ' read -r ppid target; do
        pane_targets[$ppid]="$target"
    done < <(tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_name}.#{pane_index}' 2>/dev/null)

    declare -A ppid_of=()
    local _pid _ppid
    while read -r _pid _ppid; do
        ppid_of[$_pid]="$_ppid"
    done < <(ps -axo pid=,ppid= 2>/dev/null)

    local -a session_pids=() session_wt_names=() session_statuses=() session_pane_targets=()
    declare -A wt_session_count=() wt_indices=()

    local wt_root
    wt_root="$(realpath "$worktrees_dir" 2>/dev/null || echo "$worktrees_dir")"

    local pid cwd status kind name started_at wt_name
    while IFS=$'\t' read -r pid cwd status kind name started_at; do
        [[ -n "$pid" && -n "$cwd" ]] || continue
        wt_name="$(worktree_name_for_path "$cwd" "$wt_root")" || continue
        [[ -n "$wt_name" && -d "$worktrees_dir/$wt_name" ]] || continue

        # Walk up the snapshotted process tree to find the enclosing tmux pane.
        local pane_target="" current="$pid" parent
        for _ in 1 2 3 4 5; do
            parent="${ppid_of[$current]:-}"
            [[ -n "$parent" && "$parent" != "1" && "$parent" != "0" ]] || break
            if [[ -n "${pane_targets[$parent]+x}" ]]; then
                pane_target="${pane_targets[$parent]}"
                break
            fi
            current="$parent"
        done

        local idx=${#session_pids[@]}
        session_pids+=("$pid")
        session_wt_names+=("$wt_name")
        session_pane_targets+=("$pane_target")
        case "$status" in
            busy)    session_statuses+=("Running") ;;
            *)       session_statuses+=("WaitingOnUser") ;;
        esac
        wt_session_count[$wt_name]=$(( ${wt_session_count[$wt_name]:-0} + 1 ))
        wt_indices[$wt_name]="${wt_indices[$wt_name]:-} $idx"
    done < <(_claude_agents_tsv)

    if [[ ${#session_pids[@]} -eq 0 ]]; then
        echo "No active Claude sessions found in worktrees."
        return 0
    fi

    # Filter to stale worktrees (not viewed within max_days).
    local -a filtered_wt_names=()
    while IFS= read -r wt_name; do
        [[ -n "$wt_name" ]] && filtered_wt_names+=("$wt_name")
    done < <(_claude_stale_worktrees "$cutoff_epoch" "${!wt_session_count[@]}")

    if [[ ${#filtered_wt_names[@]} -eq 0 ]]; then
        echo "No Claude sessions older than ${max_days}d found."
        return 0
    fi

    # Interactive selection (fzf). Multi-select, all pre-selected. Each row is
    # "<display columns><TAB><wt_name>": the display half is sanitized of tabs
    # and newlines so the trailing field is always the name to act on.
    local summary_file="${claude_summary_file:-.fw-summary.md}"
    local picker_lines="" wt_name
    for wt_name in "${filtered_wt_names[@]}"; do
        local wt_path="$worktrees_dir/$wt_name"
        local count_display="" branch="" summary="" age viewed_ts
        [[ "${wt_session_count[$wt_name]}" -gt 1 ]] && count_display=" (${wt_session_count[$wt_name]})"
        viewed_ts=$(last_viewed_ts "$wt_name")
        age=$(format_age "$viewed_ts" "$now_epoch"); [[ -n "$age" ]] || age="never"
        if read_worktree_env "$wt_path" 2>/dev/null; then branch="$WT_BRANCH"; fi
        [[ -f "$wt_path/$summary_file" ]] && summary=$(head -1 "$wt_path/$summary_file" | sed 's/^#* *//')

        # Aggregate status across the worktree's sessions: running if any is.
        local status_display="waiting" idx
        for idx in ${wt_indices[$wt_name]:-}; do
            [[ "${session_statuses[$idx]}" == "Running" ]] && { status_display="running"; break; }
        done

        # Strip embedded tabs/newlines from free-form fields so they can't
        # forge column boundaries in the tab-delimited row.
        local name_disp="${wt_name}${count_display}"
        branch="${branch//[$'\t\n']/ }"
        summary="${summary//[$'\t\n']/ }"
        picker_lines+="$(printf '%-30s  %-6s  %-8s  %-30s  %s' \
            "${name_disp:0:30}" "$age" "$status_display" "${branch:0:30}" "${summary:0:50}")"$'\t'"${wt_name}"$'\n'
    done

    # This picker calls fzf directly (not via _fzf_pick_line) because it needs
    # the raw multi-select output. Its binds are fzf-internal ACTIONS only
    # (toggle-all/select-all) — no shell command runs, so it is immune to the
    # login-shell bind trap that _fzf_pick_line guards against (see lib/fzf.sh).
    # If a shell `--bind` (transform/reload/execute/preview) is ever added here,
    # route through _fzf_pick_line (or pin SHELL) or it will break under fish.
    local selected
    selected=$(printf '%s' "$picker_lines" | fzf --ansi --reverse --multi \
        --header="$(printf '%-30s  %-6s  %-8s  %-30s  %s' WORKTREE AGE STATUS BRANCH SUMMARY)" \
        --bind 'ctrl-a:toggle-all' --bind 'start:select-all') || return 0

    local -a selected_wt_names=()
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        # The name is the second (last) tab-delimited field by construction.
        wt_name=$(printf '%s' "$line" | awk -F'\t' '{print $2}')
        # Ignore a selection that doesn't map to a known worktree (guards the
        # assoc-array derefs below under set -u).
        [[ -n "$wt_name" && -n "${wt_session_count[$wt_name]:-}" ]] &&
            selected_wt_names+=("$wt_name")
    done <<<"$selected"
    [[ ${#selected_wt_names[@]} -gt 0 ]] || return 0

    # Summarize first: paste the prompt into each worktree's Claude pane and
    # wait for the summary file to be (re)written.
    local summarize_prompt
    summarize_prompt='Write a '"$summary_file"' at the worktree root summarizing what this worktree was about. Use the format: # one-line summary, ## Status (Done / In progress / Blocked / Abandoned), ## What was done, ## What'"'"'s left, ## Context. Keep it under 200 words. Do not ask me any questions, just write it.'

    declare -A pre_mtime=() summarize_sent=()
    echo "Sending summarization prompt to ${#selected_wt_names[@]} worktree(s)..."
    for wt_name in "${selected_wt_names[@]}"; do
        local wt_path="$worktrees_dir/$wt_name"
        pre_mtime[$wt_name]=$(_mtime_or_0 "$wt_path/$summary_file")
        local idx pane sent=false
        for idx in ${wt_indices[$wt_name]:-}; do
            pane="${session_pane_targets[$idx]}"
            [[ -n "$pane" ]] || continue
            tmux set-buffer -b fw-summarize "$summarize_prompt"
            tmux paste-buffer -b fw-summarize -t "$pane"
            tmux send-keys -t "$pane" Enter
            summarize_sent[$wt_name]="$pane"
            sent=true
            echo "  -> $wt_name"
            break
        done
        [[ "$sent" == true ]] || echo "  skipping $wt_name: no tmux pane found"
    done

    if [[ ${#summarize_sent[@]} -gt 0 ]]; then
        echo "Waiting for summaries (timeout 120s)..."
        local timeout=120 start_time
        start_time=$(date +%s)
        declare -A summary_done=()
        while true; do
            local elapsed=$(( $(date +%s) - start_time ))
            [[ $elapsed -ge $timeout ]] && { echo "Timeout reached. Proceeding with close."; break; }
            local all_done=true
            for wt_name in "${!summarize_sent[@]}"; do
                [[ -n "${summary_done[$wt_name]+x}" ]] && continue
                local wt_path="$worktrees_dir/$wt_name" pre="${pre_mtime[$wt_name]}"
                if [[ -f "$wt_path/$summary_file" ]]; then
                    local cur_mtime
                    cur_mtime=$(_mtime_or_0 "$wt_path/$summary_file")
                    # pre==0 means the summary didn't exist before, so any file
                    # now is freshly written; otherwise require a newer mtime.
                    if [[ "$pre" == "0" || "$cur_mtime" -gt "$pre" ]]; then
                        summary_done[$wt_name]=1
                        echo "  done $wt_name"
                        continue
                    fi
                fi
                all_done=false
            done
            [[ "$all_done" == true ]] && break
            sleep 3
        done

        # Name the worktrees whose summary never landed, so a timeout isn't
        # silent about what will be closed unsummarized.
        for wt_name in "${!summarize_sent[@]}"; do
            [[ -n "${summary_done[$wt_name]+x}" ]] ||
                echo "  timed out $wt_name (closing unsummarized)"
        done
    fi

    # Close: send /exit to each session's pane.
    echo "Closing session(s)..."
    for wt_name in "${selected_wt_names[@]}"; do
        local idx pane pid
        for idx in ${wt_indices[$wt_name]:-}; do
            pane="${session_pane_targets[$idx]}"
            pid="${session_pids[$idx]}"
            if [[ -n "$pane" ]]; then
                tmux send-keys -t "$pane" "/exit" Enter
                echo "  -> $wt_name (pid $pid, pane $pane)"
            else
                echo "  skipping $wt_name (pid $pid): no tmux pane"
            fi
        done
    done
    echo "Done. Resume any session with claude -r"
}

cmd_sessions() {
    local subcmd="${1:-}"
    shift 2>/dev/null || true
    case "$subcmd" in
        close-old) cmd_sessions_close_old "$@" ;;
        *)
            [[ -n "$subcmd" ]] && echo "Error: unknown sessions subcommand '$subcmd'" >&2
            echo "Usage: fw sessions <close-old>"
            echo
            echo "  close-old [--days N]  Close stale Claude sessions (default: 7 days)"
            return 1
            ;;
    esac
}
