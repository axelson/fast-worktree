load ../test_helper

setup() {
    isolate_env
    command -v yq >/dev/null || skip "yq not installed"
    make_repo "$BATS_TEST_TMPDIR/myrepo"
    register_project myproj "$BATS_TEST_TMPDIR/myrepo"
    cd "$BATS_TEST_TMPDIR/myrepo"

    # A user skill.
    mkdir -p "$HOME/.claude/skills/greet"
    cat >"$HOME/.claude/skills/greet/SKILL.md" <<'EOF'
---
name: greet
description: Says hello to the user
---
# Greet
Say hello.
EOF

    # A manual user skill.
    mkdir -p "$HOME/.claude/skills/danger"
    cat >"$HOME/.claude/skills/danger/SKILL.md" <<'EOF'
---
name: danger
description: A manual-only skill
disable-model-invocation: true
---
Careful.
EOF

    # A repo skill.
    mkdir -p "$BATS_TEST_TMPDIR/myrepo/.claude/skills/repoify"
    cat >"$BATS_TEST_TMPDIR/myrepo/.claude/skills/repoify/SKILL.md" <<'EOF'
---
name: repoify
description: A repo-scoped skill
---
Repo.
EOF
}

@test "fw skills: lists user, repo, and built-in entries" {
    run "$FW_BIN" skills
    [ "$status" -eq 0 ]
    [[ "$output" == *"greet"* ]]
    [[ "$output" == *"Says hello to the user"* ]]
    [[ "$output" == *"repoify"* ]]
    [[ "$output" == *"commit"* ]]           # a built-in command
    [[ "$output" == *"User Skills"* ]]
}

@test "fw skills --user-skills: excludes repo and built-in entries" {
    run "$FW_BIN" skills --user-skills
    [ "$status" -eq 0 ]
    [[ "$output" == *"greet"* ]]
    [[ "$output" != *"repoify"* ]]
    [[ "$output" != *"commit"* ]]
}

@test "fw skills --manual: keeps only manual-invocation skills" {
    run "$FW_BIN" skills --manual
    [ "$status" -eq 0 ]
    [[ "$output" == *"danger"* ]]
    [[ "$output" != *"greet"* ]]
}

@test "fw skills <filter>: narrows by name substring" {
    run "$FW_BIN" skills greet
    [ "$status" -eq 0 ]
    [[ "$output" == *"greet"* ]]
    [[ "$output" != *"repoify"* ]]
}

@test "fw skills show: prints the skill body" {
    run "$FW_BIN" skills show greet
    [ "$status" -eq 0 ]
    [[ "$output" == *"# Greet"* ]]
    [[ "$output" == *"Say hello."* ]]
}

@test "fw skills show: repo skill resolves too" {
    run "$FW_BIN" skills show repoify
    [ "$status" -eq 0 ]
    [[ "$output" == *"Repo."* ]]
}

@test "fw skills: summary counts manual skills but not manual commands" {
    run "$FW_BIN" skills
    [ "$status" -eq 0 ]
    # Only `danger` is manual; the built-in commands are manual by nature.
    [[ "$output" == *"1 manual skills (disable-model-invocation)"* ]]
}

@test "fw skills --auto: no manual line when nothing manual survives the filter" {
    run "$FW_BIN" skills --auto
    [ "$status" -eq 0 ]
    [[ "$output" != *"disable-model-invocation"* ]]
}

@test "fw skills: a block-scalar description stays on one row" {
    mkdir -p "$HOME/.claude/skills/blocky"
    cat >"$HOME/.claude/skills/blocky/SKILL.md" <<'EOF'
---
name: blocky
description: |
  First line here.
  Second line here.
---
Body.
EOF
    run "$FW_BIN" skills
    [ "$status" -eq 0 ]
    [[ "$output" == *"First line here. Second line here."* ]]
}

# make_marketplace <path> — a directory marketplace registered in settings.json
make_marketplace() {
    mkdir -p "$HOME/.claude"
    cat >"$HOME/.claude/settings.json" <<EOF
{"extraKnownMarketplaces": {"mkt": {"source": {"source": "directory", "path": "$1"}}}}
EOF
}

# make_plugin_install <name> <installPath> — an entry in the install cache
make_plugin_install() {
    mkdir -p "$HOME/.claude/plugins"
    cat >"$HOME/.claude/plugins/installed_plugins.json" <<EOF
{"plugins": {"$1@mkt": [{"installPath": "$2"}]}}
EOF
}

make_plugin_skill() {
    mkdir -p "$1/skills/$2"
    cat >"$1/skills/$2/SKILL.md" <<EOF
---
name: $2
description: Plugin skill body
---
Plugin.
EOF
}

@test "fw skills: a plugin in both the install cache and its marketplace lists once" {
    make_plugin_skill "$BATS_TEST_TMPDIR/mkt/dup" thing
    make_marketplace "$BATS_TEST_TMPDIR/mkt"
    make_plugin_install dup "$BATS_TEST_TMPDIR/mkt/dup"

    run "$FW_BIN" skills
    [ "$status" -eq 0 ]
    [ "$(grep -c 'dup:thing' <<<"$output")" -eq 1 ]
    [[ "$output" == *"1 plugin skills"* ]]
}

@test "fw skills: a flat-layout marketplace already in the install cache lists once" {
    make_plugin_skill "$BATS_TEST_TMPDIR/flat" thing
    mkdir -p "$HOME/.claude"
    cat >"$HOME/.claude/settings.json" <<EOF
{"extraKnownMarketplaces": {"mkt": {"source": {"source": "directory", "path": "$BATS_TEST_TMPDIR/flat"}}}}
EOF
    make_plugin_install mkt "$BATS_TEST_TMPDIR/flat"

    run "$FW_BIN" skills
    [ "$status" -eq 0 ]
    [ "$(grep -c 'mkt:thing' <<<"$output")" -eq 1 ]
}

@test "fw skills: a marketplace plugin absent from the install cache still lists" {
    make_plugin_skill "$BATS_TEST_TMPDIR/mkt/other" thing
    make_plugin_skill "$BATS_TEST_TMPDIR/mkt/dup" dupskill
    make_marketplace "$BATS_TEST_TMPDIR/mkt"
    make_plugin_install dup "$BATS_TEST_TMPDIR/mkt/dup"

    run "$FW_BIN" skills
    [ "$status" -eq 0 ]
    [[ "$output" == *"other:thing"* ]]
    [ "$(grep -c 'dup:dupskill' <<<"$output")" -eq 1 ]
}

@test "fw skills: a skillOverrides-disabled skill is marked off and counted" {
    mkdir -p "$HOME/.claude"
    echo '{"skillOverrides": {"greet": "off"}}' >"$HOME/.claude/settings.json"

    run "$FW_BIN" skills
    [ "$status" -eq 0 ]
    [[ "$output" == *"[off] Says hello to the user"* ]]
    [[ "$output" == *"1 disabled (skillOverrides off)"* ]]
    # Skills left alone keep their plain row.
    [[ "$output" != *"[off] A repo-scoped skill"* ]]
}

@test "fw skills: a disabled manual skill shows both markers" {
    mkdir -p "$HOME/.claude"
    echo '{"skillOverrides": {"danger": "off"}}' >"$HOME/.claude/settings.json"

    run "$FW_BIN" skills
    [ "$status" -eq 0 ]
    [[ "$output" == *"[off] [manual] A manual-only skill"* ]]
}

@test "fw skills: a skillOverrides-disabled command is marked off" {
    mkdir -p "$HOME/.claude/commands"
    cat >"$HOME/.claude/commands/deploy.md" <<'EOF'
---
name: deploy
description: Ships the thing
---
Deploy.
EOF
    mkdir -p "$HOME/.claude"
    echo '{"skillOverrides": {"deploy": "off"}}' >"$HOME/.claude/settings.json"

    run "$FW_BIN" skills
    [ "$status" -eq 0 ]
    [[ "$output" == *"[off] [manual] Ships the thing"* ]]
    [[ "$output" == *"1 disabled (skillOverrides off)"* ]]
}

@test "fw skills: no disabled line without skillOverrides" {
    run "$FW_BIN" skills
    [ "$status" -eq 0 ]
    [[ "$output" != *"skillOverrides off"* ]]
    [[ "$output" != *"[off]"* ]]
}

@test "fw skills show: unknown name errors" {
    run "$FW_BIN" skills show nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"no skill or command named 'nope'"* ]]
}
