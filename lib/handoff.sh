# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# Handoff docs: save a Markdown brief now, resume the work later (in a fresh
# worktree / Claude session). Docs live in $handoff_dir (default
# <worktrees_dir>/handoffs); a 5-column TSV log beside the worktrees tracks
# each one's slug, title, status (pending|done), and source branch. This log is
# deliberately NOT folded into the shared recency/project append-log helper:
# those are 2-column "<ts>\t<name>" logs, whereas a handoff row carries a
# mutable status and title, so it is its own shape (see the remaining-work
# plan's consolidation note).

_handoff_dir() {
    echo "${handoff_dir:-$worktrees_dir/handoffs}"
}

_handoff_log() {
    echo "$worktrees_dir/.fw_handoff_log"
}

# _handoff_slug_from_file <file> — basename without .md, minus a handoff- prefix.
_handoff_slug_from_file() {
    local slug
    slug="$(basename "$1" .md)"
    echo "${slug#handoff-}"
}

# _handoff_title_from_file <file> — text after the first "<heading>: " in the
# doc's first heading (handoff docs are written as "# Handoff: <title>"),
# falling back to "(no title)".
_handoff_title_from_file() {
    local first_heading
    first_heading="$(grep -m1 '^#' "$1" 2>/dev/null || true)"
    first_heading="${first_heading#*: }"
    first_heading="${first_heading## }"
    [[ -n "$first_heading" ]] && echo "$first_heading" || echo "(no title)"
}

# _handoff_valid_slug <slug> — a slug usable as a filename and a pickable log
# field. Rejects whitespace/tabs (which would break the picker's field
# recovery), path separators and "."/".." (filename safety), and a leading dash
# (arg parsing). Deliberately permits other punctuation (brackets, dots): the
# log-rewrite compares the field exactly, so metacharacters are safe there.
_handoff_valid_slug() {
    local s="$1"
    [[ -n "$s" ]] || return 1
    [[ "$s" != *[[:space:]]* ]] || return 1
    [[ "$s" != */* ]] || return 1
    [[ "$s" != -* ]] || return 1
    [[ "$s" != "." && "$s" != ".." ]] || return 1
    return 0
}

# _handoff_pick [status] — fzf over the log (optionally filtered to a status),
# echoing the chosen slug. Return contract mirrors _fzf_pick_line so callers can
# tell cancel from failure: 0 a slug on stdout; 1 cancelled/nothing selected
# (the caller's quiet no-op); 2 nothing to pick or fzf missing (message already
# on stderr); 3 fzf failed for real.
_handoff_pick() {
    local filter_status="${1:-}" log
    log="$(_handoff_log)"
    if [[ ! -f "$log" ]]; then
        echo "No handoffs saved yet." >&2
        return 2
    fi

    local entries="" now_epoch _ts _slug _title _status _source
    now_epoch="$(date +%s)"
    while IFS=$'\t' read -r _ts _slug _title _status _source; do
        [[ -n "$_ts" ]] || continue
        [[ -z "$filter_status" || "$_status" == "$filter_status" ]] || continue
        local age
        age="$(format_age "$_ts" "$now_epoch")"
        # Carry the exact slug as a hidden trailing tab field so recovery never
        # depends on parsing the (space-padded) display columns.
        local disp_title="${_title//[$'\t\n']/ }"
        entries+="$(printf '%-30s %-8s %-8s %s' "$_slug" "${age:--}" "$_status" "$disp_title")"$'\t'"$_slug"$'\n'
    done <"$log"

    if [[ -z "$entries" ]]; then
        echo "No matching handoffs." >&2
        return 2
    fi

    local header selected rc=0
    header="$(printf '%-30s %-8s %-8s %s' 'SLUG' 'AGE' 'STATUS' 'TITLE')"
    selected="$(printf '%s' "$entries" \
        | _fzf_pick_line --header="$header" --no-sort --tac \
            --delimiter=$'\t' --with-nth=1)" || rc=$?
    [[ $rc -eq 0 ]] || return "$rc"
    printf '%s\n' "${selected#*$'\t'}"
}

# _handoff_update_status <slug> <new-status> — rewrite the log with slug's
# status changed.
_handoff_update_status() {
    local target_slug="$1" new_status="$2" log tmp
    log="$(_handoff_log)"
    tmp="$(mktemp "${log}.XXXXXX")"
    local _ts _slug _title _status _source
    while IFS=$'\t' read -r _ts _slug _title _status _source; do
        if [[ "$_slug" == "$target_slug" ]]; then
            printf '%s\t%s\t%s\t%s\t%s\n' "$_ts" "$_slug" "$_title" "$new_status" "$_source"
        else
            printf '%s\t%s\t%s\t%s\t%s\n' "$_ts" "$_slug" "$_title" "$_status" "$_source"
        fi
    done <"$log" >"$tmp"
    mv "$tmp" "$log"
}

cmd_handoff_save() {
    local file="" slug=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                [[ $# -ge 2 ]] || { echo "Error: --name requires a value" >&2; return 1; }
                slug="$2"; shift 2 ;;
            --name=*) slug="${1#--name=}"; shift ;;
            -*) echo "Error: unknown flag '$1'" >&2; return 1 ;;
            *) file="$1"; shift ;;
        esac
    done

    if [[ -z "$file" ]]; then
        echo "Usage: fw handoff save <file> [--name SLUG]" >&2
        return 1
    fi
    if [[ ! -f "$file" ]]; then
        echo "Error: file not found: $file" >&2
        return 1
    fi

    [[ -n "$slug" ]] || slug="$(_handoff_slug_from_file "$file")"
    # Lowercase the slug (both the filename-derived and --name paths) so
    # `fw handoff resume`'s suggested `fw create <slug>` is always a valid
    # worktree name — create rejects uppercase. Mirrors cmd_init lowercasing
    # project names rather than erroring on them.
    slug="${slug,,}"
    if ! _handoff_valid_slug "$slug"; then
        echo "Error: invalid handoff slug '$slug'" >&2
        echo "Slugs may not contain whitespace or '/', or start with '-'." >&2
        return 1
    fi
    local title
    title="$(_handoff_title_from_file "$file")"

    local dir log dest
    dir="$(_handoff_dir)"
    log="$(_handoff_log)"
    mkdir -p "$dir"
    dest="$dir/$slug.md"

    if [[ -f "$dest" ]]; then
        echo "Handoff '$slug' already exists — overwriting."
        # Drop the stale log entry so a fresh one replaces it. Match field 2
        # exactly (an awk string compare, not a regex) so a slug with regex
        # metacharacters can neither over-delete nor blank the whole log.
        if [[ -f "$log" ]]; then
            local tmp
            tmp="$(mktemp "${log}.XXXXXX")"
            if awk -F'\t' -v s="$slug" '$2 != s' "$log" >"$tmp"; then
                mv "$tmp" "$log"
            else
                rm -f "$tmp"
            fi
        fi
    fi

    cp "$file" "$dest"

    local now source
    now="$(date +%s)"
    source="$(current_branch_or_unknown)"
    mkdir -p "$(dirname "$log")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$slug" "$title" "pending" "$source" >>"$log"

    echo "Saved handoff '$slug' -> $dest"
}

cmd_handoff_list() {
    local grep_text="" show_all=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) show_all=true; shift ;;
            --grep)
                [[ $# -ge 2 ]] || { echo "Error: --grep requires a value" >&2; return 1; }
                grep_text="$2"; shift 2 ;;
            --grep=*) grep_text="${1#--grep=}"; shift ;;
            *) shift ;;
        esac
    done

    local log
    log="$(_handoff_log)"
    if [[ ! -f "$log" ]]; then
        echo "No handoffs saved yet. Save one with: fw handoff save <file>"
        return 0
    fi

    local now_epoch cutoff_epoch=0
    now_epoch="$(date +%s)"
    [[ "$show_all" == true ]] || cutoff_epoch=$(( now_epoch - 7 * 86400 ))

    if [[ "$show_all" == true ]]; then
        echo "Handoffs"
    else
        echo "Handoffs (last 7 days; --all for full history)"
    fi
    echo

    local max_slug=30
    printf '%-*s %-8s %-8s %-40s %s\n' "$max_slug" "SLUG" "AGE" "STATUS" "SOURCE" "TITLE"
    printf '%-*s %-8s %-8s %-40s %s\n' "$max_slug" "----" "---" "------" "------" "-----"

    local count=0 ts slug title status source
    while IFS=$'\t' read -r ts slug title status source; do
        [[ -n "$ts" ]] || continue
        if [[ "$ts" -lt "$cutoff_epoch" ]] 2>/dev/null; then
            continue
        fi
        if [[ -n "$grep_text" ]]; then
            if [[ "$slug" != *"$grep_text"* && "$title" != *"$grep_text"* && "$source" != *"$grep_text"* ]]; then
                continue
            fi
        fi

        local display_slug="$slug"
        if [[ ${#display_slug} -gt $max_slug ]]; then
            display_slug="${display_slug:0:$((max_slug - 1))}…"
        fi
        local age=""
        if [[ -n "$ts" && "$ts" -gt 0 ]] 2>/dev/null; then
            age="$(format_age "$ts" "$now_epoch")"
        fi
        local display_source="${source:-}"
        if [[ ${#display_source} -gt 40 ]]; then
            display_source="${display_source:0:39}…"
        fi

        printf '%-*s %-8s %-8s %-40s %s\n' "$max_slug" "$display_slug" "${age:--}" "$status" "$display_source" "$title"
        (( count++ )) || true
    done <"$log"

    echo
    echo "$count handoff(s). Show one with: fw handoff show <slug>"
}

cmd_handoff_show() {
    local slug="${1:-}"
    if [[ -z "$slug" ]]; then
        local rc=0
        slug="$(_handoff_pick)" || rc=$?
        case $rc in
            0) ;;
            1) return 0 ;;     # cancelled — quiet no-op
            *) return 1 ;;     # nothing to pick / fzf missing / error (printed)
        esac
    fi

    local file
    file="$(_handoff_dir)/$slug.md"
    if [[ ! -f "$file" ]]; then
        echo "Error: No handoff found with slug '$slug'" >&2
        echo "List handoffs with: fw handoffs" >&2
        return 1
    fi
    cat "$file"
}

cmd_handoff_done() {
    local slug="${1:-}"
    if [[ -z "$slug" ]]; then
        local rc=0
        slug="$(_handoff_pick pending)" || rc=$?
        case $rc in
            0) ;;
            1) return 0 ;;     # cancelled — quiet no-op
            *) return 1 ;;     # nothing to pick / fzf missing / error (printed)
        esac
    fi

    local log
    log="$(_handoff_log)"
    if ! grep -q $'\t'"$slug"$'\t' "$log" 2>/dev/null; then
        echo "Error: No handoff found with slug '$slug'" >&2
        return 1
    fi
    _handoff_update_status "$slug" "done"
    echo "Marked handoff '$slug' as done."
}

cmd_handoff_resume() {
    local slug="${1:-}" log
    log="$(_handoff_log)"

    if [[ "$slug" == "last" ]]; then
        slug="$(awk -F'\t' '$4 == "pending" { s = $2 } END { print s }' "$log" 2>/dev/null)"
        if [[ -z "$slug" ]]; then
            echo "Error: No pending handoffs found." >&2
            return 1
        fi
    elif [[ -z "$slug" ]]; then
        local rc=0
        slug="$(_handoff_pick pending)" || rc=$?
        case $rc in
            0) ;;
            1) return 0 ;;     # cancelled — quiet no-op
            *) return 1 ;;     # nothing to pick / fzf missing / error (printed)
        esac
    fi

    local file
    file="$(_handoff_dir)/$slug.md"
    if [[ ! -f "$file" ]]; then
        echo "Error: No handoff found with slug '$slug'" >&2
        return 1
    fi

    # `fw create` takes a NAME and derives the branch itself (via branch_prefix),
    # so suggest the bare slug — a "prefix/slug" argument would be rejected by
    # validate_worktree_name.
    local create_cmd="fw create $slug"
    local claude_cmd="cat \"$file\" | claude"

    echo "Handoff: $slug"
    echo "File: $file"
    echo

    # Copy both resume commands to the clipboard when a clipboard tool is present
    # (macOS pbcopy); a no-op elsewhere. Two separate pbcopy calls so a clipboard
    # manager (Alfred) captures each in its history. create_cmd is copied last,
    # so the live clipboard holds the first command to run and the `| claude`
    # pipe sits behind it in history. The sleep between copies is required:
    # Alfred captures the clipboard by polling on an interval, so without a pause
    # the first value is overwritten before a poll tick sees it and only one
    # entry lands in history.
    if command -v pbcopy >/dev/null 2>&1; then
        printf '%s' "$claude_cmd" | pbcopy
        sleep 0.3
        printf '%s' "$create_cmd" | pbcopy
        echo "Copied to clipboard (2 entries): $create_cmd"
        echo
    fi

    echo "To resume, create a worktree and pipe the handoff to Claude:"
    echo "  $create_cmd"
    echo "  $claude_cmd"
}

cmd_handoff() {
    local subcmd="${1:-}"
    shift 2>/dev/null || true

    case "$subcmd" in
        save)   cmd_handoff_save "$@" ;;
        show)   cmd_handoff_show "${1:-}" ;;
        done)   cmd_handoff_done "${1:-}" ;;
        resume) cmd_handoff_resume "${1:-}" ;;
        *)
            [[ -n "$subcmd" ]] && echo "Error: unknown handoff subcommand '$subcmd'" >&2
            echo "Usage: fw handoff <save|show|done|resume>" >&2
            echo >&2
            echo "  save <file> [--name SLUG]  Save a handoff doc" >&2
            echo "  show [slug]                Display handoff content (fzf picker if no slug)" >&2
            echo "  done [slug]                Mark handoff as completed" >&2
            echo "  resume [slug|last]         Get the handoff path for resuming work" >&2
            return 1
            ;;
    esac
}
