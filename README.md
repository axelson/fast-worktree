# fast-worktree

A git worktree manager that clones from your main checkout instead of
rebuilding from scratch.

Creating a worktree normally means starting empty: install dependencies,
compile, set up a database, wait. `fast-worktree` copies all of that from your
main checkout, so a new worktree is ready to run in a few seconds.

```console
$ fw create cool-feature
# branch jason/cool-feature, build artifacts and database copied
# from the main checkout, env file written — ready to run.
```

## Why I built this

I wanted a worktree per task — one for the feature I'm on, one for a PR
review, one for whatever Claude is chewing on — but every new worktree required
minutes of deps, compile, and database setup before it was usable. The main
checkout I already keep built has all of that, so the fix was to clone from it.

This is written primarily for my personal use, but I share it in the hopes that
it can inspire others.

## Install

```bash
git clone https://github.com/axelson/fast-worktree.git ~/dev/fast-worktree
cd ~/dev/fast-worktree

# Put the entrypoint on your PATH (bash/zsh; adjust for fish)
export PATH="$PATH:$HOME/dev/fast-worktree"
```

You'll need bash 4+, git, tmux, and fzf — see [Requirements](#requirements)
for the full list.

The tool installs as `fast-worktree`. I alias it to `fw` (as this README
does):

```bash
alias fw=fast-worktree
```

On macOS the fast clone path uses a small bundled C helper that builds itself
the first time it's needed; `cc` from the Xcode Command Line Tools is enough.
If the C helper isn't compiled it falls back to `cp -cR` which is still
copy-on-write on APFS, just slower.

## Quickstart

From inside the repo you want worktrees for:

```bash
fw init                  # register this repo; writes a commented config template
fw create cool-feature   # new worktree: branch, artifacts, database, env
fw switch cool-feature   # attach its tmux session (bare `fw switch` = fzf picker)
fw list                  # worktrees, branches, dirty markers
fw delete cool-feature   # remove worktree, branch, and database
```

A minimal project config
(`~/.config/fast-worktree/projects/myapp/config.sh`), here for an
Elixir/Phoenix app:

```bash
repo_root=~/dev/myapp
branch_prefix=jason

# Build artifacts copied into each new worktree
cow_assets=(_build deps assets/node_modules)

# Postgres: setting db_source turns on per-worktree database cloning
db_source=myapp_dev

# What `fw start` / `fw check` run inside a worktree
start_cmd="mix phx.server"
check_cmd="mix check"

# Each worktree's env, derived from the FW_* contract
hook_worktree_env() {
    cat <<EOF
PORT=$((4000 + FW_PORT_SLOT))
DATABASE_URL=postgres://localhost/$FW_DB_NAME
EOF
}
```

Config is plain sourced bash — no parser, and hooks are ordinary shell
functions in the same file. `fw config` finds and edits these files without
memorizing paths: `fw config show` prints the effective merged config, `fw
config open` edits a layer in `$EDITOR`, and `fw config set KEY VALUE` / `get
KEY` / `unset KEY` read and write a single scalar value (e.g. `fw config set
stack_backend none`). Each takes an optional `--global` / `--repo` / `--project`
layer flag. See [`docs/configuration.md`](docs/configuration.md) for the layers
and the full key list.

## Core concepts

**The golden checkout.** Your main checkout, kept built and on `main` —
`fw sync` fast-forwards it and rebuilds. Every `fw create` bases its branch on
`main` and copies from it, and the tool never leaves it dirty or parked on
another branch. `fw refresh` re-copies a worktree's artifacts.

**Projects.** One install manages several repos. `fw init` registers the
current repo; after that the active project is derived from your working
directory on every call.

**Extending.** Hooks are ordinary shell functions in your project config
(`hook_post_create`, `hook_sync`, …). Any unknown subcommand runs the matching
executable from a per-project or global `commands/` directory, with the `FW_*`
environment exported.

**The env contract.** A worktree's identity — name, branch, port slot,
database name — lives in an env file inside the worktree, written as `FW_*`
variables at create time. Your `hook_worktree_env` derives the variables your
stack actually reads (a `PORT`, a `DATABASE_URL`) from those.

**Databases.** Setting `db_source` (a template database) turns on
per-worktree cloning, drop-on-delete, and `fw db`. Leave it unset and there
are no database steps at all. Postgres only. Set `db_template` to clone new
worktree DBs from a dedicated golden template (kept migrated by `hook_sync`)
instead of `db_source`, so live connections to `db_source` — like the main
checkout's running dev server — never block the clone; it falls back to
`db_source` when unset.

**Stacked branches.** `stack_backend` is `auto` | `graphite` | `none`.
`auto` uses Graphite when its CLI and metadata are present; `none` treats
every branch as a stack of one and hides the stack commands.

See the docs for the rest of the config keys and details on the ports:
- [`docs/configuration.md`](docs/configuration.md)
- [`docs/workflows.md`](docs/workflows.md)
- [`docs/architecture.md`](docs/architecture.md)

## Commands

Run `fw` with no arguments (or `fw help`) for all the commands.

**Projects**
`init`, `projects`, `switch-project` / `sp`.

**Worktree lifecycle**
`create`, `pull` (from a remote branch, PR number, or URL), `delete`, `clean`,
`refresh`, `regen-env`.

**Moving around**
`switch` / `sw`, `stack-switch` / `ss`, `tmux-open`, `last`, `menu`, `list`,
`info`.

**Archive**
`archive`, `restore`, `purge`, `list --archived`.

**Stacks**
`stack`, `up`, `down`, `top`, `bottom`, `restack`, `changes`, `sync`.

**Running the project**
`start`, `check`, `fix`, `db`, `stop`, `open`.

**GitHub / CI** (via `gh`)
`prs`, `pr` (`open` | `info` | `assign`), `checks`, `checks-wait`, `retry`,
`ci`, `comments`, `ticket`.

**Claude Code**
`claude`, `sessions close-old`, `skills`; plus `--model` and
`--claude "<prompt>"` on `create`/`pull`.

**Misc**
`shelve`, `open-file`, `handoff` (`save`/`show`/`done`/`resume`), `handoffs`,
`notify`, `logs`.

## Requirements

Supports macOS and Linux. Copies are near-instant on APFS (macOS) and on Linux
filesystems with reflink support (btrfs/XFS); elsewhere you still get the
workflow, just with plain copies.

- **bash ≥ 4**, **git**, **tmux**, **fzf** — the core set. macOS ships
  bash 3.2; `brew install bash`.
- **gh** — only for the PR/CI commands.
- **Graphite (`gt`)** — only when `stack_backend` resolves to `graphite`.
- **PostgreSQL** — only when `db_source` is set.
- **A C compiler** (Xcode CLT `cc`) — for the macOS fast-copy helper;
  optional, with a slower fallback.
- **fish** — only for the shipped completions
  (see [`docs/configuration.md`](docs/configuration.md#fish-completions)).

Optional local-HTTPS integration (`https://<name>.<domain>`) uses Caddy and
dnsmasq — setup in [`docs/caddy.md`](docs/caddy.md); unconfigured, worktrees
are reached at `http://localhost:<port>`.

## Contributing

I'm not really looking for pull requests — I may take a look, but mostly I'm
just sharing the code. If you want to dig in anyway,
[`DEVELOPMENT.md`](DEVELOPMENT.md) covers the test suite and conventions.

## License

fast-worktree is licensed under the **MIT License**. See
[`LICENSE`](LICENSE) for the full text.

### How `fw usage` counts cost

Session costs come from [`ccusage`](https://github.com/ryoppippi/ccusage), whose
per-session totals **already include that session's subagent transcripts**. The Go
transcript parser in `cmd/subagent-parser` therefore contributes only *relative
weights*: `fw usage` uses them to split each ccusage total into main-loop and
subagent shares, so `main + subagents` always equals the ccusage figure. Adding the
parser's costs on top of ccusage would count subagent spend twice.

Token accounting differs between the two transcript formats, so the parser treats
them differently (both behaviours verified against ccusage):

- **Main-loop transcripts** repeat one response's *total* usage on every
  content-block line, so entries are deduplicated on `(message.id, requestId)`.
- **Subagent transcripts** record each block's *incremental* usage on its own line,
  so every line counts.

Because a session forked or resumed from another replays the parent's messages
verbatim, each API response is credited to exactly one transcript (the
`response_owners` table). Without that, both transcripts count the replay and the
main-loop share is overstated.

Rates live in `modelRates` in `cmd/subagent-parser/main.go`, at Anthropic list
pricing: cache write is 2× input (the 1-hour cache TTL that Claude Code uses; the
5-minute TTL would be 1.25×) and cache read is 0.1× input. Since the figures are
only ever used as relative weights, what matters is that every model sits on the
same scale — a model priced on a different scale skews the split of any session
that mixes models. Model IDs missing from the map fall back to Opus pricing and are
reported on stderr during `fw usage sync`; add them when the warning appears.

### The `CR%` column

Cache reads are ~95% of all tokens in a typical worktree, and even at a 10:1
discount they drive most of the estimated cost — so `fw usage` reports what share
of each worktree's cost is cache reads. It is computed from the parser's weights
(the only place with a per-component token breakdown), not from the apportioned
ccusage dollars.

### Sessions outside your worktrees

Claude runs in plenty of directories that are not worktrees — other repos, the main
checkout's own subdirectories, `~/config`. Those sessions are tracked, but they are
listed under **Other projects** at the foot of `fw usage summary`, with their own
subtotal. They stay inside the summary's grand total, so no spend goes missing, and
they stay out of the own/review/misc breakdown, where they would attribute another
repo's cost to your worktree work. Each session's directory is matched against the
registered projects in the `projects` table; a session whose directory no project
claims gets the `USAGE_NO_PROJECT` sentinel (`lib/usage.sh`) and falls to the
**Other projects** side.

Name one by path:

```
fw usage .
fw usage ~/dev/some-other-repo
fw usage                     # outside a worktree, reports on $PWD
```

Paths are the referencing scheme because the stored name cannot be turned back into
one: Claude's project directory replaces both `/` and `_` with `-`, so
`~/dev/forks/geo_postgis` and a hypothetical `~/dev/forks/geo/postgis` mangle
identically. Transcripts record the real `cwd`, so `cmd/subagent-parser` reads it
and stores the mapping in a `projects` table — one short file scan per
newly-discovered project, no re-parse. A path naming a worktree resolves through the
same lookup the sync uses, so `fw usage .` inside a worktree and `fw usage <name>`
land on the same row.

### Cache rewrites

A steady turn writes only its delta into the prompt cache and reads the rest, so
cache writes are normally a rounding error. Sometimes a request instead re-writes
the whole prefix and reads only the ~23k shared system prefix — paying write price
(2x input) for tokens a warm cache would have served at 0.1x. `fw usage <worktree>`
counts those and reports them under the header when there are any.

A request counts as a cache rewrite when cache writes are more than 40% of its
cached prompt. Steady turns sit under 1% and rewrites above 85%, so the cut is
nowhere near either population. Two deliberate exclusions:

- **The transcript's first counted response.** It writes the system prompt and
  tool definitions into an empty cache — a cold start, not a rewrite. A resumed
  session's first own request is skipped by the same rule, since the responses it
  inherited are credited to the parent transcript.
- **Subagents.** A subagent runs to completion in one stretch, so its context
  cannot outlive the cache TTL; its large cache write is its cold start. Counting
  them would report one rewrite per agent. `cache_rewrites` is therefore always 0
  on `subagents` rows. The cost is that a subagent that somehow does lose its
  cache goes unreported — the fix for that would be per-request timestamps, not a
  different ratio.

The counter names the symptom, not the cause. TTL expiry explains some rewrites,
but plenty happen only minutes apart, so treat a high count as something to
investigate rather than as a diagnosis.

Adding the columns bumped `parserSchemaVersion` in `cmd/subagent-parser/main.go`.
Transcripts are skipped when their size and mtime match the last parse, so a new
column alone would leave old rows on its default forever — a version bump wipes
`main_loop` and lets the next sync re-parse it.

### Choosing a split basis: `--weight`

`SUB%` is sensitive to how you measure "share", because cache reads dominate the
token mix and each basis prices them differently. `--weight` picks the basis; the
session total and the `CR%` column are unaffected.

| Basis | Weighs each transcript by | Answers |
|---|---|---|
| `cost` (default) | estimated spend | "what would this have cost on the API" — matches ccusage's own basis, so the numbers stay reconcilable |
| `output` | output tokens only | "how much did each side actually produce" — ignores context size |
| `tokens` | input + output + cache write + cache read | a middle ground that still counts context |

Over a 30-day window the aggregate subagent share came to 31% by cost, 27% by
output tokens, and 25% by all tokens; individual worktrees move further (one went
from 51% to 38%). No basis is more correct than the others — they answer different
questions, so pick per question rather than looking for the true number.

`CR%` is always cost-based, whatever basis splits the total: it reports how much of
the spend is cache reads, which is a property of the session's token mix rather
than of the chosen weighting.

Each basis is a SQL view (`session_costs_cost`, `_output`, `_tokens`) built from the
same stored rows, so switching costs nothing and needs no re-sync — the parser
records every token component separately. Adding a basis means adding one case to
`_usage_weight_expr` in `lib/usage.sh`.
