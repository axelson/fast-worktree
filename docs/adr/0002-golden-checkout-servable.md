# Golden checkout is a first-class servable target

Each project's golden checkout runs a dev server that needs a port, and with several projects on one machine, hand-assigning those ports to avoid collisions is exactly the toil fast-worktree exists to remove. So the golden checkout now gets an allocated, persisted **port slot** — drawn from the same globally-unique pool as every worktree — plus an HTTPS **`main.<domain>`** site, and `fw open` works from it. This identity is materialized by running `fw regen-env` in the main checkout, not at registration.

## Considered options

- **Leave the golden checkout port-less** (the prior state): rejected — multiple projects' dev servers collide on default ports, and `fw open` can't work from the main checkout.
- **Allocate the golden slot at `fw init`**: rejected — registration shouldn't reach into the working tree, and making allocation an explicit, re-runnable `fw regen-env` keeps the env file re-derivable and opt-in per machine.
- **Give main an HTTPS site or leave it localhost-only**: chose the site. It's the same `<name>.<domain>` rule with `name=main`, so it costs no special-casing in the site block, and it makes the golden checkout reachable by the same stable URL scheme as its worktrees.

## Consequences

- Amends the rule that a checkout's identity and port are written only at **create** time: the golden checkout is the exception, written by `fw regen-env` in the main checkout (which allocates a slot when none exists).
- The golden env file lands in the tracked working tree, so it must be gitignored to keep the checkout clean — `fw regen-env` warns when it isn't, but never edits ignore rules itself.
- Resolving the golden checkout is opt-in (`resolve_worktree --allow-main`): only checkout-scoped commands (`open`, `regen-env`, `start`/`check`/`fix`, `stop`) accept `main`; the destructive lifecycle commands (`delete`, `archive`) must explicitly refuse it, since it resolves to `repo_root`.
