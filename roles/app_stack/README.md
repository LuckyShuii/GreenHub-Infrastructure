# app_stack role

Deploys the GREENER application stack with docker compose: **postgres** + **backend** +
**ai** + **qdrant** behind an **internal nginx gateway**, on the isolated `greener_internal`
network. Only the gateway is published (on loopback), and the host-facing **Caddy**
reverse-proxies to it. Postgres and qdrant publish no port — they are reachable only by the
other services (and via VPN for debugging).

```
WAN → Caddy (host, 80/443, TLS) → gateway (nginx, 127.0.0.1:8080) → backend / ai
                                                                       backend → postgres
                                                                       ai      → qdrant
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

- `/api/*` → `backend:8000/api/*` — **URI forwarded untouched**: the FastAPI app owns the
  `/api` prefix, the gateway only routes. A dev running the backend repo's compose alone
  (no gateway) therefore calls the exact same paths on `localhost:8000`.
- `/ai/*`  → `ai:{{ ai_port }}/*` — prefix **stripped**, because the AI service (owned by
  Houssem) carries no prefix of its own and serves `/greener/...`.
- `/health` → backend `/health` (stack liveness through the gateway)

Anything outside those three prefixes is not routed, so the backend must keep every route
under `/api` (Swagger included) or `/health`.

Upstreams resolve per-request via the Docker DNS resolver, so a service that is down does
not stop the gateway from booting (same resilience as the Caddyfile fallback).

## AI service and qdrant

The AI service embeds the uploaded photo (`facebook/dinov2-small`) and searches a **Qdrant**
collection per region, so qdrant is a hard dependency, not an option.

At **startup** it discovers the region JSON files in `DATA_DIR`, then for every item it does
not already have in qdrant it searches and downloads reference images, embeds them and
upserts the vectors. That work runs inside the FastAPI **lifespan**, i.e. **before uvicorn
accepts any connection**: a cold start with an empty `qdrant_storage` takes many minutes
(114 items × `IMAGES_PER_LABEL` images, CPU embedding) and the service answers nothing until
it is done — hence `app_stack_ai_start_period` (20m) on the healthcheck. Once the volume is
warm, indexing is skipped item by item and the start is quick. **Never `docker volume rm`
`qdrant_storage`** unless a full re-index is intended.

Egress note: that indexing calls out to the internet (image search + downloads), so the VPS
needs outbound HTTPS; it is not a self-contained boot. The searches hit DuckDuckGo first and
fall back to Bing when rate-limited (403s in the logs are expected, not a failure).

**VPS sizing** — measured on the dev stack while indexing: `ai` alone holds ~2.4 GB RSS
(torch + tensorflow + the embedding model) and its image weighs ~3.6 GB; the whole stack sits
around 2.8 GB. A 2 GB VPS cannot run this, and 4 GB leaves little headroom.

## Local dev

For a build-from-source stack, use `docker-compose.dev.yml` at the repo root
(`docker compose -f docker-compose.dev.yml up`). It builds `backend` from its `Dockerfile.dev`
and bind-mounts the source (hot reload); `ai` has only one `dockerfile` (no dev variant, no
reload) and is a heavy build. Assumes the sibling-repo workspace layout.

## Pending / cross-team

Blocks the first AI deploy, on the AI repo (owned by Houssem — do not change it here):

- **`data/` must be in the image**: `dockerfile` copied `src/`, `main.py`, `configs.py` and
  `logging_config.py` but not `data/`, while `DATA_DIR=./data`. In prod the image is pulled
  with no source checkout, so region discovery raised `FileNotFoundError`, indexing was
  skipped and every request answered 404 "unknown region". Fixed by a `COPY ./data ./data`
  on the AI repo's `fix/LBT-SCRUM-117-copy-data-image` — **do not enable `ai` in prod until
  that branch is merged and an image built from it is published.** The region files must
  come from the image, not from here: shipping them from infra would put AI content under
  infra ownership and let it drift from the image it is supposed to match.

Non-blocking:

- **AI `/health`**: still no health endpoint; the TCP port-liveness check is a fine
  stand-in — the port only opens once the app is serving. What it cannot express is
  "serving but degraded", and because indexing runs in the lifespan the probe really means
  "done indexing" on a cold start. It only starts to matter for the CD auto-rollback rule
  (healthcheck KO > 2 min), which cannot judge a cold first boot behind a 20m start period.

- **Image size**: `dockerfile` is single-stage (despite the `AS builder` label) and runs
  `uv sync --locked` without `--no-dev`, so pytest/ruff ship in the production image, on top
  of torch + tensorflow + keras.
- **`QDRANT_VERSION`**: pinned twice — `app_stack_qdrant_image` here and the AI repo's
  `.env.example`. Bump them together. We use the official image, not its `qdrant.dockerfile`
  (which exists only to add `curl` for a healthcheck), so CI has no third image to publish.
- **AI model volume**: `ai_models` is mounted at `/root/.cache/huggingface` (default HF
  cache). Confirm the path with the AI owner if the image changes it (`HF_HOME`).
- **`IMAGE_BACKUP_DIR`**: the downloaded images are written but never read back, so nothing
  is persisted for them here (`SAVE_IMAGES=false` in prod). Note the AI repo's own compose
  mounts `./backup_images` while the code writes to `./image_backup` — a mismatch on their
  side, harmless for us.
