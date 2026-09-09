# Configure

Manage environments, variables, service config, domains, and networking.

## Environments

### List and switch

```bash
railway environment list --json
railway environment list --ephemeral --json      # only PR environments
railway environment list --no-ephemeral --json   # hide PR environments
railway environment link <environment>           # switch active environment
```

### Create

```bash
railway environment new <name>
railway environment new <name> --duplicate <source-environment>    # clone config from existing
```

Duplicating copies all service configurations and variables from the source environment.

## Variables

### Read, set, and delete

```bash
railway variable list --service <service> --environment <env> --json
railway variable set KEY=value --service <service> --environment <env>
railway variable delete KEY --service <service> --environment <env>
```

Variable changes trigger a redeployment by default. This is usually the desired behavior, since the service picks up the values on restart. Use `--skip-deploys` only when you plan to redeploy or restart separately.

CLI 5.34.2+ accepts an empty assignment such as `railway variable set OPTIONAL_VALUE= --service <service>`. Empty is a value, not a deletion. Before an idempotent delete, list keys and delete only if present.

### Bulk edit with a reviewed diff

CLI 5.48+ opens an editor and presents the changes before applying:

```bash
railway variable edit --project <project-id> --environment <env> --service <service>
railway variable edit --demo                 # offline fixture; no Railway mutation
```

This workflow requires a TTY or an explicitly configured `$EDITOR`/`$VISUAL`. Prefer `set`/`delete` for deterministic agent edits when no editor workflow was requested. Saving the editor is not approval: the CLI shows a redacted diff and asks before applying. Noninteractive apply requires `--yes`; deletions in agent or noninteractive sessions also require `--confirm-destructive`, within the user's approved scope.

Removing a line deletes that variable. Keep `<sealed>` placeholders unchanged to preserve sealed values. Railway-provided variables are comments and cannot be edited. `--reveal` exposes plaintext in the diff; use only when intended. `--skip-deploys` commits changes without triggering deploys.

### Set sensitive values

Use stdin for secrets or values that shouldn't appear in shell history:

```bash
printf "%s" "$SECRET_VALUE" | railway variable set API_KEY --stdin --service <service>
railway variable set API_URL=https://api.example.com --project <project-id> --environment <env> --service <service>
```

### Template syntax

Railway supports interpolation between services and shared variables:

```text
${{KEY}}                                         # same-service variable
${{shared.API_KEY}}                              # shared variable
${{postgres.DATABASE_URL}}                       # variable from another service
${{api.RAILWAY_PRIVATE_DOMAIN}}                  # another service's private domain
```

Wiring example, a frontend connecting to a backend over private networking:

```text
BACKEND_URL=http://${{api.RAILWAY_PRIVATE_DOMAIN}}:${{api.PORT}}
```

### Wiring services together

Each managed database creates connection variables automatically. Reference them from other services using template syntax:

| Database | Variable reference |
|---|---|
| Postgres | `${{Postgres.DATABASE_URL}}` |
| Redis | `${{Redis.REDIS_URL}}` |
| MySQL | `${{MySQL.MYSQL_URL}}` |
| MongoDB | `${{MongoDB.MONGO_URL}}` |

Service names in references are case-sensitive and must match the service name exactly as it appears in the project.

**Public vs private networking decision:**

| Traffic path | Use |
|---|---|
| Browser → API | Public domain |
| Service → Service | Private domain (`RAILWAY_PRIVATE_DOMAIN`) |
| Service → Database | Private (automatic, uses internal DNS) |

**Frontend apps cannot use private networking.** Frontends run in the user's browser, not on Railway's network. They cannot reach `RAILWAY_PRIVATE_DOMAIN` or internal database URLs. Options:

1. **Backend proxy** (recommended): frontend calls a backend API on a public domain, backend connects to the database over the private network.
2. **Public database URL**: use the public connection variable (for example, `${{Postgres.DATABASE_PUBLIC_URL}}`). This requires a TCP proxy on the database service and exposes the database to the internet. Use this only for development or low-sensitivity data.

### Railway-provided variables

These are set automatically at runtime. Availability depends on resource configuration.

**Networking:**

| Variable | Available when |
|---|---|
| `RAILWAY_PUBLIC_DOMAIN` | Public domain is configured |
| `RAILWAY_PRIVATE_DOMAIN` | Always (internal DNS for service-to-service traffic) |
| `RAILWAY_TCP_PROXY_DOMAIN` | TCP proxy is enabled |
| `RAILWAY_TCP_PROXY_PORT` | TCP proxy is enabled |

**Context:**

| Variable | Available when |
|---|---|
| `RAILWAY_PROJECT_ID` | Always |
| `RAILWAY_ENVIRONMENT_ID` | Always |
| `RAILWAY_ENVIRONMENT_NAME` | Always |
| `RAILWAY_SERVICE_ID` | Always |
| `RAILWAY_SERVICE_NAME` | Always |
| `RAILWAY_DEPLOYMENT_ID` | Always |
| `RAILWAY_REPLICA_ID` | Replicas configured |
| `RAILWAY_REPLICA_REGION` | Multi-region configured |

**Git (present when deployed from a linked repo):**

| Variable | Description |
|---|---|
| `RAILWAY_GIT_COMMIT_SHA` | Full commit hash of the deployed revision |
| `RAILWAY_GIT_AUTHOR` | Commit author name |
| `RAILWAY_GIT_COMMIT_MESSAGE` | First line of the commit message |
| `RAILWAY_GIT_BRANCH` | Branch that triggered the deploy |

**Storage (present when a volume is attached):**

| Variable | Description |
|---|---|
| `RAILWAY_VOLUME_MOUNT_PATH` | Filesystem path where the volume is mounted |
| `RAILWAY_VOLUME_NAME` | Name of the attached volume |

Sealed variables are write-only. CLI 5.47.2+ lists their names with `null` in JSON, `<sealed>` in the table, or a comment in KV output. **A null value means the sealed key already exists; do not recreate or clear it as though it were missing.** Ordinary variable output can contain plaintext secrets.

## Service config

Service configuration controls source, build, deploy, and networking settings. There are two ways to mutate it.

### Dot-path patch

For single-field changes:

```bash
railway environment edit --service-config <service> deploy.startCommand "npm start"
railway environment edit --service-config <service> build.buildCommand "npm run build"
railway environment edit --service-config <service> source.rootDirectory "/apps/api"
railway environment edit --service-config <service> deploy.numReplicas 2
railway environment edit --project <project-id> --environment production --service-config <service> deploy.startCommand "npm start"
```

### JSON patch

For multi-field changes or complex structures:

```bash
railway environment edit --json <<'JSON'
{"services":{"<service-id>":{"build":{"buildCommand":"npm run build"},"deploy":{"startCommand":"npm start"}}}}
JSON
```

Resolve exact service IDs from `railway service list --json` before constructing JSON patches. Using names in the JSON payload doesn't work.

### Stage config changes

Stage changes when the user wants to review config before committing it:

```bash
railway environment edit --service-config <service> build.buildCommand "npm run build" --stage
railway environment edit --service-config <service> deploy.startCommand "npm start" --message "Set production start command"
```

Use `--stage` only when the user requests staged config changes. Use regular edits for immediate mutations.

### Config schema (typed paths)

Include only keys you're changing. The full shape:

**Source**: `source.image` (string), `source.repo` (string), `source.branch` (string), `source.rootDirectory` (string), `source.checkSuites` (boolean), `source.commitSha` (string), `source.autoUpdates.type` (string: `disabled`, `patch`, `minor`)

**Build**: `build.builder` (string: `RAILPACK`, `NIXPACKS`, `DOCKERFILE`), `build.buildCommand` (string), `build.dockerfilePath` (string), `build.watchPatterns` (string array), `build.nixpacksConfigPath` (string)

**Deploy**: `deploy.startCommand` (string), `deploy.preDeployCommand` (string), `deploy.healthcheckPath` (string), `deploy.healthcheckTimeout` (integer), `deploy.numReplicas` (integer), `deploy.restartPolicyType` (string: `ON_FAILURE`, `ALWAYS`, `NEVER`), `deploy.restartPolicyMaxRetries` (integer), `deploy.sleepApplication` (boolean), `deploy.cronSchedule` (string), `deploy.multiRegionConfig` (object)

**Multi-region config** structure for `deploy.multiRegionConfig`:

```json
{ "us-west2": { "numReplicas": 2 }, "europe-west4-drams3a": { "numReplicas": 1 } }
```

| Region identifier | Location |
|---|---|
| `us-west2` | US West (Oregon) |
| `us-east4-eqdc4a` | US East (Virginia) |
| `europe-west4-drams3a` | Europe (Netherlands) |
| `asia-southeast1-eqsg3a` | Asia (Singapore) |

Natural language mapping: "add replicas in Europe" → `europe-west4-drams3a`, "US East" → `us-east4-eqdc4a`. When the user doesn't specify a region, query current config first with `railway environment config --json` to see existing region assignments before modifying.

**Variables**: `variables.<KEY>.value` (string), `variables.<KEY>.isOptional` (boolean), `variables.<KEY>.isSealed` (boolean). Delete a variable by setting it to `null`.

**Lifecycle**: `isDeleted` (boolean) removes the service. `isCreated` (boolean) marks as new. Prefer `railway service delete` for normal service deletion.

**Storage**: `volumeMounts.<volume-id>.mountPath` (string), `volumes.<volume-id>.isDeleted` (boolean)

**Buckets**: `buckets.<bucket-id>.region` (string: `sjc`, `iad`, `ams`, `sin`), `buckets.<bucket-id>.isCreated` (boolean), `buckets.<bucket-id>.isDeleted` (boolean). Buckets are created at the project level via `railway bucket create` and deployed to environments via config patches. The CLI handles this automatically, so use `railway bucket` commands

### Shared variables and project-level config

```bash
railway environment edit --json <<'JSON'
{"sharedVariables":{"API_BASE":{"value":"https://example.com"}}}
JSON
```

Shared variables are accessible from any service via `${{shared.KEY}}`.

### Read config

Always inspect before mutating. Config patches merge, so you need to know the state to avoid overwriting fields unintentionally:

```bash
railway environment config --json
```

Verify after mutation to confirm the change took effect:

```bash
railway environment config --json
railway service list --json
```

## Cron schedules

A cron schedule turns a service into a scheduled job: Railway runs the start command on the schedule and expects the process to exit when the task is done.

```bash
railway environment edit --service-config <service> deploy.cronSchedule "0 * * * *"
```

Rules the agent must apply:

- Five-field crontab, evaluated in UTC. Shortest interval is 5 minutes.
- The process must exit and close its connections. If the previous run is still `Active` when the next is due, Railway skips the new run.
- A cron service can share a repo with a web service. Add a second service from the same source and give it its own start command and schedule. Do not set a schedule on the web service itself.
- For a task that must run more often than every 5 minutes or that never exits, use a long-running worker instead. See [Cron Jobs, Background Workers, and Queues](https://docs.railway.com/guides/cron-workers-queues).

## Volumes

A volume is persistent storage mounted at a path inside one service. Data survives redeploys; the container filesystem does not.

```bash
railway volume list
railway volume add --mount-path /data
railway volume update --volume <name-or-id> --mount-path /new/path
railway volume attach --volume <name-or-id> --service <service>
railway volume detach --volume <name-or-id>
railway volume delete --volume <name-or-id>
```

Volume commands act on the linked service. Pass `--service <service>` to target another one.

Rules the agent must apply:

- One volume per service. Replicas cannot be used on a service with a volume.
- The mount path is available in the service as `RAILWAY_VOLUME_MOUNT_PATH`. Write there, not to a relative path.
- Default size follows the plan (Free and Trial 0.5 GB, Hobby 5 GB, Pro 50 GB). Paid plans can grow a volume live; shrinking is not supported.
- Images that run as a non-root user can hit permission errors on the mount. Set `RAILWAY_RUN_UID=0` on the service if that happens.
- For object storage that many services share, use a bucket instead. See [setup.md](setup.md).

## Replicas

Replicas scale a service horizontally. Each replica gets the full resource limits of the plan, and public traffic is distributed across replicas at random within a region.

```bash
railway environment edit --service-config <service> deploy.numReplicas 3
```

For replicas in more than one region, patch `deploy.multiRegionConfig` with the JSON shape in [Config schema](#config-schema-typed-paths). Changing the replica count is a staged change that Railway applies without a full redeploy.

Rules the agent must apply:

- `numReplicas` is an integer. Check current config first with `railway environment config --json`.
- Replicas do not work with volumes. Move state to a database or bucket before scaling out a stateful service.
- No sticky sessions. Keep session state out of process memory.
- Each replica sees `RAILWAY_REPLICA_ID` and, with multi-region, `RAILWAY_REPLICA_REGION`.

## Domains

Use the `railway domain` command for domain lifecycle work. Avoid raw `environment edit` JSON patches for normal domain management.

### Create domains

```bash
railway domain --service <service> --json                  # generate a Railway domain
railway domain example.com --service <service> --json      # add a custom domain
railway domain example.com --service <service> --port 8080 --json
```

One Railway-provided domain is allowed per service. Multiple custom domains are supported. Custom domain creation returns the DNS records to add at the DNS provider. Add both the routing record and ownership verification record exactly as returned.

Requests to a custom domain can return `404` until Railway verifies the ownership `TXT` record. DNS can take up to 72 hours to propagate.

### Inspect and update domains

```bash
railway domain list --service <service> --json
railway domain status example.com --service <service> --json
railway domain update example.com --port 8080 --service <service> --json
railway domain update old-name.up.railway.app --domain new-name --service <service> --json
railway domain certificate retry example.com --service <service> --json
```

Use `status` when DNS or certificate issuance is not healthy. Retry certificate issuance only after fixing DNS.

### Delete domains

```bash
railway domain delete example.com --service <service> --yes --json
```

Domain deletion is destructive. Confirm the domain and service before running it.

## Networking commands

### Private networking

For service-to-service traffic within a project, use private domain references instead of public URLs. This avoids egress and is faster:

```text
BACKEND_URL=http://${{api.RAILWAY_PRIVATE_DOMAIN}}:${{api.PORT}}
```

```bash
railway private-network status --service <service> --json
railway private-network update api-internal --service <service> --json
```

When multiple private networks exist, pass `--network <name-or-id>`. Endpoint updates take the prefix only, without `.internal`.

### TCP proxies

Use TCP proxies to expose non-HTTP ports, such as database or game server ports, to the public internet. Only one TCP proxy is allowed per service instance.

```bash
railway tcp-proxy list --service <service> --json
railway tcp-proxy create --service <service> --port 5432 --json
railway tcp-proxy status <proxy-id-or-domain-or-port> --service <service> --json
railway tcp-proxy delete <proxy-id-or-domain-or-port> --service <service> --yes --json
```

TCP proxy creation updates service networking config. If the proxy does not become active, redeploy the service and check status.

### Outbound networking

Use outbound networking commands for Static Outbound IPs and outbound IPv6:

```bash
railway outbound-network status --service <service> --json
railway outbound-network static-ip status --service <service> --json
railway outbound-network static-ip enable --service <service> --json
railway outbound-network static-ip disable --service <service> --json
railway outbound-network ipv6 status --service <service> --json
railway outbound-network ipv6 enable --service <service> --json
railway outbound-network ipv6 disable --service <service> --json
```

Static Outbound IP changes are committed directly but require a redeploy before outbound traffic uses the new assignment. Outbound IPv6 changes are staged as environment config changes; commit staged changes with `railway environment edit` to trigger the redeploy.

### CDN caching

CDN caching is service-scoped and requires an applied public domain.

```bash
railway cdn status --service <service> --json
railway cdn enable --service <service> --json
railway cdn update --service <service> --html-caching force --default-ttl 4h --json
railway cdn update --service <service> --no-swr --purge-on-deploy all --json
railway cdn purge html --service <service> --json
railway cdn purge all --service <service> --json
railway cdn disable --service <service> --json
```

Use the response headers `x-cache` and `age` to verify cache behavior. Cache hits do not reach the service, so service logs and server-side metrics can undercount traffic after caching is enabled.

### WAF Under Attack Mode

Under Attack Mode is service-scoped, requires an applied public domain, and is intended for active bot floods or DDoS events.

```bash
railway waf under-attack status --service <service> --json
railway waf under-attack enable --service <service> --duration 1h --json
railway waf under-attack enable --service <service> --json
railway waf under-attack disable --service <service> --json
```

While active, browser visitors must pass a check. Non-browser API clients and webhooks may receive `429` responses, so warn the user before enabling it on API-only domains.

## Troubleshoot configuration

- **Invalid dot-path**: check field names and types in the config schema section above
- **Wrong service key in JSON patch**: resolve service IDs from `railway service list --json`
- **Variable change didn't take effect**: verify with `railway variable list`, changes trigger redeploy by default
- **Domain returns errors**: run `railway domain status`, verify the target port, then check HTTP logs
- **DNS propagation delay**: custom domains can take up to 72 hours to propagate worldwide
- **Cloudflare proxy issues**: align SSL/TLS mode per Railway's domain guidance
- **Private networking failing**: run `railway private-network status`, verify the service is listening on the referenced port, and check network flow logs
- **Outbound allowlist still sees old IPs**: redeploy after enabling/disabling Static Outbound IPs
- **IPv6 still disabled**: commit the staged environment change and wait for redeploy
- **CDN appears ineffective**: check `x-cache`, `age`, cache headers, `Set-Cookie`, `Authorization`, method, and response size
- **WAF breaks API clients**: Under Attack Mode blocks non-browser traffic; disable it or scope protection to browser-facing services
- **Multi-region patch ignored**: verify region names match the exact identifiers (`us-west2`, `us-east4-eqdc4a`, `europe-west4-drams3a`, `asia-southeast1-eqsg3a`)

## Validated against

- Docs: [cron-jobs.md](https://docs.railway.com/cron-jobs), [volumes.md](https://docs.railway.com/volumes), [volumes/reference.md](https://docs.railway.com/volumes/reference), [scaling.md](https://docs.railway.com/deployments/scaling), [volume.md](https://docs.railway.com/cli/volume), [environment.md](https://docs.railway.com/cli/environment), [variable.md](https://docs.railway.com/cli/variable), [domain.md](https://docs.railway.com/cli/domain), [tcp-proxy.md](https://docs.railway.com/cli/tcp-proxy), [private-network.md](https://docs.railway.com/cli/private-network), [outbound-network.md](https://docs.railway.com/cli/outbound-network), [cdn.md](https://docs.railway.com/cli/cdn), [waf.md](https://docs.railway.com/cli/waf)
- CLI source: [volume.rs](https://github.com/railwayapp/cli/blob/v5.49.1/src/commands/volume.rs), [environment/mod.rs](https://github.com/railwayapp/cli/blob/v5.23.3/src/commands/environment/mod.rs), [environment/edit.rs](https://github.com/railwayapp/cli/blob/v5.23.3/src/commands/environment/edit.rs), [variable.rs](https://github.com/railwayapp/cli/blob/v5.49.1/src/commands/variable.rs), [domain.rs](https://github.com/railwayapp/cli/blob/v5.23.3/src/commands/domain.rs), [tcp_proxy.rs](https://github.com/railwayapp/cli/blob/v5.23.3/src/commands/tcp_proxy.rs), [private_network.rs](https://github.com/railwayapp/cli/blob/v5.23.3/src/commands/private_network.rs), [outbound_networking.rs](https://github.com/railwayapp/cli/blob/v5.23.3/src/commands/outbound_networking.rs), [cdn.rs](https://github.com/railwayapp/cli/blob/v5.23.3/src/commands/cdn.rs), [waf.rs](https://github.com/railwayapp/cli/blob/v5.23.3/src/commands/waf.rs)
