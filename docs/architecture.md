# fast-worktree architecture

fast-worktree manages git worktrees for registered projects. This doc explains
the concepts and invariants someone changing the tool needs and cannot recover
from any single file. Commands and flags live in the usage text; the build
plan and its history live in `docs/plans/`.

## The golden build

The tool's reason to exist: each project's main checkout — the *golden
checkout* — is kept compiled and current, so creating a worktree is a copy,
not a build. Build artifacts are cloned copy-on-write from it, and the
development database is cloned from its template database in a single
`CREATE DATABASE … TEMPLATE` operation.

> Nothing may leave the golden checkout dirty or parked on another branch.

Every create bases its branch there and every clone copies from it, so any
operation that must touch the golden checkout temporarily (syncing trunk,
adopting a remote branch through a stack tool that checks it out) either
restores it before returning or refuses to start when it finds the checkout
dirty. `fw sync` will check trunk out itself when the tree is clean; it never
discards work to do so.

Copy-on-write is a strategy chain, fastest first, ending in a plain copy that
works everywhere. A failed strategy must remove its partial destination before
the next one runs — `cp` into an existing directory nests instead of
replacing, which silently corrupts the clone. For the same reason the copy is
idempotent: a pre-existing destination (refresh) is cleared first, and servers
running out of the worktree are stopped before its artifacts are replaced.

## Where state lives (and doesn't)

fw holds no state about "the active project". It is derived on every
invocation: an explicit `-p` flag, else the main repo root of the current
directory (git's common dir answers this from the main checkout, any linked
worktree, or a subdirectory of either) matched against the registered
projects, else `FW_PROJECT`, else the configured default. The registry itself
is just the per-project config directories under the user's config dir.

Because the project follows the current directory, "switching projects" is
nothing more than landing in the other project's directory; no mode or cache
has to be kept consistent.

A worktree's identity — name, branch, port slot, database names — lives in an
env file inside the worktree itself, written at create time. The golden
checkout is the one exception: it never goes through create, so its env file
(identity `main`, a port slot from the same pool, the default database) is
written by `fw regen-env` run in the main checkout, which allocates a slot when
none exists yet. That file lands in the tracked working tree, so it must be
gitignored to keep the checkout clean; regen warns when it isn't but never
edits ignore rules itself. Everything else fw remembers lives in flat files
beside the thing it describes: per-project state beside that project's
worktrees, cross-project state beside the registry in the config dir. There is
no other store.

## Configuration

Configs are plain sourced bash. Precedence, last wins: built-in defaults, the
global config, a repo-local config, the user's per-project config — the user's
file is deliberately last so a personal setting always beats one checked into
a repo. Hooks are ordinary functions defined in the same files.

Scalars follow last-wins, but hooks *chain*: a hook defined at several levels
runs at every level, least-specific-first, so a project extends rather than
silently erases a global hook. This composition happens once, at source time in
`load_config` — each level's definition is captured under a private name, and a
hook with two or more levels gets a dispatcher installed under its real name.
The invariant that keeps the blast radius small: **call sites stay name-only**.
`run_hook` and `_run_hook_recording` invoke a hook by its name and never learn
whether it is one function or a chain; a single-level hook keeps its own
function (no dispatcher wrapper), so it behaves exactly as before. All hooks chain by default
except `hook_tmux_windows`, which replaces (two window layouts collide); a
config flips its level with `fw_hook_replace` / `fw_hook_chain`. `run_hook`
advertises its failure policy so a fatal chain stops at the first failing level
while a warn/ignore chain runs every level; a warn chain names each failing
level by its scope (global/repo/project) rather than emitting one generic
message.

Two rules keep sourcing safe. User configs are sourced tolerantly: a config
whose final statement is a false conditional must not kill the tool, so
sourcing never propagates the file's exit status. And when fw needs one value
from a config before loading it for real (a project's `repo_root` during
resolution), it reads it in a subshell with the variable pre-cleared, so
nothing leaks in either direction.

## The environment contract

Hooks, custom subcommands, and `db_setup_cmd` all see the same environment:
the `FW_*` variables, exported through `_export_fw_project_env` and
`_export_fw_env`, plus the worktree's env file where one exists. That pair of
helpers is the single source of the contract — a variable added anywhere else
will reach some consumers and not others, which is the hardest kind of bug for
a user's hook to surface. The apply side has a single owner too:
`_run_in_worktree_env` (in `lib/hooks.sh`) is the one place that cds into a
worktree, exports the contract, sources the env file, and runs project code —
`start`/`check`/`fix`, `db_setup_cmd`, and `hook_worktree_env` all go through
it.

The env file follows the same split: fw writes only canonical `FW_*` keys, and
the project's `hook_worktree_env` appends project-shaped lines derived from
them. Two conventions give the keys meaning:

- Any key ending in `_PORT` is a real listening port that `fw stop` may act
  on — unless the project configures a `stop_port_vars` allowlist, which
  replaces the suffix convention entirely.
- `FW_PORT_SLOT` is a slot, not a port. fw allocates slots so that a slot and
  both of its neighbours are free, because hooks commonly derive several ports
  from one slot and adjacent slots would collide at the derived-port level.
  Slots are unique across **all registered projects**, not just the current
  one — different projects' hooks may derive real ports from the same base,
  so a slot claimed anywhere is unavailable everywhere.

Every hook runs through `run_hook`, which owns the defined-check, working
directory, environment, and an explicit failure policy — fatal, warn, or
ignore. A hook site never decides those four things inline; the one that did
turned a failing user hook into a silently aborted delete.

Tmux session birth runs project hook code too — `_ensure_tmux_session` fires
`hook_tmux_windows` the first time a session is created — so the `FW_*` contract
must be exported before `_ensure_tmux_session` at every call site
(`_export_fw_session_env` is the shared helper). For the golden checkout and
other projects' main sessions there is no worktree, so `FW_WORKTREE` is exported
empty: the documented signal a hook uses to give main a different (or no)
layout.

## The stack backend seam

Stacked-branch tooling sits behind a small dispatch layer. A backend answers
a fixed set of questions — `stack_branches`, `stack_parent`, `stack_track`,
`stack_adopt`, `stack_delete_branch`, `stack_restack`, `stack_sync` — and
everything fw does with stacks is presentation over those answers. The
backend is chosen per invocation: an explicit `stack_backend` setting, or
auto-detection that requires both the tool's metadata *and* its CLI to be
present, degrading to the `none` backend (a stack of one, based on trunk)
with a warning otherwise.

> A branch ref and its stack metadata must never diverge.

That invariant explains the seam's less obvious behaviour. Branch deletion —
including create's rollback — always goes through the backend, so metadata
dies with the ref; a plain `git branch -D` on a tracked branch strands a
phantom entry that navigation will keep walking to. Re-tracking a branch that
already has a recorded parent must reuse that parent, never trunk, or
recreating a mid-stack worktree silently flattens the stack. And the graphite
backend's reads go straight to its metadata store for speed, so branch names
are escaped into SQL — names may legally contain quotes.

Stack reads derive "the current branch" from the invoking directory, so they
first confirm that directory belongs to the project; otherwise fw would
happily report a foreign repo's branch as your stack.

## The failure model

The entrypoint runs under `set -euo pipefail`; library functions use explicit
return chains so they behave the same whether errexit is live or suppressed
by a caller's conditional. Multi-step operations that materialize a worktree
share one populate-and-rollback path, and a failure after the worktree exists
rolls everything back rather than stranding half-created state behind an
"already exists" error.

> fw never destroys what it did not create.

Rollback deletes the branch only when the create made it, and drops the
database only when the create cloned it — a pre-existing stale database is an
error to report, not something to adopt or clean up. Delete removes the
branch *recorded* at create time, never whatever happens to be checked out in
the worktree, and never trunk, even if a corrupt env file names it. Archive
refuses any state it could not restore — a missing recorded branch, a
checked-out branch that diverges from the recorded one, untracked binaries —
because its promise is a round-trip: restore pops the rescue commit so loose
files come back untracked, and consumed archive entries are retired so a
destructive purge can never resolve to a branch that is live again.

Worktree and project names are validated at every entry point that takes one,
including delete — a name is a directory component, and an unvalidated one
walks out of the worktrees directory. `main` is reserved: it names the golden
checkout — its tmux session, its port slot, and its `main.<domain>` site. The
golden checkout lives at repo_root, not under the worktrees directory, so
resolving it is opt-in (a caller asks for it explicitly); checkout-scoped
commands like open, regen-env, and start/stop accept it, while the destructive
lifecycle commands refuse it, because it resolves to repo_root and deleting or
archiving it would tear down the checkout everything else is cloned from.

## The testing seam

Every external tool is invoked by bare name, resolved via `PATH`. That is the
portability story (no hardcoded install prefixes) and the entire mocking
strategy: the test harness prepends a shim directory to `PATH`, so fake `gt`,
`gh`, and `tmux` win over the real ones. A single absolute path breaks both
properties silently — nothing fails until someone runs on a machine laid out
differently, or a test quietly starts exercising the real tool.

The suite assumes it is running on a developer's real machine and must leave
no trace: each test gets a scratch `HOME` (isolating git and XDG config), the
tmux shim pins everything to a dedicated test socket and the harness clears
`TMUX` so running the suite from inside a real session cannot leak into it,
and database tests use a reserved name prefix, dropped on teardown, skipping
entirely when Postgres is absent.
