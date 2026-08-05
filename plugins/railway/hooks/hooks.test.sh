#!/bin/bash
# shellcheck disable=SC1003,SC2016
#
# Regression tests for hooks.json command execution with spaces in plugin root path.
# Run: bash hooks.test.sh

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd -P)
plugin_dir=$(cd "$script_dir/.." && pwd -P)

temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

space_plugin_dir="$temp_dir/Railway Plugin"
cp -R "$plugin_dir" "$space_plugin_dir"

hooks_json="$space_plugin_dir/hooks/hooks.json"
command_template=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$hooks_json")

payload=$(jq -nc '{tool_name: "Bash", cwd: "", tool_input: {command: "railway status"}}')

pass=0
fail=0

check_scenario() {
  local desc="$1" env_grok="$2" env_claude="$3"
  local env_opts=()
  if [[ -n "$env_grok" ]]; then
    env_opts+=(GROK_PLUGIN_ROOT="$env_grok")
  else
    env_opts+=(GROK_PLUGIN_ROOT=)
  fi
  if [[ -n "$env_claude" ]]; then
    env_opts+=(CLAUDE_PLUGIN_ROOT="$env_claude")
  else
    env_opts+=(CLAUDE_PLUGIN_ROOT=)
  fi

  local out
  out=$(printf '%s' "$payload" | env "${env_opts[@]}" bash -c "$command_template" 2>/dev/null || true)
  local decision
  decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)

  if [[ "$decision" == "allow" ]]; then
    pass=$((pass + 1))
    printf '  ok       %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf '  FAILED   %s (wanted "allow", got "%s")\n' "$desc" "$decision"
  fi
}

echo "Testing hooks.json command execution with spaces in path:"
check_scenario "CLAUDE_PLUGIN_ROOT with space (GROK_PLUGIN_ROOT unset)" "" "$space_plugin_dir"
check_scenario "GROK_PLUGIN_ROOT with space (precedence over CLAUDE_PLUGIN_ROOT)" "$space_plugin_dir" "/other/path"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
