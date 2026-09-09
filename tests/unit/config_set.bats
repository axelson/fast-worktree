load ../test_helper

setup() {
    isolate_env
    source "$FW_ROOT/lib/config.sh"
    source "$FW_ROOT/lib/stack.sh"
    source "$FW_ROOT/lib/configcmd.sh"
    CFG="$BATS_TEST_TMPDIR/config.sh"
}

# --- _config_quote_value ---

@test "_config_quote_value: simple word is single-quoted" {
    [ "$(_config_quote_value none)" = "'none'" ]
}

@test "_config_quote_value: value with spaces is single-quoted" {
    [ "$(_config_quote_value 'code -w')" = "'code -w'" ]
}

@test "_config_quote_value: embedded single quote is escaped" {
    # it's  ->  'it'\''s'
    [ "$(_config_quote_value "it's")" = "'it'\\''s'" ]
}

# --- _config_write_var: comment-aware, idempotent ---

@test "_config_write_var: replaces an active assignment in place" {
    printf '# header\nstack_backend=auto\ngithub_username=x\n' >"$CFG"
    _config_write_var "$CFG" stack_backend none
    grep -q "^stack_backend='none'$" "$CFG"
    # other lines untouched
    grep -q '^# header$' "$CFG"
    grep -q '^github_username=x$' "$CFG"
    # exactly one stack_backend line
    [ "$(grep -c 'stack_backend' "$CFG")" -eq 1 ]
}

@test "_config_write_var: uncomments a commented template line in place" {
    printf '# top\n# stack_backend=auto\n# bottom\n' >"$CFG"
    _config_write_var "$CFG" stack_backend none
    grep -q "^stack_backend='none'$" "$CFG"
    grep -q '^# top$' "$CFG"
    grep -q '^# bottom$' "$CFG"
    # the commented default line is gone (replaced, not duplicated)
    ! grep -q '^# stack_backend=' "$CFG"
}

@test "_config_write_var: appends when the key is absent" {
    printf '# just a header\n' >"$CFG"
    _config_write_var "$CFG" stack_backend none
    grep -q '^# just a header$' "$CFG"
    grep -q "^stack_backend='none'$" "$CFG"
}

@test "_config_write_var: re-setting is idempotent (one line)" {
    printf '# header\n' >"$CFG"
    _config_write_var "$CFG" stack_backend none
    _config_write_var "$CFG" stack_backend graphite
    [ "$(grep -c '^stack_backend=' "$CFG")" -eq 1 ]
    grep -q "^stack_backend='graphite'$" "$CFG"
}

# Regression: the replace/uncomment paths must not mangle the escaping that
# _config_quote_value produces. A value with an embedded single quote must
# round-trip through a *re-set* and still source back to the original.
@test "_config_write_var: re-set preserves a value with an embedded single quote" {
    printf "editor='placeholder'\n" >"$CFG"
    _config_write_var "$CFG" editor "a'b"
    # the file must still be valid bash and source back to the exact value
    ( set -euo pipefail; unset editor; source "$CFG"; [ "$editor" = "a'b" ] )
}

@test "_config_write_var: re-set preserves a value with a backslash" {
    printf "start_cmd='placeholder'\n" >"$CFG"
    _config_write_var "$CFG" start_cmd 'a\tb'
    ( set -euo pipefail; unset start_cmd; source "$CFG"; [ "$start_cmd" = 'a\tb' ] )
}

@test "_config_write_var: prefers an active line over a commented one" {
    printf '# stack_backend=auto\nstack_backend=graphite\n' >"$CFG"
    _config_write_var "$CFG" stack_backend none
    grep -q "^stack_backend='none'$" "$CFG"
    # commented line preserved, active one replaced
    grep -q '^# stack_backend=auto$' "$CFG"
}

# --- _config_delete_var ---

@test "_config_delete_var: removes the active assignment line only" {
    printf '# stack_backend=auto\nstack_backend=none\ngithub_username=x\n' >"$CFG"
    _config_delete_var "$CFG" stack_backend
    ! grep -q "^stack_backend='" "$CFG"
    ! grep -q '^stack_backend=none$' "$CFG"
    grep -q '^github_username=x$' "$CFG"
    # surrounding comment left alone
    grep -q '^# stack_backend=auto$' "$CFG"
}

# --- _config_key_is_array ---

@test "_config_key_is_array: false for a scalar key" {
    run _config_key_is_array stack_backend
    [ "$status" -ne 0 ]
}

@test "_config_key_is_array: true for an array key" {
    run _config_key_is_array cow_assets
    [ "$status" -eq 0 ]
}

@test "_config_key_is_array: true for an associative-array key" {
    run _config_key_is_array claude_prompt_flags
    [ "$status" -eq 0 ]
}

# --- stack_backend valid-values / validator (lib/stack.sh) ---

@test "_stack_backend_valid_values: lists the recognized set" {
    local vals
    vals="$(_stack_backend_valid_values)"
    [[ " $vals " == *" auto "* ]]
    [[ " $vals " == *" graphite "* ]]
    [[ " $vals " == *" github "* ]]
    [[ " $vals " == *" none "* ]]
}

@test "_config_validate_stack_backend: accepts none" {
    run _config_validate_stack_backend none
    [ "$status" -eq 0 ]
}

@test "_config_validate_stack_backend: accepts github (recognized, unimplemented)" {
    run _config_validate_stack_backend github
    [ "$status" -eq 0 ]
}

@test "_config_validate_stack_backend: rejects a typo" {
    run _config_validate_stack_backend nnone
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid stack_backend"* ]]
}
