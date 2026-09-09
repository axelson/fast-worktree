# bats file_tags=core
load ../test_helper

# `run -N` (asserting the exit code inline) needs bats >= 1.5.
bats_require_minimum_version 1.5.0

setup() { isolate_env; }

# _fzf_pick_line is the single fzf entry point; its return-code contract (0
# picked / 1 cancel / 2 missing / 3 real error) is the uniform degradation
# every picker relies on. The "fzf not installed" and "fzf really failed"
# branches are the two things the shim-based integration tests can't reproduce
# on a dev machine with a real fzf on PATH, so they're asserted here in
# isolation.

@test "_fzf_pick_line returns 2 with guidance when fzf is not installed" {
    # A scratch PATH with no fzf; the function body uses only shell builtins,
    # so an empty dir is enough to reproduce the missing-tool branch hermetically.
    local scratch="$BATS_TEST_TMPDIR/nopath"
    mkdir -p "$scratch"
    run -2 bash -c 'PATH="$2"; source "$1"; printf "a\nb\n" | _fzf_pick_line --reverse' \
        bash "$FW_ROOT/lib/fzf.sh" "$scratch"
    [ "$status" -eq 2 ]
    [[ "$output" == *"fzf is not installed"* ]]
}

@test "_fzf_pick_line passes stdin through to fzf and returns its selection" {
    export FW_TEST_FZF_SELECT=b
    run bash -c 'source "$1"; printf "a\nb\nc\n" | _fzf_pick_line --reverse' \
        bash "$FW_ROOT/lib/fzf.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "b" ]
}

@test "_fzf_pick_line returns 1 (quiet) on a cancelled picker" {
    export FW_TEST_FZF_CANCEL=1
    run bash -c 'source "$1"; printf "a\nb\n" | _fzf_pick_line --reverse' \
        bash "$FW_ROOT/lib/fzf.sh"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "_fzf_pick_line returns 3 with a message on a real fzf error, distinct from cancel" {
    export FW_TEST_FZF_ERROR=1
    run bash -c 'source "$1"; printf "a\nb\n" | _fzf_pick_line --reverse' \
        bash "$FW_ROOT/lib/fzf.sh"
    [ "$status" -eq 3 ]
    [[ "$output" == *"fzf failed"* ]]
}
