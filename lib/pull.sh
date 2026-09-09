# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# fw pull — create a worktree from a remote or local branch or PR.

# name_from_branch <branch> — worktree name derived from a branch. The
# configured branch prefix is stripped (jason/foo -> foo); any other namespace
# is kept with its slash folded to '-' (jax/foo -> jax-foo) so the name keeps
# the branch's identity and can't collide across namespaces. Then lowercased,
# with invalid characters folded to '-'.
name_from_branch() {
    local name="$1"
    local prefix="${branch_prefix:-}"
    [[ -n "$prefix" ]] && name="${name#"$prefix/"}"
    name="${name//\//-}"
    name="${name,,}"
    name="${name//[^a-z0-9_-]/-}"
    while [[ "$name" == [-_]* ]]; do
        name="${name#?}"
    done
    echo "$name"
}

# _resolve_pull_branch <branch|PR#|PR-URL> — echoes the branch name,
# resolving PR references through gh.
_resolve_pull_branch() {
    local arg="$1" pr=""
    case "$arg" in
        *github.com/*/pull/*)
            pr="${arg##*/pull/}"
            pr="${pr%%[^0-9]*}"
            ;;
        '' | *[!0-9]*)
            echo "$arg"
            return 0
            ;;
        *)
            pr="$arg"
            ;;
    esac

    local branch
    if ! branch="$(gh pr view "$pr" --json headRefName --jq .headRefName 2>&1)" || [[ -z "$branch" ]]; then
        echo "Error: could not resolve PR #$pr to a branch: ${branch:-gh pr view failed}" >&2
        return 1
    fi
    echo "$branch"
}

cmd_pull() {
    local arg="" model="" claude_prompt="" no_switch=false
    while [[ $# -gt 0 ]]; do
        _parse_claude_flag model claude_prompt "$#" "$1" "${2:-}" || return 1
        if [[ "$_CF_CONSUMED" != 0 ]]; then shift "$_CF_CONSUMED"; continue; fi
        case "$1" in
            --no-switch) no_switch=true; shift ;;
            -*)
                # A bare flag that matches no built-in is looked up as a
                # configured prompt-flag (--review -> claude_prompt_flags[review]);
                # anything else is a genuine unknown flag.
                if claude_prompt="$(_prompt_flag_for "$1")"; then
                    shift
                else
                    echo "Error: unknown flag '$1'" >&2; return 1
                fi
                ;;
            *)
                if [[ -n "$arg" ]]; then
                    echo "Error: fw pull takes a single branch/PR argument" >&2
                    return 1
                fi
                arg="$1"; shift ;;
        esac
    done
    if [[ -z "$arg" ]]; then
        echo "Error: usage: fw pull <branch|PR#|PR-URL> [--model M] [--claude PROMPT] [--<prompt-flag>]" >&2
        return 1
    fi

    local branch
    branch="$(_resolve_pull_branch "$arg")" || return 1

    local name
    name="$(name_from_branch "$branch")"
    local wt_path="$worktrees_dir/$name"
    if [[ -e "$wt_path" ]]; then
        echo "Error: worktree '$name' already exists — use: fw switch $name" >&2
        return 1
    fi

    echo "Fetching $branch..."
    stack_adopt "$branch" || return 1

    echo "Creating worktree $name from $branch..."
    _materialize_worktree "$name" "$branch" || return 1

    _export_fw_env "$name" "$branch" "$wt_path"
    run_hook hook_post_pull "$wt_path" warn

    apply_claude_create_opts "$name" "$wt_path" "$model" "$claude_prompt"

    echo "Created $wt_path"
    _switch_after_create "$name" "$no_switch"
    return 0
}
