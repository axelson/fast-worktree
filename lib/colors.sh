# shellcheck disable=SC2034  # palette constants are consumed across lib/ (and by commands landing in later steps); defining the full set up front is deliberate.
#
# ANSI color constants (C_*) plus the gate that decides whether they carry
# escape codes or blank strings.
#
# The rewrite is plain-text by default; color is opt-in per command. Values are
# copied verbatim from felt-worktree (C_RESET is its NC). Constants store the
# actual escape bytes (via $'...') so plain `printf '%s'` and string
# concatenation emit them without needing `printf %b` / `echo -e`.
#
# The gate (FW_COLOR / NO_COLOR / a tty check) is applied by fw_color_init, and
# the constants are re-assignable so callers can pin a known state:
#
#   FW_COLOR=always  force codes on  (e.g. output piped into a pager/fzf)
#   FW_COLOR=never   force codes off
#   FW_COLOR=auto    (default, or unset) gate on: NO_COLOR unset AND stdout a tty
#
# The two-phase `fw switch` picker matters here: fzf runs `_switch-data` with
# its stdout on a pipe, so an auto gate would (wrongly) strip color from the
# enriched rows. The reload command sets FW_COLOR=always to keep it.

# _fw_color_enabled — 0 (true) when escape codes should be emitted.
_fw_color_enabled() {
    case "${FW_COLOR:-auto}" in
        always) return 0 ;;
        never)  return 1 ;;
    esac
    [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]
}

# fw_color_init — (re)assign the C_* constants from the current gate decision.
# Called once at startup by the entrypoint; re-callable (tests, or after
# redirecting output) to recompute against a changed environment.
fw_color_init() {
    if _fw_color_enabled; then
        C_RESET=$'\033[0m'
        C_RED=$'\033[0;31m'
        C_GREEN=$'\033[0;32m'
        C_YELLOW=$'\033[1;33m'
        C_BLUE=$'\033[0;34m'
        C_BLUE_BRIGHT=$'\033[1;94m'
        C_CYAN=$'\033[0;36m'
        C_MAGENTA=$'\033[0;35m'
        C_ORANGE=$'\033[38;5;208m'
        C_DIM=$'\033[2m'
    else
        C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' \
            C_BLUE_BRIGHT='' C_CYAN='' C_MAGENTA='' C_ORANGE='' C_DIM=''
    fi
}

fw_color_init
