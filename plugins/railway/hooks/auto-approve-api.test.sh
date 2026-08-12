#!/bin/bash
# The payloads below are shell source held as data, so the metacharacters and
# backslashes in them are deliberately literal and must not be rewritten.
# shellcheck disable=SC1003,SC2016,SC2088
#
# Regression tests for auto-approve-api.sh. Run: bash auto-approve-api.test.sh
#
# The hook's invariant is that it never returns "allow" for a command bash would
# run as more than one simple command. Each case below pins one reading of shell
# quoting where a check that is not character-exact about bash's rules would let
# a top-level `;` through as if it were quoted data.

hook_dir=$(cd "$(dirname "$0")" && pwd -P)
hook="$hook_dir/auto-approve-api.sh"
scripts_dir=$(cd "$hook_dir/../skills/use-railway/scripts" && pwd -P)
skill_dir=$(dirname "$scripts_dir")
pass=0
fail=0

# A file named like the helper but somewhere else, standing in for whatever a
# checked-out repository or a temp directory might supply.
decoy_dir=$(mktemp -d)
trap 'rm -rf "$decoy_dir"' EXIT
cp "$scripts_dir/railway-api.sh" "$decoy_dir/railway-api.sh"
printf '#!/bin/bash\nexit 0\n' > "$decoy_dir/railway"
chmod +x "$decoy_dir/railway"

# Feeds a command to the hook and echoes "allow" or "prompt". Declining to decide
# is silence on stdout, which is what leaves the command at the normal prompt.
# The optional second argument is the working directory the command would run in,
# which is what a relative path in it resolves against.
decision() {
  local out
  out=$(jq -nc --arg command "$1" --arg cwd "${2:-}" \
    '{tool_name: "Bash", cwd: $cwd, tool_input: {command: $command}}' |
    bash "$hook")
  if [[ -z "$out" ]]; then
    echo prompt
  else
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "prompt"'
  fi
}

check() {
  local want="$1" desc="$2" cmd="$3" got
  got=$(decision "$cmd" "${4:-}")
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1))
    printf '  ok       %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf '  FAILED   %s (wanted %s, got %s)\n' "$desc" "$want" "$got"
  fi
}

echo "Commands bash runs as more than one command — must prompt:"
check prompt 'escaped double quote'          'railway \" ; touch pwned ; echo \"'
check prompt 'escaped single quote'          "railway \\' ; touch pwned ; echo \\'"
check prompt 'escaped quote, api.sh branch'  'railway-api.sh \" ; touch pwned ; echo \"'
check prompt 'escaped quote, env prefix'     'RAILWAY_CALLER=x railway \" ; touch pwned ; echo \"'
check prompt 'single quote inside double'    'railway "a'"'"'b" ; touch pwned ; echo '"'"'c"d'"'"''
check prompt 'double quote inside single'    "railway 'a\"b' ; touch pwned ; echo \"c'd\""
check prompt 'trailing comment'              'touch pwned # railway-api.sh'
check prompt 'command chaining'              'railway status; touch pwned'
check prompt 'command substitution'          'railway status $(touch pwned)'
check prompt 'pipeline'                      'railway status | touch pwned'
check prompt 'redirection'                   'railway status > pwned'
check prompt 'newline between commands'      'railway status
touch pwned'
check prompt 'subshell'                      '(railway status; touch pwned)'
check prompt 'brace group'                   '{ railway status; touch pwned; }'
check prompt 'unterminated quote'            'railway " ; touch pwned'
check prompt 'trailing lone backslash'       'railway \'
check prompt 'ANSI-C quoting is not a quoted span' \
  "railway \$'\\'' ; touch pwned ; : '\\'"
check prompt 'localised string is not a quoted span' \
  'railway $" ; touch pwned ; echo "'

echo
echo "The word bash runs is not the skeleton — must prompt:"
check prompt 'quoted span inside the command name'  "r'x'ailway status"
check prompt 'empty quoted span inside the name'    "rail''way status"
check prompt 'quoting reaches a path through the name' \
  "'$decoy_dir/'railway status" /
check prompt 'escape inside the command name'       'rail\way status'
check prompt 'quoted telemetry prefix name'         "RAILWAY'_'CALLER=x railway status"
check prompt 'glob in the command name'             'railwa? status'
check prompt 'variable in the command name'         'railwa$y status'
check prompt 'tilde reaches a home-relative path'   '~/railway status'

echo
echo "CLI subcommands that run a command are not covered by the CLI's name:"
check prompt 'run executes a local command'         'railway run -- sh -c id'
check prompt 'run with flags before the command'    'railway run --service api -- sh -c id'
check prompt 'quoted subcommand is still the subcommand' "railway 'run' -- sh -c id"
check prompt 'ssh executes on a service'            'railway ssh --service api sh -c id'
check prompt 'sandbox exec executes in a sandbox'   'railway sandbox exec my-box -- sh -c id'
check prompt 'connect opens a local database shell' 'railway connect Postgres'

echo
echo "Documented call forms — must auto-approve:"
check allow 'bare CLI'                       'railway status'
check allow 'CLI with flags'                  'railway status --json'
check allow 'logs by service'                 'railway logs --service api --environment production'
check allow 'deploy'                          'railway up --detach'
check allow 'quoted argument value'           "railway variables --set 'FOO=a b'"
check allow 'telemetry env prefix'            'RAILWAY_CALLER=skill RAILWAY_SKILL_VERSION=1 railway status'
check allow 'escaped space in argument'       'railway variables --set FOO=a\ b'
check allow 'quoted query and variables' \
  "scripts/railway-api.sh 'query { me { id } }' '{}'" "$skill_dir"
check allow 'double quotes inside argument' \
  "scripts/railway-api.sh 'query { project(id: \"abc\") { id } }' '{}'" "$skill_dir"
check allow 'line continuation' "scripts/railway-api.sh \\
  'query getEnv(\$id: String!) { environment(id: \$id) { name } }' \\
  '{\"id\": \"env-uuid\"}'" "$skill_dir"
check allow 'multi-line quoted query' "scripts/railway-api.sh \\
  'query {
    me { id }
  }' \\
  '{}'" "$skill_dir"

echo
echo "Which railway-api.sh — only the one shipped beside this hook:"
check allow  'helper by absolute path'        "$scripts_dir/railway-api.sh 'q'" /
check prompt 'helper by bare name resolves in PATH, not the working directory' \
  "railway-api.sh 'q'" "$scripts_dir"
check allow  'helper via ./ from its own directory' \
  "./railway-api.sh 'q'" "$scripts_dir"
check prompt 'same name in another directory' \
  "$decoy_dir/railway-api.sh 'q'" /
check prompt 'same name reached from a working directory that supplies it' \
  "./railway-api.sh 'q'" "$decoy_dir"
check prompt 'same name reached by traversing out of the plugin' \
  "$scripts_dir/../../../../../..${decoy_dir}/railway-api.sh 'q'" /
check prompt 'relative helper with no working directory to resolve against' \
  "railway-api.sh 'q'"
check prompt 'path-qualified railway is a different file than the CLI' \
  "$decoy_dir/railway status" /

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
