load ../test_helper

setup() {
    # Resolve the real Go toolchain before HOME is isolated: `go` on PATH may
    # be a version-manager shim (asdf) that resolves the toolchain through
    # $HOME and dies in the scratch HOME with "unknown command: go".
    local goroot gocache
    goroot="$(go env GOROOT 2>/dev/null || true)"
    # Reuse the host's build cache too. isolate_env repoints XDG_CACHE_HOME at
    # the scratch HOME, so GOCACHE would default to an empty per-test dir and
    # every test would cold-compile the standard library — ~2s locally but
    # >15s on a slow CI runner, tripping BATS_TEST_TIMEOUT. Pinning the real,
    # warm cache keeps builds fast and is safe: the build cache is
    # content-addressed and concurrency-safe, exactly as a normal `go build`.
    gocache="$(go env GOCACHE 2>/dev/null || true)"
    isolate_env
    [[ -n "$goroot" && -x "$goroot/bin/go" ]] && export PATH="$goroot/bin:$PATH"
    [[ -n "$gocache" ]] && export GOCACHE="$gocache"
    # Hermetic builds: the stand-in parser has no deps, so forbid downloads —
    # otherwise the toolchain fetches its telemetry config module into the
    # scratch HOME's read-only module cache, which bats cleanup can't delete.
    export GOPROXY=off
    PARSER_DIR="$BATS_TEST_TMPDIR/parser"
    mkdir -p "$PARSER_DIR"
    # Point the build plumbing at a scratch parser dir before sourcing, so the
    # repo's real binary is never rebuilt or clobbered by the suite.
    export USAGE_PARSER_DIR="$PARSER_DIR"
    source "$FW_ROOT/lib/usage.sh"
}

teardown() {
    # Anything go still managed to write read-only must become deletable, or
    # bats' tmpdir cleanup spews "Permission denied" and leaves debris.
    chmod -R u+w "$HOME/go" 2>/dev/null || true
}

# A buildable stand-in for the real parser: echoes its arguments so callers can
# assert on the invocation, and exits nonzero when told to.
write_parser_src() {
    printf 'module parsertest\n\ngo 1.21\n' >"$PARSER_DIR/go.mod"
    cat >"$PARSER_DIR/main.go" <<'EOF'
package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Println("parsed", os.Args[1], os.Args[2])
	if os.Getenv("PARSER_FAIL") != "" {
		os.Exit(3)
	}
}
EOF
}

require_go() {
    # `go version` rather than `command -v`: a version-manager shim exists on
    # PATH even when it can't actually run a toolchain in this environment.
    go version >/dev/null 2>&1 || skip "go not installed"
}

@test "_ensure_usage_parser: builds the binary when it is missing" {
    require_go
    write_parser_src

    run _ensure_usage_parser
    [ "$status" -eq 0 ]
    [ -x "$PARSER_DIR/subagent-parser" ]
}

@test "_ensure_usage_parser: rebuilds when the source is newer than the binary" {
    require_go
    write_parser_src
    printf 'stale' >"$PARSER_DIR/subagent-parser"
    chmod +x "$PARSER_DIR/subagent-parser"
    touch "$PARSER_DIR/main.go"

    _ensure_usage_parser
    [ "$(cat "$PARSER_DIR/subagent-parser" 2>/dev/null)" != "stale" ]
}

@test "_ensure_usage_parser: leaves an up-to-date binary alone" {
    write_parser_src
    touch "$PARSER_DIR/main.go"
    printf 'prebuilt' >"$PARSER_DIR/subagent-parser"
    chmod +x "$PARSER_DIR/subagent-parser"
    touch -r "$PARSER_DIR/main.go" -A 010000 "$PARSER_DIR/subagent-parser" 2>/dev/null \
        || touch -d '+1 hour' "$PARSER_DIR/subagent-parser"

    run _ensure_usage_parser
    [ "$status" -eq 0 ]
    [ "$(cat "$PARSER_DIR/subagent-parser")" = "prebuilt" ]
}

@test "_ensure_usage_parser: missing go is a loud error, not a silent skip" {
    write_parser_src

    PATH="/usr/bin:/bin" run _ensure_usage_parser
    [ "$status" -ne 0 ]
    [[ "$output" == *"go"* ]]
    [[ "$output" == *"Error"* ]]
    [ ! -e "$PARSER_DIR/subagent-parser" ]
}

@test "_ensure_usage_parser: a build failure is fatal and leaves no binary" {
    require_go
    write_parser_src
    printf 'package main\nthis is not go\n' >"$PARSER_DIR/main.go"

    run _ensure_usage_parser
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
    [ ! -e "$PARSER_DIR/subagent-parser" ]
    # The temp compile target must not survive a failed build.
    run bash -c "ls '$PARSER_DIR'/subagent-parser.tmp.* 2>/dev/null"
    [ -z "$output" ]
}

@test "_ensure_usage_parser: missing parser source is a loud error" {
    run _ensure_usage_parser
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
}

@test "_run_usage_parser: invokes the built binary with the db and projects dir" {
    require_go
    write_parser_src
    _ensure_usage_parser

    run _run_usage_parser "$BATS_TEST_TMPDIR/usage.db" "$BATS_TEST_TMPDIR/projects"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$BATS_TEST_TMPDIR/usage.db"* ]]
    [[ "$output" == *"$BATS_TEST_TMPDIR/projects"* ]]
}

@test "_run_usage_parser: propagates a nonzero parser exit" {
    require_go
    write_parser_src
    _ensure_usage_parser

    PARSER_FAIL=1 run _run_usage_parser "$BATS_TEST_TMPDIR/usage.db" "$BATS_TEST_TMPDIR/projects"
    [ "$status" -eq 3 ]
}
