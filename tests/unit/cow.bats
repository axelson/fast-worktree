load ../test_helper

setup() {
    isolate_env
    source "$FW_ROOT/lib/config.sh"
    source "$FW_ROOT/lib/cow.sh"
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    load_config myproj
}

@test "clone_assets: copies each configured asset dir into the destination" {
    mkdir -p "$repo_root/_build/dev" "$repo_root/deps/somelib"
    echo compiled >"$repo_root/_build/dev/beam"
    echo dep >"$repo_root/deps/somelib/mix.exs"
    cow_assets=(_build deps)
    mkdir -p "$BATS_TEST_TMPDIR/dest"

    clone_assets "$BATS_TEST_TMPDIR/dest"

    [ "$(cat "$BATS_TEST_TMPDIR/dest/_build/dev/beam")" = "compiled" ]
    [ "$(cat "$BATS_TEST_TMPDIR/dest/deps/somelib/mix.exs")" = "dep" ]
}

@test "clone_assets: silently skips asset dirs missing from the golden checkout" {
    mkdir -p "$repo_root/_build"
    touch "$repo_root/_build/marker"
    cow_assets=(_build deps assets/node_modules)
    mkdir -p "$BATS_TEST_TMPDIR/dest"

    run clone_assets "$BATS_TEST_TMPDIR/dest"
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/dest/_build/marker" ]
    [ ! -e "$BATS_TEST_TMPDIR/dest/deps" ]
}

@test "clone_assets: creates parent directories for nested asset paths" {
    mkdir -p "$repo_root/services/app/_build"
    touch "$repo_root/services/app/_build/marker"
    cow_assets=(services/app/_build)
    mkdir -p "$BATS_TEST_TMPDIR/dest"

    clone_assets "$BATS_TEST_TMPDIR/dest"

    [ -f "$BATS_TEST_TMPDIR/dest/services/app/_build/marker" ]
}

@test "clone_assets: prefers the apfsclone binary when present" {
    # The apfsclone strategy is Darwin-only (_cow_copy gates it on $OSTYPE), so
    # force the Darwin branch — otherwise on Linux _cow_copy takes the reflink
    # path and never consults $APFSCLONE. The fake binary itself is portable.
    OSTYPE=darwin20
    cat >"$BATS_TEST_TMPDIR/fake-apfsclone" <<'EOF'
#!/bin/sh
cp -R "$1" "$2" && touch "$2/.via-apfsclone"
EOF
    chmod +x "$BATS_TEST_TMPDIR/fake-apfsclone"
    APFSCLONE="$BATS_TEST_TMPDIR/fake-apfsclone"
    mkdir -p "$repo_root/_build"
    touch "$repo_root/_build/marker"
    cow_assets=(_build)
    mkdir -p "$BATS_TEST_TMPDIR/dest"

    clone_assets "$BATS_TEST_TMPDIR/dest"

    [ -f "$BATS_TEST_TMPDIR/dest/_build/.via-apfsclone" ]
}

@test "clone_assets: prints per-asset progress" {
    mkdir -p "$repo_root/_build"
    cow_assets=(_build)
    mkdir -p "$BATS_TEST_TMPDIR/dest"

    run clone_assets "$BATS_TEST_TMPDIR/dest"
    [[ "$output" == *"Cloning _build"* ]]
}

@test "clone_assets: a partial destination from a failed strategy is not nested into" {
    # Fake apfsclone that creates the dest dir, then fails — the next
    # strategy must not copy src INTO the leftover dir (_build/_build).
    cat >"$BATS_TEST_TMPDIR/partial-apfsclone" <<'EOF'
#!/bin/sh
mkdir -p "$2"
exit 1
EOF
    chmod +x "$BATS_TEST_TMPDIR/partial-apfsclone"
    APFSCLONE="$BATS_TEST_TMPDIR/partial-apfsclone"
    mkdir -p "$repo_root/_build"
    touch "$repo_root/_build/marker"
    cow_assets=(_build)
    mkdir -p "$BATS_TEST_TMPDIR/dest"

    clone_assets "$BATS_TEST_TMPDIR/dest"

    [ -f "$BATS_TEST_TMPDIR/dest/_build/marker" ]
    [ ! -e "$BATS_TEST_TMPDIR/dest/_build/_build" ]
}

@test "clone_assets: an empty cow_assets array is a no-op" {
    cow_assets=()
    mkdir -p "$BATS_TEST_TMPDIR/dest"

    run clone_assets "$BATS_TEST_TMPDIR/dest"
    [ "$status" -eq 0 ]
}

@test "clone_assets: falls back to cp when apfsclone fails" {
    printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/broken-apfsclone"
    chmod +x "$BATS_TEST_TMPDIR/broken-apfsclone"
    APFSCLONE="$BATS_TEST_TMPDIR/broken-apfsclone"
    mkdir -p "$repo_root/_build"
    touch "$repo_root/_build/marker"
    cow_assets=(_build)
    mkdir -p "$BATS_TEST_TMPDIR/dest"

    run clone_assets "$BATS_TEST_TMPDIR/dest"
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/dest/_build/marker" ]
}
