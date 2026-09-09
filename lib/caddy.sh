# shellcheck disable=SC2154  # config globals ($domain, $caddyfile,
# $web_port_var, $caddy_reload_file, $worktrees_dir, $env_file) are assigned by
# load_config; WT_*
# are set by resolve_worktree.
#
# Caddy/dnsmasq opt-in HTTPS layer, plus `fw open`.
#
# Opt-in is the layer being fully configured — domain + caddyfile +
# web_port_var (see caddy_enabled); with any of the three missing it's off.
# When off, `fw open` builds http://localhost:<port> and no Caddyfile is ever
# touched. When on, each live worktree gets an
#     https://<name>.<domain>  ->  reverse_proxy localhost:<web-port>
# site, regenerated whenever the set of worktrees changes (create, delete,
# archive, regen-env), and `fw open` builds the https URL.
#
# A trailing wildcard `*.<domain>` catch-all is always appended (see
# _caddy_catchall_block): any hostname without its own site — a deleted or
# never-created worktree — falls through to a styled 404 instead of a TLS
# error. Caveat: a service worker cached by a previously-visited worktree can
# serve its own app shell before the request reaches Caddy, shadowing the 404;
# the page clears service workers/caches for the origin to heal that on the
# next visit, but a cache-first PWA may still win the first time.
#
# The proxy target and the localhost URL both come from the worktree's own env
# file: a project hook derives the real HTTP port from FW_PORT_SLOT and writes
# it under the key named by web_port_var, so core never hardcodes a port scheme
# (FW_PORT_SLOT is a slot, not a port — see docs/architecture.md).

# _worktree_web_port <wt_path> — the worktree's primary HTTP port: the value of
# the web_port_var key in its env file. Empty when web_port_var is unset or the
# key is absent.
_worktree_web_port() {
    [[ -n "$web_port_var" ]] || return 0
    local file="$1/$env_file"
    [[ -f "$file" ]] || return 0
    grep "^${web_port_var}=" "$file" | tail -1 | cut -d= -f2- || true
}

# caddy_enabled — true when the layer is fully configured: the domain opt-in
# plus the file path it writes and the port-var it proxies to.
caddy_enabled() {
    [[ -n "$domain" && -n "$caddyfile" && -n "$web_port_var" ]]
}

# _caddy_site_block <name> <port> — one Caddy site: an internal-TLS reverse
# proxy from https://<name>.<domain> to the worktree's local web port. When the
# proxy target is down, handle_errors serves an inline "not running" page (with
# the fw start hint) that polls until the server answers, instead of a bare 502.
_caddy_site_block() {
    local name="$1" port="$2"
    cat <<CADDYEOF
${name}.${domain} {
    tls internal
    reverse_proxy localhost:${port}
    handle_errors {
        header Content-Type text/html
        respond <<HTML
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="utf-8">
                <title>${name} — not running</title>
                <style>
                    body { font-family: -apple-system, system-ui, sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; background: #1a1a2e; color: #e0e0e0; }
                    .card { text-align: center; padding: 3rem; border-radius: 12px; background: #16213e; box-shadow: 0 4px 24px rgba(0,0,0,0.3); }
                    h1 { font-size: 1.5rem; margin: 0 0 0.5rem; color: #fff; }
                    .name { color: #e94560; }
                    code { background: #0f3460; padding: 0.3rem 0.6rem; border-radius: 4px; font-size: 0.95rem; }
                    p { color: #999; margin: 1rem 0 0; font-size: 0.85rem; }
                </style>
                <script>
                    setInterval(function() {
                        fetch(window.location.href, {method: 'HEAD', cache: 'no-store'})
                            .then(function(r) { if (r.ok) window.location.reload(); })
                            .catch(function() {});
                    }, 3000);
                </script>
            </head>
            <body>
                <div class="card">
                    <h1><span class="name">${name}</span> is not running</h1>
                    <div style="margin: 1.5rem 0;">Start it with: <code>fw start ${name}</code></div>
                    <p>This page will reload when the server is ready.</p>
                </div>
            </body>
            </html>
            HTML
    }
}

CADDYEOF
}

# _caddy_catchall_block <domain> — the wildcard site that catches every
# *.<domain> hostname with no specific worktree block (deleted, or never
# created) and serves a styled 404 instead of a bare TLS/connection error.
# Appended last so Caddy's exact-host match always prefers a real worktree's
# site; only unmatched hostnames fall through here. `tls internal` mints one
# wildcard cert from the same CA that `caddy trust` already trusts, so the page
# loads over HTTPS with no warning. The requested address is shown at runtime
# via {http.request.host} — the catch-all can't know the name at generation
# time the way _caddy_site_block does. respond needs the block form (status +
# `body` heredoc) because a Caddyfile heredoc opener must be the last token on
# its line, so `respond <status> <<HEREDOC` would misparse the status. A small
# script unregisters any service worker and clears caches for the dead origin,
# best-effort, so a previously-visited-then-deleted app (e.g. an offline PWA)
# stops shadowing the address on the next visit.
_caddy_catchall_block() {
    local domain="$1"
    cat <<CADDYEOF
*.${domain} {
    tls internal
    header Content-Type text/html
    respond 404 {
        body <<HTML
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="utf-8">
                <title>No worktree — {http.request.host}</title>
                <style>
                    body { font-family: -apple-system, system-ui, sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; background: #1a1a2e; color: #e0e0e0; }
                    .card { text-align: center; padding: 3rem; border-radius: 12px; background: #16213e; box-shadow: 0 4px 24px rgba(0,0,0,0.3); }
                    h1 { font-size: 1.5rem; margin: 0 0 0.5rem; color: #fff; }
                    .name { color: #e94560; }
                    code { background: #0f3460; padding: 0.3rem 0.6rem; border-radius: 4px; font-size: 0.95rem; }
                    p { color: #999; margin: 1rem 0 0; font-size: 0.85rem; }
                </style>
                <script>
                    if ('serviceWorker' in navigator) {
                        navigator.serviceWorker.getRegistrations()
                            .then(function(rs) { rs.forEach(function(r) { r.unregister(); }); })
                            .catch(function() {});
                    }
                    if (window.caches) {
                        caches.keys()
                            .then(function(ks) { ks.forEach(function(k) { caches.delete(k); }); })
                            .catch(function() {});
                    }
                </script>
            </head>
            <body>
                <div class="card">
                    <h1>No worktree for <span class="name">{http.request.host}</span></h1>
                    <div style="margin: 1.5rem 0;">It may have been deleted, or never created.</div>
                    <p>See live worktrees with <code>fw list</code>, or create one with <code>fw create &lt;name&gt;</code>.</p>
                </div>
            </body>
            </html>
            HTML
    }
}

CADDYEOF
}

# regenerate_caddyfile — rewrite $caddyfile from the current set of live
# worktrees (one site block each), then reload a running Caddy. A no-op unless
# the layer is configured, and any failure warns rather than aborting the
# lifecycle operation (create/delete/…) that triggered the regen.
#
# Write vs reload are decoupled: the site blocks are always WRITTEN to
# $caddyfile (this project's own file), but the RELOAD re-reads
# $caddy_reload_file (defaulting to $caddyfile). Since `caddy reload` replaces
# the entire running config, a multi-project setup points caddy_reload_file at
# a shared root Caddyfile that `import`s every project's file, so reloading one
# project doesn't collapse the config to just that project's sites.
regenerate_caddyfile() {
    # Batch callers (e.g. `fw clean`) set FW_SKIP_CADDY_REGEN to coalesce N
    # per-operation regens into a single one after their loop.
    [[ -n "${FW_SKIP_CADDY_REGEN:-}" ]] && return 0
    caddy_enabled || return 0

    local tmpfile
    tmpfile="$(mktemp)" || return 0

    local dir file name port
    for dir in "$worktrees_dir"/*/; do
        dir="${dir%/}"
        file="$dir/$env_file"
        [[ -f "$file" ]] || continue
        # Worktrees live at $worktrees_dir/<name> and FW_WORKTREE is written
        # from that same name, so the basename is the name without re-parsing
        # the env contract (read_worktree_env would clobber caller WT_* globals).
        name="${dir##*/}"
        port="$(_worktree_web_port "$dir")"
        [[ -n "$name" && -n "$port" ]] || continue
        _caddy_site_block "$name" "$port" >>"$tmpfile"
    done

    # The golden checkout is served at main.<domain> too, but it lives at
    # repo_root (not under worktrees_dir) and only has a site once `fw regen-env`
    # in the main checkout has written its env file with a web port.
    local main_port
    main_port="$(_worktree_web_port "$repo_root")"
    [[ -n "$main_port" ]] && _caddy_site_block main "$main_port" >>"$tmpfile"

    # The catch-all goes last so exact-host sites above always win; it's
    # unconditional (within the enabled layer) so an unknown OR deleted
    # worktree address gets the 404 even when no worktree exists at all.
    _caddy_catchall_block "$domain" >>"$tmpfile"

    mkdir -p "$(dirname "$caddyfile")" 2>/dev/null || true
    if ! mv "$tmpfile" "$caddyfile" 2>/dev/null; then
        rm -f "$tmpfile"
        echo "Warning: could not write Caddyfile at $caddyfile" >&2
        return 0
    fi

    # Reload only a Caddy that is actually running, so a create when Caddy is
    # stopped just leaves an updated file for the next start — and a stale
    # reload warning never looks like a failure of the triggering command.
    _caddy_reload_if_running "${caddy_reload_file:-$caddyfile}"
    return 0
}

# _caddy_reload_if_running <config> — hand <config> to a running Caddy so it
# re-reads the (possibly whole import chain) config; a no-op when Caddy isn't
# running, and a failed reload warns rather than aborting the caller. Shared by
# regenerate_caddyfile (lifecycle regens) and `fw caddy remove` (site teardown).
_caddy_reload_if_running() {
    local config="$1"
    if command -v caddy >/dev/null 2>&1 && pgrep -q caddy 2>/dev/null; then
        caddy reload --config "$config" 2>/dev/null ||
            echo "Warning: caddy reload failed" >&2
    fi
}

# cmd_open [name] — open a worktree's web URL in the browser. With the caddy
# layer enabled, https://<name>.<domain>; otherwise http://localhost:<web-port>.
cmd_open() {
    local wt_arg="" arg
    for arg in "$@"; do
        case "$arg" in
            -*) echo "Error: unknown flag '$arg'" >&2; return 1 ;;
            *) wt_arg="$arg" ;;
        esac
    done

    # --allow-main: `fw open` (from the golden checkout) / `fw open main` opens
    # the golden checkout's URL too.
    resolve_worktree --allow-main "$wt_arg" || return 1

    local url
    # Only build the https URL when the caddy layer is actually enabled — a
    # partial config (e.g. domain without caddyfile) never generated a site, so
    # https would be dead.
    if caddy_enabled; then
        # A worktree always has a site once caddy is enabled; the golden checkout
        # only does after `fw regen-env` gives it a web port — otherwise its
        # https URL would be dead, so guide the user there instead.
        if [[ "$WT_NAME" == "main" && -z "$(_worktree_web_port "$WT_PATH")" ]]; then
            echo "Error: the golden checkout has no site yet — run 'fw regen-env' in the main checkout first" >&2
            return 1
        fi
        url="https://${WT_NAME}.${domain}"
    else
        local port
        port="$(_worktree_web_port "$WT_PATH")"
        if [[ -z "$port" ]]; then
            echo "Error: no web port for '$WT_NAME' — set web_port_var (or enable the caddy layer: domain + caddyfile + web_port_var, for an HTTPS URL)" >&2
            return 1
        fi
        url="http://localhost:${port}"
    fi

    echo "Opening $url"
    _open_url "$url"
}
