# Build fast-worktree's two compiled helpers from source.
#
# Both binaries are gitignored; only their sources are checked into git, and
# both are auto-built on first use (lib/cow.sh, lib/usage.sh), so running
# `make` by hand is optional.
#
# apfsclone wraps macOS clonefile(2); it is Darwin-only, and elsewhere
# fast-worktree falls back to cp reflink/plain copy and never uses it.
# subagent-parser reads Claude Code transcripts for `fw usage`.
CC ?= cc
CFLAGS ?= -O2
GO ?= go

APFSCLONE := scripts/apfsclone/apfsclone
PARSER_DIR := cmd/subagent-parser
PARSER := $(PARSER_DIR)/subagent-parser

.PHONY: all apfsclone subagent-parser clean check

all: apfsclone subagent-parser

# Run the full suite + lint on Linux in a container — the same checks CI runs.
# See tests/check. (Native `./tests/run` stays the fast local inner loop.)
check:
	./tests/check

apfsclone: $(APFSCLONE)

$(APFSCLONE): $(APFSCLONE).c
	$(CC) $(CFLAGS) -o $@ $<

subagent-parser: $(PARSER)

$(PARSER): $(PARSER_DIR)/main.go $(PARSER_DIR)/go.mod
	cd $(PARSER_DIR) && $(GO) build -o subagent-parser .

clean:
	rm -f $(APFSCLONE) $(PARSER)
