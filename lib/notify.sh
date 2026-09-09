# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# Notifications and their log. `notify_log` is the single announce-and-record
# helper: it appends a TSV line to the per-project notification log and, on
# macOS, voices the message (`say`) and posts a desktop notification
# (`osascript`). Both are invoked by bare name and guarded by `command -v`, so
# off macOS the call degrades to just the log line (the settled cross-platform
# decision from the remaining-work plan). `fw notify` is the user-facing entry;
# `fw checks-wait` announces through the same helper.

# _notify_log_file — the append-only notification log, beside the worktrees
# (where the tool keeps everything else it remembers). Missing until the first
# notification is logged.
_notify_log_file() {
    echo "$worktrees_dir/.fw_notify_log"
}

# notify_log <category> <message> [branch] — record and announce. Branch
# defaults to the current git branch. Arguments must not contain tabs (they
# would corrupt the TSV log). Announcing is best-effort and never fails the
# caller.
notify_log() {
    local category="$1" message="$2" branch="${3:-}"

    if [[ "$message" == *$'\t'* || "$category" == *$'\t'* ]]; then
        echo "Error: notify arguments must not contain tabs" >&2
        return 1
    fi

    [[ -n "$branch" ]] || branch="$(current_branch_or_unknown)"

    local log ts
    log="$(_notify_log_file)"
    mkdir -p "$(dirname "$log")"
    # Epoch seconds, like every other fw log — cmd_logs consumes the integer
    # directly (no per-line ISO re-parsing).
    ts="$(date +%s)"
    printf '%s\t%s\t%s\t%s\n' "$ts" "$category" "$branch" "$message" >>"$log"

    # macOS-only alert + voice, by bare name so tests shim them; skipped
    # entirely when the tools are absent (i.e. off macOS).
    if command -v osascript >/dev/null 2>&1; then
        # Pass message/title as argv data so quotes/`&` in the text can never be
        # compiled as AppleScript (checks-wait feeds attacker-influenced CI
        # check names through here).
        osascript \
            -e 'on run argv' \
            -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
            -e 'end run' \
            "$message" "fw: $category" >/dev/null 2>&1 || true
    fi
    if command -v say >/dev/null 2>&1; then
        # Fire-and-forget: a blocking `say` stalls checks-wait several seconds
        # per announcement. Detach from stdin/stdout so no caller waits on it.
        say "$message" </dev/null >/dev/null 2>&1 &
    fi
    return 0
}

# cmd_notify <category> <message> — validate the category against
# notify_categories, then announce.
cmd_notify() {
    local category="${1:-}"
    local -a cats=("${notify_categories[@]}")

    if [[ -z "$category" || $# -lt 2 ]]; then
        echo "Usage: fw notify <category> <message>" >&2
        echo "Categories: ${cats[*]}" >&2
        return 1
    fi
    # Everything after the category is the message, joined on spaces — so
    # `fw notify ci build failed` records "build failed", not just "build".
    shift
    local message="$*"

    local c valid=false
    for c in "${cats[@]}"; do
        [[ "$c" == "$category" ]] && { valid=true; break; }
    done
    if [[ "$valid" != true ]]; then
        echo "Error: unknown category '$category'" >&2
        echo "Valid categories: ${cats[*]}" >&2
        return 1
    fi

    notify_log "$category" "$message"
}

# cmd_logs [category] [--all] — show the notification log, most recent first.
# Default window: the last 16h, capped at 20 rows; --all shows everything.
cmd_logs() {
    local filter_cat="" show_all=false arg
    for arg in "$@"; do
        case "$arg" in
            --all) show_all=true ;;
            *) filter_cat="$arg" ;;
        esac
    done

    local log
    log="$(_notify_log_file)"
    if [[ ! -f "$log" ]]; then
        echo "No log entries yet."
        return 0
    fi

    local now_epoch cutoff_epoch count=0
    now_epoch="$(date +%s)"
    cutoff_epoch=$(( now_epoch - 16 * 3600 ))

    local ts category branch message
    while IFS=$'\t' read -r ts category branch message; do
        [[ -n "$ts" ]] || continue
        if [[ -n "$filter_cat" && "$category" != "$filter_cat" ]]; then
            continue
        fi

        # The log stores epoch seconds directly.
        local epoch="$ts"

        if [[ "$show_all" != true ]]; then
            [[ "$epoch" -lt "$cutoff_epoch" ]] && break
            (( count++ )) || true
            [[ $count -gt 20 ]] && break
        fi

        local age
        age="$(format_age "$epoch" "$now_epoch")"
        printf '%-5s %-9s %-40s %s\n' "${age:--}" "$category" "$branch" "$message"
    done < <(tail -r "$log" 2>/dev/null || tac "$log")
}
