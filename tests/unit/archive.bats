# bats file_tags=core
load ../test_helper

setup() {
    isolate_env
    source "$FW_ROOT/lib/config.sh"
    source "$FW_ROOT/lib/archive.sh"
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    load_config myproj
    mkdir -p "$worktrees_dir"
}

@test "_archived_entry_for: a name match beats a later row's branch match" {
    {
        printf '1\tfix\tme/other\treason1\n'
        printf '2\talpha\tfix\treason2\n'
    } >"$worktrees_dir/.fw_archive_log"

    run _archived_entry_for fix
    [ "$output" = $'fix\tme/other' ]
}

@test "_archived_entry_for: falls back to a branch match" {
    printf '1\talpha\tme/thing\treason\n' >"$worktrees_dir/.fw_archive_log"

    run _archived_entry_for me/thing
    [ "$output" = $'alpha\tme/thing' ]
}

@test "_archived_entry_for: name and branch always come from the same row" {
    {
        printf '1\toldname\tme/b\tfirst\n'
        printf '2\tnewname\tme/b\tsecond\n'
    } >"$worktrees_dir/.fw_archive_log"

    run _archived_entry_for oldname
    [ "$output" = $'oldname\tme/b' ]
    run _archived_entry_for newname
    [ "$output" = $'newname\tme/b' ]
}

@test "_retire_archive_entry: removes only the matching row" {
    {
        printf '1\ta\tme/a\tr1\n'
        printf '2\tb\tme/b\tr2\n'
    } >"$worktrees_dir/.fw_archive_log"

    _retire_archive_entry a me/a

    run cat "$worktrees_dir/.fw_archive_log"
    [ "$output" = $'2\tb\tme/b\tr2' ]
}
