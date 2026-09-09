// subagent-parser walks Claude Code session directories, parses both main-loop
// and subagent JSONL transcripts, and writes per-model token/cost data into the
// fw usage SQLite DB.
//
// The costs written here are *relative weights*, not authoritative dollars:
// `fw usage` anchors every total to the ccusage session cost and uses the
// main_loop/subagents split recorded here only to apportion it. ccusage already
// counts subagent transcripts in its session totals, so adding these costs on
// top of it would double-count subagent spend.
//
// Usage: subagent-parser <usage.db> <claude-projects-dir>
package main

import (
	"bufio"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	_ "modernc.org/sqlite"
)

// Model rates in dollars per million tokens, at Anthropic list pricing.
//
// Because these figures are only ever used as *relative* weights, what matters
// is that every model is on the same scale. Input and output are list prices;
// cache write is 2x input (the 1-hour cache TTL that Claude Code sessions use —
// the 5-minute TTL would be 1.25x) and cache read is 0.1x input.
//
// Unknown IDs are reported on stderr at the end of a run so they don't silently
// inherit `fallbackRates`.
var modelRates = map[string]rates{
	"claude-opus-5":              opusRates,
	"claude-opus-4-8":            opusRates,
	"claude-opus-4-7":            opusRates,
	"claude-opus-4-6":            opusRates,
	"claude-opus-4-5-20251101":   opusRates,
	"claude-fable-5":             {Input: 10.0, Output: 50.0, CacheWrite: 20.0, CacheRead: 1.0},
	"claude-mythos-5":            {Input: 10.0, Output: 50.0, CacheWrite: 20.0, CacheRead: 1.0},
	"claude-sonnet-5":            sonnetRates,
	"claude-sonnet-4-6":          sonnetRates,
	"claude-sonnet-4-5-20250929": sonnetRates,
	"claude-haiku-4-5-20251001":  {Input: 1.0, Output: 5.0, CacheWrite: 2.0, CacheRead: 0.10},
}

var (
	opusRates   = rates{Input: 5.0, Output: 25.0, CacheWrite: 10.0, CacheRead: 0.50}
	sonnetRates = rates{Input: 3.0, Output: 15.0, CacheWrite: 6.0, CacheRead: 0.30}
)

// Bare aliases Claude Code sometimes records instead of a full model ID.
var modelAliases = map[string]string{
	"opus":   "claude-opus-5",
	"sonnet": "claude-sonnet-5",
	"haiku":  "claude-haiku-4-5-20251001",
	"fable":  "claude-fable-5",
}

// Fallback rates for unknown models (use opus rates as conservative estimate).
var fallbackRates = opusRates

// unknownModels accumulates token counts for model IDs missing from modelRates,
// so a stale rate map surfaces as a warning instead of silent opus pricing.
var unknownModels = map[string]*modelTokens{}

type rates struct {
	Input      float64
	Output     float64
	CacheWrite float64
	CacheRead  float64
}

// jsonlEntry is the minimal structure we need from each JSONL line.
type jsonlEntry struct {
	Type             string          `json:"type"`
	Cwd              string          `json:"cwd"`
	RequestID        string          `json:"requestId"`
	AttributionAgent string          `json:"attributionAgent"`
	Message          json.RawMessage `json:"message"`
}

type messagePayload struct {
	ID    string       `json:"id"`
	Model string       `json:"model"`
	Usage messageUsage `json:"usage"`
}

type messageUsage struct {
	InputTokens              int `json:"input_tokens"`
	OutputTokens             int `json:"output_tokens"`
	CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
	CacheReadInputTokens     int `json:"cache_read_input_tokens"`
}

// response is one API response found in a main-loop transcript, held aside so
// ownership can be claimed against the whole database before it is counted.
type response struct {
	MessageID string
	RequestID string
	Model     string
	Tokens    modelTokens
}

// transcript is one parsed JSONL file: either a session's main loop or one subagent.
type transcript struct {
	Kind      string // "main" | "subagent"
	SessionID string
	AgentID   string // empty for main-loop transcripts
	AgentType string // from attributionAgent; "unknown" if absent
	FilePath  string
	FileSize  int64
	ModTime   int64
	ByModel   map[string]*modelTokens // subagent transcripts only
	Responses []response              // main-loop transcripts only
}

type modelTokens struct {
	Input       int
	Output      int
	CacheCreate int
	CacheRead   int
	// CacheRewrites counts the requests that re-sent an expired prefix, and
	// CacheRewriteTokens the share of CacheCreate they paid for — a subset, not
	// an addition. Both stay 0 on subagent rows; see countsAsCacheRewrite.
	CacheRewrites      int
	CacheRewriteTokens int
}

func (mt *modelTokens) add(o modelTokens) {
	mt.Input += o.Input
	mt.Output += o.Output
	mt.CacheCreate += o.CacheCreate
	mt.CacheRead += o.CacheRead
	mt.CacheRewrites += o.CacheRewrites
	mt.CacheRewriteTokens += o.CacheRewriteTokens
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintf(os.Stderr, "Usage: subagent-parser <usage.db> <claude-projects-dir>\n")
		os.Exit(1)
	}

	dbPath := os.Args[1]
	projectsDir := os.Args[2]

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error opening database: %v\n", err)
		os.Exit(1)
	}
	defer db.Close()

	// Enable WAL mode for better concurrent performance
	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		fmt.Fprintf(os.Stderr, "Warning: could not enable WAL mode: %v\n", err)
	}

	if err := initSchema(db); err != nil {
		fmt.Fprintf(os.Stderr, "Error initializing schema: %v\n", err)
		os.Exit(1)
	}

	// Load existing file records for incremental sync
	existing, err := loadExisting(db)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error loading existing records: %v\n", err)
		os.Exit(1)
	}

	files, err := findTranscripts(projectsDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error finding transcripts: %v\n", err)
		os.Exit(1)
	}

	// Main transcripts first, so response ownership is claimed by a session's own
	// transcript before any transcript that forked from it.
	sort.SliceStable(files, func(i, j int) bool {
		return files[i].kind == "main" && files[j].kind != "main"
	})

	tx, err := db.Begin()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error beginning transaction: %v\n", err)
		os.Exit(1)
	}
	defer tx.Rollback() //nolint:errcheck // no-op once Commit succeeds

	if err := recordProjectPaths(tx, files); err != nil {
		fmt.Fprintf(os.Stderr, "Warning: could not record project paths: %v\n", err)
	}

	var mainParsed, subParsed, skipped, replayed int
	for _, f := range files {
		info, err := os.Stat(f.path)
		if err != nil {
			continue
		}

		// Skip files whose size and mtime both match what we already parsed.
		if prev, ok := existing[f.path]; ok && prev.size == info.Size() && prev.mtime == info.ModTime().Unix() {
			skipped++
			continue
		}

		t, err := parseTranscript(f, info.Size(), info.ModTime().Unix())
		if err != nil {
			fmt.Fprintf(os.Stderr, "Warning: error parsing %s: %v\n", f.path, err)
			continue
		}

		n, err := insertTranscript(tx, t)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Warning: error inserting %s: %v\n", f.path, err)
			continue
		}
		replayed += n
		if t.Kind == "main" {
			mainParsed++
		} else {
			subParsed++
		}
	}

	if err := tx.Commit(); err != nil {
		fmt.Fprintf(os.Stderr, "Error committing transaction: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("  Transcripts: %d main + %d subagent parsed, %d skipped (unchanged), %d total\n",
		mainParsed, subParsed, skipped, len(files))
	if replayed > 0 {
		fmt.Printf("  Skipped %d replayed response(s) already credited to another transcript\n", replayed)
	}
	reportUnknownModels()
}

// parserSchemaVersion is bumped whenever stored rows have to be recomputed
// rather than merely widened. A new column alone would not do it: transcripts
// are skipped when their size and mtime match what was already parsed, so old
// rows would keep the column's default forever. Bumping wipes main_loop and lets
// the next sync re-parse every main-loop transcript.
//
//  1. Responses became globally owned (response_owners); rows before that were
//     deduplicated per-file only, overstating the main-loop share.
//  2. The cache_rewrite columns were added.
const parserSchemaVersion = 2

func initSchema(db *sql.DB) error {
	storedVersion, err := storedSchemaVersion(db)
	if err != nil {
		return err
	}

	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS subagents (
			id              INTEGER PRIMARY KEY,
			session_id      TEXT,
			agent_id        TEXT,
			agent_type      TEXT DEFAULT 'unknown',
			model           TEXT,
			input_tokens    INTEGER DEFAULT 0,
			output_tokens   INTEGER DEFAULT 0,
			cache_create    INTEGER DEFAULT 0,
			cache_read      INTEGER DEFAULT 0,
			estimated_cost  REAL DEFAULT 0,
			cache_read_cost REAL DEFAULT 0,
			file_path       TEXT,
			file_size       INTEGER,
			file_mtime      INTEGER DEFAULT 0
		);
		CREATE INDEX IF NOT EXISTS idx_subagents_session ON subagents(session_id);
		CREATE INDEX IF NOT EXISTS idx_subagents_agent ON subagents(agent_id);
		CREATE INDEX IF NOT EXISTS idx_subagents_file ON subagents(file_path);

		CREATE TABLE IF NOT EXISTS main_loop (
			id              INTEGER PRIMARY KEY,
			session_id      TEXT,
			model           TEXT,
			input_tokens    INTEGER DEFAULT 0,
			output_tokens   INTEGER DEFAULT 0,
			cache_create    INTEGER DEFAULT 0,
			cache_read      INTEGER DEFAULT 0,
			estimated_cost  REAL DEFAULT 0,
			cache_read_cost REAL DEFAULT 0,
			cache_rewrites       INTEGER DEFAULT 0,
			cache_rewrite_tokens INTEGER DEFAULT 0,
			cache_rewrite_cost   REAL DEFAULT 0,
			file_path       TEXT,
			file_size       INTEGER,
			file_mtime      INTEGER DEFAULT 0
		);
		CREATE INDEX IF NOT EXISTS idx_main_loop_session ON main_loop(session_id);
		CREATE INDEX IF NOT EXISTS idx_main_loop_file ON main_loop(file_path);

		-- Credits each API response to exactly one transcript. A session forked or
		-- resumed from another replays the parent's messages verbatim; without this
		-- both transcripts count them and the main-loop share is overstated.
		CREATE TABLE IF NOT EXISTS response_owners (
			message_id TEXT NOT NULL,
			request_id TEXT NOT NULL,
			file_path  TEXT NOT NULL,
			PRIMARY KEY (message_id, request_id)
		);
		CREATE INDEX IF NOT EXISTS idx_response_owners_file ON response_owners(file_path);

		CREATE TABLE IF NOT EXISTS parser_schema (version INTEGER NOT NULL);

		-- Claude mangles a project's path into its directory name by replacing
		-- both "/" and "_" with "-", which is not reversible. Transcripts record
		-- the real cwd, so the mapping is read from them rather than guessed.
		CREATE TABLE IF NOT EXISTS projects (
			project_dir TEXT PRIMARY KEY,
			cwd         TEXT NOT NULL
		);
	`)
	if err != nil {
		return err
	}

	if err := migrateSchema(db); err != nil {
		return err
	}

	if storedVersion < parserSchemaVersion {
		if _, err := db.Exec("DELETE FROM main_loop"); err != nil {
			return fmt.Errorf("clearing main_loop for schema v%d: %w", parserSchemaVersion, err)
		}
		if _, err := db.Exec("DELETE FROM parser_schema"); err != nil {
			return err
		}
		if _, err := db.Exec("INSERT INTO parser_schema (version) VALUES (?)", parserSchemaVersion); err != nil {
			return err
		}
	}

	return nil
}

// storedSchemaVersion reads the version stamped by the last run, or 0 for a
// database written before the table existed.
func storedSchemaVersion(db *sql.DB) (int, error) {
	var exists int
	if err := db.QueryRow(
		"SELECT count(*) FROM sqlite_master WHERE type='table' AND name='parser_schema'",
	).Scan(&exists); err != nil {
		return 0, err
	}
	if exists == 0 {
		return 0, nil
	}

	var version int
	if err := db.QueryRow("SELECT COALESCE(MAX(version), 0) FROM parser_schema").Scan(&version); err != nil {
		return 0, err
	}
	return version, nil
}

// migrateSchema adds columns missing from caches written by older versions.
// Rows predating a column get its default; parserSchemaVersion decides whether
// that default is a lie that needs a re-parse.
func migrateSchema(db *sql.DB) error {
	shared := map[string]string{
		"file_mtime":      "INTEGER DEFAULT 0",
		"cache_read_cost": "REAL DEFAULT 0",
	}
	// Only main_loop records cache rewrites — see countsAsCacheRewrite.
	mainOnly := map[string]string{
		"cache_rewrites":       "INTEGER DEFAULT 0",
		"cache_rewrite_tokens": "INTEGER DEFAULT 0",
		"cache_rewrite_cost":   "REAL DEFAULT 0",
	}

	for _, table := range []string{"subagents", "main_loop"} {
		for col, decl := range shared {
			if err := addColumn(db, table, col, decl); err != nil {
				return err
			}
		}
	}
	for col, decl := range mainOnly {
		if err := addColumn(db, "main_loop", col, decl); err != nil {
			return err
		}
	}
	return nil
}

func addColumn(db *sql.DB, table, col, decl string) error {
	has, err := hasColumn(db, table, col)
	if err != nil {
		return err
	}
	if has {
		return nil
	}
	if _, err := db.Exec("ALTER TABLE " + table + " ADD COLUMN " + col + " " + decl); err != nil {
		return fmt.Errorf("adding %s.%s: %w", table, col, err)
	}
	return nil
}

func hasColumn(db *sql.DB, table, column string) (bool, error) {
	rows, err := db.Query("SELECT 1 FROM pragma_table_info(?) WHERE name = ?", table, column)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	return rows.Next(), rows.Err()
}

type fileStamp struct {
	size  int64
	mtime int64
}

// loadExisting returns file_path → (size, mtime) for every transcript already parsed.
func loadExisting(db *sql.DB) (map[string]fileStamp, error) {
	result := make(map[string]fileStamp)

	for _, table := range []string{"subagents", "main_loop"} {
		rows, err := db.Query("SELECT DISTINCT file_path, file_size, file_mtime FROM " + table)
		if err != nil {
			return result, err
		}
		for rows.Next() {
			var path string
			var size, mtime int64
			if err := rows.Scan(&path, &size, &mtime); err != nil {
				continue
			}
			result[path] = fileStamp{size: size, mtime: mtime}
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return result, err
		}
	}
	return result, nil
}

// transcriptFile is a discovered JSONL file plus the identity derived from its path.
type transcriptFile struct {
	path       string
	kind       string // "main" | "subagent"
	projectDir string // Claude's directory name for the project, e.g. "-Users-me-src-app"
	sessionID  string
	agentID    string
}

// findTranscripts walks the projects directory for the two transcript layouts:
//
//	<projects>/<project>/<session-id>.jsonl                     — main loop
//	<projects>/<project>/<session-id>/subagents/agent-<id>.jsonl — subagent
//
// Anything else (tool-results/, remote-agents/, nested oddities) is ignored.
func findTranscripts(projectsDir string) ([]transcriptFile, error) {
	var files []transcriptFile

	err := filepath.WalkDir(projectsDir, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil // skip inaccessible dirs
		}
		if d.IsDir() || !strings.HasSuffix(d.Name(), ".jsonl") {
			return nil
		}

		rel, relErr := filepath.Rel(projectsDir, path)
		if relErr != nil {
			return nil
		}
		parts := strings.Split(rel, string(os.PathSeparator))

		switch {
		// <project>/<session-id>.jsonl
		case len(parts) == 2 && !strings.HasPrefix(d.Name(), "agent-"):
			files = append(files, transcriptFile{
				path:       path,
				kind:       "main",
				projectDir: parts[0],
				sessionID:  strings.TrimSuffix(d.Name(), ".jsonl"),
			})
		// <project>/<session-id>/subagents/agent-<id>.jsonl
		case len(parts) == 4 && parts[2] == "subagents" && strings.HasPrefix(d.Name(), "agent-"):
			files = append(files, transcriptFile{
				path:       path,
				kind:       "subagent",
				projectDir: parts[0],
				sessionID:  parts[1],
				agentID:    strings.TrimSuffix(strings.TrimPrefix(d.Name(), "agent-"), ".jsonl"),
			})
		}
		return nil
	})
	return files, err
}

// recordProjectPaths maps each project directory to the real working directory
// its transcripts were written from, so a caller can name a project by path.
//
// Runs over every discovered file, not just the ones being parsed: a project
// whose transcripts are all unchanged still needs its path the first time this
// table exists. Only directories missing from the table are read, so the cost is
// one short file scan per new project.
func recordProjectPaths(tx *sql.Tx, files []transcriptFile) error {
	known := map[string]bool{}
	rows, err := tx.Query("SELECT project_dir FROM projects")
	if err != nil {
		return err
	}
	for rows.Next() {
		var dir string
		if err := rows.Scan(&dir); err == nil {
			known[dir] = true
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	for _, f := range files {
		if f.projectDir == "" || known[f.projectDir] {
			continue
		}
		cwd := transcriptCwd(f.path)
		if cwd == "" {
			continue // another of this project's files may still carry one
		}
		if _, err := tx.Exec(
			"INSERT OR IGNORE INTO projects (project_dir, cwd) VALUES (?, ?)", f.projectDir, cwd,
		); err != nil {
			return err
		}
		known[f.projectDir] = true
	}
	return nil
}

// transcriptCwd returns the first working directory recorded in a transcript, or
// "" if it carries none.
func transcriptCwd(path string) string {
	fh, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer fh.Close()

	cwd := ""
	readJSONL(fh, func(line []byte) bool {
		var entry jsonlEntry
		if err := json.Unmarshal(line, &entry); err != nil {
			return true
		}
		if entry.Cwd != "" {
			cwd = entry.Cwd
			return false
		}
		return true
	})
	return cwd
}

// maxLineBytes bounds how much of a single transcript line readJSONL will hold
// in memory. Real lines are bounded by one message's content, but a pathological
// paste (a large PDF, many inline images) could be far bigger; rather than pull
// an unbounded amount into RAM, a line past this limit is drained and skipped so
// the rest of the file's usage still counts.
const maxLineBytes = 50 * 1024 * 1024

// readJSONL invokes fn for each newline-delimited record in r, stopping early if
// fn returns false. Unlike bufio.Scanner — which caps a token at a fixed size
// and then fails the whole file — it grows to fit lines up to maxLineBytes, so a
// line carrying a large pasted tool result or image does not abort the file and
// discard its usage. A line longer than maxLineBytes is drained and skipped (fn
// is not called for it), as are empty lines; any read error other than EOF is
// returned.
func readJSONL(r io.Reader, fn func(line []byte) bool) error {
	br := bufio.NewReaderSize(r, 256*1024)
	var buf []byte     // accumulates a line that spans multiple reads
	overLimit := false // current line already crossed maxLineBytes; draining it
	for {
		frag, err := br.ReadSlice('\n')
		if err == bufio.ErrBufferFull {
			// The line runs past this fragment; keep accumulating until it
			// completes or crosses the size limit.
			if !overLimit {
				buf = append(buf, frag...)
				if len(buf) > maxLineBytes {
					overLimit = true
					buf = nil // release; drain the rest without holding it
				}
			}
			continue
		}
		if err != nil && err != io.EOF {
			return err
		}

		if overLimit {
			// The over-limit line ends here; drop it and reset for the next.
			overLimit = false
			buf = nil
		} else {
			line := frag
			if len(buf) > 0 {
				buf = append(buf, frag...)
				line = buf
			}
			// fn is short-circuited past the limit, so an oversized final
			// fragment is skipped rather than parsed.
			if len(line) > 0 && len(line) <= maxLineBytes && !fn(line) {
				return nil
			}
			buf = nil
		}

		if err == io.EOF {
			return nil
		}
	}
}

// parseTranscript reads a JSONL transcript and accumulates tokens per model.
//
// Deduplication is asymmetric, because the two transcript formats record usage
// differently — both behaviours were verified against ccusage:
//
//   - Main-loop transcripts repeat one response's *total* usage on every
//     content-block line, so responses are deduplicated on
//     (message.id, requestId). On a sampled session, 181 of 515 assistant lines
//     were repeats, and deduplicating reproduced ccusage's figure exactly
//     (93,559 output tokens). Deduplication continues across files via
//     response_owners — see insertTranscript.
//   - Subagent (sidechain) transcripts record each block's *incremental* usage
//     on its own line, so every line counts. Deduplicating one sampled subagent
//     file collapsed 10,220 output tokens to 216, where ccusage reported 10,133.
func parseTranscript(f transcriptFile, size, mtime int64) (*transcript, error) {
	fh, err := os.Open(f.path)
	if err != nil {
		return nil, err
	}
	defer fh.Close()

	t := &transcript{
		Kind:      f.kind,
		SessionID: f.sessionID,
		AgentID:   f.agentID,
		AgentType: "unknown",
		FilePath:  f.path,
		FileSize:  size,
		ModTime:   mtime,
		ByModel:   make(map[string]*modelTokens),
	}

	type dedupKey struct{ messageID, requestID string }
	seen := make(map[dedupKey]struct{})

	err = readJSONL(fh, func(line []byte) bool {
		var entry jsonlEntry
		if err := json.Unmarshal(line, &entry); err != nil {
			return true
		}

		// The subagent's own transcript carries its agent type, so we never need
		// to cross-reference the parent transcript.
		if t.Kind == "subagent" && t.AgentType == "unknown" && entry.AttributionAgent != "" {
			t.AgentType = entry.AttributionAgent
		}

		if entry.Type != "assistant" || len(entry.Message) == 0 {
			return true
		}

		var msg messagePayload
		if err := json.Unmarshal(entry.Message, &msg); err != nil {
			return true
		}

		// "<synthetic>" entries are generated locally and cost nothing.
		if msg.Model == "" || msg.Model == "<synthetic>" {
			return true
		}

		tokens := modelTokens{
			Input:       msg.Usage.InputTokens,
			Output:      msg.Usage.OutputTokens,
			CacheCreate: msg.Usage.CacheCreationInputTokens,
			CacheRead:   msg.Usage.CacheReadInputTokens,
		}
		model := canonicalModel(msg.Model)

		if t.Kind == "subagent" {
			mt, ok := t.ByModel[model]
			if !ok {
				mt = &modelTokens{}
				t.ByModel[model] = mt
			}
			mt.add(tokens)
			return true
		}

		if msg.ID != "" || entry.RequestID != "" {
			key := dedupKey{messageID: msg.ID, requestID: entry.RequestID}
			if _, dup := seen[key]; dup {
				return true
			}
			seen[key] = struct{}{}
		}
		t.Responses = append(t.Responses, response{
			MessageID: msg.ID,
			RequestID: entry.RequestID,
			Model:     model,
			Tokens:    tokens,
		})
		return true
	})

	return t, err
}

// canonicalModel resolves bare aliases ("sonnet") to a full model ID.
func canonicalModel(model string) string {
	if full, ok := modelAliases[model]; ok {
		return full
	}
	return model
}

// computeCost calculates the estimated cost for a set of tokens at a given
// model's rates, recording the model as unknown if it is missing from the map.
// The second return value is the portion of that cost from cache reads.
func computeCost(model string, mt *modelTokens) (total, cacheRead, cacheRewrite float64) {
	r, ok := modelRates[model]
	if !ok {
		r = fallbackRates
		agg, seen := unknownModels[model]
		if !seen {
			agg = &modelTokens{}
			unknownModels[model] = agg
		}
		agg.add(*mt)
	}

	cacheRead = float64(mt.CacheRead) * r.CacheRead / 1e6
	// Already inside total's CacheCreate term — reported separately, not added.
	cacheRewrite = float64(mt.CacheRewriteTokens) * r.CacheWrite / 1e6
	total = (float64(mt.Input)*r.Input +
		float64(mt.Output)*r.Output +
		float64(mt.CacheCreate)*r.CacheWrite) / 1e6
	return total + cacheRead, cacheRead, cacheRewrite
}

// reportUnknownModels warns about model IDs that fell back to opus rates.
func reportUnknownModels() {
	if len(unknownModels) == 0 {
		return
	}

	names := make([]string, 0, len(unknownModels))
	for name := range unknownModels {
		names = append(names, name)
	}
	sort.Slice(names, func(i, j int) bool {
		return unknownModels[names[i]].Output > unknownModels[names[j]].Output
	})

	fmt.Fprintf(os.Stderr,
		"  Warning: %d unknown model ID(s) priced at fallback (opus) rates — add them to modelRates in cmd/subagent-parser/main.go:\n",
		len(unknownModels))
	for _, name := range names {
		mt := unknownModels[name]
		fmt.Fprintf(os.Stderr, "    %-32s %d output tokens, %d cache-read tokens\n", name, mt.Output, mt.CacheRead)
	}
}

// insertTranscript writes one transcript's data to the database (one row per
// model). For main-loop transcripts it first claims ownership of each response,
// so a response replayed into a forked transcript is counted only once; the
// count of responses skipped that way is returned.
// cacheRewriteShare is the cache-write fraction of a request's cached prompt
// above which the prefix is taken to have been re-written rather than read. A
// steady turn writes only its delta — well under 1% of the prompt — while a
// re-written prefix is nearly all of it, so the two populations sit orders of
// magnitude apart and the exact cut does not matter.
//
// Why the prefix was not served from cache is not recorded here. TTL expiry is
// one cause, but rewrites also show up minutes apart, so the counter names the
// symptom and leaves the cause to whoever investigates it.
const cacheRewriteShare = 0.4

// countsAsCacheRewrite reports whether a request paid to re-write a prefix that
// a warm cache would have served as a read.
//
// Main-loop responses only. A subagent runs to completion in one stretch, so it
// rarely lives long enough to lose its cache; a large cache write there is
// normally its cold start, and counting subagents would report one rewrite per
// agent. The cost is that a subagent that does lose its cache goes unreported —
// the fix for that would be per-request timestamps, not a different ratio.
func countsAsCacheRewrite(mt modelTokens) bool {
	prompt := mt.CacheCreate + mt.CacheRead
	return prompt > 0 && float64(mt.CacheCreate)/float64(prompt) > cacheRewriteShare
}

func insertTranscript(tx *sql.Tx, t *transcript) (int, error) {
	table := "main_loop"
	if t.Kind == "subagent" {
		table = "subagents"
	}

	// Delete any existing rows for this file (re-parse case). Releasing the
	// file's owned responses first lets it re-claim its own on this pass.
	if _, err := tx.Exec("DELETE FROM "+table+" WHERE file_path = ?", t.FilePath); err != nil {
		return 0, err
	}

	var replayed int
	if t.Kind == "main" {
		if _, err := tx.Exec("DELETE FROM response_owners WHERE file_path = ?", t.FilePath); err != nil {
			return 0, err
		}
		claim, err := tx.Prepare(
			"INSERT OR IGNORE INTO response_owners (message_id, request_id, file_path) VALUES (?, ?, ?)")
		if err != nil {
			return 0, err
		}
		defer claim.Close()

		counted := 0
		for _, r := range t.Responses {
			// A response carrying neither identifier can't be attributed, so it is
			// counted here rather than dropped.
			if r.MessageID != "" || r.RequestID != "" {
				res, err := claim.Exec(r.MessageID, r.RequestID, t.FilePath)
				if err != nil {
					return replayed, err
				}
				n, err := res.RowsAffected()
				if err != nil {
					return replayed, err
				}
				if n == 0 {
					replayed++
					continue
				}
			}
			tokens := r.Tokens
			// The first response this transcript owns writes the system prompt and
			// tool definitions into an empty cache: a cold start, not a rewrite. A
			// resumed transcript's first *own* request is skipped on the same rule,
			// since the responses it inherited belong to the parent transcript.
			if counted > 0 && countsAsCacheRewrite(tokens) {
				tokens.CacheRewrites = 1
				tokens.CacheRewriteTokens = tokens.CacheCreate
			}
			counted++

			mt, ok := t.ByModel[r.Model]
			if !ok {
				mt = &modelTokens{}
				t.ByModel[r.Model] = mt
			}
			mt.add(tokens)
		}
	}

	var stmt *sql.Stmt
	var err error
	if t.Kind == "subagent" {
		stmt, err = tx.Prepare(`
			INSERT INTO subagents
				(session_id, agent_id, agent_type, model, input_tokens, output_tokens,
				 cache_create, cache_read, estimated_cost, cache_read_cost,
				 file_path, file_size, file_mtime)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		`)
	} else {
		stmt, err = tx.Prepare(`
			INSERT INTO main_loop
				(session_id, model, input_tokens, output_tokens,
				 cache_create, cache_read, estimated_cost, cache_read_cost,
				 cache_rewrites, cache_rewrite_tokens, cache_rewrite_cost,
				 file_path, file_size, file_mtime)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		`)
	}
	if err != nil {
		return replayed, err
	}
	defer stmt.Close()

	// A transcript that contributes no tokens still needs a row, otherwise the
	// incremental-sync check re-parses it on every run.
	if len(t.ByModel) == 0 {
		t.ByModel[""] = &modelTokens{}
	}

	for model, mt := range t.ByModel {
		var cost, crCost, rwCost float64
		if model != "" {
			cost, crCost, rwCost = computeCost(model, mt)
		}
		if t.Kind == "subagent" {
			_, err = stmt.Exec(
				t.SessionID, t.AgentID, t.AgentType, model,
				mt.Input, mt.Output, mt.CacheCreate, mt.CacheRead,
				cost, crCost, t.FilePath, t.FileSize, t.ModTime,
			)
		} else {
			_, err = stmt.Exec(
				t.SessionID, model,
				mt.Input, mt.Output, mt.CacheCreate, mt.CacheRead,
				cost, crCost,
				mt.CacheRewrites, mt.CacheRewriteTokens, rwCost,
				t.FilePath, t.FileSize, t.ModTime,
			)
		}
		if err != nil {
			return replayed, err
		}
	}

	return replayed, nil
}
