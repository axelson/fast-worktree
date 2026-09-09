# shellcheck disable=SC2154  # config globals ($repo_root, $cow_assets) are
# assigned by load_config.
#
# Copy-on-write cloning of build artifacts from the golden checkout.
#
# Strategy chain, fastest first:
#   apfsclone  — single clonefile(2) syscall, atomic (macOS, built from
#                scripts/apfsclone)
#   cp -cR     — per-file clonefile (macOS)
#   cp -a --reflink=auto — reflink where the filesystem supports it (Linux
#                btrfs/XFS), silent plain copy elsewhere
#   cp -a      — plain copy, works everywhere

: "${APFSCLONE:=${SCRIPT_DIR:-.}/scripts/apfsclone/apfsclone}"

# _ensure_apfsclone
# The apfsclone helper ships as source only ($APFSCLONE.c); build it on first
# use so a fresh checkout gets the fast clonefile(2) path without a manual
# `make`. Compile quietly, at most once per process — a failed attempt falls
# back to cp rather than retrying for every asset. Returns 0 when $APFSCLONE is
# runnable, non-zero (with a one-line note) otherwise.
_apfsclone_build_attempted=""
_ensure_apfsclone() {
    [[ -x "$APFSCLONE" ]] && return 0
    # clonefile(2) is Darwin-only; elsewhere the cp reflink path is used.
    [[ "$OSTYPE" == darwin* ]] || return 1
    [[ -n "$_apfsclone_build_attempted" ]] && return 1
    _apfsclone_build_attempted=1
    local src="$APFSCLONE.c"
    [[ -f "$src" ]] || return 1
    if ! command -v cc >/dev/null 2>&1; then
        echo "Note: apfsclone unavailable (no C compiler on PATH); using slower cp -cR." \
            "Install the Xcode Command Line Tools for faster clones." >&2
        return 1
    fi
    # Compile to a temp file in the same directory, then atomically rename into
    # place: two concurrent first-ever runs (two simultaneous creates on a fresh
    # checkout) must not interleave writes to the live binary. mv within one
    # filesystem is atomic; a failed compile leaves no partial artifact.
    local dir tmp
    dir="$(dirname "$APFSCLONE")"
    mkdir -p "$dir"
    if ! tmp="$(mktemp "$dir/apfsclone.tmp.XXXXXX" 2>/dev/null)"; then
        echo "Note: apfsclone build failed (could not create temp file); using slower cp -cR." >&2
        return 1
    fi
    if cc -O2 -o "$tmp" "$src" 2>/dev/null && mv -f "$tmp" "$APFSCLONE" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp"
    echo "Note: apfsclone build failed; using slower cp -cR." >&2
    return 1
}

# _cow_copy <src> <dest>
# A failed strategy may leave a partial $dest; it must be removed before the
# next strategy, or cp copies src INTO the leftover dir (nested _build/_build).
_cow_copy() {
    local src="$1" dest="$2"
    # Idempotent: a pre-existing dest (refresh) would make cp nest into it.
    if [[ -e "$dest" ]]; then
        rm -rf "$dest"
    fi
    if [[ "$OSTYPE" == darwin* ]]; then
        _ensure_apfsclone || :   # a build failure just means we fall back to cp
        if [[ -x "$APFSCLONE" ]]; then
            "$APFSCLONE" "$src" "$dest" 2>/dev/null && return 0
            rm -rf "$dest"
        fi
        cp -cR "$src" "$dest" 2>/dev/null && return 0
        rm -rf "$dest"
        echo "Warning: CoW clone failed for $src — falling back to a full copy (slow)" >&2
        cp -a "$src" "$dest"
    else
        # reflink where the filesystem supports it, silent plain copy elsewhere
        cp -a --reflink=auto "$src" "$dest"
    fi
}

# cmd_refresh [name] — re-clone build artifacts from the golden checkout.
cmd_refresh() {
    resolve_worktree "${1:-}" || return 1
    # Never rm -rf build artifacts under a running dev server.
    cmd_stop "$WT_NAME"
    echo "Re-cloning assets into $WT_NAME from the golden checkout..."
    clone_assets "$WT_PATH"
    echo "Refreshed $WT_NAME"
    return 0
}

# clone_assets <dest_worktree_path>
# Clones every dir in cow_assets that exists under repo_root.
clone_assets() {
    local dest="$1"
    local dir
    for dir in ${cow_assets[@]+"${cow_assets[@]}"}; do
        if [[ -d "$repo_root/$dir" ]]; then
            echo "Cloning $dir..."
            mkdir -p "$dest/$(dirname "$dir")"
            _cow_copy "$repo_root/$dir" "$dest/$dir"
        fi
    done
    return 0
}
