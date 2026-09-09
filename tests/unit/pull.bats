# bats file_tags=core
load ../test_helper

setup() {
    isolate_env
    source "$FW_ROOT/lib/pull.sh"
}

@test "name_from_branch: folds the namespace into the worktree name" {
    # A non-default namespace stays, with its slash folded to '-', so the name
    # keeps the branch's identity and can't collide across namespaces.
    [ "$(name_from_branch colleague/cool-fix)" = "colleague-cool-fix" ]
    [ "$(name_from_branch cool-fix)" = "cool-fix" ]
    [ "$(name_from_branch a/b/deep-branch)" = "a-b-deep-branch" ]
}

@test "name_from_branch: strips the configured branch prefix" {
    local branch_prefix=jason
    [ "$(name_from_branch jason/cool-fix)" = "cool-fix" ]
    # A different namespace is not the prefix, so it is kept and folded.
    [ "$(name_from_branch jax/cool-fix)" = "jax-cool-fix" ]
}

@test "name_from_branch: lowercases and sanitizes to a valid worktree name" {
    [ "$(name_from_branch "Colleague/Fix_It.2")" = "colleague-fix_it-2" ]
    [ "$(name_from_branch "x/--weird")" = "x---weird" ]
}
