# Fish completions for fast-worktree.
#
# This is the NEW tool's completion file. It replaces the legacy
# completions/fw.fish at cutover — install it under whatever alias you call the
# tool (`ln -s .../fast-worktree.fish ~/.config/fish/completions/fw.fish`), at
# which point the legacy file is retired.
#
# The completions register against the file's own basename, so the symlink name
# IS the command they bind to — install as fw.fish to complete `fw`, as
# fast-worktree.fish to complete `fast-worktree`. No hand-editing needed.
#
# Dynamic candidates (worktrees, custom commands, aliases, handoffs, archived
# branches, projects) come live from `<cmd> _complete <what>` — no generated
# data, so completions never go stale. Each helper stays cheap.

# Command name = this file's basename, matching fish's autoload convention.
set -l fw (basename (status current-filename) .fish)

function __fw_complete
    set -l tokens (commandline -opc)

    # Delegate to the command actually being completed (fw, fast-worktree, or
    # any alias the user installed under) rather than a baked-in name: a file
    # local like $fw above is out of scope inside a deferred completion
    # function, so read it live from the command line. Fall back to
    # fast-worktree when the typed name is not a runnable binary — e.g. a bare
    # `alias fw=fast-worktree` (README setup), where `command fw` would fail.
    set -l cmd $tokens[1]
    command -q -- $cmd; or set cmd fast-worktree

    # Forward an explicit -p/--project scope so candidates match the project the
    # command will act on, not whichever project cwd happens to resolve to.
    set -l proj_args
    set -l i 2
    while test $i -le (count $tokens)
        # `?` is a literal in fish globs (not a wildcard), so match the glued
        # short form with `-p*`; the exact `-p`/`--project` case precedes it and
        # switch stops at the first match, so bare `-p` still takes look-ahead.
        set -l v
        switch $tokens[$i]
            case -p --project
                set v $tokens[(math $i + 1)]
                set i (math $i + 1)
            case '--project=*'
                set v (string replace -- --project= '' $tokens[$i])
            case '-p*'
                set v (string replace -- -p '' $tokens[$i])
        end
        # Guard against an empty value (e.g. a dangling `-p` or `--project=`),
        # which would otherwise forward `-p ''` and make the backend error out.
        test -n "$v"; and set proj_args -p $v
        set i (math $i + 1)
    end

    command $cmd $proj_args _complete $argv[1] 2>/dev/null
end

# Disable file completions by default
complete -c $fw -f

# --- Global flags ---
complete -c $fw -s p -l project -d 'Act on another project' -x -a '(__fw_complete projects)'
complete -c $fw -s h -l help -d 'Show usage'
complete -c $fw -l help-internal -d 'List internal commands'

# --- Subcommands (only when no subcommand seen yet) ---
complete -c $fw -n __fish_use_subcommand -a setup -d 'Install fish completions + a global config template'
complete -c $fw -n __fish_use_subcommand -a init -d 'Register the current repo as a project'
complete -c $fw -n __fish_use_subcommand -a projects -d 'List registered projects'
complete -c $fw -n __fish_use_subcommand -a config -d 'Read/edit layered config files'
complete -c $fw -n __fish_use_subcommand -a switch-project -d 'Open another project (fzf picker)'
complete -c $fw -n __fish_use_subcommand -a sp -d 'Open another project (fzf picker)'
complete -c $fw -n __fish_use_subcommand -a create -d 'Create a worktree with cloned assets'
complete -c $fw -n __fish_use_subcommand -a delete -d 'Remove a worktree and its branch'
complete -c $fw -n __fish_use_subcommand -a merge -d 'Merge the branch into main, then delete the worktree'
complete -c $fw -n __fish_use_subcommand -a list -d 'List worktrees'
complete -c $fw -n __fish_use_subcommand -a info -d "Show a worktree's configuration"
complete -c $fw -n __fish_use_subcommand -a refresh -d 'Re-clone build artifacts from golden'
complete -c $fw -n __fish_use_subcommand -a regen-env -d 'Rewrite the worktree env file'
complete -c $fw -n __fish_use_subcommand -a stop -d "Kill a worktree's port listeners"
complete -c $fw -n __fish_use_subcommand -a start -d 'Run the project start_cmd'
complete -c $fw -n __fish_use_subcommand -a check -d 'Run the project check_cmd'
complete -c $fw -n __fish_use_subcommand -a fix -d 'Run the project fix_cmd'
complete -c $fw -n __fish_use_subcommand -a db -d 'Open psql on the worktree database'
complete -c $fw -n __fish_use_subcommand -a clean -d 'Remove merged/deleted-upstream worktrees'
complete -c $fw -n __fish_use_subcommand -a switch -d 'Switch to a worktree (fzf picker)'
complete -c $fw -n __fish_use_subcommand -a sw -d 'Switch to a worktree (fzf picker)'
complete -c $fw -n __fish_use_subcommand -a switch-claude -d 'Pick a live Claude session across projects (fzf)'
complete -c $fw -n __fish_use_subcommand -a sc -d 'Pick a live Claude session across projects (fzf)'
complete -c $fw -n __fish_use_subcommand -a stack-switch -d 'Switch within the branch stack'
complete -c $fw -n __fish_use_subcommand -a ss -d 'Switch within the branch stack'
complete -c $fw -n __fish_use_subcommand -a tmux-open -d "Attach the worktree's tmux session"
complete -c $fw -n __fish_use_subcommand -a last -d 'Switch to the previous worktree'
complete -c $fw -n __fish_use_subcommand -a menu -d 'fzf quick-actions menu'
complete -c $fw -n __fish_use_subcommand -a copy -d 'Copy a worktree fact to the clipboard'
complete -c $fw -n __fish_use_subcommand -a archive -d 'Remove worktree, keep the branch'
complete -c $fw -n __fish_use_subcommand -a restore -d 'Recreate an archived worktree'
complete -c $fw -n __fish_use_subcommand -a purge -d 'Permanently delete an archived branch'
complete -c $fw -n __fish_use_subcommand -a pull -d 'Create a worktree from a remote or local branch/PR'
complete -c $fw -n __fish_use_subcommand -a changes -d 'Diff the worktree against its parent'
complete -c $fw -n __fish_use_subcommand -a stack -d 'Show the current branch stack'
complete -c $fw -n __fish_use_subcommand -a up -d 'Switch up the stack'
complete -c $fw -n __fish_use_subcommand -a down -d 'Switch down the stack'
complete -c $fw -n __fish_use_subcommand -a top -d 'Switch to the tip of the stack'
complete -c $fw -n __fish_use_subcommand -a bottom -d 'Switch to the base of the stack'
complete -c $fw -n __fish_use_subcommand -a restack -d 'Rebase current branch and below'
complete -c $fw -n __fish_use_subcommand -a sync -d 'Fast-forward trunk and rebuild golden'
complete -c $fw -n __fish_use_subcommand -a open -d "Open the worktree's web URL"
complete -c $fw -n __fish_use_subcommand -a caddy -d 'Enable/disable local HTTPS (setup/remove)'
complete -c $fw -n __fish_use_subcommand -a prs -d 'List worktrees with PR status'
complete -c $fw -n __fish_use_subcommand -a pr -d 'Open a PR (open/info/assign)'
complete -c $fw -n __fish_use_subcommand -a checks -d 'Show CI check results'
complete -c $fw -n __fish_use_subcommand -a checks-wait -d 'Poll CI checks until they finish'
complete -c $fw -n __fish_use_subcommand -a retry -d 'Rerun failed CI workflow runs'
complete -c $fw -n __fish_use_subcommand -a ci -d "CI status across worktrees' PRs"
complete -c $fw -n __fish_use_subcommand -a comments -d 'Show a review comment thread'
complete -c $fw -n __fish_use_subcommand -a ticket -d "Open the branch's tracker ticket"
complete -c $fw -n __fish_use_subcommand -a claude -d 'Show running Claude instances'
complete -c $fw -n __fish_use_subcommand -a sessions -d 'Manage Claude sessions'
complete -c $fw -n __fish_use_subcommand -a skills -d 'List/show Claude skills'
complete -c $fw -n __fish_use_subcommand -a usage -d 'Claude Code token usage by worktree'
complete -c $fw -n __fish_use_subcommand -a shelve -d 'Push worktree(s) down the switch list'
complete -c $fw -n __fish_use_subcommand -a open-file -d 'Pick an untracked file and open it'
complete -c $fw -n __fish_use_subcommand -a handoff -d 'Manage handoff docs'
complete -c $fw -n __fish_use_subcommand -a handoffs -d 'List saved handoffs'
complete -c $fw -n __fish_use_subcommand -a notify -d 'Log and announce a notification'
complete -c $fw -n __fish_use_subcommand -a logs -d 'Show the notification log'
complete -c $fw -n __fish_use_subcommand -a log -d 'Show the notification log'
complete -c $fw -n __fish_use_subcommand -a help -d 'Show help'
# Project custom commands surface as top-level subcommands too
complete -c $fw -n __fish_use_subcommand -a '(__fw_complete commands)'

# --- Worktree-name arguments ---
set -l __fw_wt_cmds delete merge info refresh regen-env stop start check fix db \
    switch sw tmux-open changes shelve archive open open-file pr checks \
    checks-wait retry ticket usage
complete -c $fw -n "__fish_seen_subcommand_from $__fw_wt_cmds" -a '(__fw_complete worktrees)'

# restore / purge take archived branches
complete -c $fw -n '__fish_seen_subcommand_from restore purge' -a '(__fw_complete archived)'

# switch-project / sp take a project name
complete -c $fw -n '__fish_seen_subcommand_from switch-project sp' -a '(__fw_complete projects)'

# --- copy items ---
set -l __fw_copy_items branch path pr-link pr-number ticket-url stack-branch
# First arg: the item token. Second arg (item already chosen): a worktree/branch.
complete -c $fw -n "__fish_seen_subcommand_from copy; and not __fish_seen_subcommand_from $__fw_copy_items" -a '(__fw_complete copy-items)'
complete -c $fw -n "__fish_seen_subcommand_from copy; and __fish_seen_subcommand_from $__fw_copy_items" -a '(__fw_complete worktrees)'

# --- pr subcommands ---
complete -c $fw -n '__fish_seen_subcommand_from pr; and not __fish_seen_subcommand_from open info assign' -a open -d 'Open PR in browser'
complete -c $fw -n '__fish_seen_subcommand_from pr; and not __fish_seen_subcommand_from open info assign' -a info -d 'Show PR details'
complete -c $fw -n '__fish_seen_subcommand_from pr; and not __fish_seen_subcommand_from open info assign' -a assign -d 'Assign a GitHub user to the PR'

# --- sessions subcommands ---
complete -c $fw -n '__fish_seen_subcommand_from sessions; and not __fish_seen_subcommand_from close-old' -a close-old -d 'Close stale Claude sessions'
complete -c $fw -n '__fish_seen_subcommand_from sessions; and __fish_seen_subcommand_from close-old' -l days -d 'Age threshold in days' -r

# --- handoff subcommands ---
complete -c $fw -n '__fish_seen_subcommand_from handoff; and not __fish_seen_subcommand_from save show done resume' -a save -d 'Save a handoff doc'
complete -c $fw -n '__fish_seen_subcommand_from handoff; and not __fish_seen_subcommand_from save show done resume' -a show -d 'Display handoff content'
complete -c $fw -n '__fish_seen_subcommand_from handoff; and not __fish_seen_subcommand_from save show done resume' -a done -d 'Mark handoff as completed'
complete -c $fw -n '__fish_seen_subcommand_from handoff; and not __fish_seen_subcommand_from save show done resume' -a resume -d 'Get handoff path for resuming'
complete -c $fw -n '__fish_seen_subcommand_from handoff; and __fish_seen_subcommand_from show done resume' -a '(__fw_complete handoffs)'
complete -c $fw -n '__fish_seen_subcommand_from handoff; and __fish_seen_subcommand_from save' -l name -d 'Override slug name' -r

# --- skills subcommands ---
complete -c $fw -n '__fish_seen_subcommand_from skills; and not __fish_seen_subcommand_from show' -a show -d 'Show skill markdown content'
complete -c $fw -n '__fish_seen_subcommand_from skills' -l user-skills -d 'User skills only'
complete -c $fw -n '__fish_seen_subcommand_from skills' -l repo-skills -d 'Repo skills only'
complete -c $fw -n '__fish_seen_subcommand_from skills' -l auto -d 'Model-invokable skills only'
complete -c $fw -n '__fish_seen_subcommand_from skills' -l manual -d 'Manually-invoked skills only'

# --- caddy subcommands ---
complete -c $fw -n '__fish_seen_subcommand_from caddy; and not __fish_seen_subcommand_from setup remove' -a setup -d 'Enable https://<name>.<domain> for this project'
complete -c $fw -n '__fish_seen_subcommand_from caddy; and not __fish_seen_subcommand_from setup remove' -a remove -d 'Reverse the caddy setup for this project'
complete -c $fw -n '__fish_seen_subcommand_from caddy; and __fish_seen_subcommand_from setup' -l domain -d 'Domain to use (default <project>.local)' -r

# --- config subcommands ---
set -l __fw_config_subs open show get set unset
complete -c $fw -n "__fish_seen_subcommand_from config; and not __fish_seen_subcommand_from $__fw_config_subs" -a open -d 'Edit a config file'
complete -c $fw -n "__fish_seen_subcommand_from config; and not __fish_seen_subcommand_from $__fw_config_subs" -a show -d 'Effective merged config, or one file raw'
complete -c $fw -n "__fish_seen_subcommand_from config; and not __fish_seen_subcommand_from $__fw_config_subs" -a get -d 'Read a config value'
complete -c $fw -n "__fish_seen_subcommand_from config; and not __fish_seen_subcommand_from $__fw_config_subs" -a set -d 'Set a scalar config value'
complete -c $fw -n "__fish_seen_subcommand_from config; and not __fish_seen_subcommand_from $__fw_config_subs" -a unset -d 'Remove a scalar config value'
# layer flags apply to every config subcommand
complete -c $fw -n '__fish_seen_subcommand_from config' -l global -d 'Global config layer'
complete -c $fw -n '__fish_seen_subcommand_from config' -l repo -d 'Repo-local config layer'
complete -c $fw -n '__fish_seen_subcommand_from config' -l project -d 'User project config layer'
# get/set/unset take a scalar config key
complete -c $fw -n '__fish_seen_subcommand_from config; and __fish_seen_subcommand_from get set unset' -a '(__fw_complete config-keys)'
# `set stack_backend` takes a recognized backend value
complete -c $fw -n '__fish_seen_subcommand_from config; and __fish_seen_subcommand_from set; and __fish_seen_subcommand_from stack_backend' -a '(__fw_complete stack-backends)'

# --- usage subcommands + flags ---
# summary / sync are alternatives to a worktree/path arg (which __fw_wt_cmds
# above already offers); only surface them before one has been chosen.
complete -c $fw -n '__fish_seen_subcommand_from usage; and not __fish_seen_subcommand_from summary sync' -a summary -d 'Per-worktree summary table'
complete -c $fw -n '__fish_seen_subcommand_from usage; and not __fish_seen_subcommand_from summary sync' -a sync -d 'Refresh the usage cache'
complete -c $fw -n '__fish_seen_subcommand_from usage' -l since -d 'Start date (YYYY-MM-DD)' -r
complete -c $fw -n '__fish_seen_subcommand_from usage' -l period -d 'Period shortcut' -x -a '7d 30d 90d all'
complete -c $fw -n '__fish_seen_subcommand_from usage' -l category -d 'Filter to a category' -x -a 'own review misc'
complete -c $fw -n '__fish_seen_subcommand_from usage' -l weight -d 'Main/subagent split basis' -x -a 'cost output tokens'
complete -c $fw -n '__fish_seen_subcommand_from usage' -l json -d 'Output JSON instead of a table'

# --- Flags ---
complete -c $fw -n '__fish_seen_subcommand_from setup' -l name -d 'Completion filename to install as' -r
complete -c $fw -n '__fish_seen_subcommand_from create' -l base -d 'Base branch' -r
complete -c $fw -n '__fish_seen_subcommand_from create pull' -l model -d 'Claude model' -x -a '(__fw_complete claude-models)'
complete -c $fw -n '__fish_seen_subcommand_from create pull' -l claude -d 'Launch Claude with a literal prompt' -r
complete -c $fw -n '__fish_seen_subcommand_from create pull' -l no-switch -d "Create the worktree but don't switch into it"
# Config-driven bare prompt-flags (--<name> => a Claude prompt; see claude_prompt_flags).
complete -c $fw -n '__fish_seen_subcommand_from create pull' -a '(__fw_complete prompt-flags)'
complete -c $fw -n '__fish_seen_subcommand_from delete' -l force -d 'Skip dirty-worktree guard'
complete -c $fw -n '__fish_seen_subcommand_from merge' -l no-ff -d 'Force a merge commit'
complete -c $fw -n '__fish_seen_subcommand_from merge' -l ff-only -d 'Only fast-forward, else abort'
complete -c $fw -n '__fish_seen_subcommand_from merge' -s y -l yes -d 'Skip confirmation prompts'
complete -c $fw -n '__fish_seen_subcommand_from merge' -l no-sync -d 'Skip the fw sync step after merging'
complete -c $fw -n '__fish_seen_subcommand_from archive' -l reason -d 'Reason for archiving' -r
complete -c $fw -n '__fish_seen_subcommand_from switch sw' -l all -d 'Include all worktrees'
complete -c $fw -n '__fish_seen_subcommand_from switch sw last' -l quiet -d 'Suppress the "Switching to …" message'
complete -c $fw -n '__fish_seen_subcommand_from switch-claude sc' -l project-only -d 'Scope the picker to the current project'
complete -c $fw -n '__fish_seen_subcommand_from changes' -l stat -d 'Show diffstat only'
complete -c $fw -n '__fish_seen_subcommand_from restack' -l all -d 'Restack the whole stack'
complete -c $fw -n '__fish_seen_subcommand_from prs' -l merged -d 'Show only merged PRs'
complete -c $fw -n '__fish_seen_subcommand_from prs' -l closed -d 'Show closed and merged PRs'
complete -c $fw -n '__fish_seen_subcommand_from prs checks' -l open -d 'Pick items to open'
complete -c $fw -n '__fish_seen_subcommand_from ci' -l all -d 'Show all authors'
complete -c $fw -n '__fish_seen_subcommand_from clean' -l cache -d 'Clear cache_dirs and exit'
complete -c $fw -n '__fish_seen_subcommand_from list' -l archived -d 'Show archived worktrees'
complete -c $fw -n '__fish_seen_subcommand_from claude' -l active -d 'Show only active instances'
complete -c $fw -n '__fish_seen_subcommand_from claude' -l json -d 'Output enriched JSON'
complete -c $fw -n '__fish_seen_subcommand_from shelve' -s t -d 'Duration (e.g. 10m, 2h, 3d)' -r
complete -c $fw -n '__fish_seen_subcommand_from shelve' -s p -l project -d 'Shelve registered project(s) in the sp list'
complete -c $fw -n '__fish_seen_subcommand_from handoffs' -l all -d 'Show full history'
complete -c $fw -n '__fish_seen_subcommand_from handoffs' -l grep -d 'Filter by text' -r
complete -c $fw -n '__fish_seen_subcommand_from logs log' -l all -d 'Show full history'

# --- notify / logs categories (project-neutral defaults) ---
complete -c $fw -n '__fish_seen_subcommand_from notify' -a 'ci deploy fix alert' -d 'Category'
complete -c $fw -n '__fish_seen_subcommand_from logs log' -a 'ci deploy fix alert' -d 'Filter by category'
