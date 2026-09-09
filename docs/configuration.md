# Configuration reference

Config files are plain sourced bash — no parser, and hooks are ordinary shell
functions in the same file.

Files, in sourcing order (last wins, so a personal setting always beats one
checked into a repo):

1. defaults
2. global: `~/.config/fast-worktree/config.sh`
3. repo-local: `.fast-worktree/config.sh` (or `.fw/config.sh`) in the repo
4. per-project: `~/.config/fast-worktree/projects/<name>/config.sh`

All keys are optional except `repo_root`. Defaults are project-neutral, so an
unconfigured feature is simply inert.

## Editing config from the CLI

`fw config` finds, reads, and edits these files without memorizing paths. Each
subcommand takes an optional layer flag (`--global`, `--repo`, `--project`);
the default differs per subcommand.

| Command | Default layer | What it does |
|---------|---------------|--------------|
| `fw config` | — | List the layer paths for the current project. |
| `fw config open [--layer]` | project | Open a layer in `$EDITOR`, creating a commented template if missing. |
| `fw config show [--layer]` | merged | Print the effective merged config, or one layer raw. |
| `fw config get [--layer] KEY` | merged | Print one value: effective by default, or that layer's raw value. |
| `fw config set [--layer] KEY VALUE` | project | Set a scalar value in one layer. |
| `fw config unset [--layer] KEY` | project | Remove a scalar value from one layer. |

`get`/`set`/`unset` operate on the **managed scalar surface** — the scalar keys
in the table below. Array and associative-array keys (`cow_assets`,
`stop_port_vars`, `claude_prompt_flags`, …) are edited by hand via `fw config open`
and viewed with `fw config show`; `set`/`get`/`unset` refuse them.

Details worth knowing:

- **`set`** writes an idempotent, single-quoted assignment (`stack_backend='none'`),
  replacing an existing line in place (or uncommenting the template line) and
  preserving surrounding comments. It creates the target file as a commented
  template if it doesn't exist yet.
- **Validation** — `set` rejects an unknown key, and rejects an invalid value
  for keys that have a validator. `stack_backend` is validated against
  `auto | graphite | github | none`; a typo is caught at write time rather than
  surfacing later.
- **Shadow warning** — if you `set` a key in a lower-precedence layer while a
  higher one also assigns it, `set` warns that the higher layer still wins.
- **`get`** prints the bare value on stdout (scriptable). With a layer flag it
  exits non-zero (and prints nothing) when the key isn't set in that layer.
- **`unset`** deletes the assignment line and reports the value that now takes
  effect (from a lower layer, or the built-in default).

```console
$ fw config set stack_backend none
Set stack_backend = 'none' (project: ~/.config/fast-worktree/projects/myapp/config.sh)
$ fw config get stack_backend
none
$ fw config unset stack_backend
Unset stack_backend in project (~/.config/fast-worktree/projects/myapp/config.sh)
now resolves to 'auto' (defaults)
```

## Keys

| Key | Default | Purpose |
|-----|---------|---------|
| `repo_root` | — | Path to the golden checkout. Set by `fw init`. |
| `worktrees_dir` | `<repo-parent>/<project>-worktrees` | Where worktrees are created. |
| `branch_prefix` | `$USER` | Branch becomes `<prefix>/<name>` on `fw create`. |
| `default_project` | — | Project used when cwd matches nothing and no `-p`. |
| `github_username` | — | Your GitHub login (author filtering in `fw ci`). |
| `stack_backend` | `auto` | `auto` \| `graphite` \| `github` \| `none`. |
| `cow_assets` | `(_build deps assets/node_modules)` | Directories copy-on-write-cloned from the golden checkout. |
| `cache_dirs` | `()` | Absolute cache dirs removed by `fw clean --cache`. |
| `env_file` | `.env.worktree` | Worktree env-file path, relative to the worktree root. |
| `stop_port_vars` | `()` | Allowlist of env keys `fw stop` may kill. Empty ⇒ every `*_PORT` key. |
| `db_source` | — | Template database. Setting it enables per-worktree DB cloning + `fw db`. |
| `db_prefix` | `<project>_` | Prefix for cloned database names. |
| `db_setup_cmd` | — | Fallback DB setup when a template clone isn't used (e.g. `mix ecto.setup`). |
| `start_cmd` / `check_cmd` / `fix_cmd` | — | Commands run by `fw start` / `check` / `fix` in the worktree. |
| `ticket_pattern` | `/([a-zA-Z]+)-([0-9]+)` | Branch-name regex; capture groups join with `-`, uppercased. |
| `ticket_url` | — | Tracker URL template (`{id}`). Gates the ticket menu entries. |
| `domain` | — | Caddy HTTPS domain (opt-in, see [`caddy.md`](caddy.md)). Unset ⇒ `fw open` uses `http://localhost:<port>`. |
| `caddyfile` | — | Caddyfile path core rewrites when `domain` is set. |
| `caddy_reload_file` | `$caddyfile` | Path handed to `caddy reload`; point at a shared root Caddyfile for multiple projects (see [`caddy.md`](caddy.md)). |
| `web_port_var` | — | Env key holding a worktree's primary HTTP port (Caddy target / localhost URL). |
| `default_browser` | — | Browser for `fw open` / `open-file` (else the system default). |
| `editor` | `$EDITOR` | Editor for `fw open-file` on `.md` files; may carry args (`code -w`). |
| `ignored_checks` | `()` | CI check names `fw checks-wait` should not wait on. |
| `checks_poll_interval` | `30` | Seconds between `fw checks-wait` polls. |
| `notify_categories` | `(ci deploy fix alert)` | Valid categories for `fw notify`. |
| `team_members` | `()` | Roster for `fw pr assign` (`alias:github[:linear]`); else GitHub collaborators. |
| `handoff_dir` | `<worktrees_dir>/handoffs` | Where `fw handoff save` stores docs. |
| `switch_recent_days` | `7` | Recency window for the bare `fw switch` picker (`--all` ignores it). |
| `switch_refresh_secs` | `10` | Seconds between live re-enrichment of the `fw switch` picker while open (keeps the Claude badge current); `0` disables. |
| `switch_claude_refresh_secs` | `10` | Seconds between live refreshes of the cross-project `fw switch-claude` (`sc`) picker while open (keeps the Claude-session list current); `0` disables. Global-only. |
| `menu_order` | `()` | Labels floated to the top of `fw menu`, in order. |
| `claude_prompt_flags` | `()` | Bare flags for `create`/`pull` that launch Claude with a named prompt, e.g. `[review]="/pr-review"` makes `--review` work (assoc array). |
| `claude_model_aliases` | `()` | Shorthand names for `--model` (assoc array). |
| `claude_archive_dir` | `<config>/projects/<project>/claude-archive` | Where Claude artifacts are copied on delete. |
| `claude_archive_paths` | `()` | `src:dest` file/dir entries preserved on archive/delete, restored on `restore`. |
| `claude_summary_file` | `.fw-summary.md` | Per-worktree summary file, archived on delete. |

## A full example: Phoenix project

Everything a typical Elixir/Phoenix + Postgres project needs, in
`~/.config/fast-worktree/projects/myapp/config.sh`. The env hook assumes your
`config/dev.exs` reads `PORT` and `DATABASE_URL` (and `config/test.exs` reads
`TEST_DATABASE_URL`).

```bash
repo_root=~/dev/myapp
branch_prefix=jason
stack_backend=auto

# Build artifacts copied from the golden checkout into each new worktree
cow_assets=(_build deps assets/node_modules)

# Per-worktree databases, cloned from the dev DB as a template
db_source=myapp_dev
db_setup_cmd="mix ecto.setup"    # fallback when a template clone can't be used

# What `fw start` / `fw check` / `fw fix` run inside the worktree
start_cmd="mix phx.server"
check_cmd="mix test"
fix_cmd="mix format"

# `fw open` needs to know which env key holds the web port
web_port_var=PORT

# Optional local HTTPS — https://<name>.myapp.local (see caddy.md)
# domain=myapp.local
# caddyfile=/opt/homebrew/etc/Caddyfile

# --- Hooks. Each runs with the FW_* contract exported; the worktree-scoped
# --- ones run cd'd into the worktree with its env file applied.

# Project-shaped env, appended to the worktree's .env.worktree at create time
hook_worktree_env() {
    cat <<EOF
PORT=$((4000 + FW_PORT_SLOT))
DATABASE_URL=ecto://postgres@localhost/$FW_DB_NAME
TEST_DATABASE_URL=ecto://postgres@localhost/$FW_TEST_DB_NAME
EOF
}

# Bring over files git doesn't track that a fresh worktree needs
hook_post_create() {
    if [[ -f "$FW_REPO_ROOT/.env" ]]; then
        cp "$FW_REPO_ROOT/.env" .env
    fi
}

# The build step of `fw sync` — runs in the golden checkout after trunk
# fast-forwards, so freshly created worktrees clone a current build
hook_sync() {
    mix deps.get
    mix compile
    mix ecto.migrate
}
```

With that in place: `fw create foo` gives you a worktree on branch
`jason/foo` with `_build`/`deps`/`node_modules` copied, a `myapp_foo`
database cloned from `myapp_dev`, and an env file wiring the app to its own
port and database; `fw start` runs the server on that port; `fw delete foo`
tears it all down.

## Hooks

Optional shell functions defined in a project config, each run with the
`FW_*` environment:

| Hook | When |
|------|------|
| `hook_worktree_env` | Appending project-shaped lines to a new worktree's env file |
| `hook_pre_db` | Before the database step during create |
| `hook_post_create` | After a worktree is created (setup file copies, symlinks, etc.) |
| `hook_post_pull` | After a worktree is created from a remote or local branch/PR |
| `hook_pre_delete` | Before a worktree is deleted |
| `hook_post_switch` | After switching into a worktree |
| `hook_sync` | The build step of `fw sync` (unrecognized `sync` flags pass through) |

Hooks, custom commands, and `db_setup_cmd` all see the same environment: the
`FW_*` variables plus the worktree's env file.

## The env contract in detail

Core writes only canonical `FW_*` keys to the worktree's env file:
`FW_WORKTREE`, `FW_BRANCH`, `FW_PORT_SLOT`, `FW_DB_NAME`,
`FW_TEST_DB_NAME`. Your `hook_worktree_env` appends project-shaped lines
derived from them.

Two conventions give the keys meaning:

- Any env key ending in `_PORT` is a real listening port that `fw stop` may
  kill (narrow this with `stop_port_vars`).
- `FW_PORT_SLOT` is a *slot* (100–999), not a port — allocated so the slot
  and both neighbours are free, since hooks commonly derive several ports
  from one slot. Slots are unique across all registered projects, so two
  projects deriving ports from the same base never collide.

## Custom commands

Any unknown subcommand `fw foo` dispatches to the first executable named
`foo` in `~/.config/fast-worktree/projects/<project>/commands/`, then
`~/.config/fast-worktree/commands/`. It runs with the project `FW_*`
environment exported (`FW_PROJECT`, `FW_REPO_ROOT`, `FW_WORKTREES_DIR`, plus
`FW_BIN` to re-invoke the tool and `FW_BROWSER`). This is how team- or
personal-specific features live outside core.

## Menu providers

`fw menu` is an fzf quick-actions popup. A project extends it by defining
`menu_extra_entries()` (emitting `label<TAB>command` lines) and ordering it
with `menu_order=(…)` in config (listed labels float to the top, in order).

## Stack backends

`stack_backend` is `auto` (default) | `graphite` | `github` | `none`:

- **`auto`** uses `graphite` when both its metadata
  (`.graphite_metadata.db`) and CLI are present, else degrades to `none`.
- **`graphite`** drives stack navigation, tracking, and restacking through
  `gt`.
- **`none`** is a stack of one, based on trunk; stack commands hide
  themselves.
- **`github`** (GitHub's stacked PRs) is planned post-launch.

Stack operations (`up`/`down`/`top`/`bottom`, `stack`, `stack-switch`,
`restack`, `changes`) are presentation over the backend.

## Fish completions

Completions delegate every dynamic value to `<cmd> _complete <what>`, so they
read your live config and never go stale.

The easy way is `fw setup`, which symlinks the shipped completion file into
fish's completions directory under the name you invoked it as, and — if you
don't have one yet — drops a commented-out global config template at
`~/.config/fast-worktree/config.sh`:

```fish
fw setup          # links ~/.config/fish/completions/fw.fish
exec fish         # reload so completions take effect
```

Pass `--name` to install under a different name (e.g. `fw setup --name ftw`).
An existing global config is never overwritten.

To install by hand instead, symlink the file yourself, named after whatever
alias you call the tool:

```bash
# If your alias is `fw`
ln -s ~/dev/fast-worktree/completions/fast-worktree.fish \
      ~/.config/fish/completions/fw.fish
```

The completions bind to the command matching the file's basename, so the
symlink name is the command they complete — no editing needed. Name it
`fast-worktree.fish` if you call the tool by its full name.
