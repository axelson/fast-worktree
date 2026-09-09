# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# `fw usage` — Claude Code token usage per worktree, classified by category.
#
# Cost model: `npx ccusage` is the authority on what a session cost, and its
# session totals already include the session's subagent transcripts. The
# transcript parser's per-file costs are used only as *weights* splitting that
# total into main-loop and subagent shares — never added to it, which would
# count subagent spend twice.

# The cache DB is rebuildable — `fw usage sync` re-derives every row — so it
# lives in the cache root, not in config. One DB covers every project.
: "${USAGE_DB:=${XDG_CACHE_HOME:-$HOME/.cache}/fast-worktree/usage.db}"

# Bases for splitting a session total between main loop and subagents. SUB% is
# sensitive to this choice — cache reads dominate the token mix, so a basis
# that prices them differently moves the answer a lot.
USAGE_VALID_WEIGHTS=(cost output tokens)

# The Go transcript parser ships as source; the binary is gitignored and built
# on first use. Overridable so tests can point at a scratch parser dir instead
# of rebuilding (or clobbering) the repo's own binary.
: "${USAGE_PARSER_DIR:=${SCRIPT_DIR:-.}/cmd/subagent-parser}"

# _ensure_usage_parser — compile the transcript parser when the binary is
# missing or older than its source. Every failure is fatal: a sync without
# transcript weights reports every session as 100% main loop, which is wrong
# data rather than degraded data.
_ensure_usage_parser() {
    local bin="$USAGE_PARSER_DIR/subagent-parser"
    local src="$USAGE_PARSER_DIR/main.go"

    if [[ -x "$bin" && ! "$src" -nt "$bin" ]]; then
        return 0
    fi

    if [[ ! -f "$src" ]]; then
        echo "Error: transcript parser source not found at $src" >&2
        return 1
    fi

    if ! command -v go >/dev/null 2>&1; then
        echo "Error: go not found on PATH — needed to build the transcript parser" >&2
        echo "Install Go (brew install go), then re-run 'fw usage sync'." >&2
        return 1
    fi

    echo "  Building transcript parser..."
    # Compile to a temp file beside the binary and rename into place: two
    # concurrent syncs must not interleave writes to the live binary, and a
    # failed compile must leave no partial artifact. mv is atomic within a
    # filesystem.
    local tmp
    if ! tmp="$(mktemp "$USAGE_PARSER_DIR/subagent-parser.tmp.XXXXXX" 2>/dev/null)"; then
        echo "Error: could not create a temp file in $USAGE_PARSER_DIR" >&2
        return 1
    fi
    if (cd "$USAGE_PARSER_DIR" && go build -o "$tmp" .) && mv -f "$tmp" "$bin"; then
        return 0
    fi
    rm -f "$tmp"
    echo "Error: failed to build the transcript parser in $USAGE_PARSER_DIR" >&2
    return 1
}

# _run_usage_parser <db> <projects-dir> — the one parser invocation, isolated
# so tests can shim it the way the cow tests shim apfsclone.
_run_usage_parser() {
    "$USAGE_PARSER_DIR/subagent-parser" "$@"
}

# --- SQLite cache ---

# _usage_require_cmd <cmd> <what-needs-it> [install-hint] — `fw usage` has no
# degraded mode: a missing tool means a wrong report, so every dependency
# check ends the command instead of narrowing it.
_usage_require_cmd() {
    command -v "$1" >/dev/null 2>&1 && return 0
    echo "Error: $1 not found on PATH — $2" >&2
    [[ -n "${3:-}" ]] && echo "$3" >&2
    return 1
}

# Every `fw usage` invocation reads the cache, so sqlite3 is not optional.
_usage_require_sqlite3() {
    _usage_require_cmd sqlite3 "'fw usage' stores its cache in SQLite" \
        "Install it (macOS ships one; brew install sqlite otherwise)."
}

# Escape a value for single-quoted SQL interpolation.
_sql_quote() { printf "%s" "${1//\'/\'\'}"; }

# SQL expression measuring one transcript's share, per --weight basis.
_usage_weight_expr() {
    case "$1" in
        output) echo "output_tokens" ;;
        tokens) echo "input_tokens + output_tokens + cache_create + cache_read" ;;
        *)      echo "estimated_cost" ;;
    esac
}

# Human-readable label for the header line.
_usage_weight_label() {
    case "$1" in
        cost)   echo "cost" ;;
        output) echo "output tokens" ;;
        tokens) echo "all tokens" ;;
        *)      echo "$1" ;;
    esac
}

_usage_init_db() {
    _usage_require_sqlite3 || return 1
    mkdir -p "$(dirname "$USAGE_DB")"
    # Creates every table `fw usage` reads, including the ones the Go parser
    # also creates: reporting queries join across all of them, and a read
    # before the first successful sync must not hit a missing table.
    #
    # sessions.project is the registered project a session belongs to, or NULL
    # for a directory no project claims; sessions.worktree then holds Claude's
    # mangled project dir instead of a worktree name.
    sqlite3 "$USAGE_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS sessions (
    session_id       TEXT PRIMARY KEY,
    project          TEXT,        -- registered project name, NULL when unclaimed
    worktree         TEXT,
    category         TEXT,        -- own | review | misc (| ignore, deleted after sync)
    category_source  TEXT,        -- branch_prefix | extra_prefix | git_author | hook | fallback
    model            TEXT,
    input_tokens     INTEGER DEFAULT 0,
    output_tokens    INTEGER DEFAULT 0,
    cache_create     INTEGER DEFAULT 0,
    cache_read       INTEGER DEFAULT 0,
    total_cost       REAL DEFAULT 0,
    first_activity   TEXT,
    last_activity    TEXT
);
CREATE INDEX IF NOT EXISTS idx_sessions_worktree ON sessions(worktree);
CREATE INDEX IF NOT EXISTS idx_sessions_project_worktree ON sessions(project, worktree);
CREATE INDEX IF NOT EXISTS idx_sessions_category ON sessions(category);
CREATE INDEX IF NOT EXISTS idx_sessions_first_activity ON sessions(first_activity);

CREATE TABLE IF NOT EXISTS subagents (
    id             INTEGER PRIMARY KEY,
    session_id     TEXT,
    agent_id       TEXT,
    agent_type     TEXT DEFAULT 'unknown',
    model          TEXT,
    input_tokens   INTEGER DEFAULT 0,
    output_tokens  INTEGER DEFAULT 0,
    cache_create   INTEGER DEFAULT 0,
    cache_read     INTEGER DEFAULT 0,
    estimated_cost REAL DEFAULT 0,
    cache_read_cost REAL DEFAULT 0,
    file_path      TEXT,
    file_size      INTEGER,
    file_mtime     INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_subagents_session ON subagents(session_id);
CREATE INDEX IF NOT EXISTS idx_subagents_agent ON subagents(agent_id);
CREATE INDEX IF NOT EXISTS idx_subagents_file ON subagents(file_path);

CREATE TABLE IF NOT EXISTS main_loop (
    id             INTEGER PRIMARY KEY,
    session_id     TEXT,
    model          TEXT,
    input_tokens   INTEGER DEFAULT 0,
    output_tokens  INTEGER DEFAULT 0,
    cache_create   INTEGER DEFAULT 0,
    cache_read     INTEGER DEFAULT 0,
    estimated_cost REAL DEFAULT 0,
    cache_read_cost REAL DEFAULT 0,
    -- Requests whose cached prefix was not served from cache and got re-written
    -- whole, and what that subset of cache_create cost. Main-loop rows only.
    cache_rewrites       INTEGER DEFAULT 0,
    cache_rewrite_tokens INTEGER DEFAULT 0,
    cache_rewrite_cost   REAL DEFAULT 0,
    file_path      TEXT,
    file_size      INTEGER,
    file_mtime     INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_main_loop_session ON main_loop(session_id);
CREATE INDEX IF NOT EXISTS idx_main_loop_file ON main_loop(file_path);

CREATE TABLE IF NOT EXISTS projects (
    project_dir TEXT PRIMARY KEY,
    cwd         TEXT NOT NULL
);
SQL

    # The cache_rewrite columns arrived after main_loop's original shape. The
    # views below reference them, and a read can run against a DB whose
    # main_loop an older parser created. Values stay 0 until the next sync,
    # which re-parses on the parser's schema version.
    if [[ "$(sqlite3 "$USAGE_DB" \
        "SELECT COUNT(*) FROM pragma_table_info('main_loop') WHERE name = 'cache_rewrites';")" == "0" ]]; then
        sqlite3 "$USAGE_DB" "
ALTER TABLE main_loop ADD COLUMN cache_rewrites INTEGER DEFAULT 0;
ALTER TABLE main_loop ADD COLUMN cache_rewrite_tokens INTEGER DEFAULT 0;
ALTER TABLE main_loop ADD COLUMN cache_rewrite_cost REAL DEFAULT 0;"
    fi

    # One view per --weight basis. Each splits the ccusage session total into
    # main-loop and subagent shares using a different measure of "how much"
    # each side did, so main_cost + sub_cost = total_cost under every basis.
    local mode weight_expr
    for mode in "${USAGE_VALID_WEIGHTS[@]}"; do
        weight_expr=$(_usage_weight_expr "$mode")
        sqlite3 "$USAGE_DB" "
DROP VIEW IF EXISTS session_costs_${mode};
CREATE VIEW session_costs_${mode} AS
SELECT s.session_id, s.project, s.worktree, s.category, s.category_source, s.model,
       s.output_tokens, s.first_activity, s.last_activity,
       s.total_cost,
       CASE WHEN COALESCE(w.total_w, 0) > 0
            THEN s.total_cost * w.sub_w / w.total_w ELSE 0 END AS sub_cost,
       s.total_cost - CASE WHEN COALESCE(w.total_w, 0) > 0
            THEN s.total_cost * w.sub_w / w.total_w ELSE 0 END AS main_cost,
       -- Always cost-based, whatever basis splits the total: this reports how
       -- much of the spend is cache reads, which is a property of the session's
       -- token mix rather than of the chosen weighting. Computed from the
       -- parser's own figures, not the apportioned ccusage dollars, because only
       -- the parser records the per-component token breakdown.
       CASE WHEN COALESCE(w.cost_w, 0) > 0
            THEN w.cr_w / w.cost_w * 100 ELSE 0 END AS cache_read_pct,
       -- Cache rewrites, on the same cost basis and for the same reason as
       -- cache_read_pct: the parser is the only place with a token breakdown.
       COALESCE(w.rw_n, 0) AS cache_rewrites,
       COALESCE(w.rw_t, 0) AS cache_rewrite_tokens,
       CASE WHEN COALESCE(w.cost_w, 0) > 0
            THEN w.rw_c / w.cost_w * 100 ELSE 0 END AS cache_rewrite_pct
FROM sessions s
LEFT JOIN (
    SELECT session_id,
           SUM(w) AS total_w,
           SUM(CASE WHEN kind = 'sub' THEN w ELSE 0 END) AS sub_w,
           SUM(c) AS cost_w,
           SUM(cr) AS cr_w,
           SUM(rw_n) AS rw_n,
           SUM(rw_t) AS rw_t,
           SUM(rw_c) AS rw_c
    FROM (
        SELECT session_id, 'main' AS kind, ${weight_expr} AS w,
               estimated_cost AS c, cache_read_cost AS cr,
               cache_rewrites AS rw_n, cache_rewrite_tokens AS rw_t,
               cache_rewrite_cost AS rw_c FROM main_loop
        UNION ALL
        SELECT session_id, 'sub'  AS kind, ${weight_expr} AS w,
               estimated_cost AS c, cache_read_cost AS cr,
               0 AS rw_n, 0 AS rw_t, 0 AS rw_c FROM subagents
    )
    GROUP BY session_id
) w ON w.session_id = s.session_id;"
    done
}

# --- display timezone ---
#
# Timestamps are stored exactly as ccusage emits them: ISO-8601 UTC with a Z.
# The zone below moves only what a human reads and where the --since/--period
# window edges fall; --json keeps emitting UTC.

USAGE_TZ_MINUTES=""
USAGE_TZ_LABEL=""

# _usage_offset_minutes <offset> — signed minutes east of UTC from "-10",
# "+0530", or "-1000". Two digits or fewer means hours; three or four means
# HHMM, which is what `date +%z` emits.
_usage_offset_minutes() {
    local raw="$1" sign=1 hours mins
    case "$raw" in
        -*) sign=-1; raw="${raw#-}" ;;
        +*) raw="${raw#+}" ;;
    esac
    if [[ "$raw" =~ ^([0-9]{1,2})([0-9]{2})$ ]]; then
        hours="${BASH_REMATCH[1]}"
        mins="${BASH_REMATCH[2]}"
    elif [[ "$raw" =~ ^[0-9]{1,2}$ ]]; then
        hours="$raw"
        mins=0
    else
        return 1
    fi
    echo $(( sign * (10#$hours * 60 + 10#$mins) ))
}

# _usage_load_tz — resolve the display zone once per run: the usage_tz config
# pair, else the system zone. Reading `date` once keeps a run internally
# consistent even across a DST boundary.
_usage_load_tz() {
    [[ -n "$USAGE_TZ_MINUTES" ]] && return 0
    local spec="${usage_tz:-}" offset label
    if [[ -n "$spec" ]]; then
        if [[ "$spec" != *:* ]]; then
            echo "Error: usage_tz must be 'offset:label' (e.g. -10:HST), got '$spec'" >&2
            return 1
        fi
        offset="${spec%%:*}"
        label="${spec#*:}"
        if [[ -z "$label" ]]; then
            echo "Error: usage_tz is missing its zone label (e.g. -10:HST), got '$spec'" >&2
            return 1
        fi
    else
        offset="$(date +%z)"
        label="$(date +%Z)"
    fi
    if ! USAGE_TZ_MINUTES="$(_usage_offset_minutes "$offset")"; then
        echo "Error: usage_tz offset '$offset' is not ±HH or ±HHMM" >&2
        return 1
    fi
    USAGE_TZ_LABEL="$label"
    return 0
}

# _usage_local_sql <expr> — SQL converting a stored UTC timestamp to the
# display zone. Display only; comparisons use the stored UTC values.
_usage_local_sql() {
    printf "datetime(%s, '%+d minutes')" "$1" "$USAGE_TZ_MINUTES"
}

# -g: lib files are sourced from inside functions in the test harness, where a
# bare `declare -A` would make the cache local and vanish.
declare -gA _usage_since_utc_cache=()

# _usage_since_utc <YYYY-MM-DD> — the UTC instant that local calendar date
# begins. `--since 2026-08-18` in HST means from 10:00Z that day; comparing
# against 00:00Z instead would pull in the whole preceding local afternoon.
_usage_since_utc() {
    _usage_load_tz || return 1
    local day="$1"
    if [[ -n "${_usage_since_utc_cache[$day]:-}" ]]; then
        echo "${_usage_since_utc_cache[$day]}"
        return 0
    fi
    local instant
    # sqlite3 does the calendar arithmetic: `date` disagrees between BSD and
    # GNU on how to shift a given date, and sqlite3 is already required here.
    instant="$(sqlite3 :memory: "SELECT strftime('%Y-%m-%dT%H:%M:%SZ',
        datetime('$(_sql_quote "$day") 00:00:00', '$(printf '%+d' $(( -USAGE_TZ_MINUTES )) ) minutes'));")"
    if [[ -z "$instant" ]]; then
        echo "Error: could not resolve --since date '$day'" >&2
        return 1
    fi
    _usage_since_utc_cache[$day]="$instant"
    echo "$instant"
}

# _usage_compute_since <since> <period> — the local calendar date a report
# starts on. Deliberately local, not UTC: "7d" means seven local days.
_usage_compute_since() {
    local since="$1" period="$2"
    if [[ -n "$since" ]]; then
        if [[ ! "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            if [[ "$since" == "all" || "$since" =~ ^[0-9]+d$ ]]; then
                echo "Error: --since takes a date (YYYY-MM-DD); for '$since' use --period $since" >&2
            else
                echo "Error: --since must be YYYY-MM-DD, got '$since'" >&2
            fi
            return 1
        fi
        echo "$since"
        return 0
    fi
    if [[ "$period" == "all" ]]; then
        echo "2020-01-01"
        return 0
    fi
    local days="${period%d}"
    if [[ ! "$period" =~ ^[0-9]+d$ ]]; then
        echo "Error: --period must be Nd (e.g. 7d, 30d) or 'all', got '$period'" >&2
        return 1
    fi
    date -v-"${days}"d +%Y-%m-%d 2>/dev/null || date -d "-${days} days" +%Y-%m-%d
}

# --- classification ---

USAGE_VALID_CATEGORIES=(own review misc ignore)

# Teammate branch prefixes, derived from team_members once per run: deriving
# them per session made sync quadratic in team size. Fields are
# alias:github[:branch-prefix]; the lowercased login matches a branch named
# after a GitHub user.
USAGE_REVIEW_PREFIXES=()
_usage_review_prefixes_built=""
_usage_build_review_prefixes() {
    [[ -n "$_usage_review_prefixes_built" ]] && return 0
    _usage_review_prefixes_built=1
    local entry alias github_user branch_prefix_field p
    for entry in ${team_members[@]+"${team_members[@]}"}; do
        alias="${entry%%:*}"
        # "me" is the roster's own-user marker; their branches are own work.
        [[ "$alias" == "me" ]] && continue
        github_user="$(printf '%s' "$entry" | cut -d: -f2)"
        branch_prefix_field="$(printf '%s' "$entry" | cut -d: -f3)"
        for p in "$branch_prefix_field" "${github_user,,}" "$alias"; do
            [[ -n "$p" ]] && USAGE_REVIEW_PREFIXES+=("$p")
        done
    done
    return 0
}

# _usage_prefix_match <worktree> <glob> — does the name belong to that branch
# namespace? The glob may be a plain prefix ("claude") or a pattern
# ("app-[0-9]*"), and matches the name itself as well as its "-"/"/" children.
_usage_prefix_match() {
    local wt="$1" glob="$2"
    # Unquoted right-hand sides: these are patterns, not literals.
    # shellcheck disable=SC2053
    [[ "$wt" == $glob || "$wt" == ${glob}-* || "$wt" == ${glob}/* ]]
}

# _usage_default_classify <worktree> — "category|source" from config alone.
_usage_default_classify() {
    local wt="$1" p entry glob category

    if _usage_prefix_match "$wt" "${branch_prefix}"; then
        echo "own|branch_prefix"
        return 0
    fi

    # Teammate prefixes come before the own-work globs below, so a teammate's
    # "fix-..." branch is not miscounted as own work.
    _usage_build_review_prefixes
    for p in ${USAGE_REVIEW_PREFIXES[@]+"${USAGE_REVIEW_PREFIXES[@]}"}; do
        if _usage_prefix_match "$wt" "$p"; then
            echo "review|branch_prefix"
            return 0
        fi
    done

    for p in ${usage_own_prefixes[@]+"${usage_own_prefixes[@]}"}; do
        if _usage_prefix_match "$wt" "$p"; then
            echo "own|branch_prefix"
            return 0
        fi
    done

    for entry in ${usage_extra_prefixes[@]+"${usage_extra_prefixes[@]}"}; do
        glob="${entry%%:*}"
        category="${entry##*:}"
        if _usage_prefix_match "$wt" "$glob"; then
            echo "${category}|extra_prefix"
            return 0
        fi
    done

    # Eligible for the git-author pass, which only reconsiders misc|fallback.
    echo "misc|fallback"
}

# _usage_classify_worktree <worktree> — "category|source" for one worktree
# name. hook_usage_classify claims a session by printing the pair and exiting
# 0, and declines by exiting nonzero; a claim it can't honour must fail loudly
# rather than land in misc. Called directly rather than through run_hook, whose
# policies cover side-effecting hooks, not a value the caller needs back.
_usage_classify_worktree() {
    local wt="$1" claim category
    if declare -F hook_usage_classify >/dev/null; then
        if claim="$(hook_usage_classify "$wt")"; then
            category="${claim%%|*}"
            if [[ "$claim" != *"|"* || -z "$category" || -z "${claim#*|}" ]]; then
                echo "Error: hook_usage_classify returned '$claim' for '$wt' — expected 'category|source'" >&2
                return 1
            fi
            local valid=false c
            for c in "${USAGE_VALID_CATEGORIES[@]}"; do
                [[ "$category" == "$c" ]] && valid=true && break
            done
            if [[ "$valid" != true ]]; then
                echo "Error: hook_usage_classify returned category '$category' for '$wt'." \
                     "Valid: ${USAGE_VALID_CATEGORIES[*]}" >&2
                return 1
            fi
            printf '%s\n' "$claim"
            return 0
        fi
    fi
    _usage_default_classify "$wt"
}

# --- projects and Claude's mangled directory names ---
#
# Claude names a session's project directory after its path with every
# character outside [A-Za-z0-9] replaced by "-". That mangling is
# deterministic forwards and irreversible backwards (both "/" and "_" become
# "-"), so core maps each registered project's directories *into* that
# namespace rather than trying to invert a name back into a path.

_usage_mangle_dir() {
    printf '%s' "${1//[^a-zA-Z0-9]/-}"
}

# Mangled repo root -> project, and mangled worktrees dir -> project.
# -g: lib files are sourced from inside functions in the test harness.
declare -gA USAGE_MAP_MAIN=()
declare -gA USAGE_MAP_WT=()

# A project field of "-" means "no registered project claims this directory".
# The placeholder exists because bash `read` with a tab IFS swallows a leading
# empty field, which would silently shift the worktree name into it.
USAGE_NO_PROJECT="-"
# And "*" means "any project" — a bare name typed with no project to scope it.
USAGE_ANY_PROJECT="*"

_usage_load_project_map() {
    USAGE_MAP_MAIN=()
    USAGE_MAP_WT=()
    local name pair root wt rp
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        # One subshell per project: load_config assigns the config globals and
        # sources that project's extension, neither of which may leak into the
        # next project or into the caller.
        pair="$(load_config "$name" >/dev/null 2>&1 && printf '%s\t%s' "$repo_root" "$worktrees_dir")" || continue
        IFS=$'\t' read -r root wt <<<"$pair"
        # Both the configured and the resolved path: Claude records the cwd it
        # was started in, which may have travelled through a symlink.
        if [[ -n "$root" ]]; then
            USAGE_MAP_MAIN["$(_usage_mangle_dir "$root")"]="$name"
            rp="$(realpath "$root" 2>/dev/null || true)"
            [[ -n "$rp" && "$rp" != "$root" ]] && USAGE_MAP_MAIN["$(_usage_mangle_dir "$rp")"]="$name"
        fi
        if [[ -n "$wt" ]]; then
            USAGE_MAP_WT["$(_usage_mangle_dir "$wt")"]="$name"
            rp="$(realpath "$wt" 2>/dev/null || true)"
            [[ -n "$rp" && "$rp" != "$wt" ]] && USAGE_MAP_WT["$(_usage_mangle_dir "$rp")"]="$name"
        fi
    done < <(list_projects)
    return 0
}

# _usage_target_for_dir <mangled-dir> — "<project-or-dash>\t<worktree>".
# A main checkout reports the worktree name "main"; an unclaimed directory
# keeps the mangled name as its worktree, which is all there is to call it.
_usage_target_for_dir() {
    local dir="$1" key best="" best_len=0
    if [[ -n "${USAGE_MAP_MAIN[$dir]:-}" ]]; then
        printf '%s\t%s' "${USAGE_MAP_MAIN[$dir]}" main
        return 0
    fi
    # Longest match wins, so nested worktrees dirs resolve to the inner project.
    for key in ${USAGE_MAP_WT[@]+"${!USAGE_MAP_WT[@]}"}; do
        if [[ "$dir" == "$key-"* && ${#key} -gt $best_len ]]; then
            best="$key"
            best_len=${#key}
        fi
    done
    if [[ -n "$best" ]]; then
        printf '%s\t%s' "${USAGE_MAP_WT[$best]}" "${dir#"$best"-}"
        return 0
    fi
    printf '%s\t%s' "$USAGE_NO_PROJECT" "$dir"
}

# --- sync ---

# _usage_sync <since> <period> — rebuild the cache: ccusage totals, then
# per-project classification, then the transcript parser. Any failure ends the
# run; half a report is worse than none, because the missing half reads as
# zero rather than as absent.
_usage_sync() {
    local since="$1" period="$2"

    _usage_init_db || return 1
    # Resolve the zone here, in the caller's shell: every other reader of
    # USAGE_TZ_* would otherwise pick it up inside a command substitution,
    # where the resolved values die with the subshell.
    _usage_load_tz || return 1
    since="$(_usage_compute_since "$since" "$period")" || return 1
    local since_utc
    since_utc="$(_usage_since_utc "$since")" || return 1

    _usage_require_cmd npx "'fw usage sync' reads totals from ccusage" \
        "Install Node.js." || return 1
    _usage_require_cmd jq "'fw usage sync' parses the ccusage JSON with it" \
        "Install jq (brew install jq)." || return 1
    # Build before the network call: a missing toolchain should fail in a
    # second rather than after a ccusage fetch.
    _ensure_usage_parser || return 1

    # One scratch dir, removed on every exit path. Not a RETURN trap: the test
    # harness runs with functrace, where such a trap fires on the return of
    # every nested function and deletes the files mid-run.
    local work rc=0
    work="$(mktemp -d "${TMPDIR:-/tmp}/fw-usage.XXXXXX")" || return 1
    _usage_sync_run "$work" "$since" "$since_utc" || rc=$?
    rm -rf "$work"
    return $rc
}

# _usage_sync_run <scratch-dir> <since> <since-utc> — the pipeline itself.
_usage_sync_run() {
    local work="$1" since="$2" since_utc="$3"

    echo "Syncing usage data since ${since} ${USAGE_TZ_LABEL}..."

    local ccusage_json
    # --yes: on a first run npx must install ccusage, and without it npx prompts
    # "Ok to proceed?" on stderr while blocking on stdin — which the 2>/dev/null
    # here would swallow, leaving the sync silently hung waiting for a keypress.
    ccusage_json="$(npx --yes ccusage claude session --json --since "$since" 2>/dev/null)" || {
        echo "Error: ccusage failed. Try: npx ccusage@latest --help" >&2
        return 1
    }

    local session_count
    session_count="$(printf '%s' "$ccusage_json" | jq '.sessions | length')" || {
        echo "Error: could not read the ccusage output as JSON" >&2
        return 1
    }
    echo "  Found $session_count sessions from ccusage"

    # One jq pass emits TSV, one bash pass resolves projects, one bash pass
    # applies the classifications, one sqlite3 import loads them. The
    # pre-optimization legacy version forked ~11 jq processes plus a sqlite3
    # per session.
    local tsv="$work/ccusage.tsv" resolved="$work/resolved.tsv"
    local staged="$work/staged.tsv" classes="$work/classes.tsv"
    : >"$resolved"
    : >"$staged"
    : >"$classes"

    printf '%s' "$ccusage_json" | jq -r '
        .sessions[] | [
            .sessionId, .projectPath, (.modelsUsed[0] // "unknown"),
            (.inputTokens // 0), (.outputTokens // 0),
            (.cacheCreationTokens // 0), (.cacheReadTokens // 0),
            (.totalCost // 0), (.firstActivity // ""), (.lastActivity // "")
        ] | @tsv' > "$tsv" || {
        echo "Error: could not read the ccusage output as JSON" >&2
        return 1
    }

    _usage_load_project_map

    # Pass 1: resolve each session's directory to (project, worktree),
    # memoised per directory, and collect the worktrees each project owns.
    local -A dir_target=()
    local -A proj_worktrees=()
    local -A pair_seen=()
    local sid ppath model in_tok out_tok cc_tok cr_tok cost first last proj wt
    local inserted=0
    while IFS=$'\t' read -r sid ppath model in_tok out_tok cc_tok cr_tok cost first last; do
        [[ -z "$sid" ]] && continue
        if [[ -z "${dir_target[$ppath]:-}" ]]; then
            dir_target[$ppath]="$(_usage_target_for_dir "$ppath")"
        fi
        IFS=$'\t' read -r proj wt <<<"${dir_target[$ppath]}"
        if [[ "$proj" != "$USAGE_NO_PROJECT" && -z "${pair_seen[$proj/$wt]:-}" ]]; then
            pair_seen[$proj/$wt]=1
            proj_worktrees[$proj]+="$wt"$'\n'
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$proj" "$wt" "$sid" "$model" "$in_tok" "$out_tok" "$cc_tok" "$cr_tok" \
            "$cost" "$first" "$last" "$ppath" >> "$resolved"
        inserted=$((inserted + 1))
    done < "$tsv"

    # Pass 2: classify, one project at a time, each in a subshell holding only
    # that project's config and hooks. Sessions in unregistered directories
    # are left uncategorised — no project's rules apply to them.
    for proj in ${proj_worktrees[@]+"${!proj_worktrees[@]}"}; do
        printf '%s' "${proj_worktrees[$proj]}" | (
            # A hook from a previously-loaded project must not classify this
            # one; load_config resets the config globals but not functions.
            unset -f hook_usage_classify
            USAGE_REVIEW_PREFIXES=()
            _usage_review_prefixes_built=""
            load_config "$proj" >/dev/null || exit 1
            name=""
            claim=""
            while IFS= read -r name; do
                [[ -n "$name" ]] || continue
                claim="$(_usage_classify_worktree "$name")" || exit 1
                printf '%s\t%s\t%s\n' "$proj" "$name" "$claim"
            done
        ) >> "$classes" || return 1
    done

    local -A class_of=()
    local cat_and_source
    while IFS=$'\t' read -r proj wt cat_and_source; do
        [[ -n "$proj" ]] || continue
        class_of["$proj/$wt"]="$cat_and_source"
    done < "$classes"

    # Pass 3: stage the rows with their categories. Unclaimed directories
    # carry empty project/category fields, which the import turns into NULL.
    local claim category cat_source
    while IFS=$'\t' read -r proj wt sid model in_tok out_tok cc_tok cr_tok cost first last ppath; do
        [[ -z "$sid" ]] && continue
        category=""
        cat_source=""
        if [[ "$proj" == "$USAGE_NO_PROJECT" ]]; then
            proj=""
        else
            claim="${class_of["$proj/$wt"]:-}"
            category="${claim%%|*}"
            cat_source="${claim##*|}"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$sid" "$proj" "$wt" "$category" "$cat_source" "$model" \
            "$in_tok" "$out_tok" "$cc_tok" "$cr_tok" "$cost" "$first" "$last" >> "$staged"
    done < "$resolved"

    if [[ $inserted -gt 0 ]]; then
        sqlite3 "$USAGE_DB" <<SQL || { echo "Error: could not import the ccusage sessions" >&2; return 1; }
CREATE TEMP TABLE staging (
    session_id TEXT, project TEXT, worktree TEXT, category TEXT, category_source TEXT,
    model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_create INTEGER,
    cache_read INTEGER, total_cost REAL, first_activity TEXT, last_activity TEXT
);
.mode tabs
.import '$staged' staging
INSERT OR REPLACE INTO sessions
    (session_id, project, worktree, category, category_source, model,
     input_tokens, output_tokens, cache_create, cache_read,
     total_cost, first_activity, last_activity)
SELECT session_id, NULLIF(project, ''), worktree, NULLIF(category, ''),
       NULLIF(category_source, ''), model,
       input_tokens, output_tokens, cache_create, cache_read,
       total_cost, first_activity, last_activity
FROM staging;
SQL
    fi

    echo "  Synced $inserted sessions to $USAGE_DB"

    _usage_reclassify_by_git_author "$since_utc" || return 1

    sqlite3 "$USAGE_DB" "DELETE FROM sessions WHERE category = 'ignore';"

    _run_usage_parser "$USAGE_DB" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" || {
        echo "Error: the transcript parser failed — no main-loop/subagent split was recorded" >&2
        return 1
    }

    echo
    echo "Category breakdown:"
    sqlite3 -column -header "$USAGE_DB" "
        SELECT
            COALESCE(category, 'unclaimed') AS category,
            COUNT(*) AS sessions,
            -- round() before every precision-0 printf: sqlite's own printf
            -- truncates at %.0f (66.9 prints as 66) instead of rounding.
            printf('\$%,.0f', round(SUM(total_cost))) AS cost,
            printf('%,.0fk', round(SUM(output_tokens) / 1000.0)) AS output_tokens
        FROM sessions
        WHERE first_activity >= '$since_utc'
        GROUP BY category
        ORDER BY SUM(total_cost) DESC;
    "
}

# _usage_own_email_patterns — email fragments identifying the current user, for
# git-author classification. Runs with a project's config loaded.
_usage_own_email_patterns() {
    local email
    email="$(git -C "$repo_root" config user.email 2>/dev/null || true)"
    if [[ -n "$email" ]]; then
        echo "$email"
        # The local part too, so jason@example.com also matches a
        # jason@users.noreply address.
        echo "${email%%@*}"
    fi
    [[ -n "$branch_prefix" ]] && echo "$branch_prefix"
    return 0
}

# _usage_reclassify_by_git_author <since-utc> — second look at the worktrees
# the classifier could only call misc|fallback: whoever authored the branch tip
# decides. Local refs only — a sync must never fetch.
_usage_reclassify_by_git_author() {
    local since_utc="$1"
    local rows
    rows="$(sqlite3 -separator $'\t' "$USAGE_DB" "
        SELECT DISTINCT project, worktree FROM sessions
        WHERE category = 'misc' AND category_source = 'fallback'
          AND project IS NOT NULL AND worktree <> 'main'
          AND first_activity >= '$since_utc';
    ")"
    [[ -z "$rows" ]] && return 0

    local -A proj_worktrees=()
    local proj wt total=0
    while IFS=$'\t' read -r proj wt; do
        [[ -n "$proj" && -n "$wt" ]] || continue
        proj_worktrees[$proj]+="$wt"$'\n'
        total=$((total + 1))
    done <<<"$rows"
    [[ $total -eq 0 ]] && return 0

    echo "  Checking git author for $total unclassified worktrees..."
    local reclassified=0 counted
    for proj in "${!proj_worktrees[@]}"; do
        counted="$(printf '%s' "${proj_worktrees[$proj]}" | (
            load_config "$proj" >/dev/null || exit 0
            own_patterns=()
            while IFS= read -r pattern; do
                [[ -n "$pattern" ]] && own_patterns+=("$pattern")
            done < <(_usage_own_email_patterns)

            done_count=0
            while IFS= read -r name; do
                [[ -n "$name" ]] || continue
                # The worktree name is the branch name, possibly without the
                # user's own prefix.
                branch=""
                for prefix in "" "${branch_prefix}/"; do
                    if git -C "$repo_root" rev-parse --verify "origin/${prefix}${name}" &>/dev/null; then
                        branch="${prefix}${name}"
                        break
                    fi
                done
                [[ -n "$branch" ]] || continue
                author="$(git -C "$repo_root" log -1 --format='%ae' "origin/$branch" 2>/dev/null)" || continue

                new_category=""
                for pattern in ${own_patterns[@]+"${own_patterns[@]}"}; do
                    if [[ "$author" == *"$pattern"* ]]; then
                        new_category="own"
                        break
                    fi
                done
                # Anything else authored in the project's own repo is a
                # teammate's branch.
                [[ -n "$new_category" ]] || new_category="review"

                sqlite3 "$USAGE_DB" "
                    UPDATE sessions SET category = '$new_category', category_source = 'git_author'
                    WHERE project = '$(_sql_quote "$proj")' AND worktree = '$(_sql_quote "$name")'
                      AND category = 'misc' AND category_source = 'fallback';"
                done_count=$((done_count + 1))
            done
            printf '%s' "$done_count"
        ))" || counted=0
        reclassified=$((reclassified + counted))
    done

    [[ $reclassified -gt 0 ]] && echo "  Reclassified $reclassified worktrees by git author"
    return 0
}

# --- reporting ---

# SQL rewriting an absolute path under $HOME to its "~/..." form.
_usage_home_relative_sql() {
    local expr="$1" home
    home="$(_sql_quote "$HOME")"
    echo "CASE WHEN $expr LIKE '${home}/%'
               THEN '~' || SUBSTR($expr, LENGTH('${home}') + 1)
               ELSE $expr END"
}

# _usage_resolve_worktree_name <name> — a worktree name, branch name, or the
# truncated cell `fw prs` prints. A name matching no live worktree passes
# through unchanged: usage data outlives the directory it was recorded in.
_usage_resolve_worktree_name() {
    local name="${1%…}"
    [[ -n "$name" ]] || return 1
    if [[ -d "$worktrees_dir/$name" ]]; then
        echo "$name"
        return 0
    fi
    local resolved
    resolved="$(worktree_name_for_branch "$name")"
    if [[ -n "$resolved" ]]; then
        echo "$resolved"
        return 0
    fi
    echo "$name"
}

# _usage_worktree_for_path <path> — "<project-or-dash>\t<worktree>" for any
# directory Claude has run in. A path is the only way to name a directory
# outside a project: Claude's mangling of "/" and "_" to "-" cannot be
# inverted, but the transcripts record the real cwd and sync stores it.
_usage_worktree_for_path() {
    local path="$1" abs project_dir
    abs="$(cd "$path" 2>/dev/null && pwd)" || abs="$path"
    project_dir="$(sqlite3 "$USAGE_DB" "
        SELECT project_dir FROM projects WHERE cwd = '$(_sql_quote "$abs")';")"
    if [[ -z "$project_dir" ]]; then
        echo "Error: no usage data for '$abs'" >&2
        if [[ "$(sqlite3 "$USAGE_DB" "SELECT COUNT(*) FROM projects;")" == "0" ]]; then
            echo "No project paths recorded yet — run 'fw usage sync'." >&2
        else
            echo "Only directories Claude has run in have usage; 'fw usage summary' lists them." >&2
        fi
        return 1
    fi
    # A path and a sync must land on the same row, so both go through the one
    # directory-to-target rule.
    _usage_load_project_map
    _usage_target_for_dir "$project_dir"
}

# _usage_project_clause <project-or-dash> — the SQL scoping a report to one
# project ("-" being the sessions no project claims).
_usage_project_clause() {
    case "$1" in
        "$USAGE_NO_PROJECT")  echo "project IS NULL" ;;
        "$USAGE_ANY_PROJECT") echo "1 = 1" ;;
        *) echo "project = '$(_sql_quote "$1")'" ;;
    esac
}

# _usage_sub_pct_display <pct> — SUB% right-aligned in 5 columns, with an em
# dash where there is nothing to split.
_usage_sub_pct_display() {
    if [[ "$1" == "0" || -z "$1" ]]; then
        printf '    —'
    else
        printf '%5s' "${1}%"
    fi
}

_usage_show_summary() {
    local since="$1" category_filter="$2" json_output="$3" weight="$4" active="$5"
    local view="session_costs_${weight}"
    local since_utc
    since_utc="$(_usage_since_utc "$since")" || return 1
    local where="first_activity >= '$since_utc'"
    [[ -n "$category_filter" ]] && where="$where AND category = '$(_sql_quote "$category_filter")'"

    if [[ "$json_output" == true ]]; then
        sqlite3 -json "$USAGE_DB" "
            SELECT
                v.project,
                v.worktree,
                p.cwd AS project_path,
                category,
                COUNT(*) as sessions,
                ROUND(SUM(total_cost), 2) as cost,
                ROUND(SUM(main_cost), 2) as main_cost,
                ROUND(SUM(sub_cost), 2) as subagent_cost,
                ROUND(SUM(cache_read_pct * total_cost) / NULLIF(SUM(total_cost), 0), 1) as cache_read_pct,
                '$weight' as weight_basis,
                SUM(output_tokens) as output_tokens,
                MIN(first_activity) as earliest,
                MAX(last_activity) as latest
            FROM (SELECT * FROM $view WHERE $where) v
            LEFT JOIN projects p ON p.project_dir = v.worktree
            GROUP BY v.project, v.worktree
            ORDER BY SUM(total_cost) DESC;
        "
        return 0
    fi

    # Totals are summed at full precision and rounded once for display, so the
    # header agrees with the rows beneath it.
    local header total_sessions total_cost main_cost sub_cost cr_pct
    header="$(sqlite3 -separator '|' "$USAGE_DB" "
        SELECT COUNT(DISTINCT session_id),
               printf('%.0f', round(COALESCE(SUM(total_cost), 0))),
               printf('%.0f', round(COALESCE(SUM(main_cost), 0))),
               printf('%.0f', round(COALESCE(SUM(sub_cost), 0))),
               printf('%.0f', CASE WHEN COALESCE(SUM(total_cost), 0) > 0
                                   THEN round(SUM(cache_read_pct * total_cost) / SUM(total_cost)) ELSE 0 END)
        FROM $view WHERE $where;
    ")"
    IFS='|' read -r total_sessions total_cost main_cost sub_cost cr_pct <<<"$header"

    echo "Claude Code Usage since ${since} ${USAGE_TZ_LABEL}  ·  ${total_sessions} sessions  ·  \$${total_cost} (main \$${main_cost} + subagents \$${sub_cost})"
    echo "${cr_pct}% of estimated cost is cache reads · split weighted by $(_usage_weight_label "$weight")"

    if [[ -n "$active" ]]; then
        _usage_show_project_section "$active" "$where" "$view"
        _usage_show_other_registered "$active" "$where" "$view"
    else
        # No active project: nothing makes one project the headline, so each
        # gets the full treatment.
        local proj
        while IFS= read -r proj; do
            [[ -n "$proj" ]] && _usage_show_project_section "$proj" "$where" "$view"
        done < <(sqlite3 "$USAGE_DB" "
            SELECT project FROM $view WHERE $where AND project IS NOT NULL
            GROUP BY project ORDER BY SUM(total_cost) DESC;")
    fi

    _usage_show_other_projects "$where" "$view"
}

# _usage_show_project_section <project> <where> <view> — one project's category
# split and per-worktree table. Silent when the project has no sessions in the
# window, so an empty heading never appears.
_usage_show_project_section() {
    local project="$1" where="$2" view="$3"
    local scope
    scope="$where AND project = '$(_sql_quote "$project")'"

    local rows
    rows="$(sqlite3 -separator '|' "$USAGE_DB" "
        SELECT category, COUNT(DISTINCT session_id), printf('%.0f', round(SUM(total_cost)))
        FROM $view WHERE $scope
        GROUP BY category ORDER BY SUM(total_cost) DESC;")"
    [[ -n "$rows" ]] || return 0

    echo
    echo "$project"
    local cat cnt cost
    while IFS='|' read -r cat cnt cost; do
        [[ -n "$cat" ]] || continue
        printf "  %-14s %3s sessions  \$%s\n" "$cat" "$cnt" "$cost"
    done <<<"$rows"

    echo
    printf "%-44s %-4s %5s %10s %5s %4s  %s\n" "WORKTREE" "CAT" "SESS" "COST" "SUB%" "CR%" "OUTPUT"
    printf "%-44s %-4s %5s %10s %5s %4s  %s\n" "--------" "---" "----" "----" "----" "---" "------"

    local wt output sub_pct
    sqlite3 -separator '|' "$USAGE_DB" "
        SELECT
            worktree,
            UPPER(SUBSTR(category, 1, 1)) || SUBSTR(category, 2, 3),
            COUNT(DISTINCT session_id),
            printf('\$%,.0f', round(SUM(total_cost))),
            printf('%,.0fk', round(SUM(output_tokens) / 1000.0)),
            CASE WHEN SUM(total_cost) > 0
                THEN printf('%.0f', round(SUM(sub_cost) / SUM(total_cost) * 100)) ELSE '0' END,
            CASE WHEN SUM(total_cost) > 0
                THEN printf('%.0f', round(SUM(cache_read_pct * total_cost) / SUM(total_cost))) ELSE '0' END
        FROM $view
        WHERE $scope
        GROUP BY worktree
        ORDER BY SUM(total_cost) DESC;
    " | while IFS='|' read -r wt cat cnt cost output sub_pct cr_pct; do
        [[ ${#wt} -gt 44 ]] && wt="${wt:0:42}.."
        printf "%-44s %-4s %5s %10s %s %3s%%  %s\n" \
            "$wt" "$cat" "$cnt" "$cost" "$(_usage_sub_pct_display "$sub_pct")" "$cr_pct" "$output"
    done
}

# _usage_show_other_registered <active> <where> <view> — every other
# registered project as a single subtotal line: the active project is the one
# being worked in, the rest are context.
_usage_show_other_registered() {
    local active="$1" where="$2" view="$3"
    local scope
    scope="$where AND project IS NOT NULL AND project <> '$(_sql_quote "$active")'"

    local rows
    rows="$(sqlite3 -separator '|' "$USAGE_DB" "
        SELECT project,
               COUNT(DISTINCT session_id),
               printf('\$%,.0f', round(SUM(total_cost))),
               printf('%,.0fk', round(SUM(output_tokens) / 1000.0)),
               CASE WHEN SUM(total_cost) > 0
                   THEN printf('%.0f', round(SUM(sub_cost) / SUM(total_cost) * 100)) ELSE '0' END,
               CASE WHEN SUM(total_cost) > 0
                   THEN printf('%.0f', round(SUM(cache_read_pct * total_cost) / SUM(total_cost))) ELSE '0' END
        FROM $view WHERE $scope
        GROUP BY project ORDER BY SUM(total_cost) DESC;")"
    [[ -n "$rows" ]] || return 0

    echo
    echo "Other projects you have registered"
    local proj cnt cost output sub_pct cr_pct
    while IFS='|' read -r proj cnt cost output sub_pct cr_pct; do
        [[ -n "$proj" ]] || continue
        printf "%-49s %5s %10s %s %3s%%  %s\n" \
            "$proj" "$cnt" "$cost" "$(_usage_sub_pct_display "$sub_pct")" "$cr_pct" "$output"
    done <<<"$rows"
}

# _usage_show_other_projects <where> <view> — sessions in directories no
# registered project claims. They carry no category worth reporting, and
# mixing them into the own/review/misc split would attribute other work to a
# project. They stay in the header total, so nothing goes missing.
_usage_show_other_projects() {
    local where="$1" view="$2"
    local subtotal other_sessions other_cost
    subtotal="$(sqlite3 -separator '|' "$USAGE_DB" "
        SELECT COUNT(DISTINCT session_id), printf('%.0f', round(COALESCE(SUM(total_cost), 0)))
        FROM $view WHERE $where AND project IS NULL;")"
    IFS='|' read -r other_sessions other_cost <<<"$subtotal"
    [[ "${other_sessions:-0}" -eq 0 ]] && return 0

    echo
    echo "Other projects — ${other_sessions} sessions, \$${other_cost} (in the total above, not in the categories)"

    # The mangled directory name is the join key; the path is what a caller can
    # actually type back, so a directory the parser has not seen yet falls back
    # to the name it is stored under.
    local proj cnt cost output sub_pct cr_pct
    sqlite3 -separator '|' "$USAGE_DB" "
        SELECT
            COALESCE($(_usage_home_relative_sql "p.cwd"), v.worktree),
            COUNT(DISTINCT v.session_id),
            printf('\$%,.0f', round(SUM(v.total_cost))),
            printf('%,.0fk', round(SUM(v.output_tokens) / 1000.0)),
            CASE WHEN SUM(v.total_cost) > 0
                THEN printf('%.0f', round(SUM(v.sub_cost) / SUM(v.total_cost) * 100)) ELSE '0' END,
            CASE WHEN SUM(v.total_cost) > 0
                THEN printf('%.0f', round(SUM(v.cache_read_pct * v.total_cost) / SUM(v.total_cost))) ELSE '0' END
        FROM (SELECT * FROM $view WHERE $where AND project IS NULL) v
        LEFT JOIN projects p ON p.project_dir = v.worktree
        GROUP BY v.worktree
        ORDER BY SUM(v.total_cost) DESC;
    " | while IFS='|' read -r proj cnt cost output sub_pct cr_pct; do
        [[ ${#proj} -gt 49 ]] && proj="${proj:0:47}.."
        printf "%-49s %5s %10s %s %3s%%  %s\n" \
            "$proj" "$cnt" "$cost" "$(_usage_sub_pct_display "$sub_pct")" "$cr_pct" "$output"
    done
}

# _usage_show_detail <project-or-dash> <worktree> <since> <json> <weight>
_usage_show_detail() {
    local project="$1" wt_name="$2" since="$3" json_output="$4" weight="$5"
    local view="session_costs_${weight}"
    local since_utc
    since_utc="$(_usage_since_utc "$since")" || return 1
    local proj_clause
    proj_clause="$(_usage_project_clause "$project")"
    local escaped_wt
    escaped_wt="$(_sql_quote "$wt_name")"

    # Exact match first, then a prefix — a truncated or shortened name is the
    # common way to type one of these.
    local match
    match="$(sqlite3 "$USAGE_DB" "
        SELECT worktree FROM sessions
        WHERE $proj_clause AND worktree = '$escaped_wt' AND first_activity >= '$since_utc'
        LIMIT 1;")"
    if [[ -z "$match" ]]; then
        match="$(sqlite3 "$USAGE_DB" "
            SELECT DISTINCT worktree FROM sessions
            WHERE $proj_clause AND worktree LIKE '${escaped_wt}%' AND first_activity >= '$since_utc'
            ORDER BY worktree LIMIT 1;")"
    fi
    if [[ -z "$match" ]]; then
        echo "Error: no usage data for '$wt_name'" >&2
        echo "Try 'fw usage summary' to see what is recorded." >&2
        return 1
    fi
    wt_name="$match"
    escaped_wt="$(_sql_quote "$wt_name")"
    local scope="$proj_clause AND worktree = '$escaped_wt' AND first_activity >= '$since_utc'"

    # A directory no project claims is stored under Claude's mangled name.
    # Show the path instead — it is also what a caller can type back.
    # Only a mangled directory name has a recorded path, so this lookup is a
    # no-op for real worktree names.
    local label="$wt_name" project_cwd
    if [[ "$project" == "$USAGE_NO_PROJECT" || "$project" == "$USAGE_ANY_PROJECT" ]]; then
        project_cwd="$(sqlite3 "$USAGE_DB" "SELECT cwd FROM projects WHERE project_dir = '$escaped_wt';")"
        if [[ -n "$project_cwd" ]]; then
            label="$project_cwd"
            # Not ${x/#$HOME/~}: bash tilde-expands the replacement straight back.
            [[ "$project_cwd" == "$HOME"/* ]] && label="~${project_cwd#"$HOME"}"
        fi
    fi

    if [[ "$json_output" == true ]]; then
        sqlite3 -json "$USAGE_DB" "
            SELECT session_id,
                   ROUND(main_cost, 4) AS main_loop_cost,
                   ROUND(sub_cost, 4)  AS subagent_cost,
                   ROUND(total_cost, 4) AS total_cost,
                   ROUND(cache_read_pct, 1) AS cache_read_pct,
                   cache_rewrites,
                   cache_rewrite_tokens,
                   ROUND(cache_rewrite_pct, 1) AS cache_rewrite_pct,
                   '$weight' AS weight_basis,
                   model, first_activity
            FROM $view
            WHERE $scope
            ORDER BY total_cost DESC;
        "
        return 0
    fi

    local header total_sessions grand_total sub_pct cr_pct rw_count rw_tokens rw_cost
    header="$(sqlite3 -separator '|' "$USAGE_DB" "
        SELECT COUNT(*),
               printf('%.2f', COALESCE(SUM(total_cost), 0)),
               printf('%.0f', CASE WHEN COALESCE(SUM(total_cost), 0) > 0
                                   THEN round(SUM(sub_cost) / SUM(total_cost) * 100) ELSE 0 END),
               printf('%.0f', CASE WHEN COALESCE(SUM(total_cost), 0) > 0
                                   THEN round(SUM(cache_read_pct * total_cost) / SUM(total_cost)) ELSE 0 END),
               COALESCE(SUM(cache_rewrites), 0),
               CASE WHEN COALESCE(SUM(cache_rewrite_tokens), 0) >= 1000000
                    THEN printf('%.1fM', SUM(cache_rewrite_tokens) / 1e6)
                    ELSE printf('%.0fk', round(COALESCE(SUM(cache_rewrite_tokens), 0) / 1000.0)) END,
               printf('%.2f', COALESCE(SUM(cache_rewrite_pct * total_cost), 0) / 100)
        FROM $view WHERE $scope;
    ")"
    IFS='|' read -r total_sessions grand_total sub_pct cr_pct rw_count rw_tokens rw_cost <<<"$header"

    echo "${label} — ${total_sessions} sessions, \$${grand_total} (${sub_pct}% subagents by $(_usage_weight_label "$weight") · ${cr_pct}% cache reads)"
    # Rewrites are usually absent, so they get a line only when they happen.
    if [[ "${rw_count:-0}" -gt 0 ]]; then
        local plural=""
        [[ "$rw_count" -ne 1 ]] && plural="s"
        echo "${rw_count} cache rewrite${plural} — ${rw_tokens} tokens the cache did not hold, re-written at write price (\$${rw_cost})"
    fi
    echo

    # One query renders every line of the breakdown: percentages and the
    # apportioned per-agent costs are computed in SQL rather than by forking a
    # process per session per agent type.
    local kind f1 f2 f3 f4 f5
    sqlite3 -separator '|' "$USAGE_DB" "
        WITH sc AS (
            SELECT * FROM $view WHERE $scope
        ),
        agent_totals AS (
            SELECT session_id, SUM(estimated_cost) AS tw FROM subagents GROUP BY session_id
        ),
        by_type AS (
            SELECT sa.session_id, sa.agent_type,
                   SUM(sa.estimated_cost) AS w,
                   COUNT(DISTINCT sa.agent_id) AS n,
                   (SELECT REPLACE(s2.model, 'claude-', '') FROM subagents s2
                     WHERE s2.session_id = sa.session_id AND s2.agent_type = sa.agent_type
                     GROUP BY s2.model ORDER BY SUM(s2.estimated_cost) DESC LIMIT 1) AS m
            FROM subagents sa GROUP BY sa.session_id, sa.agent_type
        )
        SELECT sc.total_cost AS sort_total, 0 AS ord, 0 AS sort_cost, 'S',
               SUBSTR(sc.session_id, 1, 8), printf('%.2f', sc.total_cost),
               SUBSTR($(_usage_local_sql 'sc.first_activity'), 1, 10), REPLACE(sc.model, 'claude-', ''),
               CASE WHEN sc.cache_rewrites > 0
                    THEN printf('↻%d rewrite%s (%s)', sc.cache_rewrites,
                                CASE WHEN sc.cache_rewrites = 1 THEN '' ELSE 's' END,
                                CASE WHEN sc.cache_rewrite_tokens >= 1000000
                                     THEN printf('%.1fM', sc.cache_rewrite_tokens / 1e6)
                                     ELSE printf('%.0fk', round(sc.cache_rewrite_tokens / 1000.0)) END)
                    ELSE '' END
        FROM sc
        UNION ALL
        SELECT sc.total_cost, 1, 0, 'M',
               'Main loop', printf('%.2f', sc.main_cost),
               printf('%.0f', CASE WHEN sc.total_cost > 0
                                   THEN round(sc.main_cost / sc.total_cost * 100) ELSE 100 END), '', ''
        FROM sc
        WHERE EXISTS (SELECT 1 FROM by_type WHERE by_type.session_id = sc.session_id)
        UNION ALL
        SELECT sc.total_cost, 2, bt.w, 'A',
               bt.agent_type, printf('%.2f', sc.sub_cost * bt.w / at.tw),
               printf('%.0f', CASE WHEN sc.total_cost > 0
                                   THEN round((sc.sub_cost * bt.w / at.tw) / sc.total_cost * 100) ELSE 0 END),
               bt.n, bt.m
        FROM sc
        JOIN by_type bt ON bt.session_id = sc.session_id
        JOIN agent_totals at ON at.session_id = sc.session_id AND at.tw > 0
        UNION ALL
        SELECT sc.total_cost, 3, 0, 'N', '', '', '', '', ''
        FROM sc
        WHERE NOT EXISTS (SELECT 1 FROM by_type WHERE by_type.session_id = sc.session_id)
        ORDER BY sort_total DESC, ord, sort_cost DESC;
    " | while IFS='|' read -r _sort_total _ord _sort_cost kind f1 f2 f3 f4 f5; do
        case "$kind" in
            S) [[ -n "${seen_session:-}" ]] && echo
               seen_session=1
               echo "Session ${f1}  \$${f2}  ${f3}  ${f4}${f5:+  ${f5}}" ;;
            M) printf "  %-36s \$%-8s (%s%%)\n" "$f1" "$f2" "$f3" ;;
            A) printf "  %-36s \$%-8s (%s%%)  ×%-2s %s\n" "$f1" "$f2" "$f3" "$f4" "$f5" ;;
            N) echo "  (no subagents)" ;;
        esac
    done

    echo
}

cmd_usage() {
    local since="" period="30d" subcmd="" show_category="" json_output=false
    local worktree_arg="" weight="cost"

    if [[ $# -gt 0 && "$1" != -* ]]; then
        case "$1" in
            sync)    subcmd="sync"; shift ;;
            summary) subcmd="summary"; shift ;;
            *)       worktree_arg="$1"; shift ;;
        esac
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --since) since="${2:?Error: --since requires a date}"; shift 2 ;;
            --period) period="${2:?Error: --period requires a value}"; shift 2 ;;
            --category) show_category="${2:?Error: --category requires a value}"; shift 2 ;;
            --weight) weight="${2:?Error: --weight requires a value}"; shift 2 ;;
            --json) json_output=true; shift ;;
            -h|--help) _usage_help; return 0 ;;
            *)
                echo "Error: unknown option '$1'" >&2
                return 1
                ;;
        esac
    done

    if [[ -n "$show_category" ]]; then
        local cat_valid=false c
        for c in "${USAGE_VALID_CATEGORIES[@]}"; do
            [[ "$show_category" == "$c" ]] && cat_valid=true && break
        done
        if [[ "$cat_valid" != true ]]; then
            echo "Error: invalid category '$show_category'. Valid: ${USAGE_VALID_CATEGORIES[*]}" >&2
            return 1
        fi
    fi

    local weight_valid=false w
    for w in "${USAGE_VALID_WEIGHTS[@]}"; do
        [[ "$weight" == "$w" ]] && weight_valid=true && break
    done
    if [[ "$weight_valid" != true ]]; then
        echo "Error: invalid weight '$weight'. Valid: ${USAGE_VALID_WEIGHTS[*]}" >&2
        return 1
    fi

    # The active project leads the report and resolves worktree names, but
    # usage is global by nature: with no project resolvable there is still a
    # machine-wide report to print.
    local active=""
    if active="$(resolve_project "${PROJECT_FLAG:-}" 2>/dev/null)" && [[ -n "$active" ]]; then
        load_config "$active" >/dev/null 2>&1 || active=""
    else
        active=""
    fi

    _usage_init_db || return 1
    # Same reason as in _usage_sync: the zone must be resolved in this shell,
    # not in the subshell of the first `$(_usage_since_utc ...)`.
    _usage_load_tz || return 1

    if [[ "$subcmd" == "sync" ]]; then
        _usage_sync "$since" "$period"
        return $?
    fi

    since="$(_usage_compute_since "$since" "$period")" || return 1
    local since_utc
    since_utc="$(_usage_since_utc "$since")" || return 1

    local count
    count="$(sqlite3 "$USAGE_DB" "SELECT COUNT(*) FROM sessions WHERE first_activity >= '$since_utc';")"
    if [[ "${count:-0}" -eq 0 ]]; then
        echo "No usage data for this window. Run 'fw usage sync' first."
        return 0
    fi

    if [[ "$subcmd" == "summary" ]]; then
        _usage_show_summary "$since" "$show_category" "$json_output" "$weight" "$active"
        return $?
    fi

    local wt_name="$worktree_arg" project="$USAGE_NO_PROJECT"
    if [[ -z "$wt_name" && -n "$active" ]]; then
        wt_name="$(detect_worktree_name 2>/dev/null)" || true
    fi
    # Outside a worktree, report on the directory we are standing in — every
    # directory Claude has run in has usage, worktree or not.
    [[ -n "$wt_name" ]] || wt_name="$PWD"

    case "$wt_name" in
        /* | . | .. | ./* | ../*)
            local target
            target="$(_usage_worktree_for_path "$wt_name")" || return 1
            IFS=$'\t' read -r project wt_name <<<"$target"
            ;;
        *)
            if [[ -n "$active" ]]; then
                wt_name="$(_usage_resolve_worktree_name "$wt_name")" || return 1
                project="$active"
            else
                # Nothing scopes the name, so let any project's row answer.
                project="$USAGE_ANY_PROJECT"
            fi
            ;;
    esac

    _usage_show_detail "$project" "$wt_name" "$since" "$json_output" "$weight"
}

_usage_help() {
    cat <<'EOF'
Usage: fw usage [<worktree>|<branch>|<path>|summary|sync] [OPTIONS]

Claude Code token usage by worktree, with a subagent breakdown.

Commands:
  (none)                  Detail view for the current worktree, or for the
                          current directory when outside one
  <worktree>|<branch>     Detail view for a named worktree (names resolve as
                          they do for every other command)
  <path>                  Detail view for any directory Claude has run in
  summary                 Per-worktree summary table with subagent %
  sync                    Refresh the cache from ccusage + the transcript parser

Options:
  --since YYYY-MM-DD      Start date, local (default: 30 days ago)
  --period 7d|30d|90d|all Period shortcut (default: 30d, overridden by --since)
  --category CATEGORY     Filter to: own, review, misc
  --weight cost|output|tokens
                          Basis for the main/subagent split (default: cost)
  --json                  Output JSON instead of a table
  -h, --help              Show this help

Session costs come from ccusage, which already includes subagent spend; the
main-loop/subagent split is apportioned from the parsed transcripts.

The active project's worktrees lead the summary (-p picks another); other
registered projects follow as one-line subtotals. Sessions in directories no
project claims are listed under "Other projects", apart from the
own/review/misc split but still inside the grand total. Name one by path:
Claude's project directory mangles both "/" and "_" to "-", so the path cannot
be recovered from it, but the transcripts record the real directory.

--weight picks what "share" means when splitting a session. 'cost' weights by
estimated spend (matching ccusage's basis); 'output' by output tokens only,
which ignores context size and reads closer to work done; 'tokens' by every
token. Cache reads dominate the token mix, so SUB% is genuinely sensitive to
this — the CR% column is always cost-based regardless.

Examples:
  fw usage sync                     Refresh data
  fw usage                          Detail view for the current worktree
  fw usage jax-ls-pipeline          Detail view for a named worktree
  fw usage jax/ls-pipeline          Same, by branch name
  fw usage .                        Detail view for the current directory
  fw usage summary                  Summary of all worktrees
  fw usage summary --period 7d      Summary, last 7 days
  fw usage summary --category review  Summary, reviews only
  fw usage summary --weight output  Summary, split by output tokens
EOF
}
