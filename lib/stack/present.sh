# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# Stack presentation: the cmd_* functions users invoke, layered over the stack
# backend seam in lib/stack.sh. Nothing here knows which backend is active — it
# all runs on the answers the dispatchers return, so every command degrades to
# "a stack of one based on trunk" under the none backend.

# _stack_require_cwd_in_project — stack reads derive the current branch from
# cwd, so refuse to answer for a cwd outside the project's repo/worktrees.
_stack_require_cwd_in_project() {
    local common cwd_root
    if ! common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
        echo "Error: not inside a git repo — run this from $project's repo or a worktree" >&2
        return 1
    fi
    cwd_root="$(realpath "$(dirname "$common")" 2>/dev/null || true)"
    if [[ "$cwd_root" != "$(realpath "$repo_root")" ]]; then
        echo "Error: current directory is not part of project '$project' ($repo_root)" >&2
        return 1
    fi
    return 0
}

# _stack_decode <raw-row> — split a stack_branches row into "<mark>\t<branch>"
# (newline-terminated): mark is "*" for the current branch, else empty. Shared
# by cmd_stack and cmd_stack_switch so the leading-* convention lives in one
# place.
_stack_decode() {
    local b="$1"
    if [[ "$b" == \** ]]; then
        printf '*\t%s\n' "${b#\*}"
    else
        printf '\t%s\n' "$b"
    fi
}

# _stack_parse — read stack_branches (bottom→top) into the STACK_ROWS array with
# the current-branch marker stripped, and set STACK_CURRENT_IDX to the current
# branch's index (-1 when the stack has no marked branch). Returns nonzero when
# the backend read fails. Shared by navigation and restack.
_stack_parse() {
    STACK_ROWS=()
    STACK_CURRENT_IDX=-1
    local raw
    raw="$(stack_branches)" || return 1
    local b idx=0
    while IFS= read -r b; do
        [[ -n "$b" ]] || continue
        if [[ "$b" == \** ]]; then
            STACK_CURRENT_IDX=$idx
            b="${b#\*}"
        fi
        STACK_ROWS+=("$b")
        ((idx++)) || true
    done <<<"$raw"
    return 0
}

# cmd_stack — show the current stack, bottom→top, current branch marked.
cmd_stack() {
    _stack_require_cwd_in_project || return 1
    _ensure_trunk
    local branches
    branches="$(stack_branches)" || return 1
    if [[ -z "$branches" ]]; then
        echo "No stack (on trunk)"
        return 0
    fi
    local b mark bn
    while IFS= read -r b; do
        [[ -n "$b" ]] || continue
        IFS=$'\t' read -r mark bn < <(_stack_decode "$b")
        if [[ "$mark" == "*" ]]; then
            echo "* $bn"
        else
            echo "  $bn"
        fi
    done <<<"$branches"
}

# cmd_stack_switch (ss) — fzf picker over the current branch stack; switch to
# the worktree backing the chosen branch. Reuses stack_branches (the same
# presentation source as cmd_stack) and cmd_switch for the actual jump.
cmd_stack_switch() {
    _stack_require_cwd_in_project || return 1
    _ensure_trunk
    local branches
    branches="$(stack_branches)" || return 1
    if [[ -z "$branches" ]]; then
        echo "No stack (on trunk)"
        return 0
    fi

    # Offer "<mark> <branch>" (display) with the bare branch as a hidden field.
    local lines="" b mark bn
    while IFS= read -r b; do
        [[ -n "$b" ]] || continue
        IFS=$'\t' read -r mark bn < <(_stack_decode "$b")
        [[ "$mark" == "*" ]] || mark=" "
        lines+="${mark} ${bn}"$'\t'"${bn}"$'\n'
    done <<<"$branches"

    local selected rc=0
    selected="$(printf '%s' "$lines" | _fzf_pick_line --no-sort --reverse \
        --delimiter=$'\t' --with-nth=1 --header='Stack')" || rc=$?
    case $rc in
        0) ;;
        1) return 0 ;;     # cancelled — quiet no-op
        *) return 1 ;;     # fzf missing or real error (message already printed)
    esac

    # The pick is one "<display>\t<branch>" line; take the hidden branch field.
    local target_branch="${selected#*$'\t'}"

    # Picking trunk routes to the golden-checkout switch, exactly like
    # `fw switch main` — unless the user is already in the golden checkout, in
    # which case there's nothing to switch to.
    if [[ "$target_branch" == "$(trunk_branch)" ]]; then
        if [[ "$(_current_worktree_name)" == "main" ]]; then
            echo "Already on trunk from the stack view — nothing to switch to" >&2
            return 0
        fi
        cmd_switch main
        return
    fi

    # resolve_worktree matches recorded branches, so delegate the jump to
    # cmd_switch; keep the tailored error when no worktree backs the branch.
    if ! resolve_worktree "$target_branch" 2>/dev/null; then
        echo "Error: no worktree for branch '$target_branch'" >&2
        return 1
    fi
    cmd_switch "$target_branch"
}

# _stack_navigate <up|down|top|bottom> — switch to the worktree of an adjacent
# (up/down) or terminal (top/bottom) branch in the current stack. up moves
# toward the tip, down toward trunk; the branch list is bottom→top.
_stack_navigate() {
    local direction="$1"
    _stack_require_cwd_in_project || return 1
    _ensure_trunk

    _stack_parse || return 1
    local n=${#STACK_ROWS[@]}
    if [[ $n -eq 0 ]]; then
        echo "No stack (on trunk)"
        return 0
    fi
    if [[ $STACK_CURRENT_IDX -lt 0 ]]; then
        echo "Error: current branch is not in the stack" >&2
        return 1
    fi

    local target_idx
    case "$direction" in
        up)
            target_idx=$((STACK_CURRENT_IDX + 1))
            if [[ $target_idx -ge $n ]]; then
                echo "Already at top of stack"
                return 0
            fi
            ;;
        down)
            target_idx=$((STACK_CURRENT_IDX - 1))
            if [[ $target_idx -lt 0 ]]; then
                echo "Already at bottom of stack"
                return 0
            fi
            ;;
        top)
            target_idx=$((n - 1))
            if [[ $target_idx -eq $STACK_CURRENT_IDX ]]; then
                echo "Already at top of stack"
                return 0
            fi
            ;;
        bottom)
            target_idx=0
            if [[ $target_idx -eq $STACK_CURRENT_IDX ]]; then
                echo "Already at bottom of stack"
                return 0
            fi
            ;;
        *)
            echo "Error: unknown stack direction '$direction'" >&2
            return 1
            ;;
    esac

    local target_branch="${STACK_ROWS[$target_idx]}"

    # resolve_worktree matches recorded branches; keep the legacy pull hint so
    # the user can materialize a stack branch that has no worktree yet.
    if ! resolve_worktree "$target_branch" 2>/dev/null; then
        echo "Error: no worktree for branch '$target_branch'" >&2
        echo "Create one with: fw pull $target_branch" >&2
        return 1
    fi
    cmd_switch "$WT_NAME"
}

cmd_up()     { _stack_navigate up; }
cmd_down()   { _stack_navigate down; }
cmd_top()    { _stack_navigate top; }
cmd_bottom() { _stack_navigate bottom; }

# cmd_restack [--all] — rebase the current branch and everything below it
# (default) or the whole stack (--all) onto their parents, one worktree at a
# time bottom→top so each parent is restacked before its children. Pre-flights
# the whole scope — every branch needs a worktree and a clean tree — so a
# missing or dirty worktree stops the run before any rebase starts.
cmd_restack() {
    local restack_all=false arg
    for arg in "$@"; do
        case "$arg" in
            --all) restack_all=true ;;
            *) echo "Error: unknown flag '$arg'" >&2; return 1 ;;
        esac
    done

    _stack_require_cwd_in_project || return 1
    _ensure_trunk

    # Refuse before announcing anything when there is no backend that can
    # restack — the none backend has no rebase machinery. Mirrors `fw up`
    # exiting on its clean path rather than starting and then failing.
    if [[ "$STACK_BACKEND" == none ]]; then
        echo "Error: restack needs a stack backend (set stack_backend=graphite)" >&2
        return 1
    fi

    _stack_parse || return 1
    local n=${#STACK_ROWS[@]}
    if [[ $n -eq 0 ]]; then
        echo "No stack (on trunk)"
        return 0
    fi
    if [[ $STACK_CURRENT_IDX -lt 0 ]]; then
        echo "Error: current branch is not in the stack" >&2
        return 1
    fi

    # Scope: bottom→current (default) or the whole stack (--all).
    local end_idx=$STACK_CURRENT_IDX
    [[ "$restack_all" == true ]] && end_idx=$((n - 1))

    local -a wt_names=() wt_paths=() missing=() dirty=()
    local i branch
    for (( i=0; i<=end_idx; i++ )); do
        branch="${STACK_ROWS[$i]}"
        if ! resolve_worktree "$branch" 2>/dev/null; then
            missing+=("$branch")
            continue
        fi
        wt_names+=("$WT_NAME")
        wt_paths+=("$WT_PATH")
        if [[ -n "$(git -C "$WT_PATH" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
            dirty+=("$WT_NAME")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: missing worktrees for stack branches:" >&2
        for branch in "${missing[@]}"; do
            echo "  $branch" >&2
        done
        echo "Create them with: fw pull <branch>" >&2
        return 1
    fi
    if [[ ${#dirty[@]} -gt 0 ]]; then
        echo "Error: worktrees have uncommitted changes:" >&2
        for branch in "${dirty[@]}"; do
            echo "  $branch" >&2
        done
        return 1
    fi

    local count=${#wt_paths[@]}
    echo "Restacking $count branch(es)..."
    for (( i=0; i<count; i++ )); do
        if stack_restack "${wt_paths[$i]}"; then
            echo "  ✓ ${wt_names[$i]}"
        else
            echo "  ✗ ${wt_names[$i]} — restack failed; resolve the conflict as shown above, then re-run 'fw restack' for the remaining branches" >&2
            return 1
        fi
    done
    echo "Done."
}
