# Railway Agent Plugins

Agent plugins for [Railway](https://railway.com). Interact with Railway through one orchestration skill and the Railway MCP server.

## Plugin model

The shared plugin payload lives in `plugins/railway`.

- Claude Code: `plugins/railway/.claude-plugin/plugin.json`, `plugins/railway/.mcp.json`, and the repo marketplace at `.claude-plugin/marketplace.json`.
- OpenAI Codex: `plugins/railway/.codex-plugin/plugin.json`, `plugins/railway/.mcp.json`, and the repo marketplace at `.agents/plugins/marketplace.json`.
- Grok Build / xAI marketplace: resolves `plugins/railway` as the plugin by using a remote source subpath (`source.path: "plugins/railway"`). The shared payload therefore exposes `plugins/railway/.grok-plugin/plugin.json`, `plugins/railway/.grok-plugin/mcp.json`, `plugins/railway/skills`, and `plugins/railway/hooks` directly.
- Cursor: `plugins/railway/.cursor-plugin/plugin.json`, `plugins/railway/.cursor-plugin/mcp.json`, and the repo marketplace at `.cursor-plugin/marketplace.json`.

Claude Code and Grok Build also use `plugins/railway/hooks/hooks.json` for the existing Railway CLI/API auto-approval hook. The hook command resolves `${GROK_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/auto-approve-api.sh`.

## Skill model

The plugin ships one Railway skill:

- `plugins/railway/skills/use-railway/SKILL.md`

`use-railway` is route-first. Routing rules and intent mapping live in `SKILL.md`.

## Reference loading pattern

1. Read `plugins/railway/skills/use-railway/SKILL.md`.
2. Choose the minimum reference set needed for the request.
3. For multi-step requests, load multiple references and compose one response.

References:

| Intent | Reference | Use for |
|---|---|---|
| Create or connect resources | `references/setup.md` | Projects, services, databases, buckets, templates, workspaces |
| Ship code or manage releases | `references/deploy.md` | Deploy, redeploy, restart, build config, monorepo, Dockerfile |
| Change configuration | `references/configure.md` | Environments, variables, config patches, domains, networking, cron schedules, volumes, replicas |
| Manage feature flags | `references/feature-flags.md` | MCP registry operations; CLI targeting rules and rollouts; SDK runtime reads |
| Define configuration in source control | `references/iac.md` | TypeScript/Python/Go IaC, legacy migration, imports, saved plans, apply and drift checks |
| Manage database features | `references/databases.md` | Postgres PITR, backups, HA and PgBouncer; MySQL/Redis HA |
| Inspect costs or manage limits | `references/usage.md` | Workspace/project/service usage and workspace/agent spending limits |
| Run coding agents on Railway | `references/cloud-agents.md` | Cloud agent lifecycle, harness launches, desktop SSH setup |
| Check health or debug failures | `references/operate.md` | Status, logs, metrics, build/runtime triage, recovery |
| Use a sandbox or build remotely | `references/sandbox.md` | Sandboxes: create/fork, remote exec, remote template builds, checkpoints, port forwarding (requires Priority Boarding) |
| Analyze databases | `references/analyze-db.md` | Database introspection and performance analysis, then DB-specific refs |
| Request from API, docs, or community | `references/request.md` | GraphQL mutations, metrics queries, Central Station, official docs |

## Architecture

### Tool routing

Choose the Railway operation path that matches the job.

- Railway CLI (`railway`): local-machine workflows such as current-directory deploys, `railway up`, `railway run`, SSH, database analysis scripts, local linking, interactive setup, and exact command output.
- Remote MCP (`https://mcp.railway.com`): default plugin MCP path for account/project/service discovery, deployment status, feature flags, bounded logs, simple redeploys, simple project creation, and complex workflows through `railway-agent`. Remote MCP uses Railway OAuth and does not depend on local CLI state.
- GraphQL through `railway api`: operations without a dedicated MCP tool or CLI command, with live schema search and inspection.

Optional: an already configured in-process CLI MCP (`railway mcp local`) can supply operations not available through hosted MCP. Bare `railway mcp` starts the hosted proxy using CLI login; it is not the in-process server. Published plugin configs use direct hosted HTTP with editor OAuth.

### Railway CLI

Use Railway CLI for context-aware local operations.

- Command: `railway`
- Prefer `--json` output where available.
- Skill telemetry: prefix Railway CLI invocations with `RAILWAY_CALLER=skill:use-railway@<plugin-version>` and a stable `RAILWAY_AGENT_SESSION`; do not run separate telemetry-only `export` commands.

### MCP

Published plugin MCP configs use Railway's hosted MCP server for single-click setup.

- Keep `plugins/railway/.mcp.json`, `plugins/railway/.cursor-plugin/mcp.json`, and `plugins/railway/.grok-plugin/mcp.json` in sync.
- Plugin MCP configs must point at `https://mcp.railway.com` with HTTP transport.
- Do not store credentials in plugin MCP config. Remote MCP authentication uses Railway OAuth.
- CLI installation defaults to the hosted proxy (`railway mcp`, with `mcp proxy` retained as an alias). `railway mcp install --oauth` selects direct HTTP/editor OAuth; `--local` selects `railway mcp local`. `--remote` is an alias for the proxy default. Published plugin configs keep direct HTTP transport.

### GraphQL API

Use GraphQL for operations without a dedicated command or MCP tool. Prefer the CLI's authenticated API client.

- Endpoint: `https://backboard.railway.com/graphql/v2`
- CLI (5.28+): `railway api`, with `search`, `describe`, and `schema` for discovery.
- Legacy helper: `plugins/railway/skills/use-railway/scripts/railway-api.sh`, retained for older CLI compatibility and still required by the database analysis scripts (`dal.py`, `analyze-postgres.py`). It attaches `X-Railway-Skill-Id`, `X-Railway-Skill-Version`, and `X-Railway-Agent-Session` headers.

### API authentication

`railway api` uses normal CLI authentication and token refresh. The legacy helper reads only `~/.railway/config.json` under `user.token`; it does not implement environment-token selection or OAuth refresh.

Example:

```bash
railway api \
  'query getEnv($id: String!) { environment(id: $id) { name } }' \
  --variables '{"id": "env-uuid"}'
```

API docs: https://docs.railway.com/api/llms-docs.md

## Authoring guidance

When editing this plugin:

- Keep `SKILL.md` focused on routing, preflight, composition, and common operations.
- Keep references organized by information type (setup, deploy, configure, iac, operate, api).
- Keep references action-oriented with reasoning. Explain why, not only what.
- Keep CLI behavior claims aligned with Railway docs and CLI source.
- Keep a single "Validated against" block at the end of each reference.
- Keep plugin versions aligned across the Claude Code, Codex, Cursor, and Grok (`plugins/railway/.grok-plugin/plugin.json`) manifests when plugin behavior changes.
- For Grok/xAI marketplace entries, use the remote source subpath `plugins/railway` instead of adding root-level symlinks or copies.
- Bump `version` in `plugins/railway/.claude-plugin/plugin.json` in any PR that changes skill content or published plugin behavior. Claude Code uses this version to detect updates, and users will not receive changes without a bump.

## References

- https://code.claude.com/docs/en/skills
- https://code.claude.com/docs/en/plugins
- https://agentskills.io/specification
- https://docs.railway.com/ai/remote-mcp-server
