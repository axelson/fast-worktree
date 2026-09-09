#!/usr/bin/env bash
set -euo pipefail

# gt-stack-fast.sh — Read the current Graphite stack without starting Node.js.
#
# WHY THIS EXISTS
#   `gt ls -s` takes ~400ms due to Node.js startup. This script does the same
#   thing in ~20ms by reading Graphite's SQLite metadata DB directly. The speed
#   matters because `fw ss` (stack-switch) is bound to a tmux hotkey.
#
# WHAT IT DOES
#   Equivalent to `gt log short --stack`: walks the parent chain from the
#   current branch down to trunk, then walks first-child links upward to the
#   tip. Output is one branch per line, bottom-of-stack first. The current
#   branch is prefixed with * (e.g. "*jason/my-branch"). The trunk branch
#   (second argument, default "main") is excluded.
#
# HOW GRAPHITE STORES STACK DATA (as of gt 1.x, May 2025)
#   File:   .git/.graphite_metadata.db  (SQLite 3)
#   Table:  branch_metadata
#   Schema:
#     branch_name          TEXT PRIMARY KEY  — full branch name (e.g. "jason/my-feature")
#     parent_branch_name   TEXT              — parent in the stack ("main" for bottom)
#     children             TEXT              — JSON array of child branch names, e.g. '["jason/part-2"]'
#     (other columns: parent_branch_revision, branch_revision, state, etc. — unused here)
#   Index:  idx_branch_metadata_parent ON (parent_branch_name)
#
#   The parent/children links form a tree rooted at trunk. A "stack" is a path
#   through this tree. When a branch has multiple children (fork in the stack),
#   this script follows the first child — matching `gt up` default behavior.
#
# IF THIS BREAKS AFTER A GRAPHITE UPDATE
#   1. Check the schema:  sqlite3 .git/.graphite_metadata.db ".schema branch_metadata"
#   2. Check the data:    sqlite3 .git/.graphite_metadata.db "SELECT * FROM branch_metadata LIMIT 5"
#   3. Compare with:      gt ls -s  (the canonical output this script reimplements)
#   Likely failure modes:
#     - Table/column renamed → query fails with "no such table/column"
#     - children JSON format changed → json_extract returns NULL, upstack walk stops early
#     - DB file moved/renamed → "metadata not found" error on startup
#   If the schema changed significantly, fall back to `gt ls -s` and accept the latency,
#   or update the query to match the new schema.
#
# Usage: gt-stack-fast.sh <repo-root> [trunk-branch]

REPO_ROOT="${1:?Usage: gt-stack-fast.sh <repo-root> [trunk-branch]}"
TRUNK="${2:-main}"
GT_DB="$REPO_ROOT/.git/.graphite_metadata.db"

if [[ ! -f "$GT_DB" ]]; then
    echo "Error: Graphite metadata not found at $GT_DB (run 'gt init')" >&2
    exit 1
fi

# Use cwd's branch (respects worktrees), not REPO_ROOT's branch.
# REPO_ROOT is the main repo, usually sitting on trunk; the worktree has its own HEAD.
current_branch=$(git branch --show-current 2>/dev/null)
if [[ -z "$current_branch" ]]; then
    echo "Error: Could not determine current branch" >&2
    exit 1
fi

# Branch names may legally contain single quotes; escape for SQL.
current_sql="${current_branch//\'/\'\'}"
trunk_sql="${TRUNK//\'/\'\'}"

# No stack when on trunk
if [[ "$current_branch" == "$TRUNK" ]]; then
    exit 0
fi

# Single sqlite3 call: walk parent chain down to main, then children chain up.
# Uses negative sort_key for downstack (so they sort before upstack).
sqlite3 "$GT_DB" "
WITH RECURSIVE
  down(branch, depth) AS (
    SELECT '$current_sql', 0
    UNION ALL
    SELECT bm.parent_branch_name, d.depth + 1
    FROM branch_metadata bm JOIN down d ON bm.branch_name = d.branch
    WHERE d.branch != '$trunk_sql'
  ),
  up(branch, depth) AS (
    SELECT json_extract(bm.children, '\$[0]'), 1
    FROM branch_metadata bm
    WHERE bm.branch_name = '$current_sql'
      AND bm.children IS NOT NULL AND bm.children != '[]'
    UNION ALL
    SELECT json_extract(bm.children, '\$[0]'), u.depth + 1
    FROM branch_metadata bm JOIN up u ON bm.branch_name = u.branch
    WHERE bm.children IS NOT NULL AND bm.children != '[]'
  )
SELECT branch FROM (
  SELECT branch, -depth as sort_key FROM down WHERE branch != '$trunk_sql'
  UNION ALL
  SELECT branch, 1000 + depth as sort_key FROM up WHERE branch IS NOT NULL AND branch != ''
) ORDER BY sort_key;
" | while IFS= read -r branch; do
    if [[ "$branch" == "$current_branch" ]]; then
        echo "*$branch"
    else
        echo "$branch"
    fi
done
