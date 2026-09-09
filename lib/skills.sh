# shellcheck disable=SC2154  # config globals are assigned by load_config.
#
# fw skills — list and show the Claude Code skills/commands available in this
# context (user, repo, plugin, and built-in). Part of the core Claude layer.
# Frontmatter is read with yq; the plugin/marketplace registries are read with
# jq. Both are invoked by bare name (PATH seam).

# _skills_require_yq — skills reads frontmatter with yq; without it names would
# silently fall back to basenames and descriptions would vanish, so fail with a
# clear message instead of emitting degraded output.
_skills_require_yq() {
    command -v yq >/dev/null 2>&1 && return 0
    echo "Error: yq not found — fw skills needs yq to read skill frontmatter" >&2
    return 1
}

# _skill_frontmatter <file> — "name<TAB>description<TAB>manual-flag" from a
# skill/command file's YAML frontmatter, in ONE yq call. Newlines inside the
# description are folded to spaces (sub) so a block scalar can't inject spurious
# rows into the line-per-record list protocol.
_skill_frontmatter() {
    yq --front-matter=extract \
        '[.name // "", (.description // "" | sub("\n"; " ")), (.["disable-model-invocation"] // "" | tostring)] | @tsv' \
        "$1" 2>/dev/null || true
}

# _skill_name <file> — just the frontmatter name (used by `show`, which only
# needs to match on the name and skips this entirely when the basename matches).
_skill_name() {
    yq --front-matter=extract '.name // ""' "$1" 2>/dev/null || true
}

# _plugin_skill_dirs <claude-config-dir> — "dir<TAB>name-prefix" lines for every
# plugin and directory-marketplace skills dir. One place for the registry jq so
# list and show don't each re-implement it.
_plugin_skill_dirs() {
    local claude_dir="$1"
    local plugins_file="$claude_dir/plugins/installed_plugins.json"
    local settings_file="$claude_dir/settings.json"

    # A directory marketplace is often the install source for its own plugins,
    # so the same skills dir surfaces twice. Emit each plugin name once.
    local -A emitted=()

    if [[ -f "$plugins_file" ]]; then
        local plugin_key install_path plugin_name
        while IFS=$'\t' read -r plugin_key install_path; do
            [[ -n "$install_path" && -d "$install_path/skills" ]] || continue
            plugin_name="${plugin_key%%@*}"
            printf '%s\t%s\n' "$install_path/skills" "${plugin_name}:"
            emitted[$plugin_name]=1
        done < <(jq -r '.plugins | to_entries[] | "\(.key)\t\(.value[0].installPath)"' "$plugins_file" 2>/dev/null)
    fi

    if [[ -f "$settings_file" ]]; then
        local mkt_name mkt_path pkg_dir pkg_name
        while IFS=$'\t' read -r mkt_name mkt_path; do
            [[ -n "$mkt_path" && -d "$mkt_path" ]] || continue
            for pkg_dir in "$mkt_path"/*/; do
                [[ -d "$pkg_dir/skills" ]] || continue
                pkg_name=$(basename "$pkg_dir")
                [[ -n "${emitted[$pkg_name]+x}" ]] && continue
                printf '%s\t%s\n' "$pkg_dir/skills" "${pkg_name}:"
                emitted[$pkg_name]=1
            done
            if [[ -d "$mkt_path/skills" && -z "${emitted[$mkt_name]+x}" ]]; then
                printf '%s\t%s\n' "$mkt_path/skills" "${mkt_name}:"
                emitted[$mkt_name]=1
            fi
        done < <(jq -r '.extraKnownMarketplaces // {} | to_entries[] | select(.value.source.source == "directory") | "\(.key)\t\(.value.source.path)"' "$settings_file" 2>/dev/null)
    fi
}

cmd_skills_show() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        echo "Error: skill name required" >&2
        echo "Usage: fw skills show <name>" >&2
        return 1
    fi
    _skills_require_yq || return 1

    local claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    local skills_dir="$claude_dir/skills"
    local commands_dir="$claude_dir/commands"
    local repo_skills_dir="${repo_root}/.claude/skills"
    local repo_commands_dir="${repo_root}/.claude/commands"

    _search_skills_dir() {
        local dir="$1" prefix="${2:-}"
        [[ -d "$dir" ]] || return 0
        local skill_dir skill_file skill_name base
        for skill_dir in "$dir"/*/; do
            [[ -d "$skill_dir" ]] || continue
            if [[ -f "$skill_dir/SKILL.md" ]]; then
                skill_file="$skill_dir/SKILL.md"
            elif [[ -f "$skill_dir/skill.md" ]]; then
                skill_file="$skill_dir/skill.md"
            else
                continue
            fi
            # Cheap basename match first — no yq unless the dir name can't be it.
            base="$(basename "$skill_dir")"
            if [[ "${prefix}${base}" == "$name" ]]; then
                cat "$skill_file"; exit 0
            fi
            skill_name=$(_skill_name "$skill_file")
            if [[ -n "$skill_name" && "${prefix}${skill_name}" == "$name" ]]; then
                cat "$skill_file"; exit 0
            fi
        done
    }

    _search_commands_dir() {
        local dir="$1"
        [[ -d "$dir" ]] || return 0
        local cmd_file cmd_name
        for cmd_file in "$dir"/*.md; do
            [[ -f "$cmd_file" ]] || continue
            if [[ "$(basename "$cmd_file" .md)" == "$name" ]]; then
                cat "$cmd_file"; exit 0
            fi
            cmd_name=$(_skill_name "$cmd_file")
            if [[ -n "$cmd_name" && "$cmd_name" == "$name" ]]; then
                cat "$cmd_file"; exit 0
            fi
        done
    }

    # Priority order: user > repo > plugin.
    _search_skills_dir "$skills_dir"
    _search_commands_dir "$commands_dir"
    _search_skills_dir "$repo_skills_dir"
    _search_commands_dir "$repo_commands_dir"

    local dir prefix
    while IFS=$'\t' read -r dir prefix; do
        _search_skills_dir "$dir" "$prefix"
    done < <(_plugin_skill_dirs "$claude_dir")

    echo "Error: no skill or command named '$name'" >&2
    return 1
}

cmd_skills() {
    case "${1:-}" in
        show) shift; cmd_skills_show "$@"; return ;;
    esac

    _skills_require_yq || return 1

    local show_user=true show_repo=true show_plugin=true show_builtin=true
    local filter_invoke="" filter_name="" arg
    for arg in "$@"; do
        case "$arg" in
            --user-skills) show_user=true; show_repo=false; show_plugin=false; show_builtin=false ;;
            --repo-skills) show_user=false; show_repo=true; show_plugin=false; show_builtin=false ;;
            --auto)   filter_invoke="auto" ;;
            --manual) filter_invoke="manual" ;;
            -*) echo "Error: unknown flag '$arg'" >&2; return 1 ;;
            *) filter_name="$arg" ;;
        esac
    done

    local claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    local skills_dir="$claude_dir/skills"
    local commands_dir="$claude_dir/commands"
    local repo_skills_dir="${repo_root}/.claude/skills"
    local repo_commands_dir="${repo_root}/.claude/commands"
    local settings_file="$claude_dir/settings.json"

    # skillOverrides in settings.json turns skills and commands "off" by name.
    local -A skill_overrides=()
    if [[ -f "$settings_file" ]]; then
        local ov_name ov_value
        while IFS=$'\t' read -r ov_name ov_value; do
            [[ -n "$ov_name" ]] || continue
            skill_overrides[$ov_name]="$ov_value"
        done < <(jq -r '.skillOverrides // {} | to_entries[] | "\(.key)\t\(.value)"' "$settings_file" 2>/dev/null)
    fi

    local max_name=0
    local -a lines=()

    _collect_skills() {
        local dir="$1" category="$2" prefix="${3:-}"
        [[ -d "$dir" ]] || return 0
        local skill_dir skill_file name desc manual invoke_mode display_name override
        for skill_dir in "$dir"/*/; do
            [[ -d "$skill_dir" ]] || continue
            if [[ -f "$skill_dir/SKILL.md" ]]; then
                skill_file="$skill_dir/SKILL.md"
            elif [[ -f "$skill_dir/skill.md" ]]; then
                skill_file="$skill_dir/skill.md"
            else
                continue
            fi
            IFS=$'\t' read -r name desc manual <<<"$(_skill_frontmatter "$skill_file")"
            [[ -n "$name" ]] || name=$(basename "$skill_dir")
            invoke_mode="auto"
            [[ "$manual" == "true" ]] && invoke_mode="manual"
            display_name="${prefix}${name}"
            [[ ${#display_name} -gt $max_name ]] && max_name=${#display_name}
            # Default "on" — an empty middle field would collapse under tab-IFS
            # and shift the description out of the record.
            override="${skill_overrides[$name]:-on}"
            lines+=("${category}"$'\t'"${display_name}"$'\t'"${invoke_mode}"$'\t'"${override}"$'\t'"${desc:-}")
        done
    }

    _collect_commands() {
        local dir="$1" category="$2"
        [[ -d "$dir" ]] || return 0
        local cmd_file name desc _manual override
        for cmd_file in "$dir"/*.md; do
            [[ -f "$cmd_file" ]] || continue
            IFS=$'\t' read -r name desc _manual <<<"$(_skill_frontmatter "$cmd_file")"
            [[ -n "$name" ]] || name=$(basename "$cmd_file" .md)
            [[ ${#name} -gt $max_name ]] && max_name=${#name}
            override="${skill_overrides[$name]:-on}"
            lines+=("${category}"$'\t'"${name}"$'\t'"manual"$'\t'"${override}"$'\t'"${desc:-}")
        done
    }

    _collect_builtin_commands() {
        # Best-effort snapshot of Claude Code's built-in slash commands: there
        # is no API to enumerate them, so this list is a moving target and will
        # drift as the CLI adds/removes commands. Update it by hand when it does.
        local -a builtins=(
            "autofix-pr|Auto-fix PR issues from CI failures and review comments"
            "code-review|Review current diff for correctness bugs and cleanups"
            "commit|Commit with context"
            "deep-research|Multi-source research with verification"
            "explain|Explain files"
            "fewer-permission-prompts|Add tool allowlist from transcript analysis"
            "init|Initialize a new CLAUDE.md file"
            "loop|Run a prompt on a recurring interval"
            "review|Review a pull request"
            "run|Launch and drive the app to verify a change"
            "schedule|Create/manage scheduled cloud agents"
            "security-review|Security review of pending changes"
            "simplify|Apply reuse/simplification/efficiency fixes"
            "verify|Verify a code change by running the app"
        )
        local entry name desc override
        for entry in "${builtins[@]}"; do
            name="${entry%%|*}"
            desc="${entry#*|}"
            [[ ${#name} -gt $max_name ]] && max_name=${#name}
            override="${skill_overrides[$name]:-on}"
            lines+=("builtin"$'\t'"${name}"$'\t'"manual"$'\t'"${override}"$'\t'"${desc}")
        done
    }

    if [[ "$show_repo" == true ]]; then
        _collect_skills "$repo_skills_dir" "repo skill"
        _collect_commands "$repo_commands_dir" "repo command"
    fi
    if [[ "$show_user" == true ]]; then
        _collect_skills "$skills_dir" "user skill"
        _collect_commands "$commands_dir" "user command"
    fi
    if [[ "$show_plugin" == true ]]; then
        local dir prefix
        while IFS=$'\t' read -r dir prefix; do
            _collect_skills "$dir" "plugin" "$prefix"
        done < <(_plugin_skill_dirs "$claude_dir")
    fi
    if [[ "$show_builtin" == true ]]; then
        _collect_builtin_commands
    fi

    if [[ ${#lines[@]} -eq 0 ]]; then
        echo "No skills found."
        return 0
    fi

    [[ $max_name -gt 40 ]] && max_name=40

    local last_category="" total=0
    local count_repo_skill=0 count_repo_command=0 count_user_skill=0
    local count_user_command=0 count_plugin=0 count_builtin=0 count_manual=0 count_off=0
    local category name invoke_mode override desc
    while IFS=$'\t' read -r category name invoke_mode override desc; do
        [[ -n "$filter_invoke" && "$invoke_mode" != "$filter_invoke" ]] && continue
        [[ -n "$filter_name" && "$name" != *"$filter_name"* ]] && continue

        if [[ "$category" != "$last_category" ]]; then
            [[ -n "$last_category" ]] && echo
            local header
            case "$category" in
                "repo skill")    header="Repo Skills" ;;
                "repo command")  header="Repo Commands" ;;
                "user skill")    header="User Skills" ;;
                "user command")  header="User Commands" ;;
                "plugin")        header="Plugin Skills" ;;
                "builtin")       header="Built-in Commands" ;;
                *)               header="$category" ;;
            esac
            echo "$header"
            last_category="$category"
        fi

        case "$category" in
            "repo skill")   (( count_repo_skill++ )) || true ;;
            "repo command") (( count_repo_command++ )) || true ;;
            "user skill")   (( count_user_skill++ )) || true ;;
            "user command") (( count_user_command++ )) || true ;;
            "plugin")       (( count_plugin++ )) || true ;;
            "builtin")      (( count_builtin++ )) || true ;;
        esac
        # Commands are manual by nature; only skills earn the manual count.
        case "$category" in
            *skill|plugin) [[ "$invoke_mode" == "manual" ]] && (( count_manual++ )) || true ;;
        esac
        [[ "$override" == "off" ]] && (( count_off++ )) || true
        (( total++ )) || true

        local display_name="$name"
        if [[ ${#display_name} -gt $max_name ]]; then
            display_name="${display_name:0:$((max_name - 1))}…"
        fi
        local marker=""
        [[ "$override" == "off" ]] && marker+="[off] "
        [[ "$invoke_mode" == "manual" ]] && marker+="[manual] "
        local desc_width=$((80 - ${#marker}))
        if [[ -n "$desc" && ${#desc} -gt $desc_width ]]; then
            desc="${desc:0:$((desc_width - 3))}..."
        fi
        printf "  %-${max_name}s  ${marker}%s\n" "$display_name" "$desc"
    done < <(printf '%s\n' "${lines[@]}" | sort -t$'\t' -k1,1 -k2,2)

    if [[ $total -gt 0 ]]; then
        echo
        local summary=""
        [[ $count_repo_skill -gt 0 ]]   && summary+="$count_repo_skill repo skills, "
        [[ $count_repo_command -gt 0 ]] && summary+="$count_repo_command repo commands, "
        [[ $count_user_skill -gt 0 ]]   && summary+="$count_user_skill user skills, "
        [[ $count_user_command -gt 0 ]] && summary+="$count_user_command user commands, "
        [[ $count_plugin -gt 0 ]]       && summary+="$count_plugin plugin skills, "
        [[ $count_builtin -gt 0 ]]      && summary+="$count_builtin built-in, "
        summary="${summary%, }"
        echo "${total} total ($summary)"
        [[ $count_manual -gt 0 ]] && echo "${count_manual} manual skills (disable-model-invocation)"
        [[ $count_off -gt 0 ]] && echo "${count_off} disabled (skillOverrides off)"

        # Warn about names that resolve to multiple locations; `show` picks the
        # highest-priority one.
        local -A name_locations=() name_winner=()
        local -a show_priority=("user skill" "user command" "repo skill" "repo command" "plugin" "builtin")
        while IFS=$'\t' read -r category name invoke_mode override desc; do
            [[ -n "$filter_invoke" && "$invoke_mode" != "$filter_invoke" ]] && continue
            [[ -n "$filter_name" && "$name" != *"$filter_name"* ]] && continue
            local loc="$category"
            if [[ -z "${name_locations[$name]+x}" ]]; then
                name_locations[$name]="$loc"
                name_winner[$name]="$loc"
            elif [[ "${name_locations[$name]}" != *"$loc"* ]]; then
                name_locations[$name]="${name_locations[$name]}, $loc"
                local cur_pri=99 new_pri=99 i
                for i in "${!show_priority[@]}"; do
                    [[ "${show_priority[$i]}" == "${name_winner[$name]}" ]] && cur_pri=$i
                    [[ "${show_priority[$i]}" == "$loc" ]] && new_pri=$i
                done
                [[ $new_pri -lt $cur_pri ]] && name_winner[$name]="$loc"
            fi
        done < <(printf '%s\n' "${lines[@]}")

        local dup_name locs winner
        for dup_name in "${!name_locations[@]}"; do
            locs="${name_locations[$dup_name]}"
            if [[ "$locs" == *","* ]]; then
                winner="${name_winner[$dup_name]}"
                if [[ "$winner" == "builtin" ]]; then
                    echo "Warning: duplicate skill name \"${dup_name}\" (${locs}) — \"show\" has no file for built-in"
                else
                    echo "Warning: duplicate skill name \"${dup_name}\" (${locs}) — \"show\" will use ${winner}"
                fi
            fi
        done
    fi
    return 0
}
