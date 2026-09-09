load ../test_helper

setup() {
    isolate_env
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    cd "$BATS_TEST_TMPDIR/myrepo"

    export FW_TEST_GH_NWO="owner/repo"
    export FW_TEST_GH_COMMENT_JSON='{"id":111,"in_reply_to_id":null,"url":"https://api.github.com/repos/owner/repo/pulls/comments/111","pull_request_url":"https://api.github.com/repos/owner/repo/pulls/42"}'
    export FW_TEST_GH_THREAD_JSON='[{"id":111,"in_reply_to_id":null,"path":"lib/foo.sh","original_line":10,"line":10,"user":{"login":"alice"},"body":"please fix this","created_at":"2026-08-20T10:00:00Z"}]'
    export FW_TEST_GH_GRAPHQL_JSON='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":111}]}}]}}}}}'
}

teardown() { "$FW_ROOT/tests/shims/tmux" kill-server 2>/dev/null || true; }

@test "fw comments: renders a review thread by comment id" {
    run "$FW_BIN" comments 111
    [ "$status" -eq 0 ]
    [[ "$output" == *"lib/foo.sh:10"* ]]
    [[ "$output" == *"PR #42"* ]]
    [[ "$output" == *"alice"* ]]
    [[ "$output" == *"please fix this"* ]]
    [[ "$output" == *"Unresolved"* ]]
}

@test "fw comments: marks a resolved thread" {
    export FW_TEST_GH_GRAPHQL_JSON='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":true,"comments":{"nodes":[{"databaseId":111}]}}]}}}}}'

    run "$FW_BIN" comments 111
    [ "$status" -eq 0 ]
    [[ "$output" == *"Resolved"* ]]
}

@test "fw comments: resolves a discussion_r URL to the comment id" {
    export FW_TEST_GH_LOG="$BATS_TEST_TMPDIR/gh.log"

    run "$FW_BIN" comments "https://github.com/owner/repo/pull/42#discussion_r111"
    [ "$status" -eq 0 ]
    grep -q "pulls/comments/111" "$FW_TEST_GH_LOG"
}

@test "fw comments: requires an argument" {
    run "$FW_BIN" comments
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage"* || "$output" == *"usage"* ]]
}
