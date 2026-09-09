# shellcheck disable=SC2154  # config globals ($ticket_pattern, $ticket_url) are
# assigned by load_config; the gh/browser helpers (_gh, _gh_resolve_target,
# _open_url, GH_BRANCH) come from lib/gh.sh, sourced before this file.
#
# fw ticket — open the issue-tracker ticket for a worktree's branch.
#
# Generic replacement for the felt-specific `fw linear`: no tracker API is
# involved. The ticket id is extracted from the branch name (or, failing that,
# the PR body) with the configurable `ticket_pattern`, and the URL is the
# `ticket_url` template with `{id}` substituted — so the same command serves
# Linear, Jira, GitHub issues, etc. Menu integration (lib/menu.sh) only surfaces
# the entry when `ticket_url` is set.

# _extract_ticket <text> [pattern] — match <text> against a bash regex (defaults
# to $ticket_pattern) and set TICKET_ID to the ticket id: the capture groups
# joined with "-" and upper-cased, or the whole match when the pattern has no
# groups. Returns 1 (and clears TICKET_ID) when the pattern is empty, invalid,
# or does not match. Pure/stateless besides TICKET_ID, so it is unit-tested
# directly.
_extract_ticket() {
    TICKET_ID=""
    local text="$1"
    local pattern="${2:-${ticket_pattern:-}}"
    [[ -n "$pattern" ]] || return 1

    # An invalid regex makes [[ =~ ]] return 2 and print to stderr; suppress it
    # and treat it as "no match" rather than letting it abort the caller.
    if [[ "$text" =~ $pattern ]] 2>/dev/null; then
        local id=""
        if (( ${#BASH_REMATCH[@]} == 1 )); then
            # No capture groups — use the whole match.
            id="${BASH_REMATCH[0]}"
        else
            local i
            for (( i = 1; i < ${#BASH_REMATCH[@]}; i++ )); do
                [[ -n "${BASH_REMATCH[$i]}" ]] || continue
                [[ -n "$id" ]] && id+="-"
                id+="${BASH_REMATCH[$i]}"
            done
        fi
        [[ -n "$id" ]] || return 1
        TICKET_ID="${id^^}"
        return 0
    fi
    return 1
}

# _resolve_ticket_id <branch> — set TICKET_ID from a branch's ticket id: the
# branch name first, then the PR body. Return non-zero (TICKET_ID cleared) when
# neither yields one. Shared by `fw ticket` and `fw copy ticket-url` so the two
# extraction paths never drift.
_resolve_ticket_id() {
    local branch="$1"
    if _extract_ticket "$branch"; then
        return 0
    fi
    # Fall back to the PR body. The branch pattern is anchored on the "/" that
    # separates a branch's prefix from its id; a PR body carries the bare id, so
    # strip a single leading "/" from the pattern before matching prose.
    local body
    body="$(_gh pr view "$branch" --json body --jq '.body' 2>/dev/null)" || true
    if [[ -n "$body" ]] && _extract_ticket "$body" "${ticket_pattern#/}"; then
        return 0
    fi
    TICKET_ID=""
    return 1
}

# cmd_ticket [name|branch] — resolve the target branch, extract its ticket id
# (branch name first, then the PR body), and open $ticket_url with {id} filled
# in through the browser seam.
cmd_ticket() {
    if [[ -z "${ticket_url:-}" ]]; then
        echo "Error: ticket_url is not configured (set it in your project config to use 'fw ticket')" >&2
        return 1
    fi

    _gh_resolve_target "${1:-}" || return 1

    if ! _resolve_ticket_id "$GH_BRANCH"; then
        echo "Error: no ticket found in branch name or PR description" >&2
        return 1
    fi

    local url="${ticket_url//\{id\}/$TICKET_ID}"
    echo "Opening $TICKET_ID ($url)"
    _open_url "$url"
}
