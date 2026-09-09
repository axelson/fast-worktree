# shellcheck disable=SC2154,SC2034  # config globals ($repo_root,
# $github_username, $default_browser, $ignored_checks, $checks_poll_interval, …)
# are assigned by load_config; GH_NAME/GH_PATH are set by _gh_resolve_target as
# the resolved-target contract for callers (GH_PATH is reserved for future use).
#
# GitHub surface: PRs, checks, CI status, and review comments.
#
# Every gh call goes through _gh, which runs gh from the project's repo so gh
# infers owner/repo from the remote — no repo is hardcoded, and PATH resolution
# keeps the tests/shims/gh seam intact. REST paths use gh's {owner}/{repo}
# templating for the same reason. Output is plain text, matching the rest of
# the tool (no ANSI); the interactive fzf pickers (prs/checks --open) land with
# the interactive batch.

# _gh [args…] — run gh against the project's repo directory so it resolves the
# repository from the remote.
_gh() {
    (cd "$repo_root" && gh "$@")
}

# _open_url <url> — open a URL through the browser seam: the configured
# default_browser command, else the OS `open` (macOS), else `xdg-open` (Linux),
# else just print it.
_open_url() {
    local url="$1"
    if [[ -n "${default_browser:-}" ]]; then
        # default_browser is either an executable command line
        # (e.g. "firefox --new-tab") or a macOS application name for `open -a`
        # (e.g. "Google Chrome"). Word-split it: if the first token resolves to
        # a command, run the whole value as a command; otherwise treat the
        # value as an app name and hand it to `open -a` (macOS). This keeps the
        # command form (Linux browsers are executables) while also honoring the
        # app-name form legacy relied on.
        local -a browser_cmd
        read -ra browser_cmd <<<"$default_browser"
        if command -v "${browser_cmd[0]}" >/dev/null 2>&1; then
            "${browser_cmd[@]}" "$url"
        elif command -v open >/dev/null 2>&1; then
            open -a "$default_browser" "$url"
        else
            echo "Error: default_browser '$default_browser' is not a command" >&2
            return 1
        fi
    elif command -v open >/dev/null 2>&1; then
        open "$url"
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url"
    else
        echo "$url"
    fi
}

# _gh_resolve_target [name|branch] — sets GH_BRANCH (and GH_NAME/GH_PATH when a
# local worktree backs it). Empty arg detects the worktree from cwd; a name or
# a recorded branch resolves to that worktree; anything else is a bare branch.
_gh_resolve_target() {
    local arg="${1:-}"
    GH_NAME="" GH_PATH="" GH_BRANCH=""
    if resolve_worktree "$arg" 2>/dev/null; then
        GH_NAME="$WT_NAME"
        GH_PATH="$WT_PATH"
        if read_worktree_env "$WT_PATH" 2>/dev/null && [[ -n "$WT_BRANCH" ]]; then
            GH_BRANCH="$WT_BRANCH"
        else
            GH_BRANCH="$(git -C "$WT_PATH" branch --show-current 2>/dev/null || true)"
        fi
    elif [[ -n "$arg" ]]; then
        GH_BRANCH="$arg"
    else
        echo "Error: not inside a worktree — pass a name or branch" >&2
        return 1
    fi
    if [[ -z "$GH_BRANCH" ]]; then
        echo "Error: could not determine branch for '${arg}'" >&2
        return 1
    fi
    return 0
}

# _gh_pr_json <branch> <fields> — echo the PR JSON for a branch (the given
# --json fields), or emit one canonical error and fail. The single
# fetch-or-error path shared by pr open / pr info / the number lookup.
_gh_pr_json() {
    local branch="$1" fields="$2" out
    out="$(_gh pr view "$branch" --json "$fields" 2>/dev/null)" || {
        echo "Error: no PR found for branch '$branch'" >&2
        return 1
    }
    if [[ -z "$out" ]]; then
        echo "Error: no PR found for branch '$branch'" >&2
        return 1
    fi
    printf '%s' "$out"
}

# _gh_pr_number <branch> — echo the PR number for a branch, or fail. Captures
# stdout only so success-path stderr chatter never corrupts the number.
_gh_pr_number() {
    _gh_pr_json "$1" number | jq -r '.number'
}

# _pr_status_plain <is_draft> <state> <review_decision> <has_assignees>
_pr_status_plain() {
    local is_draft="$1" pr_state="$2" review_decision="$3" has_assignees="${4:-false}"
    local status
    if [[ "$is_draft" == "true" ]]; then
        status="draft"
    else
        status="$(printf '%s' "$pr_state" | tr '[:upper:]' '[:lower:]')"
    fi
    if [[ "$review_decision" == "APPROVED" ]]; then
        status="$status (approved)"
    elif [[ "$review_decision" == "CHANGES_REQUESTED" ]]; then
        status="$status (changes requested)"
    elif [[ "$status" == "open" && "$has_assignees" == "true" ]]; then
        status="$status (assigned)"
    fi
    printf '%s' "$status"
}

# --- checks helpers ---

# _ignored_checks_json — the ignored_checks config array as a JSON array. The
# --args form is flag-safe and handles an empty array plus names with newlines
# in one jq spawn.
_ignored_checks_json() {
    jq -cn '$ARGS.positional' --args -- ${ignored_checks[@]+"${ignored_checks[@]}"}
}

# filter_checks — stdin: `gh pr checks --json` array; stdout: the same minus
# ignored names, deduplicated to the latest run per check name.
filter_checks() {
    local ignored
    ignored="$(_ignored_checks_json)"
    jq --argjson ignored "$ignored" '
        [.[] | select(.name as $n | $ignored | index($n) | not)]
        | group_by(.name)
        | map(sort_by(.startedAt // "") | last)
    '
}

# _failed_checks <checks-json> — the failed-bucket entries as a JSON array. The
# single source of the `.bucket == "fail"` filter, shared by show_checks,
# cmd_retry, cmd_checks_wait, _ci_status_for, and checks --open.
_failed_checks() {
    printf '%s' "$1" | jq -c '[.[] | select(.bucket == "fail")]'
}

# show_checks <checks-json> — failures with links, then a per-bucket summary.
show_checks() {
    local checks="$1"
    local failed
    failed=$(_failed_checks "$checks" | jq -r '.[] | "  \(.name)\n    \(.link)"')
    if [[ -n "$failed" ]]; then
        echo "Failed:"
        echo "$failed"
        echo
    fi
    echo "$checks" | jq -r '
        [.[] | select(.bucket == "fail" | not)]
        | group_by(.bucket)
        | map(
            "\(.[0].bucket): \(length)" +
            if .[0].bucket == "pending" and length <= 2
            then " (" + (map(.name) | join(", ")) + ")"
            else ""
            end
        )
        | .[]'
}

# _checks_for <pr-number> — fetch and filter a PR's checks. Real gh exits 1
# ("no checks reported on the X branch") for a PR with no checks; under
# set -euo pipefail that would abort every caller, so a checkless PR is
# normalized to an empty array instead. Genuine gh errors are surfaced on
# stderr but still yield [] so the pipeline never dies.
_checks_for() {
    local out rc=0 err
    err="$(mktemp)"
    out="$(_gh pr checks "$1" --json name,bucket,link,startedAt 2>"$err")" || rc=$?
    if [[ $rc -ne 0 ]]; then
        if ! grep -qi "no checks reported" "$err"; then
            cat "$err" >&2
        fi
        rm -f "$err"
        printf '[]'
        return 0
    fi
    rm -f "$err"
    printf '%s' "$out" | filter_checks
}

# _open_url_selection <header> [select_all] — stdin: `label<TAB>url` lines. A
# single entry opens directly (no picker); several go through an fzf
# multi-select and every chosen url is opened. With select_all=true every row
# is preselected (Enter opens them all). Cancel, no selection, or empty input
# is a quiet no-op; returns 1 only when fzf is required but missing or errors.
_open_url_selection() {
    local header="$1" select_all="${2:-false}" entries count
    entries="$(cat)"
    [[ -n "$entries" ]] || return 0
    count="$(printf '%s\n' "$entries" | grep -c .)"
    if [[ "$count" -eq 1 ]]; then
        # The lone "<label>\t<url>" line — take the url field.
        local url="${entries#*$'\t'}"
        [[ -n "$url" ]] && _open_url "$url"
        return 0
    fi
    local -a fzf_args=(--multi --delimiter=$'\t' --with-nth=1 --header="$header")
    [[ "$select_all" == true ]] && fzf_args+=(--bind 'start:select-all')
    local selected rc=0
    selected="$(printf '%s\n' "$entries" | _fzf_pick_line "${fzf_args[@]}")" || rc=$?
    case $rc in
        0) ;;              # selection in $selected
        1) return 0 ;;     # cancelled / nothing selected — quiet no-op
        *) return 1 ;;     # fzf missing or real error (message already printed)
    esac
    local u
    while IFS=$'\t' read -r _ u; do
        [[ -n "$u" ]] && _open_url "$u"
    done <<<"$selected"
    return 0
}

# --- prs ---

cmd_prs() {
    local filter_state="" open_flag=false
    for arg in "$@"; do
        case "$arg" in
            --merged) filter_state="MERGED" ;;
            --closed) filter_state="CLOSED_OR_MERGED" ;;
            --open) open_flag=true ;;
            open) echo "Error: did you mean --open?" >&2; return 1 ;;
            -*) echo "Error: unknown flag '$arg'" >&2; return 1 ;;
            *) echo "Error: unexpected argument '$arg'" >&2; return 1 ;;
        esac
    done

    local nb
    nb="$(worktree_names_branches)" || {
        echo "No worktrees yet — create one with: fw create <name>"
        return 0
    }

    # One network round-trip: every PR, matched to worktree branches locally.
    local pr_list
    pr_list="$(_gh pr list --state all --json headRefName,number,state,isDraft,title,url --limit 200 2>/dev/null)" || pr_list='[]'
    [[ -n "$pr_list" ]] || pr_list='[]'

    # One jq pass indexes every PR by its head branch: branch first (branches
    # can't contain tabs), then the fields with title last (@tsv escapes any
    # embedded tab/newline, and read's last field is greedy, so a tab-bearing
    # title can't shift columns). First occurrence wins, matching the old
    # per-branch `.[0]`.
    local -A pr_by_branch=()
    local b_branch b_rest
    while IFS=$'\t' read -r b_branch b_rest; do
        [[ -n "$b_branch" ]] || continue
        [[ -n "${pr_by_branch[$b_branch]:-}" ]] || pr_by_branch["$b_branch"]="$b_rest"
    done < <(printf '%s' "$pr_list" | jq -r '
        .[] | [ .headRefName, (.number|tostring), .state, (.isDraft|tostring), (.url // ""), .title ] | @tsv')

    printf '%-20s %-32s %-8s %-8s %s\n' "NAME" "BRANCH" "STATUS" "PR" "TITLE"
    local name branch state is_draft num title url status open_entries=""
    while IFS=$'\t' read -r name branch; do
        [[ -n "$branch" ]] || continue

        if [[ -z "${pr_by_branch[$branch]:-}" ]]; then
            # No PR: a placeholder row when unfiltered, else drop the worktree.
            [[ -n "$filter_state" ]] && continue
            printf '%-20s %-32s %-8s %-8s %s\n' "$name" "$branch" "-" "-" "-"
            continue
        fi

        IFS=$'\t' read -r num state is_draft url title <<<"${pr_by_branch[$branch]}"

        if [[ "$filter_state" == "CLOSED_OR_MERGED" ]]; then
            [[ "$state" == "CLOSED" || "$state" == "MERGED" ]] || continue
        elif [[ -n "$filter_state" && "$state" != "$filter_state" ]]; then
            continue
        fi

        status="$(_pr_status_plain "$is_draft" "$state" "")"
        printf '%-20s %-32s %-8s %-8s %s\n' "$name" "$branch" "$status" "#$num" "$title"
        [[ -n "$url" ]] && open_entries+="#${num} ${title}"$'\t'"${url}"$'\n'
    done <<<"$nb"

    if [[ "$open_flag" == true ]]; then
        if [[ -z "$open_entries" ]]; then
            echo "No PRs to open."
            return 0
        fi
        printf '%s' "$open_entries" |
            _open_url_selection 'Tab: toggle, Enter: open in browser' || return 1
    fi
    return 0
}

# --- pr open / info ---

cmd_pr() {
    local subcmd="${1:-open}"
    # Guard the shift: with no args $#=0, and a bare `shift` under set -e would
    # kill fw before dispatch (matching legacy felt-worktree's shift guard).
    shift 2>/dev/null || true
    case "$subcmd" in
        open)   cmd_pr_open "${1:-}" ;;
        info)   cmd_pr_info "${1:-}" ;;
        assign) cmd_pr_assign "$@" ;;
        *)
            # A bare `pr <name|branch>` opens that PR — but only when the arg is
            # actually a worktree or an existing branch. An unknown token (e.g.
            # `pr diff`) is a mistyped subcommand, not a branch target, so name
            # the valid subcommands instead of the misleading "no PR found".
            if resolve_worktree "$subcmd" 2>/dev/null ||
               git -C "$repo_root" rev-parse --verify --quiet "$subcmd" >/dev/null 2>&1; then
                cmd_pr_open "$subcmd"
            else
                echo "Error: unknown pr subcommand '$subcmd' (valid: open, info, assign)" >&2
                return 1
            fi
            ;;
    esac
}

cmd_pr_open() {
    _gh_resolve_target "${1:-}" || return 1
    local url
    url="$(_gh_pr_json "$GH_BRANCH" url | jq -r '.url')" || return 1
    if [[ -z "$url" || "$url" == "null" ]]; then
        echo "Error: no PR URL for branch '$GH_BRANCH'" >&2
        return 1
    fi
    echo "Opening $url"
    _open_url "$url"
}

cmd_pr_info() {
    _gh_resolve_target "${1:-}" || return 1
    local pr_json
    pr_json="$(_gh_pr_json "$GH_BRANCH" \
        number,url,state,isDraft,title,assignees,reviewDecision,baseRefName)" || return 1

    local num url state is_draft assignees review base title
    # One jq pass, title last (see note in cmd_prs); reviewDecision and base
    # can be null, so default them before @tsv. Translate the tab delimiters to
    # a non-whitespace separator so `read` keeps empty fields (an empty assignees
    # field under tab-IFS collapses and shifts every later field left).
    IFS=$'\037' read -r num url state is_draft assignees review base title < <(
        printf '%s' "$pr_json" | jq -r '
            [ (.number|tostring), .url, .state, (.isDraft|tostring),
              (.assignees | map(.login) | join(",")),
              (.reviewDecision // ""), (.baseRefName // ""), .title ] | @tsv' \
            | tr '\t' '\037')

    local has_assignees=false status
    [[ -n "$assignees" ]] && has_assignees=true
    status="$(_pr_status_plain "$is_draft" "$state" "$review" "$has_assignees")"

    _ensure_trunk
    echo "Branch:           $GH_BRANCH"
    [[ "$base" != "$(trunk_branch)" ]] && echo "Merge into:       $base"
    echo "PR:               #$num"
    echo "Title:            $title"
    echo "Status:           $status"
    echo "URL:              $url"
    [[ -n "$assignees" ]] && echo "Assignees:        $assignees"
    return 0
}

# --- pr assign ---

# _pr_assign_login <user_arg> — resolve a GitHub login to assign. The roster is
# the team_members config array (alias:github[:linear]; core reads fields 1-2)
# when non-empty, else the repo's GitHub collaborators. An exact alias/login
# match on the arg wins outright; otherwise an fzf picker (seeded with the arg
# as its query) chooses. Echoes the login on stdout. Returns:
#   0  resolved (login on stdout)
#   1  cancelled — quiet no-op for the caller
#   2  no candidates, or fzf missing/failed (message already printed)
_pr_assign_login() {
    local user_arg="$1"
    local -a lines=()
    if [[ ${#team_members[@]} -gt 0 ]]; then
        # Roster entries: exact match on alias or github login; picker lines are
        # "alias (github)". Field 2 is the login; fall back to the alias when a
        # bare "alias" entry omits it.
        local entry alias gh_login
        for entry in "${team_members[@]}"; do
            alias="${entry%%:*}"
            gh_login="$(printf '%s' "$entry" | cut -d: -f2)"
            [[ -n "$gh_login" ]] || gh_login="$alias"
            # Skip a malformed entry (empty alias and login) so it never becomes
            # a selectable " ()" line or a bogus " ()" assignee.
            [[ -n "$alias" || -n "$gh_login" ]] || continue
            if [[ -n "$user_arg" && ( "$user_arg" == "$alias" || "$user_arg" == "$gh_login" ) ]]; then
                printf '%s' "$gh_login"
                return 0
            fi
            lines+=("$alias ($gh_login)")
        done
    else
        # Fallback: bare collaborator logins from gh (repo inferred by _gh).
        # --paginate so a login past the first 30 collaborators isn't missed;
        # capture the status so an API failure reports distinctly rather than
        # degrading into "no candidates found".
        local collab_out rc=0 err
        err="$(mktemp)"
        collab_out="$(_gh api "repos/{owner}/{repo}/collaborators" --paginate --jq '.[].login' 2>"$err")" || rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "Error: failed to list repository collaborators" >&2
            cat "$err" >&2
            rm -f "$err"
            return 2
        fi
        rm -f "$err"
        local candidate
        while IFS= read -r candidate; do
            [[ -n "$candidate" ]] || continue
            if [[ -n "$user_arg" && "$user_arg" == "$candidate" ]]; then
                printf '%s' "$candidate"
                return 0
            fi
            lines+=("$candidate")
        done <<<"$collab_out"
    fi

    if [[ ${#lines[@]} -eq 0 ]]; then
        echo "Error: no assignee candidates found" >&2
        return 2
    fi

    local -a fzf_args=(--header='Select assignee' --reverse)
    [[ -n "$user_arg" ]] && fzf_args+=(--query "$user_arg")
    local selected rc=0
    selected="$(printf '%s\n' "${lines[@]}" | _fzf_pick_line "${fzf_args[@]}")" || rc=$?
    case $rc in
        0) ;;              # selection in $selected
        1) return 1 ;;     # cancelled — quiet no-op
        *) return 2 ;;     # fzf missing / real error (message already printed)
    esac

    # "alias (login)" -> login; a bare collaborator login stays as-is.
    if [[ "$selected" =~ \(([^\)]+)\)[[:space:]]*$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "$selected"
    fi
    return 0
}

cmd_pr_assign() {
    # First non-flag arg is the user, second the worktree/branch (legacy order).
    local user_arg="" wt_arg=""
    for arg in "$@"; do
        if [[ "$arg" == -* ]]; then
            echo "Error: unknown flag '$arg'" >&2
            return 1
        elif [[ -z "$user_arg" ]]; then
            user_arg="$arg"
        else
            wt_arg="$arg"
        fi
    done

    _gh_resolve_target "$wt_arg" || return 1
    local pr_json num is_draft
    pr_json="$(_gh_pr_json "$GH_BRANCH" number,isDraft)" || return 1
    IFS=$'\t' read -r num is_draft < <(
        printf '%s' "$pr_json" | jq -r '[(.number|tostring), (.isDraft|tostring)] | @tsv')

    # Warn before assigning to a draft PR (legacy y/N confirm).
    if [[ "$is_draft" == "true" ]]; then
        echo "Warning: PR #$num is a draft"
        local confirm=""
        # EOF/closed stdin (scripted or popup-noninteractive use) declines
        # cleanly instead of dying under errexit mid-prompt. The check is
        # case-insensitive so the capital Y the [y/N] prompt invites works.
        read -rp "Assign anyway? [y/N] " confirm || confirm=""
        if [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]]; then
            echo "Cancelled."
            return 0
        fi
    fi

    local login rc=0
    login="$(_pr_assign_login "$user_arg")" || rc=$?
    case $rc in
        0) ;;              # login resolved
        1) return 0 ;;     # cancelled picker — quiet no-op
        *) return 1 ;;     # no candidates / fzf failure
    esac
    [[ -n "$login" ]] || return 0

    echo "Assigning @$login to PR #$num..."
    _gh pr edit "$GH_BRANCH" --add-assignee "$login"
    echo "Assigned @$login to PR #$num"
    return 0
}

# --- checks / retry ---

cmd_checks() {
    local wt_arg="" open_flag=false
    for arg in "$@"; do
        case "$arg" in
            --open) open_flag=true ;;
            open) echo "Error: did you mean --open?" >&2; return 1 ;;
            -*) echo "Error: unknown flag '$arg'" >&2; return 1 ;;
            *) wt_arg="$arg" ;;
        esac
    done
    _gh_resolve_target "$wt_arg" || return 1
    local pr checks
    pr="$(_gh_pr_number "$GH_BRANCH")" || return 1
    checks="$(_checks_for "$pr")"
    if [[ "$(printf '%s' "$checks" | jq 'length')" -eq 0 ]]; then
        echo "No checks reported"
        return 0
    fi
    show_checks "$checks"

    if [[ "$open_flag" == true ]]; then
        # Only failures with a real link are openable; drop null/empty links so
        # a linkless failure never becomes the literal string "null".
        local failed
        failed="$(_failed_checks "$checks" |
            jq -r '.[] | select(.link != null and .link != "") | "\(.name)\t\(.link)"')"
        if [[ -z "$failed" ]]; then
            echo "No failed checks to open."
            return 0
        fi
        # select_all=true preselects every failure (legacy --bind start:select-all)
        # so Enter opens them all when the picker surfaces.
        printf '%s\n' "$failed" |
            _open_url_selection 'Tab: toggle, Enter: open failed check' true || return 1
    fi
    return 0
}

cmd_retry() {
    _gh_resolve_target "${1:-}" || return 1
    local pr checks run_ids
    pr="$(_gh_pr_number "$GH_BRANCH")" || return 1
    checks="$(_checks_for "$pr")"

    run_ids="$(_failed_checks "$checks" | jq -r '.[] | .link' |
        sed -n 's|.*/actions/runs/\([0-9]*\).*|\1|p' | sort -u)"

    if [[ -z "$run_ids" ]]; then
        echo "No failed checks to retry."
        return 0
    fi

    local count
    count="$(echo "$run_ids" | wc -l | tr -d ' ')"
    echo "Retrying failed jobs in $count workflow run(s)..."
    local run_id
    while IFS= read -r run_id; do
        [[ -n "$run_id" ]] || continue
        echo "  Rerunning failed jobs in run $run_id"
        _gh run rerun "$run_id" --failed
    done <<<"$run_ids"
    echo "Done."
    return 0
}

cmd_checks_wait() {
    _gh_resolve_target "${1:-}" || return 1
    local pr label interval start_epoch
    pr="$(_gh_pr_number "$GH_BRANCH")" || return 1
    label="${GH_NAME:-$GH_BRANCH}"
    interval="${checks_poll_interval:-30}"
    start_epoch="$(date +%s)"
    local announced=""

    while true; do
        local checks total pending fails elapsed
        checks="$(_checks_for "$pr")"
        total="$(printf '%s' "$checks" | jq 'length')"
        if [[ "$total" -eq 0 ]]; then
            echo "No checks reported yet"
        else
            show_checks "$checks"
        fi

        # Announce each newly-seen failure once, via the notify layer.
        local fname
        while IFS= read -r fname; do
            [[ -n "$fname" ]] || continue
            if ! printf '%s' "$announced" | grep -qxF "$fname"; then
                announced+="$fname"$'\n'
                notify_log ci "$label: $fname failed" "$GH_BRANCH"
            fi
        done < <(_failed_checks "$checks" | jq -r '.[].name')

        # Elapsed since the command started (deviation from legacy, which used
        # the earliest check startedAt; a monotonic wall-clock is portable and
        # avoids the BSD-only date -jf parse).
        elapsed=$(( $(date +%s) - start_epoch ))
        echo "Elapsed: $((elapsed / 60))m $((elapsed % 60))s"

        pending="$(printf '%s' "$checks" | jq '[.[] | select(.bucket == "pending")] | length')"
        # A checkless PR (total 0) counts as still pending: keep waiting for
        # checks to appear rather than declaring success.
        if [[ "$total" -gt 0 && "$pending" == "0" ]]; then
            fails="$(_failed_checks "$checks" | jq 'length')"
            echo
            if [[ "$fails" == "0" ]]; then
                echo "All checks passed! ($label)"
                notify_log ci "All checks passed: $label" "$GH_BRANCH"
                return 0
            fi
            echo "$fails check(s) failed ($label)"
            notify_log ci "$label: $fails check(s) failed" "$GH_BRANCH"
            return 1
        fi

        echo
        if [[ "$total" -eq 0 ]]; then
            echo "Waiting... (no checks yet)"
        else
            echo "Waiting... ($pending pending)"
        fi
        echo
        sleep "$interval"
    done
}

# --- ci ---

# _ci_status_for <pr-number> — echo "TAG<TAB>STATUS<TAB>DETAILS" where TAG is
# 0/1/2 for failed/in-progress/ok (the sort key) and STATUS/DETAILS are the
# human columns. A checkless PR reports "no checks" rather than a false "ok".
_ci_status_for() {
    local checks total fails pending
    checks="$(_checks_for "$1")"
    total="$(printf '%s' "$checks" | jq 'length')"
    if [[ "$total" -eq 0 ]]; then
        printf '1\tno checks\t'
        return 0
    fi
    fails="$(_failed_checks "$checks" | jq -r '[.[] | .name] | join(", ")')"
    pending="$(printf '%s' "$checks" | jq '[.[] | select(.bucket == "pending")] | length')"
    if [[ -n "$fails" ]]; then
        printf '0\tfailed\t%s' "$fails"
    elif [[ "$pending" -gt 0 ]]; then
        printf '1\tin-progress\t(%s pending)' "$pending"
    else
        printf '2\tok\t'
    fi
}

cmd_ci() {
    local show_all=false target=""
    for arg in "$@"; do
        case "$arg" in
            --all) show_all=true ;;
            -*) echo "Error: unknown flag '$arg'" >&2; return 1 ;;
            *)
                if [[ -n "$target" ]]; then
                    echo "Error: unexpected argument '$arg'" >&2; return 1
                fi
                target="$arg"
                ;;
        esac
    done

    # Show an AUTHOR column whenever the view isn't scoped to one known user:
    # --all drops the author filter, and an empty github_username can't scope.
    local show_author=false
    if [[ "$show_all" == true || -z "$github_username" ]]; then
        show_author=true
    fi

    # Build the (name, branch) worklist: an explicit target, else the
    # worktrees visited in the last 48h (most recent first). --all only widens
    # the author filter below — it does not change the worklist.
    local -a names=() branches=()
    if [[ -n "$target" ]]; then
        _gh_resolve_target "$target" || return 1
        names+=("${GH_NAME:-$(name_from_branch "$GH_BRANCH")}")
        branches+=("$GH_BRANCH")
    else
        local now cutoff name
        now="$(date +%s)"; cutoff=$((now - 48 * 3600))
        while IFS= read -r name; do
            [[ -n "$name" && -d "$worktrees_dir/$name" ]] || continue
            if read_worktree_env "$worktrees_dir/$name" 2>/dev/null && [[ -n "$WT_BRANCH" ]]; then
                names+=("$name"); branches+=("$WT_BRANCH")
            fi
        done < <(recent_names "$cutoff")
    fi

    if [[ ${#names[@]} -eq 0 ]]; then
        echo "No worktrees to report."
        return 0
    fi

    echo "CI Status"
    echo
    if [[ "$show_author" == true ]]; then
        printf '%-8s %-20s %-12s %-12s %s\n' "PR" "NAME" "AUTHOR" "STATUS" "DETAILS"
    else
        printf '%-8s %-20s %-12s %s\n' "PR" "NAME" "STATUS" "DETAILS"
    fi

    local -a lines=()
    local i branch pr_json num state author st tag status details
    for i in "${!names[@]}"; do
        branch="${branches[$i]}"
        pr_json="$(_gh pr view "$branch" --json number,state,author 2>/dev/null)" || {
            # An explicit target with no PR is an error, not an empty success.
            if [[ -n "$target" ]]; then
                echo "Error: no PR found for branch '$branch'" >&2
                return 1
            fi
            continue
        }
        if [[ -z "$pr_json" ]]; then
            if [[ -n "$target" ]]; then
                echo "Error: no PR found for branch '$branch'" >&2
                return 1
            fi
            continue
        fi

        IFS=$'\t' read -r num state author < <(
            printf '%s' "$pr_json" | jq -r '[(.number|tostring), .state, (.author.login // "")] | @tsv')

        # The CI view covers open PRs only (matches legacy's states: OPEN).
        [[ "$state" == "OPEN" ]] || continue

        if [[ "$show_all" != true && -n "$github_username" ]]; then
            [[ "$author" == "$github_username" ]] || continue
        fi

        st="$(_ci_status_for "$num")"
        IFS=$'\t' read -r tag status details <<<"$st"
        if [[ "$show_author" == true ]]; then
            lines+=("$(printf '%s\t#%-7s %-20s %-12s %-12s %s' "$tag" "$num" "${names[$i]}" "$author" "$status" "$details")")
        else
            lines+=("$(printf '%s\t#%-7s %-20s %-12s %s' "$tag" "$num" "${names[$i]}" "$status" "$details")")
        fi
    done

    # Sort by status tag (failed, in-progress, ok), stable, then drop the key.
    local line
    for line in "${lines[@]+"${lines[@]}"}"; do printf '%s\n' "$line"; done |
        sort -t$'\t' -k1,1 -s | cut -f2-
    return 0
}

# --- comments ---

# _resolve_github_comment_id <id|url> — normalize the many comment references
# to a numeric review-comment id.
_resolve_github_comment_id() {
    local input="$1"
    if [[ "$input" =~ discussion_r([0-9]+) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$input" =~ \#comment-([A-Za-z0-9_-]+)$ ]]; then
        _gh api graphql -f query="{ node(id: \"${BASH_REMATCH[1]}\") { ... on PullRequestReviewComment { databaseId } } }" \
            --jq '.data.node.databaseId'
        return 0
    fi
    if [[ "$input" == PRRC_* ]]; then
        _gh api graphql -f query="{ node(id: \"$input\") { ... on PullRequestReviewComment { databaseId } } }" \
            --jq '.data.node.databaseId'
        return 0
    fi
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$input"
        return 0
    fi
    echo "Error: unrecognized comment format: $input" >&2
    return 1
}

cmd_comments() {
    local input="${1:-}"
    if [[ -z "$input" ]]; then
        echo "Usage: fw comments <comment_id|url>" >&2
        return 1
    fi

    local comment_id
    comment_id="$(_resolve_github_comment_id "$input")" || return 1

    local comment
    comment="$(_gh api "repos/{owner}/{repo}/pulls/comments/$comment_id" 2>&1)" || {
        echo "Error fetching comment: $comment" >&2
        return 1
    }

    local root_id pr_number
    root_id="$(echo "$comment" | jq '.in_reply_to_id // .id')"
    pr_number="$(echo "$comment" | jq -r '.pull_request_url | split("/") | last')"

    local thread
    thread="$(_gh api "repos/{owner}/{repo}/pulls/$pr_number/comments" --paginate |
        jq -s --argjson rid "$root_id" 'add | [.[] | select(.id == $rid or .in_reply_to_id == $rid)]')"

    local count
    count="$(echo "$thread" | jq 'length')"
    if [[ "$count" == "0" ]]; then
        echo "No thread found for comment $comment_id" >&2
        return 1
    fi

    # owner/repo for the GraphQL query comes from the already-fetched comment's
    # API url (…/repos/OWNER/REPO/pulls/…) — no extra network round-trip.
    local owner_repo owner name gql resolved
    owner_repo="$(echo "$comment" | jq -r '.url // .pull_request_url' |
        sed -E 's|.*/repos/([^/]+)/([^/]+)/.*|\1/\2|')"
    owner="${owner_repo%%/*}"
    name="${owner_repo#*/}"
    # Query and jq run as separate substitutions: bash mis-parses a heredoc
    # string with escaped quotes piped into a jq filter inside one "$(…)".
    gql="$(_gh api graphql -f query="
        query {
            repository(owner: \"$owner\", name: \"$name\") {
                pullRequest(number: $pr_number) {
                    reviewThreads(first: 100) {
                        nodes { isResolved comments(first: 1) { nodes { databaseId } } }
                    }
                }
            }
        }")"
    # Distinguish a false isResolved from a missing thread: jq's `// "unknown"`
    # would coalesce false to "unknown" (a legacy quirk that hid the
    # "Unresolved" state), so branch on the array length instead.
    resolved="$(echo "$gql" | jq -r --argjson rid "$root_id" '
        [.data.repository.pullRequest.reviewThreads.nodes[]
         | select(.comments.nodes[0].databaseId == $rid)
         | .isResolved] | if length == 0 then "unknown" else .[0] end')"

    local file line
    file="$(echo "$thread" | jq -r '.[0].path')"
    line="$(echo "$thread" | jq -r '.[0].original_line // .[0].line // "?"')"

    if [[ "$resolved" == "true" ]]; then
        echo "Resolved  $file:$line  PR #$pr_number"
    elif [[ "$resolved" == "false" ]]; then
        echo "Unresolved  $file:$line  PR #$pr_number"
    else
        echo "$file:$line  PR #$pr_number"
    fi
    echo

    # One jq pass renders every comment: "  <author>  <date>", then the body
    # indented four spaces, then a trailing blank line — no per-comment
    # date/sed/jq forks and no BSD-only date parsing.
    echo "$thread" | jq -r '.[] |
        "  \(.user.login)  \(try (.created_at | fromdateiso8601 | gmtime | strftime("%b %d %H:%M")) catch .created_at)\n"
        + (.body | split("\n") | map("    " + .) | join("\n")) + "\n"'
    return 0
}
