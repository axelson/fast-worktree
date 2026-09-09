# Development

[![CI](https://github.com/axelson/fast-worktree/actions/workflows/ci.yml/badge.svg)](https://github.com/axelson/fast-worktree/actions/workflows/ci.yml)

```bash
./tests/run                 # bats suite (DB tests skip without Postgres;
                            # tmux tests use an isolated socket)
./tests/run core            # just the `core`-tagged unit smoke tests, serial
./tests/run tests/integration/foo.bats   # a single file
./tests/lint                # shellcheck the whole tree — the pre-push gate
```

The suite needs brew bash (≥ 4) and bats-core. Database tests skip when no
Postgres is reachable; tmux tests run on an isolated socket so they never
touch your real sessions.

`tests/run` parallelizes across test files with `bats --jobs` when GNU
`parallel` is on PATH (`brew install parallel`) — roughly 14s → 9s on the unit
suite. It's optional: without `parallel`, the suite runs serially and passes
just the same. Override the lane count with `BATS_JOBS` (default 8); the gain
is capped by the largest single file, which bats can't split.

## Pre-commit hook

A fast gate lives in
[`scripts/git-hooks/pre-commit`](scripts/git-hooks/pre-commit) and blocks the
commit on any failure. It runs in ~2–3s by checking only what a commit is
likely to have broken:

- **shellcheck on the staged shell files only** (with `-x` for cross-file
  `source` resolution), not the whole tree. A typical commit lints in well
  under a second; staging the `fast-worktree` entrypoint is the slow case
  (~3.5s, since `-x` parses everything it sources).
- **the `core`-tagged unit smoke tests, run serially** (`./tests/run core`).

Both scopes are deliberately narrow, so the full `./tests/lint` and
`./tests/run` are the **pre-push** gate — run both before pushing. Tag a unit
file into the core set with a top-of-file `# bats file_tags=core` directive.

Install once per clone (the config lives in the shared `.git`, so one command
covers every worktree):

```bash
git config core.hooksPath scripts/git-hooks
```

Bypass it for a work-in-progress commit with `git commit --no-verify`.

Conventions (red-first TDD, the PATH-as-mocking-seam rule, test isolation,
ported-behavior audits, the per-step review protocol) are in
[`CONTRIBUTING.md`](CONTRIBUTING.md). The concepts and invariants the code
must preserve are in [`docs/architecture.md`](docs/architecture.md).

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs the bats
suite, shellcheck, and a real Postgres on Linux; a macOS job is defined and
enabled at open-sourcing.

## Building apfsclone

The macOS fast-copy helper is auto-built on first use, or ahead of time with:

```bash
make          # builds scripts/apfsclone/apfsclone
```

Only the C source is checked in; the binary is gitignored.
