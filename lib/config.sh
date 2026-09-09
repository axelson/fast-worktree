# shellcheck disable=SC2030,SC2031  # the repo_root subshell peek in
# load_config is intentional; later reads use the real sourced value.
#
# Configuration loading for fast-worktree.
#
# Configs are plain sourced bash. Precedence, last wins:
#   defaults → global config.sh → repo-local (.fast-worktree/ preferred, else
#   .fw/) → user project config (projects/<name>/config.sh)
#
# The user project config wins so a personal setting always beats one checked
# into the repo.

fw_config_dir() {
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/fast-worktree"
}

# _peek_config_var <file> <var> — echo the value <var> is assigned when <file>
# is sourced, without leaking anything into the caller. The subshell pre-clears
# <var> and runs with `set +eu` so a config statement that trips errexit/nounset
# (e.g. an associative-array assignment before its `declare -A`) can't abort the
# peek before the value is echoed.
_peek_config_var() {
    local file="$1" var="$2"
    # shellcheck disable=SC1090  # dynamic user config path
    ( set +eu; unset "$var"; source "$file" >/dev/null 2>&1; echo "${!var:-}" )
}

# _source_config <file> — source a user config, tolerating a nonzero status
# from its last statement (e.g. a trailing `[[ -d x ]] && …` that's false).
# Without this, `set -e` in the entrypoint would kill fw with no message.
# Syntax errors still surface on stderr.
_source_config() {
    # shellcheck disable=SC1090
    source "$1" || true
}

# --- hook chaining -----------------------------------------------------------
#
# A hook defined at a more-specific config level runs *in addition to* the same
# hook from less-specific levels, so a project can extend (not silently erase) a
# global hook. Composition happens here at source time: each level's definition
# is captured under a private name and, when a hook has two or more levels, a
# dispatcher is (re)installed under the real hook name that calls them in
# least-specific-first order. Call sites (run_hook, _run_hook_recording) are
# unchanged — they still invoke the hook by name.
#
# Each hook has a default direction (chain vs replace). A level flips it with a
# co-located `fw_hook_replace <hook>` / `fw_hook_chain <hook>` call.

# The hooks that participate in chaining. hook_usage_classify (lib/usage.sh) is
# deliberately excluded: it returns a single category|source verdict, so
# last-wins override is the right semantics for it, not chaining.
__fw_hook_names=(
    hook_worktree_env hook_pre_db hook_post_create
    hook_pre_delete hook_post_switch hook_sync hook_tmux_windows
)

# Per-hook default direction. Absent => chain. hook_tmux_windows lays out tmux
# windows; two layouts collide, so it replaces by default.
# -g so the arrays are global even when lib/config.sh is sourced inside a
# function (the bats setup(), and the entrypoint's loader).
declare -gA __fw_hook_default_mode=(
    [hook_tmux_windows]=replace
)

# Populated during a load_config run: hook name -> space-separated list of the
# captured per-level function names, in source order. Reset per run.
declare -gA __fw_hook_chain=()
# hook name -> 1 when it was installed as a multi-level dispatcher, so run_hook
# knows the dispatcher already reported its own per-level failures. Reset per run.
declare -gA __fw_hook_is_chain=()
# A level's one-shot direction override, set by the helpers below and consumed
# (then cleared) after that level is sourced.
declare -gA __fw_hook_mode_override=()

# fw_hook_replace / fw_hook_chain <hook> — called from a config to override the
# hook's default direction for *this* level's definition.
fw_hook_replace() { __fw_hook_mode_override["$1"]=replace; }
fw_hook_chain()   { __fw_hook_mode_override["$1"]=chain; }

# _copy_function <from> <to> — define <to> with <from>'s body. `declare -f`
# prints "from () \n{ … }"; dropping its first line and prepending "to()"
# rebuilds the function under the new name. It is behavior-preserving, not a
# byte copy: declare -f reparses and reformats the body (and drops comments), so
# <to> runs identically but its source text is bash's canonical form, not the
# original.
_copy_function() {
    local from="$1" to="$2"
    declare -F "$from" >/dev/null || return 1
    eval "$(printf '%s()\n' "$to"; declare -f "$from" | tail -n +2)"
}

# _source_config_hooks <file> <scope> — source a config, then capture any of the
# known hooks it defined into the chain. <scope> is the human label for this
# level (global/repo/project); it is baked into the captured function name so a
# failing level can be reported by scope. Known hooks are unset first so "defined
# after sourcing" means "defined by THIS level", not inherited from an earlier
# one (which is already captured-and-unset).
_source_config_hooks() {
    local file="$1" scope="$2" h mode captured
    for h in "${__fw_hook_names[@]}"; do
        unset -f "$h" 2>/dev/null || true
    done
    __fw_hook_mode_override=()

    _source_config "$file"

    for h in "${__fw_hook_names[@]}"; do
        declare -F "$h" >/dev/null || continue
        captured="__fw_${h}__${scope}"
        _copy_function "$h" "$captured"
        unset -f "$h"
        mode="${__fw_hook_mode_override[$h]:-${__fw_hook_default_mode[$h]:-chain}}"
        if [[ "$mode" == replace ]]; then
            __fw_hook_chain["$h"]="$captured"
        else
            __fw_hook_chain["$h"]="${__fw_hook_chain[$h]:+${__fw_hook_chain[$h]} }$captured"
        fi
    done
}

# _install_hook_dispatchers — after all levels are sourced, materialize each
# hook's real name from its chain. One level: the function itself, no wrapper, so
# it behaves exactly as today. Two or more: a dispatcher that runs them in order,
# honoring the failure policy run_hook advertises via __fw_hook_policy. A failing
# level is named by its scope (global/repo/project, recovered from the captured
# name's suffix): under fatal the chain stops at the first failure and propagates
# it; under warn every level runs and each failure is reported; under ignore
# every level runs silently. run_hook sees __fw_hook_is_chain and so does not add
# its own generic message on top of the dispatcher's per-level ones.
_install_hook_dispatchers() {
    local h fns
    for h in "${__fw_hook_names[@]}"; do
        fns="${__fw_hook_chain[$h]:-}"
        [[ -n "$fns" ]] || continue
        if [[ "$fns" != *" "* ]]; then
            _copy_function "$fns" "$h"
            continue
        fi
        __fw_hook_is_chain["$h"]=1
        eval "$h() {
            local __f __rc=0 __scope
            for __f in $fns; do
                \"\$__f\" \"\$@\" && continue
                __rc=1
                __scope=\"\${__f##*__}\"
                case \"\${__fw_hook_policy:-}\" in
                    fatal) echo \"Error: $h failed (\$__scope)\" >&2; return 1 ;;
                    warn)  echo \"Warning: $h failed (\$__scope)\" >&2 ;;
                esac
            done
            return \$__rc
        }"
    done
}

# The tool's config surface as an explicit list — everything _config_defaults
# declares, in the same order. `fw config show` prints exactly these, and a
# guard test (tests/integration/config.bats) asserts the two stay in sync so
# a new config variable can't silently vanish from `show`.
# shellcheck disable=SC2034  # consumed by cmd_config in lib/configcmd.sh
_config_vars=(
    project repo_root worktrees_dir branch_prefix github_username
    default_project stack_backend env_file stop_port_vars cow_assets
    cache_dirs ticket_pattern ticket_url db_source db_template db_prefix db_setup_cmd
    start_cmd check_cmd fix_cmd domain caddyfile caddy_reload_file web_port_var
    default_browser ignored_checks checks_poll_interval notify_categories
    team_members editor handoff_dir switch_recent_days switch_refresh_secs
    switch_claude_refresh_secs switch_on_create menu_order
    claude_prompt_flags claude_model_aliases claude_archive_dir
    claude_archive_paths claude_summary_file
    usage_own_prefixes usage_extra_prefixes usage_tz
)

# These variables are the tool's config surface, consumed across lib/ and by
# sourced user configs.
# shellcheck disable=SC2034
_config_defaults() {
    project=""
    repo_root=""
    worktrees_dir=""
    branch_prefix="${USER:-}"
    github_username=""
    default_project=""
    stack_backend=auto
    env_file=.env.worktree
    # stop_port_vars: an allowlist of env-file variable names `fw stop`/`refresh`
    # may kill listeners on (exact match, so a bare `PORT` is expressible and a
    # shared-ingress key like an external 443 port can be excluded). Empty
    # (default) => the felt-neutral convention stands: every key ending in
    # `_PORT` is a killable port.
    stop_port_vars=()
    cow_assets=(_build deps assets/node_modules)
    # cache_dirs: absolute directories a project's cache lives in. `fw clean
    # --cache` removes each one (rm -rf) and then exits without touching
    # worktrees. Empty (default) => felt-neutral: no cache to clear. Extension
    # layers set concrete paths (felt lists its Render cache in the felt repo's
    # config, separately from core).
    cache_dirs=()
    ticket_pattern='/([a-zA-Z]+)-([0-9]+)'
    ticket_url=""
    db_source=""
    # db_template: the database `fw create` template-clones new worktree DBs
    # from. Empty (default) => clone from db_source. Set it to a dedicated
    # golden template DB (kept migrated by hook_sync) so live connections to
    # db_source — e.g. the main checkout's running dev server — never block the
    # clone. Presence-gated on db_source: without db_source there is no DB
    # feature and db_template is inert.
    db_template=""
    db_prefix=""
    db_setup_cmd=""
    # start_cmd/check_cmd/fix_cmd: project commands run by `fw start`/`check`/
    # `fix` in the worktree directory with the FW_* env contract applied. Empty
    # => the command reports that the project hasn't configured it.
    start_cmd=""
    check_cmd=""
    fix_cmd=""
    # --- Caddy/dnsmasq opt-in HTTPS (see lib/caddy.sh) ---
    # domain: opt-in switch. Empty (default) => off: `fw open` builds
    # http://localhost:<port> and no Caddyfile is written. Set (e.g. felt.local)
    # => each live worktree gets an https://<name>.<domain> reverse proxy and
    # `fw open` builds that https URL.
    domain=""
    # caddyfile: path to the Caddyfile core rewrites when domain is set. Empty
    # (default) => regeneration is a no-op even with a domain, so the layer
    # never writes outside an explicitly configured location. A felt-style
    # config sets e.g. caddyfile=/opt/homebrew/etc/Caddyfile.
    caddyfile=""
    # caddy_reload_file: the path handed to `caddy reload` after a regen — i.e.
    # which config the running Caddy re-reads. Empty (default) => falls back to
    # $caddyfile, so a single-project setup reloads exactly what it just wrote.
    # `caddy reload` replaces the ENTIRE running config, so with several
    # caddy-enabled projects each writing its own $caddyfile you'd want them
    # chained under one shared root Caddyfile (nested `import`s) and this key
    # pointed at that root (e.g. /opt/homebrew/etc/Caddyfile): the reload then
    # re-reads the whole chain and no other project's live sites get dropped.
    # The WRITE target is always $caddyfile — only the reload --config differs.
    caddy_reload_file=""
    # web_port_var: the .env.worktree key whose value is a worktree's primary
    # HTTP port (a hook derives it from FW_PORT_SLOT). Core reads it back as the
    # reverse-proxy target and the `fw open` localhost port. Empty => no Caddy
    # proxy port and no localhost URL.
    web_port_var=""
    default_browser=""
    ignored_checks=()
    checks_poll_interval=30
    # notify_categories: valid categories for `fw notify` (and the labels
    # `fw checks-wait` announces under). A typo'd category is rejected so the
    # log stays tidy. Projects can override with their own set.
    notify_categories=(ci deploy fix alert)
    # team_members: roster for `fw pr assign`. Each entry is
    # `alias:github[:linear]` — core uses fields 1-2 (alias + GitHub login);
    # the optional linear field is for extension layers. Empty (default) =>
    # `pr assign` falls back to the repo's GitHub collaborators.
    team_members=()
    # editor: command used by `fw open-file` to open a Markdown file; falls
    # back to $EDITOR when empty. May carry arguments (e.g. "code -w").
    editor=""
    # handoff_dir: where `fw handoff save` stores handoff docs. Empty =>
    # defaults (in the handoff helpers) to <worktrees_dir>/handoffs.
    handoff_dir=""
    # Default recency window (in days) for the bare `fw switch` picker; --all
    # ignores it. Drives both the candidate cutoff and the picker header.
    switch_recent_days=7
    # Interval (in seconds) at which the bare `fw switch` picker re-enriches
    # itself while open, so live columns — chiefly the Claude waiting/running
    # badge — stay current without reopening. 0 (or empty) disables it: the
    # picker enriches exactly once and stops, as it did before. A non-numeric
    # value falls back to this default.
    switch_refresh_secs=10
    # Interval (in seconds) at which the cross-project `fw switch-claude` (`sc`)
    # picker re-enriches itself while open, so the live Claude-session list —
    # statuses flipping waiting/busy/idle, sessions appearing and vanishing —
    # stays current without reopening. 0 disables it (one-shot list, as before);
    # a non-numeric value falls back to this default. Global-only: switch-claude
    # is cross-project, so it reads this from the global config.sh, not per-project.
    switch_claude_refresh_secs=10
    # switch_on_create: whether `fw create`/`fw pull` switch into the new
    # worktree (open/attach its tmux session) once it's built. true (default) =>
    # you land in the worktree you just made; set false to stay put. A per-run
    # `--no-switch` flag overrides it either way.
    switch_on_create=true
    # menu_order: labels to float to the top of `fw menu`, in the given order
    # (see lib/menu.sh). Empty by default — the built-in order is used as-is.
    menu_order=()

    # --- Claude Code integration (see lib/claude.sh) ---
    # claude_prompt_flags: bare flags for `fw create`/`fw pull` that launch
    # Claude with a named prompt. Maps a flag name to the prompt Claude receives,
    # so `--<name>` runs it in the new worktree (built-in flags always win over a
    # collision). This is how felt-style `fw pull <PR> --review` works — new
    # review modes are config, not code. For a one-off prompt not worth a flag,
    # `--claude "<literal prompt>"` still works. e.g. in a project config:
    #   claude_prompt_flags=([review]="/pr-review" [understand]="/understand-pr")
    declare -gA claude_prompt_flags=()
    # claude_model_aliases: shorthand names for `--model`. Maps an alias to a
    # full model id; --model also accepts any literal model id not listed here.
    # (Model ids are Claude-Code-version-specific, so the default map is empty
    # and the value is passed through to `claude` unchanged.) e.g.:
    #   claude_model_aliases=([opus]="claude-opus-4-8[1m]" [fable]="claude-fable-5[1m]")
    declare -gA claude_model_aliases=()
    # claude_archive_dir: where `fw delete` copies a worktree's Claude
    # artifacts before removing it. Empty => defaults (in load_config) to
    # <config>/projects/<project>/claude-archive.
    claude_archive_dir=""
    # claude_archive_paths: <relative-src>:<dest-name> entries (src relative to
    # the worktree root) preserved on archive/delete. Each src may be a
    # directory (its contents land under <archive>/<branch>/<dest-name>/) or a
    # plain file (e.g. "STATUS.md:status.md" — the file lands at
    # <archive>/<branch>/<dest-name>), so a root-level file that git excludes
    # isn't destroyed with the worktree. On `fw restore` these artifacts are
    # copied back into the recreated worktree (see restore_claude), overwriting
    # any freshly-stamped template. Empty by default — .claude/plans, docs/recon,
    # STATUS.md, etc. are felt conventions, so projects opt in via their config
    # (settings.local.json and the summary file are always preserved regardless,
    # as a special case in archive_claude/restore_claude).
    claude_archive_paths=()
    # claude_summary_file: per-worktree summary file Claude writes; archived on
    # delete and used as the summary source by `fw sessions close-old`.
    claude_summary_file=".fw-summary.md"

    # --- fw usage classification (see lib/usage.sh) ---
    # usage_own_prefixes: branch-name globs that mean "my own work" beyond
    # branch_prefix, e.g. (claude fix 'app-[0-9]*'). Checked after the teammate
    # prefixes derived from team_members, so a teammate's fix-* branch is not
    # claimed as own work. Empty by default — these are project conventions.
    usage_own_prefixes=()
    # usage_extra_prefixes: "glob:category" pairs for names the roster can't
    # express, e.g. ("cloer:review"). Category is own|review|misc|ignore.
    usage_extra_prefixes=()
    # usage_tz: display zone for `fw usage` as "offset:label", e.g. "-10:HST"
    # or "+0530:IST" (hours, or HHMM for a part-hour zone). Timestamps are
    # stored as ccusage emits them (UTC); the zone moves only what a human
    # reads and the --since/--period window edges. Empty (default) => the
    # system zone, read once per run.
    usage_tz=""
}

# load_config <project-name>
# Populates the config variables above (plus any hook functions the configs
# define) in the caller's scope.
load_config() {
    local name="$1"
    local cfg_dir proj_cfg
    cfg_dir="$(fw_config_dir)"
    proj_cfg="$cfg_dir/projects/$name/config.sh"

    if [[ ! -f "$proj_cfg" ]]; then
        echo "Error: project '$name' is not registered (run 'fw init' from its repo)" >&2
        return 1
    fi

    _config_defaults

    # Start each run with an empty chain so a reused shell (e.g. one process
    # loading several projects) never carries a prior project's hooks over.
    __fw_hook_chain=()
    __fw_hook_is_chain=()

    if [[ -f "$cfg_dir/config.sh" ]]; then
        _source_config_hooks "$cfg_dir/config.sh" global
    fi

    # The repo-local config lives under repo_root, which the project config
    # declares — peek it out first, then source in precedence order.
    local root
    root="$(_peek_config_var "$proj_cfg" repo_root)"
    if [[ -n "$root" ]]; then
        if [[ -f "$root/.fast-worktree/config.sh" ]]; then
            _source_config_hooks "$root/.fast-worktree/config.sh" repo
        elif [[ -f "$root/.fw/config.sh" ]]; then
            _source_config_hooks "$root/.fw/config.sh" repo
        fi
    fi

    _source_config_hooks "$proj_cfg" project
    _install_hook_dispatchers
    project="$name"

    if [[ -z "$worktrees_dir" && -n "$repo_root" ]]; then
        worktrees_dir="$(dirname "$repo_root")/${project}-worktrees"
    fi
    if [[ -z "$db_prefix" ]]; then
        db_prefix="${project}_"
    fi
    return 0
}
