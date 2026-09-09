# apfsclone

A ~10-line C helper that clones a directory tree with one `clonefile(2)` syscall.

`fw create` copies build assets (`_build`, `deps`, `node_modules`, etc.)
from the main checkout into each new worktree. `cp -cR` does this copy-on-write
too, but walks the tree one entry at a time — ~13–17s for `node_modules` (113k
entries), and worse, it can fail partway and leave a silently incomplete tree.
`clonefile(2)` clones the whole subtree in a single syscall (~3–4s, fully CoW)
and is atomic: it either clones everything or fails cleanly, never partially.

No stock or Homebrew CLI exposes `clonefile(2)` on a directory, so `fw` ships
this tiny binary instead.

Originally from https://github.com/felt/vibing/tree/main/vince/gw-tool/utils

## Build

`fw` auto-builds the binary the first time it needs a CoW clone (quietly, once),
so no manual step is normally required. The compiled binary is gitignored; only
the source is checked in.

To build it yourself (from the repo root):

```sh
make apfsclone
# or directly:
cc -O2 -o scripts/apfsclone/apfsclone scripts/apfsclone/apfsclone.c
```

`cc` ships with the Xcode Command Line Tools — no Homebrew needed. If the binary
is missing and can't be built (no compiler, or a compile error), `fw` prints a
one-line note and falls back to `cp -cR`.

## Usage

```sh
apfsclone SRC DST
```

`DST` must not already exist, and `SRC`/`DST` must be on the same APFS volume.
On any failure (non-APFS, cross-volume, etc.) `fw` falls back to `cp -cR`.
