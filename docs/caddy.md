# Local HTTPS with Caddy and dnsmasq

Opt-in layer that gives every worktree a stable HTTPS address:

```
https://<worktree-name>.<domain>  →  localhost:<that worktree's web port>
```

No port numbers to remember, and browser features that want a secure origin
(service workers, some cookies) work locally. Without it, `fw open` uses
`http://localhost:<port>` and nothing below is needed.

The setup here is macOS + Homebrew; on Linux the fast-worktree side is the
same, but wildcard DNS is up to you (the `/etc/resolver` mechanism is
macOS-only).

> **Automated per-project wiring.** Once the one-time global bootstrap below is
> in place, `fw caddy setup` does every per-project step for you — the config
> keys, the fragment, the shared `import` glue, the dnsmasq `address=` line, and
> the `/etc/resolver` + dnsmasq-restart sudo steps — and `fw caddy remove`
> reverses them. The manual procedure below is still the reference for what it
> produces (and for the global bootstrap it deliberately does not perform).

## How it works

fast-worktree owns the file named by the `caddyfile` config key: whenever the
set of worktrees changes (create, delete, archive, restore, regen-env, clean)
it rewrites the whole file — one reverse-proxy site per live worktree, using
Caddy's internal CA — and reloads Caddy if it's running. Don't hand-edit that
file or point it at a Caddyfile with other sites in it; anything you add is
overwritten on the next regen. If Caddy isn't running, the file is still
updated and simply takes effect on the next start.

Each site proxies to the port stored in the worktree's env file under the key
named by `web_port_var` — your `hook_worktree_env` writes it, so core never
assumes a port scheme. The golden checkout gets no site; `fw open main` uses
localhost.

## Deleted or unknown worktrees

The generated file always ends with a wildcard `*.<domain>` catch-all. Caddy
prefers an exact host match, so a live worktree's own site always wins; any
other subdomain — one whose worktree was deleted, or was never created — falls
through to the catch-all, which serves a styled **404** page (a sibling of the
"not running" page) instead of a bare TLS/connection error. It uses
`tls internal` for a wildcard certificate from the same CA `caddy trust`
already trusts, so it loads over HTTPS with no warning, and names the requested
address on the page via Caddy's `{http.request.host}` placeholder.

> **Service-worker caveat.** A worktree you had visited before deleting it may
> have registered a service worker on that origin. A cache-first service worker
> can serve its cached app shell *before the request reaches Caddy*, shadowing
> the 404. The 404 page unregisters service workers and clears caches for the
> origin as a best-effort self-heal, but a cache-first PWA may still win on the
> first visit after deletion (a reload then shows the 404). A brand-new,
> never-visited subdomain has no service worker, so the 404 always wins there.

## One-time setup

Install both tools:

```bash
brew install caddy dnsmasq
```

### dnsmasq — resolve `*.<domain>` to localhost

Using `myapp.local` as the domain throughout:

```bash
echo "address=/myapp.local/127.0.0.1" >> "$(brew --prefix)/etc/dnsmasq.conf"
sudo brew services start dnsmasq

sudo mkdir -p /etc/resolver
echo "nameserver 127.0.0.1" | sudo tee /etc/resolver/myapp.local
```

Verify (note: `ping`/`dscacheutil` use the system resolver, `nslookup` does
not — test with this):

```bash
dscacheutil -q host -a name test.myapp.local
# expect: ip_address: 127.0.0.1
```

### Caddy — serve and trust the certificates

```bash
sudo brew services start caddy   # root, so it can bind ports 80/443
caddy trust                      # install Caddy's local CA into the keychain
```

`caddy trust` is what makes browsers accept `https://*.myapp.local` without
warnings.

## fast-worktree config

All three keys must be set — with any missing, the layer is off:

```bash
# ~/.config/fast-worktree/projects/myapp/config.sh
domain=myapp.local
caddyfile=/opt/homebrew/etc/Caddyfile   # brew's default, so the service
                                        # starts with it after a reboot
web_port_var=PORT                       # env-file key holding the web port

hook_worktree_env() {
    cat <<EOF
PORT=$((4000 + FW_PORT_SLOT))
EOF
}
```

Pointing `caddyfile` at brew's default means this Caddy instance is dedicated
to fast-worktree. If you need Caddy for other things too, give fast-worktree
its own file and run a second instance (or an `import`) yourself — but
remember the reload uses this file as the *entire* config.

From then on it's automatic: `fw create cool-feature` adds the site,
`fw open` prints/opens `https://cool-feature.myapp.local`, `fw delete`
removes it.

## Multiple projects, one Caddy

Give each project a **distinct `domain`**. Two projects sharing one domain would
each emit a `*.<domain>` block (the reverse-proxy sites and the 404 catch-all),
and Caddy rejects duplicate site addresses — a `felt.local` project and an
`other.local` project coexist, two `app.local` projects do not.

`caddy reload` replaces the **entire** running config. So if two projects each
set `caddyfile` to their own file and each reloads it on create/delete, a
reload of one collapses the running config to just that project's sites and
drops the other's live sites until a full Caddy restart.

The fix is to keep each project's own write target but reload a shared root
file that `import`s them all, via the global `caddy_reload_file` key. The
write target (`caddyfile`) and the reload target (`caddy_reload_file`) are
decoupled: fast-worktree still writes each project's own file, but hands the
shared root to `caddy reload`, so the reload re-reads the whole import chain
and no project's sites get dropped.

```
/opt/homebrew/etc/Caddyfile               (brew service loads; caddy_reload_file points here)
  └─ import Caddyfile-fast-worktree
       ├─ import Caddyfile-fw-felt         (felt's caddyfile= write target)
       └─ import Caddyfile-fw-<project>    (another project's caddyfile= write target)
```

Set `caddy_reload_file` once, globally (`~/.config/fast-worktree/config.sh`),
since it's the same shared root for every project:

```bash
# ~/.config/fast-worktree/config.sh
caddy_reload_file=/opt/homebrew/etc/Caddyfile
```

and give each project its own write file:

```bash
# ~/.config/fast-worktree/projects/felt/config.sh
caddyfile=/opt/homebrew/etc/Caddyfile-fw-felt
```

Then wire the imports by hand once. The intermediate
`Caddyfile-fast-worktree` (the single line fast-worktree owns end-to-end is
each `Caddyfile-fw-<project>`; the import glue is yours):

```
# /opt/homebrew/etc/Caddyfile
import Caddyfile-fast-worktree

# /opt/homebrew/etc/Caddyfile-fast-worktree
import Caddyfile-fw-felt
import Caddyfile-fw-otherproject
```

The file handed to `caddy` — the root `caddy_reload_file` — must be named
`Caddyfile` (or you must pass an adapter), because Caddy auto-detects the
caddyfile adapter from that name. The nested imports can be named anything:
only the root is handed to `caddy`, and `import` just splices the referenced
files in as text.

When `caddy_reload_file` is unset (the default) it falls back to `caddyfile`,
so a single-project setup needs none of this.
