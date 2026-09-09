# bats file_tags=core
load ../test_helper

setup() {
    isolate_env
    source "$FW_ROOT/lib/config.sh"
    source "$FW_ROOT/lib/ticket.sh"
    # The default (felt-shaped) pattern unless a test overrides it.
    ticket_pattern='/([a-zA-Z]+)-([0-9]+)'
}

@test "_extract_ticket: extracts and uppercases a felt-style branch id" {
    run_extract() { _extract_ticket "me/app-10873-some-title"; echo "$TICKET_ID"; }
    run run_extract
    [ "$status" -eq 0 ]
    [ "$output" = "APP-10873" ]
}

@test "_extract_ticket: joins capture groups with a dash" {
    TICKET_ID=""
    _extract_ticket "jason/proj-42-x"
    [ "$TICKET_ID" = "PROJ-42" ]
}

@test "_extract_ticket: succeeds and sets a return of 0 on a match" {
    _extract_ticket "x/abc-9"
    [ "$?" -eq 0 ]
    [ "$TICKET_ID" = "ABC-9" ]
}

@test "_extract_ticket: returns non-zero and clears TICKET_ID when nothing matches" {
    TICKET_ID="stale"
    run _extract_ticket "main"
    [ "$status" -ne 0 ]
    # In the caller's scope, TICKET_ID is cleared before matching.
    _extract_ticket "main" || true
    [ -z "$TICKET_ID" ]
}

@test "_extract_ticket: an empty pattern never matches" {
    ticket_pattern=""
    run _extract_ticket "me/app-1"
    [ "$status" -ne 0 ]
}

@test "_extract_ticket: an override pattern argument takes precedence over ticket_pattern" {
    # Body-style text has no leading slash; the stripped pattern still matches.
    _extract_ticket "See APP-777 for details" "${ticket_pattern#/}"
    [ "$TICKET_ID" = "APP-777" ]
}

@test "_extract_ticket: a single-group Jira-style pattern is honored" {
    ticket_pattern='([A-Z]+-[0-9]+)'
    _extract_ticket "feature JIRA-5 branch"
    [ "$TICKET_ID" = "JIRA-5" ]
}

@test "_extract_ticket: a group-less pattern falls back to the whole match" {
    ticket_pattern='[A-Z]+-[0-9]+'
    _extract_ticket "topic GH-12 here"
    [ "$TICKET_ID" = "GH-12" ]
}

@test "_extract_ticket: an invalid regex fails cleanly rather than aborting" {
    ticket_pattern='([a-z'
    run _extract_ticket "me/app-1"
    [ "$status" -ne 0 ]
}
