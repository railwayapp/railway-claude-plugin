#!/bin/bash
# Auto-approve railway-api.sh and railway CLI commands.
#
# An "allow" decision covers the WHOLE Bash command, so a prefix or substring
# match is not enough: `printf x # railway-api.sh` and `railway status; rm -rf ~`
# both start with (or contain) a trusted token yet run something else. We only
# approve when the command is a single simple invocation of the railway CLI or
# the railway-api.sh helper. Anything that chains, substitutes, redirects, or
# comments is left for the normal confirmation prompt — the safe direction.
#
# The CLI itself is the other half of that judgement: a few subcommands exist to
# run a command somewhere, so approving them approves whatever they are handed.
# Those are declined below, by the word bash would actually pass.

input=$(cat)

tool_name=$(echo "$input" | jq -r '.tool_name // empty')
command=$(echo "$input" | jq -r '.tool_input.command // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')

if [[ "$tool_name" != "Bash" ]]; then
  exit 0
fi

approve() {
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "$1"
  }
}
EOF
  exit 0
}

# Command substitution and expansion fire even inside double quotes, so check the
# raw command for them before stripping anything. Legit GraphQL uses `$var`, not
# `$(`, backticks, or `${`.
case "$command" in
  *\$\(* | *\`* | *\$\{*) exit 0 ;;
esac

# Read the command once, the way bash reads it, and keep the two answers that
# matter separately:
#
#   skeleton — only the characters bash could act on as syntax. Quoted spans and
#              backslash-escaped characters are data, so they leave nothing here
#              and the metacharacter scan below is exact rather than approximate.
#   words    — the words bash would actually pass, with quotes removed and
#              escapes resolved, split on unquoted whitespace. The executable and
#              the subcommand are decided from these, because the skeleton is not
#              the word: bash runs `rxailway` for `r'x'ailway` while the skeleton
#              reads `railway`.
#
# quoted[] records which words carried any quoting or escaping at all. A word
# that did is not something this hook can vouch for by name, so the executable
# and the telemetry prefixes are required to be written plainly.
skeleton=""
words=()
quoted=()
word=""
in_word=0
word_quoted=0
state=unquoted
i=0
len=${#command}

end_word() {
  ((in_word)) || return 0
  words+=("$word")
  quoted+=("$word_quoted")
  word=""
  in_word=0
  word_quoted=0
}

while ((i < len)); do
  char=${command:i:1}
  case "$state" in
    unquoted)
      case "$char" in
        \\)
          # Escapes whatever follows, so that character is data rather than
          # structure — and `\<newline>` is a line continuation, which joins the
          # line and contributes nothing. A backslash with nothing after it
          # doesn't parse; don't approve what we can't read.
          ((i + 1 < len)) || exit 0
          ((i++))
          next=${command:i:1}
          if [[ "$next" != $'\n' ]]; then
            word+="$next"
            in_word=1
            word_quoted=1
          fi
          ;;
        "'")
          state=single
          in_word=1
          word_quoted=1
          ;;
        '"')
          state=double
          in_word=1
          word_quoted=1
          ;;
        ' ' | $'\t')
          skeleton+="$char"
          end_word
          ;;
        *)
          skeleton+="$char"
          word+="$char"
          in_word=1
          ;;
      esac
      ;;
    single)
      # Backslash is not special inside single quotes: the span ends at the next `'`.
      if [[ "$char" == "'" ]]; then
        state=unquoted
      else
        word+="$char"
      fi
      ;;
    double)
      case "$char" in
        \\)
          ((i + 1 < len)) || exit 0
          ((i++))
          next=${command:i:1}
          # Inside double quotes a backslash is literal unless it escapes one of
          # the characters that would otherwise be special there.
          case "$next" in
            '$' | '`' | '"' | $'\\' | $'\n') ;;
            *) word+="\\" ;;
          esac
          [[ "$next" == $'\n' ]] || word+="$next"
          ;;
        '"') state=unquoted ;;
        *) word+="$char" ;;
      esac
      ;;
  esac
  ((i++))
done
end_word

# An unterminated quote means the command does not parse the way we just read it.
[[ "$state" == unquoted ]] || exit 0

# On the skeleton every remaining metacharacter is top-level: command chaining
# (`;` `|` `&`), redirection or heredoc (`<` `>`), comments (`#`), grouping or
# subshells (`(` `)` `{` `}`), or a newline joining two commands. An unquoted
# expansion (`$`, `~`, or a glob) is here too: it means the word bash runs is
# not the word we just read, and the file it names may not exist yet.
case "$skeleton" in
  *';'* | *'|'* | *'&'* | *'<'* | *'>'* | *'#'* | *'('* | *')'* | *'{'* | *'}'* | *$'\n'*) exit 0 ;;
  *'$'* | *'~'* | *'*'* | *'?'* | *'['*) exit 0 ;;
esac

# Drop the optional skill telemetry env prefixes to reach the executable itself.
while ((${#words[@]})); do
  [[ "${quoted[0]}" == 0 ]] || exit 0
  case "${words[0]}" in
    RAILWAY_CALLER=* | RAILWAY_AGENT_SESSION=* | RAILWAY_SKILL_VERSION=*)
      words=("${words[@]:1}")
      quoted=("${quoted[@]:1}")
      ;;
    *) break ;;
  esac
done

((${#words[@]})) || exit 0
executable=${words[0]}
[[ "${quoted[0]}" == 0 ]] || exit 0

# `railway run`, `railway ssh`, `railway connect` and `railway sandbox exec` all
# exist to run a command — locally or on a service — so approving the CLI by name
# would approve whatever they are given. The name of the CLI says nothing about
# what the invocation does, so decline these wherever they appear in the words
# rather than guessing which position holds the subcommand.
for arg in "${words[@]:1}"; do
  case "$arg" in
    run | ssh | shell | connect | exec) exit 0 ;;
  esac
done

# Resolve a path the way the command would, so the comparison below is about the
# file that will run rather than the spelling used to reach it. Symlinks and `..`
# in the directory part collapse; a directory that doesn't exist fails outright.
canonical_path() {
  local path=$1 dir
  if [[ "$path" != /* ]]; then
    [[ -n "$cwd" ]] || return 1
    path="$cwd/$path"
  fi
  dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s' "$dir" "$(basename "$path")"
}

# The helper this hook vouches for is the one shipped beside it, so locate it
# from the hook's own path rather than trusting the name in the command. A file
# is only that helper if it resolves to the same path; the name alone says
# nothing about which file it is, and anything a repo or temp directory can
# supply is not this plugin's script.
if [[ "$executable" == *railway-api.sh ]]; then
  # A name with no slash is looked up in PATH, not in the working directory, so
  # the file we would resolve is not the one bash would run.
  [[ "$executable" == */* ]] || exit 0
  hook_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
  helper=$(canonical_path "$hook_dir/../skills/use-railway/scripts/railway-api.sh") || exit 0
  [[ -f "$helper" ]] || exit 0
  invoked=$(canonical_path "$executable") || exit 0
  if [[ "$invoked" == "$helper" ]]; then
    approve "Railway API call auto-approved"
  fi
  exit 0
fi

# The railway CLI is resolved from PATH by name, so require exactly that name —
# a path-qualified `railway` is some other file and gets the normal prompt.
if [[ "$executable" == "railway" ]]; then
  approve "Railway CLI command auto-approved"
fi

exit 0
