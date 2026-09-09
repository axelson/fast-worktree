# shellcheck disable=SC2154  # config globals ($project, $menu_order) and the
# optional menu_extra_entries hook are provided by load_config / project config.
#
# fw menu — an fzf quick-actions menu. Entries are tab-separated lines:
#   <label>\t<command>[\t<wait>]
# core built-ins, then the project's menu_extra_entries() provider, deduped by
# label (a provider entry overrides the core entry with the same label —
# last-wins), then reordered by the menu_order config. The chosen entry
# dispatches back into fw, so a menu entry is just a saved subcommand (including
# custom, per-project subcommands).
#
# Provider contract (menu_extra_entries): print `label<TAB>command` lines. The
# command is parsed with the same shell quoting rules as a config file (it comes
# from sourced, already-trusted config), so `archive --reason "on hold"` keeps
# its quoted argument intact. An optional third tab field of `wait` marks an
# entry whose command writes to the terminal, so the popup pauses for a keypress
# before closing (the menu is bound to `tmux display-popup -E`).

# _menu_core_entries — the built-in actions, in default order. Output-producing
# entries (PR info, CI checks, diff --stat) carry the `wait` marker so their
# output stays readable in the popup.
_menu_core_entries() {
    printf '%s\t%s\n'     "Open PR on GitHub"          "pr open"
    printf '%s\t%s\t%s\n' "PR info"                    "pr info"        "wait"
    printf '%s\t%s\t%s\n' "CI checks"                  "checks"         "wait"
    printf '%s\t%s\n'     "CI checks (open failures)"  "checks --open"
    # Ticket entry only when the project configures a ticket URL (lib/ticket.sh).
    [[ -n "${ticket_url:-}" ]] && printf '%s\t%s\n' "Open ticket" "ticket"
    # Local-server entry only when a web port is configured — the common
    # requirement of both `fw open` modes (lib/caddy.sh), so the entry never
    # appears where it would only error. Browser-opening, so no `wait` marker.
    [[ -n "${web_port_var:-}" ]] && printf '%s\t%s\n' "Open local server" "open"
    printf '%s\t%s\t%s\n' "diff --stat"                "changes --stat" "wait"
    printf '%s\t%s\n'     "Switch worktree"            "switch"
    printf '%s\t%s\n'     "Switch project"             "sp"
    # Interactive picker of its own; the `wait` marker keeps the "✓ Copied"
    # confirmation on screen in the display-popup -E popup (legacy `sleep 2`).
    printf '%s\t%s\t%s\n' "📋 Copy…"                   "copy"           "wait"
}

# _menu_dedupe_labels <entries> — collapse duplicate labels, last content wins
# (so a provider entry overrides the core entry with the same label) while the
# label keeps its first position, giving a stable menu.
_menu_dedupe_labels() {
    local entries="$1" line lbl
    local -A idx=()
    local -a lines=()
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        lbl="${line%%$'\t'*}"
        if [[ -n "${idx[$lbl]:-}" ]]; then
            lines[${idx[$lbl]}]="$line"
        else
            idx[$lbl]=${#lines[@]}
            lines+=("$line")
        fi
    done <<<"$entries"
    local l
    for l in "${lines[@]}"; do printf '%s\n' "$l"; done
}

# _menu_all_entries — core + provider entries, deduped by label, reordered per
# menu_order.
_menu_all_entries() {
    local all
    all="$(_menu_core_entries)"
    if declare -F menu_extra_entries >/dev/null 2>&1; then
        local extra
        extra="$(menu_extra_entries)" || extra=""
        [[ -n "$extra" ]] && all+=$'\n'"$extra"
    fi
    all="$(_menu_dedupe_labels "$all")"

    if [[ ${#menu_order[@]} -gt 0 ]]; then
        _menu_apply_order "$all"
    else
        printf '%s\n' "$all"
    fi
}

# _menu_apply_order <entries> — labels named in menu_order sort first, in that
# order and each emitted once; every other entry follows in its original order.
# An ordered label that names no entry (or is repeated in menu_order) is simply
# skipped.
_menu_apply_order() {
    local entries="$1" label line lbl
    local -A in_order=() emitted=()
    for label in "${menu_order[@]}"; do in_order[$label]=1; done
    for label in "${menu_order[@]}"; do
        [[ -n "${emitted[$label]:-}" ]] && continue
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            if [[ "${line%%$'\t'*}" == "$label" ]]; then
                printf '%s\n' "$line"
                emitted[$label]=1
                break
            fi
        done <<<"$entries"
    done
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        lbl="${line%%$'\t'*}"
        [[ -n "${in_order[$lbl]:-}" ]] && continue
        printf '%s\n' "$line"
    done <<<"$entries"
    return 0
}

cmd_menu() {
    local entries
    entries="$(_menu_all_entries)"

    local selected rc=0
    selected="$(printf '%s\n' "$entries" |
        _fzf_pick_line --reverse --delimiter=$'\t' --with-nth=1 --header='Quick actions')" || rc=$?
    case $rc in
        0) ;;              # selection in $selected
        1) return 0 ;;     # cancelled / nothing selected — quiet no-op
        *) return 1 ;;     # fzf missing or real error (message already printed)
    esac

    local label command wait_flag
    IFS=$'\t' read -r label command wait_flag <<<"$selected"
    [[ -n "$command" ]] || return 0

    # Parse the saved command with shell quoting (config is trusted shell), so a
    # quoted spaced argument like `archive --reason "on hold"` survives.
    local -a parts=()
    eval "parts=($command)" 2>/dev/null || {
        echo "Error: could not parse menu command: $command" >&2
        return 1
    }
    [[ ${#parts[@]} -gt 0 ]] || return 0

    # Dispatch back into fw. -p pins the project (menu ran in a known project)
    # so a cwd change can't reresolve it. Capture the status so a failure
    # doesn't abort us under set -e before we can surface it.
    rc=0
    "$SCRIPT_DIR/fast-worktree" -p "$project" "${parts[@]}" || rc=$?

    # For an output-producing entry, pause so the popup (display-popup -E, which
    # closes on command exit) stays readable. A failing non-wait entry gets the
    # same treatment (legacy menu_run parity): announce the failure — its own
    # error already printed above the popup would otherwise flash and vanish —
    # then pause. The keypress pause is skipped when stdout isn't a tty so tests
    # and scripts never hang.
    if [[ "$wait_flag" == wait && -t 1 ]]; then
        printf '\nPress any key to continue... '
        read -rsn1 || true
        echo
    elif [[ $rc -ne 0 ]]; then
        echo "Command failed (exit $rc)" >&2
        if [[ -t 1 ]]; then
            printf 'Press any key to close... '
            read -rsn1 || true
            echo
        fi
    fi
    return "$rc"
}
