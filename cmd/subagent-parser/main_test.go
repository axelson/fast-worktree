package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A single transcript line can exceed bufio.Scanner's token cap when it carries
// a large pasted tool result or image. Such a line must not abort parsing and
// discard the whole file's usage — every well-formed line's tokens must count.
func TestParseTranscriptToleratesOversizedLine(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "session.jsonl")

	line := func(id, req string, out int, pad int) string {
		p := ""
		if pad > 0 {
			p = fmt.Sprintf(`,"pad":%q`, strings.Repeat("x", pad))
		}
		return fmt.Sprintf(
			`{"type":"assistant","requestId":%q,"message":{"id":%q,"model":"claude-opus-4-8","usage":{"output_tokens":%d}%s}}`,
			req, id, out, p,
		)
	}

	// A normal line, then one padded past the 4 MiB scanner ceiling.
	content := line("msg1", "req1", 100, 0) + "\n" +
		line("msg2", "req2", 200, 5*1024*1024) + "\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}

	tr, err := parseTranscript(
		transcriptFile{path: path, kind: "main", sessionID: "s"},
		info.Size(), info.ModTime().Unix(),
	)
	if err != nil {
		t.Fatalf("parseTranscript returned error on oversized line: %v", err)
	}
	if len(tr.Responses) != 2 {
		t.Fatalf("expected 2 responses, got %d", len(tr.Responses))
	}
	var total int
	for _, r := range tr.Responses {
		total += r.Tokens.Output
	}
	if total != 300 {
		t.Fatalf("expected 300 output tokens, got %d", total)
	}
}

// A line past maxLineBytes is drained and skipped, but the file keeps parsing —
// the surrounding lines' usage must still be counted.
func TestParseTranscriptSkipsLineOverLimit(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "session.jsonl")

	line := func(id, req string, out int, pad int) string {
		p := ""
		if pad > 0 {
			p = fmt.Sprintf(`,"pad":%q`, strings.Repeat("x", pad))
		}
		return fmt.Sprintf(
			`{"type":"assistant","requestId":%q,"message":{"id":%q,"model":"claude-opus-4-8","usage":{"output_tokens":%d}%s}}`,
			req, id, out, p,
		)
	}

	// A normal line, a line past the 50 MiB limit (must be skipped), a normal
	// line. The oversized line's 200 tokens must NOT appear in the total.
	content := line("msg1", "req1", 100, 0) + "\n" +
		line("msg2", "req2", 200, maxLineBytes+1024) + "\n" +
		line("msg3", "req3", 300, 0) + "\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}

	tr, err := parseTranscript(
		transcriptFile{path: path, kind: "main", sessionID: "s"},
		info.Size(), info.ModTime().Unix(),
	)
	if err != nil {
		t.Fatalf("parseTranscript returned error: %v", err)
	}
	if len(tr.Responses) != 2 {
		t.Fatalf("expected 2 responses (oversized line skipped), got %d", len(tr.Responses))
	}
	var total int
	for _, r := range tr.Responses {
		total += r.Tokens.Output
	}
	if total != 400 {
		t.Fatalf("expected 400 output tokens (100+300, oversized 200 skipped), got %d", total)
	}
}
