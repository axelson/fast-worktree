# The single fzf entry point shared by every interactive picker, so "fzf not
# installed", "user cancelled", and "fzf really failed" behave the same
# everywhere. Pickers guard empty input themselves (with a tailored message)
# before calling here.

# _fzf_pick_line [fzf-args…] — read candidate lines on stdin, run fzf, print the
# chosen line(s) on stdout. Return codes are a fixed contract so every picker
# degrades identically instead of conflating a real failure with a cancel:
#   0  a selection was made (line(s) on stdout)
#   1  cancelled or nothing selected (fzf exit 130, or exit 1/no-match, or an
#      empty selection) — the caller's quiet no-op path
#   2  fzf is not installed (guidance already printed to stderr)
#   3  fzf failed for a real reason (no tty, bad flag, exit >= 2); the message
#      "fzf failed (exit N)" is printed to stderr
_fzf_pick_line() {
    if ! command -v fzf >/dev/null 2>&1; then
        echo "Error: fzf is not installed — interactive pickers need it (https://github.com/junegunn/fzf)" >&2
        return 2
    fi
    # fzf runs its `--bind` commands (transform/reload/execute/preview) under
    # $SHELL. fw builds those binds in bash: sh syntax like the switch picker's
    # `transform:if [ -e M ]; then …; fi` (that emits pos()) plus bash `printf
    # %q` quoting of the paths embedded in them. A user whose login shell can't
    # parse that — fish errors with "Missing end to balance this if statement" —
    # silently drops the bind, so the picker misbehaves (the current worktree
    # never gets preselected). Pin the fzf process's shell to the very bash that
    # generated the binds ($BASH, the running interpreter), so both the sh syntax
    # AND the bash-specific `%q` quoting (`$'…'` for control chars) parse exactly
    # as written; fall back to /bin/sh (POSIX, still parses the sh syntax) on the
    # off chance $BASH is unset.
    local out rc=0
    out="$(SHELL="${BASH:-/bin/sh}" fzf "$@")" || rc=$?
    case $rc in
        0)
            [[ -n "$out" ]] || return 1
            printf '%s\n' "$out"
            return 0
            ;;
        1 | 130)
            return 1
            ;;
        *)
            echo "fzf failed (exit $rc)" >&2
            return 3
            ;;
    esac
}
