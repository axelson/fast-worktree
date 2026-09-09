# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# `fw open-file`: pick an untracked Markdown/HTML file in a worktree and open
# it — Markdown in the editor ($editor, else $EDITOR), HTML through the browser
# seam (_open_url in gh.sh). The picker goes through the shared _fzf_pick_line.

# _open_in_editor <file> — open <file> in the configured editor: the `editor`
# config value, else $EDITOR; error when neither is set. The editor value may
# carry arguments (e.g. "code -w").
_open_in_editor() {
    local ed="${editor:-${EDITOR:-}}"
    if [[ -z "$ed" ]]; then
        echo "Error: no editor configured (set the 'editor' config or \$EDITOR)" >&2
        return 1
    fi
    local -a ed_cmd
    read -ra ed_cmd <<<"$ed"
    "${ed_cmd[@]}" "$1"
}

cmd_open_file() {
    resolve_worktree "${1:-}" || return 1

    local -a candidates=()
    local f
    while IFS= read -r f; do
        [[ -n "$f" ]] && candidates+=("$f")
    done < <(git -C "$WT_PATH" ls-files --others --exclude-standard \
        | grep -iE '\.(md|html)$' | sort)

    if [[ ${#candidates[@]} -eq 0 ]]; then
        echo "No untracked .md or .html files in $WT_NAME"
        return 0
    fi

    local selected rc=0
    selected="$(printf '%s\n' "${candidates[@]}" \
        | _fzf_pick_line --reverse --header='Open untracked file')" || rc=$?
    case $rc in
        0) ;;             # selection in $selected
        1) return 0 ;;    # cancelled — quiet no-op
        *) return 1 ;;    # fzf missing / error (message already printed)
    esac

    local full="$WT_PATH/$selected"
    if [[ "$selected" == *.md ]]; then
        _open_in_editor "$full"
    else
        _open_url "$full"
    fi
}
