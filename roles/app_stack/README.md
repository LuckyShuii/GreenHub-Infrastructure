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
3. Creates `/opt/greener/image_dir/`, the AI reference-image dataset (see below) — the only
   artifact here that is NOT rendered by Ansible: its content is uploaded by hand.
4. Pulls images and brings the stack up (`community.docker.docker_compose_v2`).

Everything under `/opt/greener` is owned by `deploy`, the non-human CD account: that is what
lets the recurring deploy re-render these files locally without root. The modes stay
world-readable because the bind mounts are read by container uids, not by `deploy`. The one
exception is `image_dir/`, group `greener` and group-writable — it is fed by a human, not by a
deploy (see below).

DB credentials are never written into the compose file: `${DB_USER/DB_PASSWORD/DB_NAME}` are
interpolated by docker compose from `/opt/greener/.env` (0600, rendered by the backend role),
so the compose stays secret-free.

Requires the **docker** role (engine + compose plugin) and the **backend** role
(renders `/opt/greener/.env`, consumed via `env_file`) to run first.

## Enabling

`app_stack_enabled` is **false** by default, so a deploy never tries to pull images that CI
has not published yet. Flip it per env once the registry images exist (published by CI).

Three things must hold before the pull can succeed, and each fails with its own message:

| symptom | cause |
|---|---|
| `repository does not exist or may require 'docker login'` on `…:backend-<empty>` | no tag could be resolved at all — the assert at the top of this role now catches it first |
| `pull access denied … may require 'docker login'` | root has no registry credentials; the login task below fixes it, but it needs `python3-docker`, so the **docker role must have run at least once on the host** |
| `manifest unknown` | the tag is well-formed and you are authenticated, but CI has never published that image |

`app_stack_services` limits the bring-up to a subset (empty = all). Only **backend** and
**ai** come from the private registry; **postgres**, **qdrant** and the **gateway** run on
public images, so they can be deployed before anything has been published:

```bash
-e '{"app_stack_services": ["gateway", "backend", "postgres"]}'   # leave ai out
```

Compose also starts the `depends_on` of whatever is listed.

Running `--tags app_stack` on its own skips every other role. That is fine on a host already
provisioned, but on a fresh VPS run the whole play first — this role assumes the docker role
(engine, compose plugin, SDK) and the backend role (`/opt/greener/.env`) have run.

## Image tags & deploy model

Registry images live in the private repo `lucasboillot/greenhub`; backend and ai share it and
differ by a tag prefix (`backend-*` / `ai-*`). Tags are keyed by **commit SHA** so a build can be
pinned and rolled back, and the two services are versioned **independently**. `latest` is also
accepted — see the `deploy_version_pattern` note in `group_vars/all/vars.yml` for what it costs.

A tag is resolved per service, in this order:

1. **an explicit override** — `-e app_stack_backend_version=<sha>`;
2. **what this host is already running** — read from `app_stack_state_file`
   (`/opt/greener/deployed-versions.yml`), which this role rewrites after every successful
   bring-up;
3. **`app_stack_bootstrap_version`** (`latest`) — only on a host that has never deployed.

Step 2 is what makes a *targeted* redeploy safe. Rolling only the backend re-renders the whole
compose file, so without a record the `ai` image would silently fall back to the bootstrap tag
while the running container kept the old one — the file would stop describing the host. Reading
the record back means the untargeted service is re-rendered with exactly the tag it is running.

It also answers "what is deployed here" without inspecting digests:

```bash
cat /opt/greener/deployed-versions.yml
```

This role performs the **initial bring-up** (push run from the control host) and is also the
engine of the **recurring** deploy: the `webhook` role installs a daemon that runs `deploy.yml`
locally on the VPS, which calls this role back with `app_stack_services` limited to the
targeted service and its new tag. See `roles/webhook/README.md`.

`app_stack_wait` maps to `docker compose up --wait`. It is **off** for provisioning (a cold AI
start would hold the run for the whole indexing) and **on** for the recurring deploy, so a
broken image fails the deploy instead of returning green.

## Routing

- `/api/*` → `backend:8000/api/*` — **URI forwarded untouched**: the FastAPI app owns the
  `/api` prefix, the gateway only routes. A dev running the backend repo's compose alone
  (no gateway) therefore calls the exact same paths on `localhost:8000`.
- `/ai/*`  → `ai:{{ ai_port }}/*` — prefix **stripped**, because the AI service (owned by
  Houssem) carries no prefix of its own and serves `/greener/...`.
- `/health*` → backend `/health*` — URI forwarded untouched, like `/api`. Prefix, not exact
  match: the tree holds both `/health` (liveness) and `/health/db` (DB reachability), and an
  exact match would 404 the latter at the gateway, never reaching FastAPI.

Anything outside those three prefixes is not routed, so the backend must keep every route
under `/api` (Swagger included) or `/health`.

Upstreams resolve per-request via the Docker DNS resolver, so a service that is down does
not stop the gateway from booting (same resilience as the Caddyfile fallback).

## AI service and qdrant

The AI service embeds the uploaded photo (`facebook/dinov2-large`) and searches a **Qdrant**
collection per region, so qdrant is a hard dependency, not an option.

At **startup** it discovers the region JSON files in `DATA_DIR`, then for every item it does
not already have in qdrant it reads `IMAGES_PER_LABEL` reference images from the local dataset
(`IMAGE_DIR`), embeds them and upserts the vectors. That work runs inside the FastAPI
**lifespan**, i.e. **before uvicorn accepts any connection**: a cold start with an empty
`qdrant_storage` takes many minutes (114 items × `IMAGES_PER_LABEL` images, CPU embedding) and
the service answers nothing until it is done — hence `app_stack_ai_start_period` (20m) on the
healthcheck. Once the volume is warm, indexing is skipped item by item and the start is quick.
**Never `docker volume rm` `qdrant_storage`** unless a full re-index is intended.

Indexing no longer calls out to the internet: the images used to be searched and downloaded at
boot (DuckDuckGo/Bing), that script was removed from the AI repo and the dataset is now read
from disk. A cold boot is self-contained — but it is only as good as what sits in
`/opt/greener/image_dir`.

### The reference-image dataset

`app_stack_ai_image_dir` (`/opt/greener/image_dir`) is bind-mounted **read-only** at
`app_stack_ai_image_mount` (`/greener/image_dir`, which is `IMAGE_DIR` resolved against the AI
image's WORKDIR). It is a **bind mount, not a named volume, on purpose**: the dataset is
content, it does not ship in the image, and it is refreshed by hand — a named volume would put
it out of reach of a plain `scp`.

Layout: **one sub-directory per item, named after the item's `nom`** in the region JSON
(`data/<region>.json`). The match is exact or normalised (non-alphanumeric → `_`, lower case),
so `Bouteille plastique/` and `bouteille_plastique/` both work. Extensions read: jpg, jpeg,
png, bmp, gif, webp, tif, tiff.

```
/opt/greener/image_dir/
├── bouteille_plastique/   1.jpg  2.jpg  3.jpg
├── pot_de_yaourt/         …
└── …
```

The directory is `deploy:greener`, mode `2775` (setgid), so any **greener** admin can refresh
it over the VPN without root and uploads keep the group:

```bash
scp -r ./image_dir/* lboillot@<vps>:/opt/greener/image_dir/
docker compose -f /opt/greener/docker-compose.yml restart ai   # re-index the new labels
```

The dataset was first uploaded by hand, before this role described it: the staging host had it
as `lboillot:greener` mode `2555`, i.e. not even writable by its own owner. The first replay
takes it over (`deploy:greener`, `2775`) and only the top directory — the 114 sub-directories
keep the modes they were uploaded with, so adding an image **inside** an existing item may still
need a `chmod` first. The content is never touched by Ansible.

A restart alone only picks up items **missing** from qdrant (per-item skip). Replacing the
images of an item that is already indexed changes nothing until its points are dropped from the
collection, or `qdrant_storage` is wiped for a full re-index.

An empty or missing dataset does not crash the service: indexing logs
`Dataset directory not found` / `No local images available for '<item>'`, the port still opens,
and every request then answers 422 (no match). So a missing upload fails **silently** from the
gateway's point of view — check the `ai` logs after the first deploy.

**VPS sizing** — measured on the dev stack while indexing: `ai` alone holds ~2.4 GB RSS
(torch + tensorflow + the embedding model) and its image weighs ~3.6 GB; the whole stack sits
around 2.8 GB. A 2 GB VPS cannot run this, and 4 GB leaves little headroom.

## Local dev

For a build-from-source stack, use `docker-compose.dev.yml` at the repo root
(`docker compose -f docker-compose.dev.yml up`). It builds `backend` from its `Dockerfile.dev`
and bind-mounts the source (hot reload); `ai` has only one `dockerfile` (no dev variant, no
reload) and is a heavy build. Assumes the sibling-repo workspace layout.

`ai` there reads the dataset from `../ai-service/image_dir` (gitignored in that repo): drop the
images in it and restart the container, same layout as prod. Without it the mount is an empty
directory and nothing gets indexed.

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

- **`image_dir` must not be `COPY`ed into the image**: `dockerfile` had
  `COPY ./image_dir ./image_dir` while the dataset is gitignored, so it is absent from the CI
  checkout and **every CI build fails** (`"/image_dir": not found`). Removing that line is on
  the AI repo's `fix/LBT-SCRUM-122-image-dir-build`; the dataset comes from the bind mount
  above. Until it is merged, no new `ai-*` image is published at all.

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
- **Dataset ownership**: `/opt/greener/image_dir` is the one piece of state here that Ansible
  does not describe — it is uploaded, not provisioned, so it is not replayable on a fresh VPS
  and is not covered by the backups role. Keep the master copy off the VPS (the AI repo's
  gitignored `image_dir/`). Moving it under infra ownership was rejected for the same reason
  as `data/`: AI content would drift from the image meant to match it.
- **The AI repo's own compose is out of sync with its code**: it mounts `./images` and
  `./backup_images`, which nothing reads, and not `./image_dir` (`IMAGE_DIR`) — their side,
  harmless for us, but it means their compose cannot index anything.
