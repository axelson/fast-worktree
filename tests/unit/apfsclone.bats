load ../test_helper

# Auto-build of the apfsclone helper (lib/cow.sh:_ensure_apfsclone).
#
# The binary is not shipped — only its C source is. On macOS the first CoW
# clone compiles it on demand (quietly, once). These tests force OSTYPE=darwin
# and drive the compiler through a fake `cc` on PATH, so they are deterministic
# on Linux CI too; the one test that shells out to the real compiler is gated.

setup() {
    isolate_env
    source "$FW_ROOT/lib/config.sh"
    source "$FW_ROOT/lib/cow.sh"
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    load_config myproj

    mkdir -p "$repo_root/_build"
    touch "$repo_root/_build/marker"
    cow_assets=(_build)
    mkdir -p "$BATS_TEST_TMPDIR/dest"

    # Point APFSCLONE at a private location with source alongside it, so the
    # auto-build has a $APFSCLONE.c to compile and never touches the real tree.
    export APFSCLONE="$BATS_TEST_TMPDIR/bin/apfsclone"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
}

# fake_cc <exit_code> — install a `cc` on PATH that, on success, writes an
# apfsclone that clones by `cp -R` and drops a marker so we can prove it ran.
fake_cc() {
    local rc="${1:-0}"
    mkdir -p "$BATS_TEST_TMPDIR/ccbin"
    cat >"$BATS_TEST_TMPDIR/ccbin/cc" <<EOF
#!/bin/sh
[ "$rc" -eq 0 ] || exit $rc
out=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
echo "\$out" >>"$BATS_TEST_TMPDIR/cc-out-path"
cat >"\$out" <<'BIN'
#!/bin/sh
cp -R "\$1" "\$2" && touch "\$2/.via-apfsclone"
BIN
chmod +x "\$out"
EOF
    chmod +x "$BATS_TEST_TMPDIR/ccbin/cc"
    export PATH="$BATS_TEST_TMPDIR/ccbin:$PATH"
}

@test "auto-build: compiles apfsclone on first use when the binary is missing" {
    OSTYPE=darwin
    printf 'int main(){return 0;}\n' >"$APFSCLONE.c"
    fake_cc 0

    clone_assets "$BATS_TEST_TMPDIR/dest"

    [ -x "$APFSCLONE" ]                                    # binary got built
    [ -f "$BATS_TEST_TMPDIR/dest/_build/.via-apfsclone" ]  # and was used
    [ -f "$BATS_TEST_TMPDIR/dest/_build/marker" ]
}

@test "auto-build: compiles to a temp file then atomically renames into place" {
    OSTYPE=darwin
    printf 'int main(){return 0;}\n' >"$APFSCLONE.c"
    fake_cc 0

    clone_assets "$BATS_TEST_TMPDIR/dest"

    [ -x "$APFSCLONE" ]                                     # final binary in place
    [ -f "$BATS_TEST_TMPDIR/dest/_build/.via-apfsclone" ]  # and it ran
    # The compiler wrote to a temp path in the same dir, NOT the final path —
    # so two concurrent first runs can't interleave writes to the live binary.
    local compiled; compiled="$(cat "$BATS_TEST_TMPDIR/cc-out-path")"
    [ "$compiled" != "$APFSCLONE" ]
    [ "$(dirname "$compiled")" = "$(dirname "$APFSCLONE")" ]
    # No temp leftovers beside the final binary.
    [ -z "$(find "$(dirname "$APFSCLONE")" -name 'apfsclone.tmp.*' 2>/dev/null)" ]
}

@test "auto-build: a failed compile prints a clear note and falls back to cp" {
    OSTYPE=darwin
    printf 'int main(){return 0;}\n' >"$APFSCLONE.c"
    fake_cc 1

    run clone_assets "$BATS_TEST_TMPDIR/dest"
    [ "$status" -eq 0 ]
    [[ "$output" == *apfsclone* ]]                          # a clear note
    [ ! -e "$APFSCLONE" ]                                   # no half-built binary left usable
    # No temp compile artifact left behind either.
    [ -z "$(find "$BATS_TEST_TMPDIR/bin" -name 'apfsclone.tmp.*' 2>/dev/null)" ]
    [ -f "$BATS_TEST_TMPDIR/dest/_build/marker" ]           # copy still happened
}

@test "auto-build: only one build attempt per process even across assets" {
    OSTYPE=darwin
    printf 'int main(){return 0;}\n' >"$APFSCLONE.c"
    # cc that records each invocation, then fails.
    mkdir -p "$BATS_TEST_TMPDIR/ccbin"
    cat >"$BATS_TEST_TMPDIR/ccbin/cc" <<EOF
#!/bin/sh
echo x >>"$BATS_TEST_TMPDIR/cc-calls"
exit 1
EOF
    chmod +x "$BATS_TEST_TMPDIR/ccbin/cc"
    export PATH="$BATS_TEST_TMPDIR/ccbin:$PATH"
    mkdir -p "$repo_root/deps"
    touch "$repo_root/deps/marker"
    cow_assets=(_build deps)

    clone_assets "$BATS_TEST_TMPDIR/dest"

    [ "$(wc -l <"$BATS_TEST_TMPDIR/cc-calls")" -eq 1 ]
}

@test "auto-build: no C source means no build attempt and a clean fallback" {
    OSTYPE=darwin
    fake_cc 0   # available, but must not be invoked without source
    [ ! -e "$APFSCLONE.c" ]

    run clone_assets "$BATS_TEST_TMPDIR/dest"
    [ "$status" -eq 0 ]
    [ ! -e "$APFSCLONE" ]
    [ -f "$BATS_TEST_TMPDIR/dest/_build/marker" ]
}

@test "make + real cc: source compiles and the binary clones copy-on-write" {
    [[ "$OSTYPE" == darwin* ]] || skip "clonefile(2) is macOS-only"
    command -v cc >/dev/null 2>&1 || skip "no C compiler"

    cc -O2 -o "$BATS_TEST_TMPDIR/real-apfsclone" \
        "$FW_ROOT/scripts/apfsclone/apfsclone.c"
    mkdir -p "$BATS_TEST_TMPDIR/src"
    echo hello >"$BATS_TEST_TMPDIR/src/file"

    run "$BATS_TEST_TMPDIR/real-apfsclone" \
        "$BATS_TEST_TMPDIR/src" "$BATS_TEST_TMPDIR/cloned"
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/cloned/file")" = hello ]
}
