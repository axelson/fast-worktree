# Contributing to fast-worktree

Conventions for changing the `fast-worktree` tool (entrypoint + `lib/` +
`tests/`). The invariants the code must preserve are in
`docs/architecture.md`; current status and next steps are in
`docs/plans/2026-08-16-remaining-work.md`.

## The development loop

Red-first TDD: write the failing test, watch it fail for the right reason,
then write the minimal code to pass. Run the suite with `./tests/run` (a
single file: `./tests/run tests/integration/foo.bats`) and gate every commit
with `./tests/lint`.

Tests are killed after `BATS_TEST_TIMEOUT` (60s default, override via env) so
a hang fails fast and names its test instead of stalling the run.

Shellcheck directives are fine where the architecture demands them (sourced
config globals, intentional subshell peeks) — add a one-line justification
with each.

## The PATH seam

Invoke every external tool by bare name (`git`, `gt`, `gh`, `tmux`, `lsof`,
`createdb`). PATH resolution is simultaneously the portability story and the
entire test-mocking strategy: the harness prepends `tests/shims/` so fake
tools win. An absolute path defeats both, silently.

## Writing tests

The suite runs on a developer's real machine and must leave no trace. The
harness (`tests/test_helper.bash`) provides the isolation — use it:

- `isolate_env` gives each test a scratch `HOME`/`XDG_CONFIG_HOME`/
  `XDG_CACHE_HOME`, puts `tests/shims/` first on PATH, and clears `$TMUX`
  (the suite itself often runs inside tmux).
- tmux goes through the shim onto a dedicated test socket. Any test file
  whose commands may create a session needs the kill-server teardown:

  ```bash
  teardown() { "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true; }
  ```

- Database tests use `fwtest_`-prefixed names, drop them in `teardown`, and
  skip when Postgres is absent (`pg_isready -q || skip`).
- A background daemon must detach from bats' file descriptors or the whole
  run hangs waiting on it:

  ```bash
  my-server </dev/null >/dev/null 2>&1 3>&- &
  ```

  and kill it in `teardown`.
- A test-local shim for a tool the entrypoint itself uses (e.g. `realpath`,
  which resolves `$0` at startup) must pass unrelated calls through to the
  real tool (`command -p realpath "$@"`) and fail only for the targeted
  path — a blanket-failing shim breaks the tool before the code under test
  runs.
- bats runs with `functrace` on, so a `trap … RETURN` set inside a function
  fires on every nested function return under it. Don't port such traps;
  use a scratch dir plus explicit cleanup.
- Libs are sourced from inside bats `setup()`, where a bare `declare -A`
  is function-local: the array silently degrades to an indexed one
  ("value too great for base" on string keys). Libs must use `declare -gA`.
- A "tool is missing" test can't just drop the shim: macOS ships `jq` and
  `sqlite3` in `/usr/bin`. Build a PATH of symlinks to everything but the
  target tool — including `bash`, which the entrypoint re-execs through
  PATH at startup.
- Confirm *why* a red test is red before implementing: a missing function
  exits 127, which satisfies any nonzero-status assertion vacuously, and a
  too-permissive shim can make a test pass with no implementation at all.

## Porting from felt-worktree

Read the legacy implementation before porting a feature, and audit the port
against it: list what the legacy code enforced (guards, orderings, cleanup)
and where the port re-establishes each one. TDD alone encodes only the
behaviors you already thought of — the legacy code is the paid-for inventory
of edge cases, and the one feature ported without this audit produced the
project's worst review batch.

## Finishing a step

Each major step ends with an adversarial review pass (multiple independent
finder angles, then verification of candidates); confirmed findings are
fixed — test-first — before the next step starts. Fixes that change
user-visible behavior land with the rest but get called out explicitly in
the summary.

## Adding a command

Update `usage()` and the dispatch case in `fast-worktree` together — a
command in one and not the other is a bug. Document aliases in the usage
line (e.g. `(sw)`). Fish completions and the README are regenerated at
cutover (tracked in the remaining-work plan) rather than per command.
