# Workflows

Task-oriented walkthroughs of how the commands fit together day to day. The
tool's own help (`fw help`) is the authoritative command reference;
[`configuration.md`](configuration.md) covers every config key and hook.

## The daily loop

```bash
fw create cool-feature   # new worktree, ready to run
fw switch cool-feature   # attach its tmux session
fw start                 # run the project (start_cmd) in the worktree
fw check                 # run the project's check suite (check_cmd)
fw list                  # where everything is, with dirty markers
fw clean                 # remove worktrees whose branches merged or
                         # disappeared upstream
```

Bare `fw switch` opens an fzf picker over recent worktrees
(`switch_recent_days` window; `--all` for everything). Picking or typing
`main` lands you in the golden checkout's session. `fw last` toggles back to
the previous session, and `fw menu` is a quick-actions popup.

`fw clean` is conservative: it never removes a dirty worktree or one whose
checked-out branch differs from the one it recorded at create time.

## Reviewing a PR

```bash
fw pull 1234             # PR number, URL, or remote branch name
fw pull 1234 --review    # spawn Claude running the /pr-review prompt in it
                         # (--review etc. are configured in claude_prompt_flags)
fw pull 1234 --claude "review this PR"   # or a one-off literal prompt
```

`pull` builds the worktree the same way `create` does (artifacts, database,
env), just based on the remote branch instead of trunk.

## Keeping things fresh

```bash
fw sync                  # fast-forward trunk + rebuild the golden checkout
fw refresh               # re-copy a worktree's artifacts from the golden checkout
fw regen-env             # rewrite a worktree's env file (keeps its port slot)
```

Run `fw sync` whenever trunk has moved; everything created afterwards clones
the fresh build.

## Parking work: archive and restore

`fw archive` removes a worktree but keeps its branch, so long-lived
work-in-progress doesn't cost a checkout on disk:

```bash
fw archive cool-feature --reason "waiting on API design"
fw list --archived       # what's parked, and why
fw restore cool-feature  # bring it back
fw purge                 # multi-select delete of archived branches
```

The round-trip is faithful: loose files are saved in a rescue commit at
archive time and popped on restore, so untracked files come back untracked.
Restoring retires the archive entry, so a later `fw purge` can't delete a
branch that's live again.

Files git doesn't track that you still care about — plans, notes, a
`STATUS.md` — can be listed in `claude_archive_paths`; they're preserved on
archive/delete and copied back on restore.

For work that's simply abandoned, `fw delete` removes worktree, branch, and
database in one step. `fw shelve` drops the worktree but leaves the branch
and archive log alone.

## Stacked branches

With the Graphite backend (`stack_backend=auto` detects it):

```bash
fw stack                 # the current stack, current branch marked
fw up / fw down          # move between stacked branches
fw top / fw bottom       # jump to either end
fw restack               # restack current-and-below (--all for everything);
                         # conflicts abort cleanly with instructions
fw stack-switch          # fzf picker over the stack (ss for short)
fw changes               # what changed in the current branch only
```

## Watching CI

```bash
fw checks                # current branch's check status
fw checks-wait           # poll until checks settle, then notify
                         # (ignored_checks config skips never-finishing ones)
fw retry                 # re-run failed checks
fw ci                    # recent runs, filtered to you (github_username)
fw prs                   # your open PRs (--open to open in browser)
```

## Handoffs

For passing context between sessions (or between you and an agent):

```bash
fw handoff save          # write a handoff doc for the current worktree
fw handoffs              # list open handoffs
fw handoff show          # read one (bare = fzf picker)
fw handoff resume        # mark it picked-up
fw handoff done          # close it out
```
