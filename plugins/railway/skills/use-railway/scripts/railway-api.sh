#!/usr/bin/env bash
# Railway GraphQL API helper
# Usage: railway-api.sh '<graphql-query>' ['<variables-json>']

set -e

SKILL_ID="use-railway"
SKILL_VERSION="${RAILWAY_SKILL_VERSION:-1.3.6}"

export RAILWAY_CALLER="${RAILWAY_CALLER:-skill:${SKILL_ID}@${SKILL_VERSION}}"
export RAILWAY_AGENT_SESSION="${RAILWAY_AGENT_SESSION:-railway-skill-$(date +%s)-$$}"

if ! command -v jq &>/dev/null; then
  echo '{"error": "jq not installed. Install with: brew install jq"}'
  exit 1
fi

CONFIG_FILE="$HOME/.railway/config.json"

if [[ -n "${RAILWAY_API_TOKEN:-}" && -n "${RAILWAY_TOKEN:-}" ]]; then
  echo '{"error": "RAILWAY_API_TOKEN and RAILWAY_TOKEN cannot both be set"}'
  exit 1
fi

TOKEN=""
AUTH_HEADER=""

if [[ -n "${RAILWAY_API_TOKEN:-}" ]]; then
  TOKEN="$RAILWAY_API_TOKEN"
  AUTH_HEADER="Authorization: Bearer $TOKEN"
elif [[ -n "${RAILWAY_TOKEN:-}" ]]; then
  TOKEN="$RAILWAY_TOKEN"
  AUTH_HEADER="Project-Access-Token: $TOKEN"
else
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo '{"error": "Railway config not found. Run: railway login or set RAILWAY_API_TOKEN or RAILWAY_TOKEN"}'
    exit 1
  fi

  ACCESS_TOKEN=$(jq -r '.user.accessToken // empty' "$CONFIG_FILE")

  if [[ -n "$ACCESS_TOKEN" ]]; then
    ACCESS_TOKEN_EXPIRES_AT=$(jq -r '.user.tokenExpiresAt // empty' "$CONFIG_FILE")

    if [[ ! "$ACCESS_TOKEN_EXPIRES_AT" =~ ^[0-9]+$ ]]; then
      echo '{"error": "Railway access token has no valid expiry. Run a Railway CLI command or railway login to refresh it, then retry."}'
      exit 1
    fi

    if (( ACCESS_TOKEN_EXPIRES_AT <= $(date +%s) + 60 )); then
      echo '{"error": "Railway access token is expired. Run a Railway CLI command or railway login to refresh it, then retry."}'
      exit 1
    fi

    TOKEN="$ACCESS_TOKEN"
  else
    TOKEN=$(jq -r '.user.token // empty' "$CONFIG_FILE")
  fi

  if [[ -z "$TOKEN" ]]; then
    echo '{"error": "No Railway credential found. Run: railway login or set RAILWAY_API_TOKEN or RAILWAY_TOKEN"}'
    exit 1
  fi

  AUTH_HEADER="Authorization: Bearer $TOKEN"
fi

if [[ -z "$1" ]]; then
  echo '{"error": "No query provided"}'
  exit 1
fi

# Build payload with query and optional variables
if [[ -n "$2" ]]; then
  PAYLOAD=$(jq -n --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}')
else
  PAYLOAD=$(jq -n --arg q "$1" '{query: $q}')
fi

ORIGINAL_UMASK=$(umask)
umask 077
AUTH_HEADER_FILE=$(mktemp "${TMPDIR:-/tmp}/railway-api-header.XXXXXX")
umask "$ORIGINAL_UMASK"

cleanup() {
  rm -f "$AUTH_HEADER_FILE"
}

trap cleanup EXIT
printf '%s\n' "$AUTH_HEADER" > "$AUTH_HEADER_FILE"

HEADERS=(
  -H "@$AUTH_HEADER_FILE"
  -H "Content-Type: application/json"
  -H "X-Railway-Skill-Id: $SKILL_ID"
  -H "X-Railway-Skill-Version: $SKILL_VERSION"
  -H "X-Railway-Agent-Session: $RAILWAY_AGENT_SESSION"
)

curl -s https://backboard.railway.com/graphql/v2 "${HEADERS[@]}" -d "$PAYLOAD"
