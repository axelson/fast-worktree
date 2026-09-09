# shellcheck disable=SC2154  # config globals ($domain, $caddyfile,
# $web_port_var, $caddy_reload_file, $project) are assigned by load_config /
# _require_project.
#
# `fw caddy setup` / `fw caddy remove`: automate (and reverse) the per-project
# Caddy HTTPS wiring that docs/caddy.md documents as a manual, partly-sudo
# procedure. setup sets the domain+caddyfile config keys, writes the per-project
# fragment (via regenerate_caddyfile), wires the shared aggregation import line
# and the dnsmasq address line, then runs the two sudo steps (/etc/resolver +
# dnsmasq restart). remove reverses each, touching only THIS project's lines.
#
# macOS/Homebrew only — the /etc/resolver + dnsmasq mechanism is macOS-specific
# (docs/caddy.md); on Linux wildcard DNS is the user's own problem.

_caddy_usage() {
    cat <<EOF
Usage: fw caddy setup  [--domain DOMAIN]   enable https://<name>.<domain> for this project
       fw caddy remove                     reverse the setup for this project

setup sets the domain/caddyfile config keys, writes this project's Caddy
fragment, wires the shared aggregation import + dnsmasq address lines, and runs
the sudo steps (create /etc/resolver/<domain>, restart dnsmasq). Default domain
is <project>.local. macOS/Homebrew only.
EOF
}

# _caddy_ensure_line <file> <line> — append <line> to <file> unless an exact
# (whole-line) copy is already there, so repeat setups never double-write and
# another project's line is never mistaken for this one. Creates the file if new.
_caddy_ensure_line() {
    local file="$1" line="$2"
    [[ -f "$file" ]] && grep -qxF -- "$line" "$file" && return 0
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    printf '%s\n' "$line" >>"$file"
}

# _caddy_remove_line <file> <line> — delete every exact (whole-line) copy of
# <line>, leaving all other lines intact so a shared file keeps other projects'
# entries. No-op when the file is missing. Atomic via temp + mv.
_caddy_remove_line() {
    local file="$1" line="$2" tmp rc
    [[ -f "$file" ]] || return 0
    tmp="$file.fw-tmp.$$"
    # grep -v exits 1 when it selects nothing (file was only this line) — a
    # legitimate empty result to keep. But exit >=2 is a real error (unreadable
    # file, full disk); mv'ing the partial temp then would blow away every OTHER
    # project's lines in this shared file, so bail without touching the original.
    if grep -vxF -- "$line" "$file" >"$tmp" 2>/dev/null; then rc=0; else rc=$?; fi
    if (( rc > 1 )); then
        rm -f "$tmp"
        echo "Warning: could not rewrite $file (grep exit $rc) — left unchanged" >&2
        return 1
    fi
    mv "$tmp" "$file"
}

# _caddy_check_prereqs — best-effort warnings for the one-time global bootstrap
# this command deliberately does NOT perform (docs/caddy.md "One-time setup"):
# the two Homebrew tools and the root Caddyfile's import of the aggregation file.
# All non-fatal — setup still wires this project's pieces.
_caddy_check_prereqs() {
    command -v caddy >/dev/null 2>&1 ||
        echo "Warning: caddy is not installed — run 'brew install caddy' then 'caddy trust' (one-time)." >&2
    command -v dnsmasq >/dev/null 2>&1 ||
        echo "Warning: dnsmasq is not installed — run 'brew install dnsmasq' (one-time)." >&2

    # The running Caddy loads sites only if its root config imports the
    # aggregation file this command appends to. Warn when we can see it doesn't.
    if [[ -z "$caddy_reload_file" ]]; then
        echo "Warning: caddy_reload_file is unset — set it (globally) to your root Caddyfile so a caddy restart serves these sites (see docs/caddy.md)." >&2
    elif [[ -f "$caddy_reload_file" ]] && ! grep -q 'Caddyfile-fast-worktree' "$caddy_reload_file"; then
        echo "Warning: $caddy_reload_file does not import Caddyfile-fast-worktree — add 'import Caddyfile-fast-worktree' so a caddy restart serves these sites (see docs/caddy.md)." >&2
    fi
}

cmd_caddy() {
    case "${1:-}" in
        setup)  shift; _caddy_setup "$@" ;;
        remove) shift; _caddy_remove "$@" ;;
        help | -h | --help) _caddy_usage ;;
        "")
            echo "Error: 'fw caddy' needs a subcommand (setup or remove)" >&2
            _caddy_usage >&2
            return 1
            ;;
        *)
            echo "Error: unknown caddy subcommand '$1'" >&2
            _caddy_usage >&2
            return 1
            ;;
    esac
}

_caddy_setup() {
    local domain_val=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)   domain_val="${2:?Error: --domain requires a value}"; shift 2 ;;
            --domain=*) domain_val="${1#*=}"; shift ;;
            -*) echo "Error: unknown flag '$1'" >&2; _caddy_usage >&2; return 1 ;;
            *)  echo "Error: unexpected argument '$1'" >&2; _caddy_usage >&2; return 1 ;;
        esac
    done

    [[ "$OSTYPE" == darwin* ]] ||
        { echo "Error: 'fw caddy setup' is macOS/Homebrew only (see docs/caddy.md)" >&2; return 1; }
    command -v brew >/dev/null 2>&1 ||
        { echo "Error: Homebrew ('brew') is required to locate the Caddyfile/dnsmasq paths (see docs/caddy.md)" >&2; return 1; }
    [[ -n "$web_port_var" ]] ||
        { echo "Error: set web_port_var first — your hook_worktree_env writes the port under it (see docs/caddy.md)" >&2; return 1; }

    [[ -n "$domain_val" ]] || domain_val="${project}.local"
    _caddy_check_prereqs

    local etc caddyfile_val
    etc="$(brew --prefix)/etc"
    caddyfile_val="$etc/Caddyfile-fw-$project"

    # Persist the two opt-in keys to the project config and mirror them into the
    # running shell, so the regenerate below sees an enabled layer.
    local cfg
    cfg="$(fw_config_dir)/projects/$project/config.sh"
    _config_write_var "$cfg" domain "$domain_val"
    _config_write_var "$cfg" caddyfile "$caddyfile_val"
    domain="$domain_val"
    caddyfile="$caddyfile_val"

    # Splice this project's fragment into the shared aggregation file that the
    # root Caddyfile imports (the import glue docs/caddy.md leaves to the user),
    # and point *.<domain> at localhost so the browser resolves the sites. Both
    # must be in place BEFORE the regenerate below reloads a running Caddy, or
    # the reload wouldn't yet include this project's new site.
    _caddy_ensure_line "$etc/Caddyfile-fast-worktree" "import $caddyfile_val"
    _caddy_ensure_line "$etc/dnsmasq.conf" "address=/$domain_val/127.0.0.1"

    # Write this project's fragment (one site per live worktree) and reload a
    # running Caddy — reusing the same code the lifecycle commands trigger.
    regenerate_caddyfile

    # macOS wildcard-DNS resolver + a dnsmasq restart to pick up the new
    # address. Both need root, so sudo prompts for a password here.
    echo "Configuring the DNS resolver for $domain_val (sudo)…"
    sudo mkdir -p /etc/resolver
    printf 'nameserver 127.0.0.1\n' | sudo tee "/etc/resolver/$domain_val" >/dev/null
    sudo brew services restart dnsmasq

    echo "Enabled https://<name>.$domain_val for '$project'."
    echo "Verify DNS with: dscacheutil -q host -a name test.$domain_val   (expect 127.0.0.1)"
}

_caddy_remove() {
    [[ $# -eq 0 ]] ||
        { echo "Error: 'fw caddy remove' takes no arguments" >&2; _caddy_usage >&2; return 1; }
    [[ "$OSTYPE" == darwin* ]] ||
        { echo "Error: 'fw caddy remove' is macOS/Homebrew only (see docs/caddy.md)" >&2; return 1; }
    command -v brew >/dev/null 2>&1 ||
        { echo "Error: Homebrew ('brew') is required to locate the Caddyfile/dnsmasq paths (see docs/caddy.md)" >&2; return 1; }
    [[ -n "$domain" && -n "$caddyfile" ]] ||
        { echo "Error: caddy is not set up for '$project' (no domain/caddyfile) — nothing to remove" >&2; return 1; }

    local domain_val="$domain" caddyfile_val="$caddyfile"
    local etc
    etc="$(brew --prefix)/etc"

    # Tear down only this project's pieces: its fragment, its aggregation import
    # line, and its dnsmasq address line — other projects' entries are untouched.
    rm -f "$caddyfile_val"
    _caddy_remove_line "$etc/Caddyfile-fast-worktree" "import $caddyfile_val"
    _caddy_remove_line "$etc/dnsmasq.conf" "address=/$domain_val/127.0.0.1"

    # The fragment and import line are gone; reload the shared root so a running
    # Caddy drops this project's sites. We reload directly (not via
    # regenerate_caddyfile) because that no-ops once the layer is disabled — but
    # the config keys are still set here, deliberately (see below).
    _caddy_reload_if_running "${caddy_reload_file:-$etc/Caddyfile}"

    echo "Removing the DNS resolver for $domain_val (sudo)…"
    sudo rm -f "/etc/resolver/$domain_val"
    sudo brew services restart dnsmasq

    # Turn the layer off in config LAST: every step above is idempotent, so as
    # long as domain/caddyfile stay set an aborted run (e.g. sudo cancelled)
    # leaves 'fw caddy remove' able to finish the teardown on a retry.
    local cfg
    cfg="$(fw_config_dir)/projects/$project/config.sh"
    _config_delete_var "$cfg" domain
    _config_delete_var "$cfg" caddyfile
    domain=""
    caddyfile=""

    echo "Disabled local HTTPS for '$project'."
}
