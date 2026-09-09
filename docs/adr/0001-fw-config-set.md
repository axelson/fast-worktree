# Programmatic `fw config set` / `get` / `unset` over sourced-bash config

Status: accepted

## Context

Config files are plain sourced bash. The original `fw config` design
(`docs/plans/2026-08-25-fw-config-design.md`) deliberately shipped only `open`
and `show`, ruling out `get`/`set` because "configs are sourced bash;
programmatic set is a can of worms" — arbitrary bash assignments (arrays,
associative arrays, conditionals, computed values) can't be safely rewritten by
a machine.

## Decision

We add `set`/`get`/`unset`, but only over a **managed scalar surface**: the
scalar keys of the config surface (`_config_vars`). Array/associative keys are
detected by reading their declared type back off `_config_defaults` (via
`declare -p`) and refused, with a pointer to `fw config open`. `set` edits the
sourced-bash file textually — replacing an active assignment in place, else
uncommenting the template line, else appending — writing every value
single-quoted so it stays valid bash, and preserving all surrounding comments.
Values are validated at write time through an optional per-key hook
(`_config_validate_<key>`); `stack_backend`'s hook shares its allowed-value list
(`_stack_backend_valid_values`) with the use-time resolver so the two can't
drift.

## Consequences

- The can-of-worms is bounded, not solved: only scalar keys are machine-editable;
  everything else stays hand-edited. This keeps the file human-authored and
  sourced-bash — no format migration, no parser.
- Because writes are textual (not a re-serialization of parsed state), a
  hand-written file's comments, ordering, and non-managed lines survive a `set`.
- New value validation requires only adding a `_config_validate_<key>` function;
  keys without one are written blind (validated, if at all, at use time).
