# shellcheck disable=SC2154  # config globals ($ticket_url, $ticket_pattern) and
# STACK_BACKEND are assigned by load_config / resolve_stack_backend before
# cmd_copy runs (via _require_project in the dispatcher).
#
# fw copy — copy a resolved fact about the current worktree to the clipboard.
# Ported from the useful, non-Felt-specific subset of legacy felt-worktree's
# cmd_copy_menu. Each item is a small `_copy_val_<token>` resolver that echoes
# the value on stdout or fails with a clean stderr error, so the fzf picker
# (no argument) and the direct token form (`fw copy branch`) share one code
# path and every item is testable without fzf. An optional second argument is a
# worktree name / branch target, threaded into the same resolvers `fw ticket`
# uses.

# _copy_to_clipboard <value> — write value to the system clipboard via the first
# backend found on PATH: pbcopy (macOS), wl-copy (Wayland), xclip, xsel. The
# value is piped with printf (no trailing newline), matching legacy `echo -n`.
# When no backend exists, print the value to stdout with a note and return
# non-zero, so `fw copy` degrades to a usable value rather than a silent no-op.
_copy_to_clipboard() {
    local value="$1"
    if command -v pbcopy >/dev/null 2>&1; then
        printf '%s' "$value" | pbcopy
    elif command -v wl-copy >/dev/null 2>&1; then
        printf '%s' "$value" | wl-copy
    elif command -v xclip >/dev/null 2>&1; then
        printf '%s' "$value" | xclip -selection clipboard
    elif command -v xsel >/dev/null 2>&1; then
        printf '%s' "$value" | xsel --clipboard --input
    else
        echo "No clipboard tool found (pbcopy/wl-copy/xclip/xsel). Value:" >&2
        printf '%s\n' "$value"
        return 1
    fi
    return 0
}

# _copy_val_branch [target] — the branch name of the resolved worktree.
_copy_val_branch() {
    _gh_resolve_target "${1:-}" || return 1
    printf '%s' "$GH_BRANCH"
}

# _copy_val_path [target] — the absolute path of the resolved worktree. A path
# is meaningful for the golden checkout too, so --allow-main resolves it to
# repo_root instead of erroring when run from (or targeting) main.
_copy_val_path() {
    resolve_worktree --allow-main "${1:-}" || return 1
    printf '%s' "$WT_PATH"
}

# _copy_val_pr_link [target] — the GitHub PR URL for the resolved branch.
_copy_val_pr_link() {
    _gh_resolve_target "${1:-}" || return 1
    local url
    url="$(_gh_pr_json "$GH_BRANCH" url | jq -r '.url')" || return 1
    # A PR with a null/empty url would otherwise copy the literal "null"; guard
    # it the same way cmd_pr_open does.
    if [[ -z "$url" || "$url" == "null" ]]; then
        echo "Error: no PR URL for branch '$GH_BRANCH'" >&2
        return 1
    fi
    printf '%s' "$url"
}

# _copy_val_pr_number [target] — the bare PR number for the resolved branch.
_copy_val_pr_number() {
    _gh_resolve_target "${1:-}" || return 1
    _gh_pr_number "$GH_BRANCH"
}

# _copy_val_ticket_url [target] — $ticket_url with {id} filled from the branch's
# ticket id (branch name first, then the PR body), mirroring cmd_ticket.
_copy_val_ticket_url() {
    if [[ -z "${ticket_url:-}" ]]; then
        echo "Error: ticket_url is not configured (set it in your project config)" >&2
        return 1
    fi
    _gh_resolve_target "${1:-}" || return 1

    if ! _resolve_ticket_id "$GH_BRANCH"; then
        echo "Error: no ticket found in branch name or PR description" >&2
        return 1
    fi
    printf '%s' "${ticket_url//\{id\}/$TICKET_ID}"
}

# _copy_val_stack_branch [target] — a branch name picked from the current stack
# (mirrors cmd_stack_switch's picker, but copies instead of switching). The
# target argument is ignored: the stack is always read from cwd. Returns 2 when
# the user cancels the sub-picker so cmd_copy can treat it as a quiet no-op.
_copy_val_stack_branch() {
    _stack_require_cwd_in_project || return 1
    _ensure_trunk
    local branches
    branches="$(stack_branches)" || return 1
    if [[ -z "$branches" ]]; then
        echo "No stack (on trunk)" >&2
        return 1
    fi

    # "<mark> <branch>" for display, the bare branch as a hidden field.
    local lines="" b mark bn
    while IFS= read -r b; do
        [[ -n "$b" ]] || continue
        IFS=$'\t' read -r mark bn < <(_stack_decode "$b")
        [[ "$mark" == "*" ]] || mark=" "
        lines+="${mark} ${bn}"$'\t'"${bn}"$'\n'
    done <<<"$branches"

    local selected rc=0
    selected="$(printf '%s' "$lines" | _fzf_pick_line --no-sort --reverse \
        --delimiter=$'\t' --with-nth=1 --header='📋 Copy branch name')" || rc=$?
    case $rc in
        0) ;;
        1) return 2 ;;    # cancelled — quiet no-op for the caller
        *) return 1 ;;    # fzf missing / real error (message already printed)
    esac
    printf '%s' "${selected#*$'\t'}"
}

# _copy_dispatch <token> [target] — run the resolver for a copy item token.
_copy_dispatch() {
    local what="$1" target="${2:-}"
    case "$what" in
        branch)       _copy_val_branch "$target" ;;
        path)         _copy_val_path "$target" ;;
        pr-link)      _copy_val_pr_link "$target" ;;
        pr-number)    _copy_val_pr_number "$target" ;;
        ticket-url)   _copy_val_ticket_url "$target" ;;
        stack-branch) _copy_val_stack_branch "$target" ;;
        *)
            echo "Error: unknown copy item '$what'" >&2
            echo "Valid items: branch path pr-link pr-number ticket-url stack-branch" >&2
            return 1
            ;;
    esac
}

# _copy_menu_entries — the available items as `<label>\t<token>` lines. Items
# that are cheap to rule out are hidden (matching the fw menu convention): the
# ticket item only when ticket_url is configured, the stack item only when a
# real stack backend is active. The PR items always show and error at resolve
# time when no PR exists (can't be pre-checked without a network call).
_copy_menu_entries() {
    printf '%s\t%s\n' "Branch"        "branch"
    printf '%s\t%s\n' "Worktree path" "path"
    printf '%s\t%s\n' "PR link"       "pr-link"
    printf '%s\t%s\n' "PR number"     "pr-number"
    [[ -n "${ticket_url:-}" ]] && printf '%s\t%s\n' "Ticket URL" "ticket-url"
    [[ "${STACK_BACKEND:-none}" != none ]] &&
        printf '%s\t%s\n' "Branch (stack picker)" "stack-branch"
    return 0
}

# cmd_copy [item] [name|branch] — resolve a value and put it on the clipboard.
# With no item, open an fzf picker of the available items first.
cmd_copy() {
    local what="${1:-}" target="${2:-}"

    if [[ -z "$what" ]]; then
        local entries selected rc=0
        entries="$(_copy_menu_entries)"
        selected="$(printf '%s\n' "$entries" | _fzf_pick_line --reverse \
            --delimiter=$'\t' --with-nth=1 --header='📋 Copy to clipboard')" || rc=$?
        case $rc in
            0) ;;
            1) return 0 ;;    # cancelled — quiet no-op
            *) return 1 ;;    # fzf missing / real error (message already printed)
        esac
        what="${selected#*$'\t'}"
    fi

    local value rc=0
    value="$(_copy_dispatch "$what" "$target")" || rc=$?
    case $rc in
        0) ;;
        2) return 0 ;;        # sub-picker cancelled — quiet no-op
        *) return "$rc" ;;    # resolver already printed the error
    esac
    [[ -n "$value" ]] || return 1

    _copy_to_clipboard "$value" || return 1
    echo "✓ Copied: $value"
}
