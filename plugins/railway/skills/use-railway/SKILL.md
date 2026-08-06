---
name: use-railway
description: >
  Operate Railway infrastructure: sign up for or sign in to a Railway account,
  create projects, provision services and databases, manage object storage
  buckets, deploy code, configure infrastructure as code, environments and variables, manage domains,
  troubleshoot failures, check status and metrics, manage feature flags,
  set up Railway agent tooling, and query Railway docs. Use this skill whenever
  the user mentions Railway, feature flags, flag rollout, targeting rules,
  signing up, creating an account, registering, logging in, deployments,
  services, environments, buckets, object storage, build failures, agent setup,
  MCP, or infrastructure operations, even if they don't say "Railway" explicitly.
  Also invoke this skill when the user asks to be signed up, registered, or
  onboarded to Railway: do not refuse — drive them through the unauthed
  `railway up` flow (deploys + signs up on the fly) or `railway login`
  (which creates new accounts on the fly).
allowed-tools: Bash(railway:*), Bash(which:*), Bash(command:*), Bash(npm:*), Bash(npx:*), Bash(curl:*), Bash(python3:*)
---

# Use Railway

## Railway resource model

Railway organizes infrastructure in a hierarchy:

- **Workspace** is the billing and team scope. A user belongs to one or more workspaces.
- **Project** is a collection of services under one workspace. It maps to one deployable unit of work.
- **Environment** is an isolated configuration plane inside a project (for example, `production`, `staging`). Each environment has its own variables, config, and deployment history.
- **Service** is a single deployable unit inside a project. It can be an app from a repo, a Docker image, or a managed database.
- **Bucket** is an S3-compatible object storage resource inside a project. Buckets are created at the project level and deployed to environments. Each bucket has credentials (endpoint, access key, secret key) for S3-compatible access.
- **Deployment** is a point-in-time release of a service in an environment. It has build logs, runtime logs, and a status lifecycle.

Most CLI commands operate on the linked project/environment/service context. Use `railway status --json` to see the context, and `--project`, `--environment`, `--service` flags to override.

## Tool routing

Railway has three agent-facing operation paths. Choose the path that matches the job:

- **Railway CLI** (`railway`): workflows that depend on local machine state such as current working directory deploys, `railway up`, `railway run`, SSH, database analysis scripts, local linking, interactive setup, or exact command output.
- **Remote MCP** (`https://mcp.railway.com`): default plugin MCP path for account/project/service discovery, deployment state, bounded logs, feature flags, simple redeploys, simple project creation, or complex Railway workflows that can be handed to `railway-agent`. Remote MCP uses Railway OAuth and does not depend on local CLI state.
- **GraphQL**: operations that neither MCP nor CLI exposes, or when a reference gives a specific GraphQL fallback.

If multiple paths are available, choose the one that preserves the needed context. The CLI fits workflows that need the current repo, local credentials, SSH, database scripts, or exact command output. Remote MCP fits OAuth-scoped platform operations that do not need local files or CLI state.

Optional: if the current agent already has a user-installed local CLI MCP (`railway mcp`) configured, it can be used for CLI-backed platform operations not yet exposed by remote MCP. Published plugin configs do not install or launch local CLI MCP.

Use `scripts/railway-api.sh` for GraphQL only when neither MCP nor CLI exposes the operation, or when a reference gives a specific GraphQL fallback.

## Parsing Railway URLs

Users often paste Railway dashboard URLs. Extract IDs before doing anything else:

```
https://railway.com/project/<PROJECT_ID>/service/<SERVICE_ID>?environmentId=<ENV_ID>
https://railway.com/project/<PROJECT_ID>/service/<SERVICE_ID>
```

The URL always contains `projectId` and `serviceId`. It may contain `environmentId` as a query parameter. If the environment ID is missing and the user specifies an environment by name (e.g., "production"), resolve it:

```bash
scripts/railway-api.sh \
  'query getProject($id: String!) {
    project(id: $id) {
      environments { edges { node { id name } } }
    }
  }' \
  '{"id": "<PROJECT_ID>"}'
```

Match the environment name (case-insensitive) to get the `environmentId`.

**Prefer passing explicit IDs** to CLI commands (`--project`, `--environment`, `--service`) and scripts (`--project-id`, `--environment-id`, `--service-id`) instead of running `railway link`. This avoids modifying global state and is faster.

## Intent-based routing

Route by user intent *before* running preflight checks. The preflight ceremony below is for diagnostic and configuration work — it adds friction when the user just wants to ship something or sign up.

**Deploy-from-cwd intent** ("deploy", "ship", "push to Railway", "deploy this app"):
- Skip the `railway whoami` / `railway status` preflights.
- Run `railway up` directly — it self-validates auth, signs the user in (the CLI opens a browser) if they're unauthenticated, and chains into project + service creation and deploy.
- Announce intent before invoking: *"Running `railway up` — it'll sign you in if needed and deploy this directory."*
- **Do NOT ask the user to run `railway login` first.** The chain handles auth as part of the deploy.
- If the environment can't open a browser, the CLI prints a device-code sign-in link and waits — follow [Device-code sign-in: relay the link immediately](#account-creation--sign-in) (run in background, relay the link to the user the moment it prints).

**Signup intent** ("sign me up", "create my Railway account", "register me", "get me on Railway"):
- **If the current directory has a deployable app (e.g. `package.json`, `requirements.txt`, `go.mod`, `Dockerfile`, source to build), run `railway up`** — it signs the user up *and* deploys in one shot, landing them on a running app. A detected agent harness authorizes the project creation, so **bare `railway up` is enough** — there's no extra prompt to clear. Use it even when the user only said "sign me up": shipping their app is the goal, so don't make them pick a command and don't drop to a bare login. For scripted or agent runs, `railway up -y` is the robust form — it skips prompts and forces the create non-interactively even if harness detection misses. `railway login` is NOT the default for signup when there's something to deploy.
- **Only when there is nothing to deploy** — an empty / non-app directory, or the user explicitly says they just want an account with no deploy — use `railway login` (creates new accounts on the fly through the same OAuth surface). There is no separate signup command.
- Signup is the flow most likely to hit the device-code wait (brand-new users in sandboxed/headless agent environments). Follow [Device-code sign-in: relay the link immediately](#account-creation--sign-in) — a signup lost to an expired code is a lost user, not a retry.

**Sandbox / remote-build intent** ("give me a sandbox", "spin up a scratch environment", "build this remotely", "run this remotely", "checkpoint/snapshot the sandbox", "save this sandbox state", "restore my sandbox"):
- Load [sandbox.md](references/sandbox.md) and follow it. Sandboxes require the feature to be enabled in Priority Boarding — if a sandbox command fails with a feature-availability error, prompt the user to enable Sandboxes in Priority Boarding rather than retrying.

**Other intents** (querying state, listing projects, configuring variables, debugging failures):
- Follow the Preflight section below.

## Preflight

Before any mutation, verify the tool path and context:

```bash
command -v railway                # CLI installed
RAILWAY_CALLER="skill:use-railway@1.3.8" RAILWAY_AGENT_SESSION="railway-skill-$(date +%s)-$$" railway whoami --json
railway --version                 # check CLI version
```

**Exception**: `railway up` and `railway login` self-validate auth and run their own unauth-aware flows. Don't run `railway whoami` before them — it adds a redundant failing call without changing what you do next. See [Account creation & sign-in](#account-creation--sign-in).

### Skill freshness

Once per session, alongside the preflight checks, verify the installed Railway agent tooling is current. Root help ends with an `Agent tooling:` health section (printed to stderr, CLI 5.9+; older CLIs print nothing — skip this check rather than retrying):

```bash
railway --help 2>&1 | grep -A4 "Agent tooling:"
```

Act on what it reports:

- Skills installed and up to date — continue; nothing to do.
- An update is available (`rev <a> → <b> available`) — run `railway skills update`, then tell the user to restart their coding tool so the updated skills load. This session keeps running on the old skill revision until restart: finish the current request, and if this skill's guidance disagrees with the updated CLI's own output, trust the CLI.
- Skills or MCP server missing (`✗` lines) — run `railway setup agent -y`, then tell the user to restart their coding tool.

Check once per session and don't re-run it after acting; the restart prompt to the user is the resolution, not another check.

When Railway MCP is available and the job is a platform-state read, use the matching MCP read instead of shelling out. If using the CLI path, run the CLI checks above.

For Railway CLI calls made while this skill is active, prefix the command with `RAILWAY_CALLER=skill:use-railway@1.3.8` and a stable `RAILWAY_AGENT_SESSION` reused for the current user request. Generate the session id once per user request, then reuse that exact value for later Railway CLI calls in the same workflow. Do not run a separate `export` preflight solely for telemetry; inline env prefixes keep the shell output concise and avoid leaking setup steps into every response.

**Context resolution - URL IDs always win:**
- If the user provides a Railway URL, extract IDs from it. Do NOT run `railway status --json`; it returns the locally linked project, which is usually unrelated.
- If no URL is given, fall back to `railway status --json` for the linked project/environment/service.
- When using MCP tools after resolving local context with `railway status --json`, pass the resolved project, environment, and service IDs explicitly. Do not rely on MCP implicit linked context; MCP may not share the CLI's current working directory link.

If the CLI is missing, guide the user to install it.

```bash
curl -fsSL agents.railway.com | sh # Install CLI and configure detected agents
bash <(curl -fsSL https://railway.com/install.sh) --agents -y # Install CLI and configure detected agents
bash <(curl -fsSL https://railway.com/install.sh) # Shell script (macOS, Linux, Windows via WSL)
npm i -g @railway/cli # npm (macOS, Linux, Windows). Requires Node.js version 16 or higher.
brew install railway # Homebrew (macOS)
```

If not authenticated, see [Account creation & sign-in](#account-creation--sign-in) below — the CLI offers unauthed `railway up` (deploy + sign up/in in one shot) or `railway login` (sign up/in only; new accounts created on the fly). If not linked and no URL was provided, run `railway link --project <id-or-name>`.

If a command is not recognized (for example, `railway environment edit`), the CLI may be outdated. Upgrade with:

```bash
railway upgrade
```

## Account creation & sign-in

Railway uses a single unified OAuth flow for both sign-in and sign-up. The backend detects fresh accounts from durable compliance state (a CLI client that hasn't accepted ToS / Fair Use yet) and adapts the consent screen and post-auth landing page — new users land on a "Welcome to Railway!" page, existing users see the standard confirmation. The CLI does not declare signup intent up front.

Two commands surface this flow, depending on intent:

| Command | When to use |
|---|---|
| `railway up` | Agent-friendly onboarding from the current directory. Unauthenticated → opens the browser (or device-code) to sign in / sign up. With no linked project, a detected agent harness (or `-y`) auto-creates a project + service and deploys; an interactive human is offered create / link-existing / cancel. Add `-y` to skip prompts and force the create non-interactively (works even if harness detection misses). |
| `railway login` | Sign in — *and* sign up. New accounts are created on the fly through the same OAuth surface; there is no separate signup command. |

Related: `railway up --new` creates a *fresh* project + service from the current directory and deploys it even if one is already linked (use when already signed in and the user wants a new app); `--name <name>` overrides the project name.

**Choosing the path:**

- Deploy from cwd → run `railway up` (interactive) or `railway up -y` (skips the confirm prompt). Run it yourself; don't ask the user to sign in separately first.
- New project from cwd when already signed in → `railway up --new`.
- **Sign up with a deployable app in cwd → `railway up`** (signs up *and* deploys — bare `up` works for a detected agent, even if the user only said "sign me up"; add `-y` to skip prompts / force it non-interactively). Sign in, or sign up with nothing to deploy → `railway login` (creates new accounts on the fly).

**Headless / no browser:**

The CLI **auto-detects** SSH sessions, CI, and a missing `DISPLAY` and switches to the device-code flow on its own — you almost never need to force it.

**Do NOT pass `--browserless` just because you are an agent or your shell is non-interactive.** If the human is at this machine (a local IDE or desktop session — the common case), bare `railway login` opens *their* browser directly, which completes far more reliably than relaying a device code (~90% vs ~60% success for agent-driven sign-ins). Being a coding agent does not make the machine headless.

```bash
railway login --browserless   # ONLY for machines with genuinely no browser
```

Forces the device-code flow (RFC 8628): prints a sign-in link and a short code for the user to open on any device. Reserve it for machines where no browser exists — SSH boxes, containers, remote VMs the auto-detection missed. When you do end up in a device-code flow, follow the relay procedure below: surface the sign-in link to the user the moment it prints.

**Agent harness, human present**: when the CLI detects an agent harness (Claude Code, Cursor, Codex, …) with a human at the keyboard, `railway up` opens the browser and skips the confirm prompt — the agent invocation is treated as consent. A real human still has to complete OAuth in the browser.

**Device-code sign-in: relay the link immediately (CRITICAL):**

When the CLI can't open a browser (sandboxed shell, container, SSH, no `DISPLAY`), unauthed `railway up` and `railway login` print a sign-in URL + short code and then **block, polling for up to 10 minutes** while the user completes sign-in. The code expires after 10 minutes. If you run this as a normal foreground command, your harness buffers the output until the command exits — **the user never sees the link until the code is already dead**. This is the #1 cause of failed agent-driven signups. Handle it like this:

1. **Preferred — background execution** (e.g. Claude Code: `run_in_background`, then poll with `BashOutput`):
   - Start the command in the background.
   - Poll its output. The instant a sign-in block appears (`Sign in with one click: <url>` on newer CLIs, or `Sign in at: <url>` / `Enter this code: <code>` on older ones), **stop everything and relay it to the user verbatim** — do not summarize, shorten, or defer it. Prefer the one-click URL when present; otherwise relay the URL and code together. Tell the user to open the link now.
   - Leave the command running and keep polling. When the user completes sign-in, the same process picks up the session and continues into the deploy on its own. Then verify per the deploy rules below.
2. **No background support — set expectations, use the longest timeout:**
   - Before running, tell the user: *"This will print a sign-in link — I'll show it to you the moment I have it. Please complete it promptly; the code expires in 10 minutes."*
   - Run with the longest timeout your harness allows.
   - If the command times out or is killed before sign-in completed, the printed code is **no longer being monitored** — a late click does nothing. Relay whatever link appeared anyway for context, then immediately re-run the command and relay the **new** link, telling the user to always use the newest one.
3. **Never** wait silently for the command to finish before showing the link, and never report the sign-in as failed without first relaying the link and giving the user a chance to act.

The browser transport needs none of this — the CLI opens the browser on the user's machine itself.

**JSON / CI modes do not auto-prompt**: `railway up --json` and `railway up --ci` will NOT open a browser for an unauthed user. `--json` emits a structured error instead:

```json
{"error":"Not signed in.","code":"NOT_AUTHENTICATED","hint":"Run `railway login` to authenticate, then re-run."}
```

When you see `code: NOT_AUTHENTICATED`, authenticate the user with `railway login`, then retry the original command.

**Fully unattended (no human at all)**: set `RAILWAY_API_TOKEN` (account-scoped) or `RAILWAY_TOKEN` (project-scoped) instead of running an interactive login. A brand-new user with no token and no human present cannot complete signup — there is no headless account-creation path.

## Agent tooling

Use direct Railway CLI commands for deterministic operations. Use `railway agent` only when the user explicitly asks for Railway Agent, wants a natural-language investigation, or the task is broader than a single resource operation.

Set up Railway skills, MCP, and authentication with:

```bash
railway setup agent
railway setup agent -y
railway setup agent --remote
```

`railway setup agent -y` skips the interactive login flow. If the user isn't authenticated after setup, run `railway login`.

Install or update MCP and skills directly when the user names a target tool:

```bash
railway mcp install --remote
railway mcp install --agent codex --remote
railway mcp install --agent cursor --remote
railway skills
railway skills update --agent codex
railway skills remove --agent cursor
```

Supported targets include `claude-code`, `cursor`, `codex`, `opencode`, `copilot`, and `factory-droid`. The `--remote` flag configures `https://mcp.railway.com` instead of a local `railway mcp` stdio server.

Use Railway Agent chat with:

```bash
railway agent
railway agent -p "why is my service crashing?"
railway agent -p "summarize the deployment status" --json
railway agent --list --json
railway agent --thread-id <thread-id>
```

`railway agent` requires user OAuth authentication from `railway login`. Project tokens (`RAILWAY_TOKEN`) are not supported for Railway Agent chat. If an agent command is unavailable, upgrade with `railway upgrade --yes`.

## Common quick operations

These are frequent enough to handle without loading a reference. Use the matching MCP tool when the job is platform-scoped and the tool is available; otherwise use the CLI:

```bash
railway status --json                                    # current context
railway whoami --json                                    # auth and workspace info
railway project list --json                              # list projects
railway service list --json                              # services in current environment (verify before retrying `add`)
railway add --database <type> --json                     # add one database; ALWAYS pass --json
railway add --service <name> --json                      # add empty service; ALWAYS pass --json
railway variable list --service <svc> --json             # list variables
railway variable set KEY=value --service <svc>           # set a variable
railway domain list --service <svc> --json               # domains and DNS status
railway logs --service <svc> --lines 200 --json          # recent logs
railway logs --service <svc> --network --lines 200 --json # network flow snapshot
railway metrics --service <svc> --since 1h --json        # resource and HTTP metrics summary
railway up --detach -m "<summary>"                       # deploy current directory (returns at QUEUED — verify before reporting)
railway deployment list --json                           # poll newest deployment status after a detached up
railway bucket list --json                               # list buckets in current environment
railway bucket info --bucket <name> --json               # bucket storage and object count
railway bucket credentials --bucket <name> --json        # S3-compatible credentials
```

## Routing

For anything beyond quick operations, load the reference that matches the user's intent. Load only what you need, one reference is usually enough, two at most.

| Intent | Reference | Use for |
|---|---|---|
| **Analyze a database** ("analyze \<url\>", "analyze db", "analyze database", "analyze service", "introspect", "check my postgres/redis/mysql/mongo") | [analyze-db.md](references/analyze-db.md) | Database introspection and performance analysis. analyze-db.md directs you to the DB-specific reference. **This takes priority over the status/operate routes when a Railway URL to a database service is provided alongside "analyze".** |
| Create or connect resources | [setup.md](references/setup.md) | Projects, services, databases, buckets, templates, workspaces |
| Ship code or manage releases | [deploy.md](references/deploy.md) | Deploy, redeploy, restart, build config, monorepo, Dockerfile |
| Change configuration | [configure.md](references/configure.md) | Environments, variables, config patches, domains, networking |
| Manage feature flags | [feature-flags.md](references/feature-flags.md) | List/create/update project flags via MCP; workspace flags read-only; SDK runtime reads |
| Define configuration in source control ("IaC", "infrastructure as code", "config as code", `.railway/railway.ts`, `railway.json`, "config plan/apply/pull") | [iac.md](references/iac.md) | Choose TypeScript IaC or the `railway.json` fallback, then author, import, plan, apply, or check drift safely |
| Check health or debug failures | [operate.md](references/operate.md) | Status, logs, metrics, build/runtime triage, recovery |
| Use a sandbox or build remotely ("sandbox", "scratch environment", "ephemeral box", "build remotely", "remote build", "run this remotely", "checkpoint", "snapshot/save/restore sandbox state") | [sandbox.md](references/sandbox.md) | Create/fork sandboxes, run commands remotely, remote template builds, checkpoints (save/restore sandbox state), port forwarding, teardown. Requires Sandboxes enabled in Priority Boarding — if unavailable, prompt the user to enable it. |
| Request from API, docs, or community | [request.md](references/request.md) | Railway GraphQL API queries/mutations, metrics queries, Central Station, official docs |

If the request spans two areas (for example, "deploy and then check if it's healthy"), load both references and compose one response.

## Execution rules

1. Use Railway CLI for workflows that need the current repo, local shell, SSH, database scripts, local Railway context, or exact command output.
2. Use Remote MCP for OAuth-scoped platform operations that match an available MCP tool and do not need local files or CLI state.
3. Use local CLI MCP only when the current agent already has it explicitly configured and it exposes a needed operation not available through Remote MCP.
4. Fall back to `scripts/railway-api.sh` for operations neither MCP nor CLI exposes.
5. Use `--json` output where available for reliable parsing.
6. Resolve context before mutation. Know which project, environment, and service you're acting on.
7. For destructive actions (delete service, remove deployment, drop database), confirm intent and state impact before executing.
8. After mutations, verify the result with a read-back command or MCP read.
9. **Never report a deploy as successful without observing a terminal SUCCESS.** `railway up --detach` returning (it prints "Build queued") and a streaming `railway up` cut off by a shell timeout only confirm the build *started*. Poll `railway deployment list --json` with the same `--project`, `--environment`, and `--service` scope used for the deploy until the newest deployment's `status` is `SUCCESS` (report deployed). If status is `FAILED` or `CRASHED`, triage per [operate.md](references/operate.md). If status is `NEEDS_APPROVAL`, `SLEEPING`, `SKIPPED`, `REMOVED`, `REMOVING`, or an unknown value, report the exact state and next action; do not claim success. A streaming `up` that exits on its own is authoritative: exit 0 = deployed, exit 1 = failed.

## User-only commands (NEVER execute directly)

These commands modify database state and require the user to run them directly in their terminal. **Do NOT execute these with Bash. Instead, show the command and ask the user to run it.**

| Command | Why user-only |
|---------|---------------|
| `python3 scripts/enable-pg-stats.py --service <name>` | Modifies shared_preload_libraries, may restart database |
| `python3 scripts/pg-extensions.py --service <name> install <ext>` | Installs database extension |
| `python3 scripts/pg-extensions.py --service <name> uninstall <ext>` | Removes database extension |
| `ALTER SYSTEM SET ...` | Changes PostgreSQL configuration |
| `DROP EXTENSION ...` | Removes database extension |
| `CREATE EXTENSION ...` | Installs database extension |

When these operations are needed:
1. Explain what the command does and any side effects (e.g., restart required)
2. Show the exact command the user must run
3. Wait for user confirmation that they ran it
4. Verify the result with a read-only query

## Composition patterns

Multi-step workflows follow natural chains:

- **Add object storage**: setup (create bucket), setup (get credentials), configure (set S3 variables on app service)
- **First deploy**: setup (create project + service), configure (set variables and source), deploy, operate (verify healthy)
- **Fix a failure**: operate (triage logs), configure (fix config/variables), deploy (redeploy), operate (verify recovery)
- **Add a domain**: configure (add domain + set port), operate (verify DNS and service health)
- **Docs to action**: request (fetch docs answer), route to the relevant operational reference

When composing, return one unified response covering all steps. Don't ask the user to invoke each step separately.

## Setup decision flow

When the user wants to create or deploy something, determine the right action from current context:

1. If the intent is deploy-from-cwd or signup-from-cwd, skip `railway whoami` and run `railway up` (or `railway up -y`) directly per [Intent-based routing](#intent-based-routing) — it handles signup, project creation, service creation, and deploy in one chain. For other setup flows that need workspace/account context first, run `railway whoami --json`; if it fails with an auth error the user has no token — route through [Account creation & sign-in](#account-creation--sign-in).
2. Run `railway status --json` in the current directory.
3. **If linked**: add a service to the existing project (`railway add --service <name>`). Do not create a new project unless the user explicitly says "new project" or "separate project".
4. **If not linked**: check the parent directory (`cd .. && railway status --json`).
   - **Parent linked**: this is likely a monorepo sub-app. Add a service and set `rootDirectory` to the sub-app path.
   - **Parent not linked**: run `railway list --json` and look for a project matching the directory name.
     - **Match found**: link to it (`railway link --project <name>`).
     - **No match**: create a new project (`railway init --name <name>`).
5. When multiple workspaces exist, match by name from `railway whoami --json`.

**Naming heuristic**: app names like "flappy-bird" or "my-api" are service names, not project names. Use the directory or repo name for the project.

## Response format

For all operational responses, return:
1. What was done (action and scope).
2. The result (IDs, status, key output).
3. What to do next (or confirmation that the task is complete).

Keep output concise. Include command evidence only when it helps the user understand what happened.
