# shellcheck disable=SC2154  # config globals (repo_root, …) are assigned by
# load_config.
#
# `fw clean` — remove worktrees whose branch has been merged and deleted on
# the remote. Mergedness uses git's own signal: after `git fetch --prune`, a
# branch whose upstream was deleted reports `[gone]`. This is exactly the
# legacy felt-worktree signal and needs neither a stack tool nor the GitHub
# API.
#
# Removal routes through cmd_delete, so every delete guard applies — in
# particular a worktree with uncommitted changes is skipped, never destroyed.
# (The legacy clean deleted unconditionally; requiring a clean tree here is a
# deliberate safety improvement.) A worktree whose live HEAD no longer matches
# its recorded branch — the user reused it for other work, or detached it — is
# skipped too: the recorded branch being [gone] says nothing about the branch
# checked out now, and cmd_delete would destroy that live work along with it.
# Caddyfile regeneration IS carried over (through cmd_delete), but coalesced to
# a single regen after the batch via FW_SKIP_CADDY_REGEN, matching the legacy
# clean's one regen.
#
# `fw clean --cache` is carried over, but generalized off felt: instead of a
# hard-coded Render cache it removes each directory listed in the `cache_dirs`
# config array, then exits WITHOUT the worktree cleaning (the legacy `--cache`
# was clear-and-exit). See clean_cache below. The other felt-only extras of the
# legacy command — loose merged-branch pruning and emitting a `cd` line — are
# intentionally not carried over.

cmd_clean() {
    if [[ $# -gt 0 ]]; then
        if [[ "$1" == "--cache" && $# -eq 1 ]]; then
            clean_cache
            return
        fi
        echo "Error: unknown argument '$1' (usage: fw clean [--cache])" >&2
        return 1
    fi

    if git -C "$repo_root" remote | grep -qx origin; then
        echo "Fetching and pruning remote refs..."
        if ! git -C "$repo_root" fetch --prune origin; then
            echo "Error: fetch failed — refusing to judge mergedness from stale state" >&2
            return 1
        fi
    fi

    # One pass over local branches records each branch's upstream track state
    # (`[gone]` once its upstream was pruned), parsed once and reused per
    # worktree below instead of a for-each-ref per branch.
    local -A track_of=()
    local ref tk
    while IFS=$'\t' read -r ref tk; do
        [[ -n "$ref" ]] || continue
        track_of["$ref"]="$tk"
    done < <(git -C "$repo_root" for-each-ref \
        --format='%(refname:short)%09%(upstream:track)' refs/heads 2>/dev/null)

    local to_clean=() name branch head
    while IFS=$'\t' read -r name branch; do
        [[ -n "$branch" ]] || continue
        [[ "${track_of[$branch]:-}" == "[gone]" ]] || continue

        # Only judge (and later delete) the recorded branch when it's actually
        # the one checked out. A reused worktree — different live branch, or a
        # detached HEAD — is left untouched.
        head="$(git -C "$worktrees_dir/$name" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
        if [[ -z "$head" ]]; then
            echo "Skipping $name: detached HEAD (recorded branch $branch)" >&2
            continue
        fi
        if [[ "$head" != "$branch" ]]; then
            echo "Skipping $name: live branch $head differs from recorded $branch" >&2
            continue
        fi
        to_clean+=("$name")
    done < <(worktree_names_branches)

    if [[ ${#to_clean[@]} -eq 0 ]]; then
        echo "No merged worktrees to clean."
        return 0
    fi

    echo "Merged worktrees to remove:"
    printf '  - %s\n' "${to_clean[@]}"
    echo
    local answer
    read -rp "Remove these worktrees? [y/N] " answer
    if [[ "$answer" != "y" && "$answer" != "yes" ]]; then
        echo "Aborted."
        return 0
    fi

    local removed=0
    # Suppress each cmd_delete's own Caddyfile regen; regenerate once after the
    # batch (below) so N deletes cost one rewrite+reload, not N. Read via dynamic
    # scope inside cmd_delete → regenerate_caddyfile, which shellcheck can't see.
    # shellcheck disable=SC2034
    local FW_SKIP_CADDY_REGEN=1
    for name in "${to_clean[@]}"; do
        if cmd_delete "$name"; then
            removed=$((removed + 1))
        else
            echo "Skipped $name — remove it anyway with: fw delete --force $name" >&2
        fi
    done
    unset FW_SKIP_CADDY_REGEN

    git -C "$repo_root" worktree prune 2>/dev/null || true
    git -C "$repo_root" gc --quiet 2>/dev/null || true

    # One Caddyfile regen for the whole batch (a no-op unless the domain layer
    # is configured).
    regenerate_caddyfile

    echo "Cleaned $removed worktree(s)."
    return 0
}

# clean_cache — `fw clean --cache`: rm -rf each directory in the `cache_dirs`
# config array, then return (no worktree cleaning). Each entry is validated
# first: an empty entry, a non-absolute path, or one that canonicalizes to `/`
# or $HOME is refused (nonzero rc, offending entry named, nothing removed after
# it). A nonexistent dir is fine — it's already clean.
clean_cache() {
    if [[ ${#cache_dirs[@]} -eq 0 ]]; then
        echo "No cache_dirs configured for this project — nothing to clear."
        return 0
    fi

    local home_canon dir canon
    home_canon="$(realpath "$HOME" 2>/dev/null || echo "$HOME")"

    for dir in "${cache_dirs[@]}"; do
        if [[ -z "$dir" ]]; then
            echo "Error: refusing to remove an empty cache_dirs entry" >&2
            return 1
        fi
        if [[ "$dir" != /* ]]; then
            echo "Error: cache_dirs entry is not an absolute path: '$dir'" >&2
            return 1
        fi
        # Nonexistence first: a nonexistent path is already clean, and realpath
        # fails on nonexistent paths on macOS — canonicalizing it would wrongly
        # trip the realpath-failure refusal below.
        if [[ ! -e "$dir" ]]; then
            echo "  $dir — already clean"
            continue
        fi
        # The entry exists, so realpath MUST resolve it. If it can't, refuse
        # rather than falling back to the unresolved literal — a non-canonical
        # entry ($HOME/, x/../..) could otherwise slip past the /$HOME guard.
        if ! canon="$(realpath "$dir" 2>/dev/null)"; then
            echo "Error: refusing '$dir' — cannot canonicalize an existing path" >&2
            return 1
        fi
        if [[ "$canon" == "/" || "$canon" == "$home_canon" ]]; then
            echo "Error: refusing to remove '$dir' (resolves to $canon)" >&2
            return 1
        fi
        echo "  Removing $dir ..."
        rm -rf "$dir"
    done

    echo "Cache cleared."
    return 0
}
