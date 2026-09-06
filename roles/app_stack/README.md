# app_stack role

Deploys the GREENER application stack with docker compose: **postgres** + **backend** +
**ai** behind an **internal nginx gateway**, on the isolated `greener_internal` network.
Only the gateway is published (on loopback), and the host-facing **Caddy** reverse-proxies
to it. Postgres publishes no port — it is reachable only by the other services (and via VPN
for debugging).

```
WAN → Caddy (host, 80/443, TLS) → gateway (nginx, 127.0.0.1:8080) → backend / ai
                                                                       backend → postgres
```

## What it does

1. Renders `/opt/greener/docker-compose.yml` (app images pulled from the registry; postgres
   from the official PostGIS image).
2. Ships the gateway config to `/opt/greener/gateway/default.conf.template` (rendered by the
   nginx image's `envsubst` from `BACKEND_UPSTREAM` / `AI_UPSTREAM`) and the postgres init
   scripts to `/opt/greener/postgres-init/`.
3. Pulls images and brings the stack up (`community.docker.docker_compose_v2`).

DB credentials are never written into the compose file: `${DB_USER/DB_PASSWORD/DB_NAME}` are
interpolated by docker compose from `/opt/greener/.env` (0600, rendered by the backend role),
so the compose stays secret-free.

Requires the **docker** role (engine + compose plugin) and the **backend** role
(renders `/opt/greener/.env`, consumed via `env_file`) to run first.

## Enabling

`app_stack_enabled` is **false** by default, so a deploy never tries to pull images that CI
has not published yet. Flip it per env once the registry images exist (published by CI).

## Image tags & deploy model

Registry images live in the private repo `lucasboillot/greenhub`; backend and ai share it and
differ by a tag prefix (`backend-*` / `ai-*`). Tags are keyed by **commit SHA** (not `:latest`)
so a build can be pinned and rolled back, and the two services are versioned **independently**
via `app_stack_backend_version` / `app_stack_ai_version` (`latest` is only a bootstrap default).

This role performs the **initial bring-up** (push run from the control host). The **recurring**
deploy is a separate concern (webhook + `deploy.yml` running locally on the VPS): the CI, after
pushing an image, POSTs to `…/hooks/deploy-backend` | `deploy-ia`; the daemon runs
`docker compose pull` + `docker compose up -d <service>` for the targeted service with the new
SHA. The compose here is written to support that targeted, per-service redeploy.

## Routing

- `/api/*` → `backend:8000`
- `/ai/*`  → `ai:{{ ai_port }}`
- `/health` → backend `/health` (stack liveness through the gateway)

Upstreams resolve per-request via the Docker DNS resolver, so a service that is down does
not stop the gateway from booting (same resilience as the Caddyfile fallback).

## Local dev

For a build-from-source, hot-reload stack, use `docker-compose.dev.yml` at the repo root
(`docker compose -f docker-compose.dev.yml up`). It builds `backend`/`ai` from their repos'
`Dockerfile.dev` and bind-mounts the source. Assumes the sibling-repo workspace layout.

## Pending / cross-team

- **AI `/health`**: the AI service (owned by Houssem) has no health endpoint yet; the `ai`
  container uses a stopgap TCP port-liveness check. Replace with a real `/health` probe once
  it exists.
- **AI model volume**: `ai_models` is mounted at `/root/.cache/huggingface` (default HF
  cache). Confirm the path with the AI owner if the image changes it (`HF_HOME`).
