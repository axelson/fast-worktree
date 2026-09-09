# bats file_tags=core
load ../test_helper

setup() {
    isolate_env
    source "$FW_ROOT/lib/config.sh"
    source "$FW_ROOT/lib/fzf.sh"
    source "$FW_ROOT/lib/copy.sh"
    # A controlled bin dir so clipboard-backend selection is deterministic:
    # only the fake tools a test creates are on PATH.
    CLIP_BIN="$BATS_TEST_TMPDIR/clipbin"
    mkdir -p "$CLIP_BIN"
    # A minimal PATH with just /bin (for the fakes' `cat`) plus our fake dir.
    # /usr/bin is deliberately excluded so macOS's real /usr/bin/pbcopy can't
    # shadow the fallback-selection tests; only fakes a test creates are found.
    STOCK_PATH="$CLIP_BIN:/bin"
}

# Write a fake clipboard tool that appends its stdin to a per-tool log.
fake_clip_tool() {
    local name="$1"
    cat >"$CLIP_BIN/$name" <<EOF
#!/bin/sh
cat >>"$BATS_TEST_TMPDIR/$name.log"
EOF
    chmod +x "$CLIP_BIN/$name"
}

@test "_copy_to_clipboard: uses pbcopy when present, no trailing newline" {
    fake_clip_tool pbcopy
    PATH="$STOCK_PATH" run _copy_to_clipboard "hello world"
    [ "$status" -eq 0 ]
    # Exactly the value, no trailing newline.
    [ "$(cat "$BATS_TEST_TMPDIR/pbcopy.log" | wc -c | tr -d ' ')" = "11" ]
    [ "$(cat "$BATS_TEST_TMPDIR/pbcopy.log")" = "hello world" ]
}

@test "_copy_to_clipboard: falls back to wl-copy when pbcopy is absent" {
    fake_clip_tool wl-copy
    PATH="$STOCK_PATH" run _copy_to_clipboard "wayland-val"
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/wl-copy.log")" = "wayland-val" ]
}

@test "_copy_to_clipboard: prefers pbcopy over wl-copy when both present" {
    fake_clip_tool pbcopy
    fake_clip_tool wl-copy
    PATH="$STOCK_PATH" run _copy_to_clipboard "pick-me"
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/pbcopy.log")" = "pick-me" ]
    [ ! -f "$BATS_TEST_TMPDIR/wl-copy.log" ]
}

@test "_copy_to_clipboard: falls back to xclip, then xsel" {
    fake_clip_tool xclip
    PATH="$STOCK_PATH" run _copy_to_clipboard "x11-val"
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/xclip.log")" = "x11-val" ]

    rm "$CLIP_BIN/xclip"
    fake_clip_tool xsel
    PATH="$STOCK_PATH" run _copy_to_clipboard "xsel-val"
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/xsel.log")" = "xsel-val" ]
}

@test "_copy_to_clipboard: no backend prints the value and returns non-zero" {
    PATH="$STOCK_PATH" run _copy_to_clipboard "unstuck-value"
    [ "$status" -ne 0 ]
    # The value is still emitted on stdout so it stays usable.
    printf '%s\n' "${lines[*]}" | grep -q "unstuck-value"
}

@test "_copy_menu_entries: hides ticket and stack items by default" {
    ticket_url=""
    STACK_BACKEND=none
    run _copy_menu_entries
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q $'Branch\tbranch'
    printf '%s\n' "$output" | grep -q $'Worktree path\tpath'
    printf '%s\n' "$output" | grep -q $'PR link\tpr-link'
    printf '%s\n' "$output" | grep -q $'PR number\tpr-number'
    ! printf '%s\n' "$output" | grep -q "ticket-url"
    ! printf '%s\n' "$output" | grep -q "stack-branch"
}

@test "_copy_menu_entries: shows the ticket item when ticket_url is set" {
    ticket_url='https://tracker/{id}'
    STACK_BACKEND=none
    run _copy_menu_entries
    printf '%s\n' "$output" | grep -q $'Ticket URL\tticket-url'
}

@test "_copy_menu_entries: shows the stack item when a stack backend is active" {
    ticket_url=""
    STACK_BACKEND=graphite
    run _copy_menu_entries
    printf '%s\n' "$output" | grep -q $'Branch (stack picker)\tstack-branch'
}

@test "_copy_dispatch: an unknown item errors and lists valid items" {
    run _copy_dispatch "bogus"
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "unknown copy item"
}

# Stub the stack backend so the picker logic is exercised without graphite.
stub_stack() {
    _stack_require_cwd_in_project() { return 0; }
    _ensure_trunk() { :; }
    stack_branches() { printf '%s\n' me/foo me/bar; }
    _stack_decode() { printf '%s\t%s' " " "$1"; }
}

@test "_copy_val_stack_branch: echoes the branch picked from the stack" {
    stub_stack
    export FW_TEST_FZF_SELECT="me/bar"
    run _copy_val_stack_branch
    [ "$status" -eq 0 ]
    [ "$output" = "me/bar" ]
}

@test "_copy_val_stack_branch: returns 2 (quiet no-op) when the sub-picker is cancelled" {
    stub_stack
    export FW_TEST_FZF_CANCEL=1
    run _copy_val_stack_branch
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "cmd_copy: a cancelled stack sub-picker exits 0 without copying" {
    _copy_val_stack_branch() { return 2; }
    _copy_to_clipboard() { echo "COPIED:$1"; }
    run cmd_copy stack-branch
    [ "$status" -eq 0 ]
    ! printf '%s\n' "$output" | grep -q "COPIED"
}

@test "_copy_val_pr_link: rejects a null url instead of copying 'null'" {
    _gh_resolve_target() { GH_BRANCH="me/foo"; return 0; }
    _gh_pr_json() { printf '%s' '{"url":null}'; }
    run _copy_val_pr_link
    [ "$status" -ne 0 ]
    ! printf '%s\n' "$output" | grep -q '^null$'
    printf '%s\n' "$output" | grep -q "no PR URL"
}
